#!/usr/bin/env python3
"""Offline follow-up controller, conversation persistence and AppKit layout checks."""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile

from source_files import ROOT, app_path, app_source, swift_fixture_args
MAIN = app_source('main.swift')
STORAGE = (ROOT / 'langmin/Sources/LangminShared/LangminStorage.swift').read_text()


# block(marker): Extract one brace-balanced production declaration for this
# isolated Swift fixture.
def block(marker):
    start = MAIN.index(marker)
    end = MAIN.index('{', start) + 1
    depth = 1
    # Include nested blocks when finding the end of the extracted declaration.
    while depth:
        depth += (MAIN[end] == '{') - (MAIN[end] == '}')
        end += 1
    return MAIN[start:end]


source = r'''
import Cocoa
// Represent fixture failures using the app’s localized-error contract.
struct HelperFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
// localized(key, english): Resolve labels through the fixture’s controlled
// localization.
func localized(_ key: String, _ english: String) -> String { english }
// ACTUAL_EXPLANATION_PROMPT
struct Option { let id: String; let displayValue: String }
// Control web-research preferences without reading the user's settings.
struct Preferences { var webResearchEnabled = true }
var preferences = Preferences()
// loadAppPreferences(): Provide the preferences configured by this fixture.
func loadAppPreferences() -> Preferences { preferences }
var enabledModels: Set<String> = ["cloud", "apple", "other"]
// enabledExplanationModelOptions([preferences = Preferences()]): Expose only
// model IDs enabled by the fixture's current selection.
func enabledExplanationModelOptions(_ preferences: Preferences = Preferences()) -> [Option] {
 [Option(id: "cloud", displayValue: "Cloud"), Option(id: "apple", displayValue: "Apple"), Option(id: "other", displayValue: "Other Provider")].filter { enabledModels.contains($0.id) }
}
// defaultEnabledExplanationModel(preferences): Provide a deterministic default
// model for follow-up fallback checks.
func defaultEnabledExplanationModel(_ preferences: Preferences) -> String { "cloud" }
// preferenceDisplayValue(id, options): Resolve the fixture's model identifier
// to its display label.
func preferenceDisplayValue(for id: String, options: [Option]) -> String { options.first { $0.id == id }!.displayValue }
// Distinguish local generation from two independent remote providers.
enum Provider { case apple, cloud, other }
// textProvider(model): Map fixture models to providers so switching and consent
// can be tested.
func textProvider(for model: String) -> (provider: Provider, model: String) { (model == "apple" ? .apple : (model == "other" ? .other : .cloud), model) }
// modelProviderSectionName(provider): Use provider identifiers as predictable
// menu section labels.
func modelProviderSectionName(_ provider: Provider) -> String { String(describing: provider) }
// modelSupportsWebResearch(model): Enable research for only the designated
// fixture model.
func modelSupportsWebResearch(_ model: String) -> Bool { model == "cloud" }
// ACTUAL_LANGUAGE_LEVEL
struct Destination { let consentID: String }
var destination = Destination(consentID: "original.example")
// remoteTextDestination(model): Model on-device requests without a remote
// destination and remote requests with a mutable endpoint.
func remoteTextDestination(for model: String) -> Destination? { model == "apple" ? nil : destination }
var confirmation: () -> Bool = { true }
var scanned = ""
var confirmedModels: [String] = []
// confirmRemoteTextSharingIfNeeded(input, model): Assert main-thread consent
// handling and return the fixture's configured response.
func confirmRemoteTextSharingIfNeeded(input: String, model: String) -> Bool {
 precondition(Thread.isMainThread)
 scanned = input
 confirmedModels.append(model)
 return confirmation()
}
'''
source += block('final class TextRequestHandle {') + '\n'
source += block('let langminControlBorderColor =') + '\n'
source += block('final class NativeSeparator:') + '\n'
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['enum PaletteAction {', 'struct PaletteItem {', 'enum PaletteRow {', 'struct PalettePage {']:
    source += block(marker) + '\n'
source += r'''
// Represent model-picker lifetime without opening a native palette.
final class LauncherPalettePanel {
 var onClose: (() -> Void)?
 var onCommandComma: (() -> Void)?
 // init(anchorProvider, width): Accept palette geometry without constructing
 // its window.
 init(anchorProvider: @escaping () -> NSRect, width: CGFloat) {}
 // closePalette(): Invoke the close callback so focus-restoration code can be
 // exercised.
 func closePalette() { onClose?() }
 // present(page, parent): Keep this production dependency inactive in the
 // isolated fixture.
 func present(page: PalettePage, over parent: NSWindow) {}
}
// Capture a follow-up prompt, model, and completion for controlled responses.
final class Request {
 let model: String
 let prompt: ExplanationPrompt
 let research: Bool
 let completion: (Result<String, Error>) -> Void
 var resumed = false
 var cancelled = false
 // init(model, prompt, research, completion): Retain the full request contract
 // for subsequent assertions.
 init(model: String, prompt: ExplanationPrompt, research: Bool, completion: @escaping (Result<String, Error>) -> Void) {
  self.model = model; self.prompt = prompt; self.research = research; self.completion = completion
 }
}
var requests: [Request] = []
var beforeStart: (() throws -> Void)?
// startTextRequest(model, prompt, emptyMessage, research, completion): Record
// the request on the main thread instead of contacting a model provider.
func startTextRequest(model: String, prompt: ExplanationPrompt, emptyMessage: String, research: Bool, completion: @escaping (Result<String, Error>) -> Void) throws -> TextRequestHandle {
 precondition(Thread.isMainThread)
 try beforeStart?()
 let request = Request(model: model, prompt: prompt, research: research, completion: completion)
 requests.append(request)
 return TextRequestHandle(resume: { request.resumed = true }, cancel: { request.cancelled = true })
}
// Retain the result and conversation fields consumed by production follow-up code.
struct Config {
 var conversation: ResultConversation?
 var textModel: String? = "Cloud"
 var languageLevel = "a"
 var mode = "explain"
 let fontSize: CGFloat = 15
}
// Supply the launcher action target without opening or closing real results.
final class Launcher {
 // libraryDidChange(): Keep this production dependency inactive in the isolated
 // fixture.
 func libraryDidChange() {}
 // allModelsPage(): Provide an empty full-catalog page without requiring real
 // model discovery.
 func allModelsPage() -> PalettePage { PalettePage(rows: { _ in [] }) }
}
// Supply launcher access and record fixture-level app dependencies.
final class Delegate {
 let launcherController = Launcher()
 var activeSession: ViewerSession?
 // showPreferences(sender): Keep this production dependency inactive in the
 // isolated fixture.
 func showPreferences(_ sender: Any?) {}
 // ACTUAL_PLAYBACK_KEY_ROUTER
}
// Offscreen windows have no WindowServer number. Supply their event target
// directly while exercising the production playback router.
final class FixtureEvent: NSEvent {
 var fixtureWindow: NSWindow?
 var fixtureKeyCode: UInt16 = 0
 override var window: NSWindow? { fixtureWindow }
 override var keyCode: UInt16 { fixtureKeyCode }
 override var modifierFlags: NSEvent.ModifierFlags { [] }
}
// Round-trip conversations in memory to exercise their Codable contract.
enum LibraryStore {
 static var saved: [String: ResultConversation] = [:]
 static var fails = false
 // setConversation(id, conversation): Persist an isolated conversation snapshot
 // or inject a disk-style failure.
 static func setConversation(id: String, conversation: ResultConversation) throws {
  // Exercise the path that receives an answer but cannot save it.
  if fails { throw HelperFailure(message: "Fixture disk failure") }
  saved[id] = try JSONDecoder().decode(ResultConversation.self, from: JSONEncoder().encode(conversation))
 }
}
// Control pointer location for deterministic paragraph-action hover tests.
final class FixtureConversationTextView: ResultConversationTextView {
 var fixtureMouseLocation: NSPoint?
 override var followUpMouseLocation: NSPoint? { fixtureMouseLocation }
}
// Host production follow-up state and rendering with controlled dependencies.
final class ViewerSession: NSObject {
 // beginTextEditing(replyID): Keep this production dependency inactive in the
 // isolated fixture.
 func beginTextEditing(replyID: String?) {}
 var config: Config
 let content = "The product is cheaper at Best Buy. Source: https://example.test/product"
 var followUpComposer: ResultFollowUpComposer?
 var followUpDraft = ""
 var followUpError: String?
 var followUpTask: TextRequestHandle?
 var followUpRunID: UUID?
 var followUpPendingQuestion: String?
 var followUpSelectedModelID: String?
 var followUpRequestModel: (id: String, name: String)?
 var followUpModelPanel: LauncherPalettePanel?
 var resourcesReleased = false
 var savedLibraryID: String?
 var appDelegate: Delegate? = Delegate()
 var diffShown = false
 // updateResultViewButtons(): Keep this production dependency inactive in the
 // isolated fixture.
 func updateResultViewButtons() {}
 var textView: NSTextView? = FixtureConversationTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
 var narrationSegments: [Int] = []
 var audioAvailable = true
 var playbackActions = 0
 var copied = ""
 // copyToClipboard(value): Record copied reply text without touching the system
 // clipboard.
 func copyToClipboard(_ value: String) { copied = value }
 // togglePlayback(sender): Count playback toggles to detect shortcuts stolen
 // from the composer.
 func togglePlayback(_ sender: Any?) { playbackActions += 1 }
 // seekAudio(seconds): Count seek actions to detect arrow keys incorrectly
 // routed to playback.
 func seekAudio(by seconds: Double) { playbackActions += 1 }
 // ACTUAL_PLAIN_TEXT_EXPORT
 // init([mode = "explain"], [legacy = false]): Configure a new or legacy
 // fixture result with the requested mode.
 init(mode: String = "explain", legacy: Bool = false) {
  config = Config(conversation: legacy ? nil : ResultConversation(originalRequest: "Is this product expensive?", modelID: "cloud"))
  config.mode = mode
  textView?.linkTextAttributes = [.cursor: NSCursor.pointingHand]
 }
 // ACTUAL_PARAGRAPH_STYLE
 // viewerTextAttributes(size, color, paragraphStyle): Apply the supplied
 // paragraph metrics and text appearance in the fixture.
 func viewerTextAttributes(size: CGFloat, color: NSColor, paragraphStyle: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
  [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraphStyle]
 }
 // markdownAttributedText(text): Match production paragraph metrics and its
 // removal of trailing newlines.
 func markdownAttributedText(from text: String) -> NSAttributedString { NSAttributedString(string: text.trimmingCharacters(in: .newlines), attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: viewerParagraphStyle()]) }
 // clearNarrationHighlight(): Keep this production dependency inactive in the
 // isolated fixture.
 func clearNarrationHighlight() {}
 // applyNarrationCursorAttributes(segments): Keep this production dependency
 // inactive in the isolated fixture.
 func applyNarrationCursorAttributes(for segments: [Int]) {}
 // applyResultText(): Render the main result and its follow-ups with the
 // production conversation renderer.
 func applyResultText() {
  let rendered = NSMutableAttributedString(attributedString: markdownAttributedText(from: content))
  appendFollowUps(to: rendered)
  textView?.textStorage?.setAttributedString(rendered)
  (textView as? ResultConversationTextView)?.updateFollowUpActivity()
 }
}
var checks = 0
// check(condition, message): Report failed fixture expectations with their case
// names.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
 // Stop this fixture when its named expectation does not hold.
 guard condition() else { fputs("FAILED: " + message + "\n", stderr); exit(1) }
 checks += 1
}
// drain(): Yield briefly for queued follow-up completions and UI updates.
func drain() async { try? await Task.sleep(nanoseconds: 20_000_000) }

// tests(): Exercise follow-up prompting, persistence, deletion, focus, and
// layout offline.
@MainActor func tests() async throws {
 _ = NSApplication.shared
 let root = URL(fileURLWithPath: CommandLine.arguments[1])
 // Check conversation behavior in every launcher mode.
 for mode in ["proofread", "rewrite", "explain", "summarize", "translate", "dictionary"] {
  let viewer = ViewerSession(mode: mode)
  viewer.followUpDraft = "Can that store deliver to Serbia?"
  viewer.submitFollowUp()
  let request = requests.last!
  check(request.resumed && request.research && request.model == "cloud", "Follow-up uses the original model and available research in " + mode)
  let payload = try JSONSerialization.jsonObject(with: Data(request.prompt.input.utf8)) as! [String: Any]
  check(payload["original_mode"] as? String == mode && payload["original_request"] as? String == "Is this product expensive?", "Original mode and request reach context")
  check(request.prompt.input.contains("Best Buy") && scanned.contains("Best Buy"), "The answer and its source are available to follow-up and secret scan")
  check(request.prompt.conversationMessages.map(\.role) == [.user, .assistant, .user] && request.prompt.conversationMessages.last?.content == viewer.followUpDraft, "Each mode sends native roles with the latest question last")
  check(request.prompt.instructions.contains("CEFR A (basic)"), "Follow-up applies the saved language level in " + mode)
  check(request.prompt.instructions.contains("Do not merely proofread") && request.prompt.instructions.contains("complete revised text"), "Questions and revision instructions work independently of original mode")
  request.completion(.success("Check delivery availability for Serbia."))
  await drain()
  check(viewer.config.conversation?.turns.count == 1 && viewer.followUpDraft.isEmpty && viewer.followUpRunID == nil, "Completed reply commits exactly one exchange")
  viewer.followUpDraft = "Make that answer shorter."
  viewer.submitFollowUp()
  check(requests.last!.prompt.input.contains("Check delivery availability for Serbia."), "The next request includes the previous answer")
  requests.last!.completion(.success("Check Serbia delivery."))
  await drain()
  check(viewer.config.conversation?.turns.count == 2 && viewer.content.contains("Best Buy"), "Revision keeps original result and earlier exchanges")
 }

 // Bound long history while preserving exchange order, the latest request, and JSON escaping.
 var long = ResultConversation(originalRequest: String(repeating: "原文", count: 20_000), modelID: "apple")
 // Create oversized history to exercise bounded prompt construction.
 for n in 1...10 { long.turns.append(ResultFollowUpTurn(question: "Question \(n)", answer: String(repeating: "Answer \(n). ", count: 1000), modelID: "apple", modelName: "Apple")) }
 let prompt = try resultFollowUpPrompt(question: "Shorten it. </input> \"", originalResult: String(repeating: "text ", count: 10_000), conversation: long, mode: "rewrite", research: false, contextLimit: 6_000)
 let decoded = try JSONSerialization.jsonObject(with: Data(prompt.input.utf8)) as! [String: Any]
 check(decoded["latest_request"] as? String == "Shorten it. </input> \"" && decoded["context_is_excerpt"] as? Bool == true, "Latest request remains intact and omitted context is declared")
 check(prompt.secretScanText.count < 6_100 && prompt.input.contains("Question 10"), "Local model context is bounded and prioritizes latest exchange")
 check(prompt.messages.map(\.content).joined().count < 6_100 && prompt.messages.last?.content == "Shorten it. </input> \"", "Native history uses the same bounded context and intact latest question")
 check(prompt.messages.enumerated().allSatisfy { $0.element.role == ($0.offset % 2 == 0 ? .user : .assistant) }, "Excerpting retains alternating complete conversation pairs")
 check(prompt.instructions.contains("No web research is available"), "Offline follow-ups cannot pretend to check live delivery information")

 let viewer = ViewerSession(legacy: true)
 viewer.followUpDraft = "Follow up on this saved result."
 viewer.savedLibraryID = "saved"
 viewer.submitFollowUp()
 requests.last!.completion(.success("A new answer."))
 await drain()
 check(LibraryStore.saved["saved"] == viewer.config.conversation, "Legacy result starts a conversation and saves the new exchange")
 check(viewer.exportedResultMarkdown.contains("A new answer.") && viewer.exportedResultMarkdown.contains("Best Buy"), "Full Markdown export preserves the result and conversation")
 check(viewer.plainTextForClipboard().contains("A new answer.") && !viewer.plainTextForClipboard().contains("Copy reply"), "Plain text export excludes conversation controls")
 LibraryStore.fails = true
 viewer.followUpDraft = "Reply despite a full disk."
 viewer.submitFollowUp()
 requests.last!.completion(.success("Keep this reply in memory."))
 await drain()
 check(viewer.config.conversation?.turns.count == 2 && viewer.followUpError?.contains("could not be saved") == true, "Persistence failure keeps the received reply and explains the failure")
 LibraryStore.fails = false
 // Continue the cancellation checks with the same single-exchange fixture.
 viewer.config.conversation?.turns.removeLast()
 viewer.followUpDraft = "Keep this draft."
 viewer.submitFollowUp()
 let cancelled = requests.last!
 viewer.cancelFollowUp()
 cancelled.completion(.success("Late answer must not appear."))
 await drain()
 check(cancelled.cancelled && viewer.followUpDraft == "Keep this draft." && viewer.config.conversation?.turns.count == 1, "Cancellation keeps draft and ignores late completion")
 viewer.submitFollowUp()
 requests.last!.completion(.failure(HelperFailure(message: "Provider failed")))
 await drain()
 check(viewer.followUpDraft == "Keep this draft." && viewer.followUpError == "Provider failed" && viewer.config.conversation?.turns.count == 1, "Failure allows retry without a half exchange")
 viewer.submitFollowUp()
 let closing = requests.last!
 viewer.resourcesReleased = true
 viewer.cancelFollowUp()
 closing.completion(.success("Closed result must not change."))
 await drain()
 check(closing.cancelled && viewer.config.conversation?.turns.count == 1, "Closing a result cancels its own follow-up")

 let denied = ViewerSession()
 denied.followUpDraft = "Don't send without consent."
 let count = requests.count
 confirmation = { false }
 denied.submitFollowUp()
 check(requests.count == count && denied.followUpRunID == nil && !denied.followUpDraft.isEmpty, "Denied sharing sends no model request")
 confirmation = { destination = Destination(consentID: "changed.example"); return true }
 denied.submitFollowUp()
 check(requests.count == count && denied.followUpError != nil, "Endpoint changes inside consent require a fresh request")
 confirmation = { true }
 denied.followUpDraft = String(repeating: "x", count: 4001)
 denied.submitFollowUp()
 check(requests.count == count && denied.followUpError != nil, "Oversized question is rejected without silently truncating it")
 let first = ViewerSession(), second = ViewerSession()
 first.followUpDraft = "First result"; second.followUpDraft = "Second result"
 first.submitFollowUp(); let a = requests.last!
 second.submitFollowUp(); let b = requests.last!
 b.completion(.success("Second reply")); a.completion(.success("First reply"))
 await drain()
 check(first.config.conversation?.turns.last?.answer == "First reply" && second.config.conversation?.turns.last?.answer == "Second reply", "Concurrent result conversations remain isolated")
 let local = ViewerSession()
 local.config.conversation?.modelID = "apple"
 local.followUpDraft = "Explain this."
 local.submitFollowUp()
 check(requests.last!.model == "apple" && !requests.last!.research, "Apple model stays local and has no research tools")
 local.cancelFollowUp()

 // Picker choices affect this conversation's next request. The original
 // answer, historical model labels and other viewers remain unchanged.
 let switching = ViewerSession()
 let choices = switching.followUpModelPage().rows("").compactMap { row -> PaletteItem? in
  // Extract selectable palette items while excluding headings and separators.
  if case .item(let item) = row { return item }; return nil
 }
 check(Set(choices.map(\.id)) == ["cloud", "apple", "other", "all-models"], "Picker offers every enabled model and the full catalog")
 let beforeSelection = requests.count
 switching.followUpDraft = "Could a different model check this?"
 _ = choices.first { $0.id == "other" }!.action?()
 check(switching.followUpModel().id == "other" && requests.count == beforeSelection, "Choosing another provider does not send a request")
 switching.savedLibraryID = "switched"
 switching.submitFollowUp()
 let otherRequest = requests.last!
 check(otherRequest.model == "other" && !otherRequest.research && confirmedModels.last == "other", "Switched model uses its own research capability and consent checks")
 check(otherRequest.prompt.input.contains("Best Buy") && switching.followUpDraft.contains("different model"), "Switching keeps the draft and original context")
 switching.selectFollowUpModel("apple")
 enabledModels.remove("other")
 check(switching.followUpModel().id == "other" && switching.followUpSelectedModelID == "other", "Pending request keeps its captured model despite Settings or selection changes")
 otherRequest.completion(.success("An answer from another provider."))
 await drain()
 check(switching.config.conversation?.turns.last?.modelID == "other" && switching.config.textModel == "Cloud", "Reply records its actual provider without relabeling the original result")
 check(switching.followUpModel().id == "cloud", "Disabled models fall back to an enabled model after completion")
 enabledModels.insert("other")
 switching.selectFollowUpModel("apple")
 switching.followUpDraft = "Now explain that on device."
 switching.submitFollowUp()
 check(requests.last!.model == "apple" && requests.last!.prompt.input.contains("An answer from another provider."), "Local models can continue a cloud conversation with its history")
 requests.last!.completion(.success("An on-device follow-up."))
 await drain()
 let reopened = ViewerSession()
 reopened.config.conversation = LibraryStore.saved["switched"]
 check(reopened.followUpModel().id == "apple" && reopened.config.conversation?.turns.map(\.modelID) == ["other", "apple"], "Saved conversation resumes with its last used model and preserves mixed-provider history")
 // Exercise the real language rule through the controller after reopening
 // and changing providers, including unconstrained older/Proofread results.
 for level in ["a", "b", "c", "off"] {
  reopened.config.languageLevel = level
  // Check follow-up model selection across local and distinct remote providers.
  for model in ["cloud", "apple", "other"] {
   reopened.selectFollowUpModel(model)
   reopened.followUpDraft = "Explain the same idea again."
   reopened.submitFollowUp()
   let instructions = requests.last!.prompt.instructions
   let rule = languageLevelInstruction(level)
   check(rule.isEmpty ? !instructions.contains("Language level: CEFR") : instructions.hasSuffix(rule), "Reopened result preserves level \(level) when switching to \(model)")
   reopened.cancelFollowUp()
  }
 }
 check(ViewerSession().followUpModel().id == "cloud", "Model choice stays independent of other results")
 switching.selectFollowUpModel("not-enabled")
 check(switching.followUpModel().id == "apple", "Unknown or disabled picker choices are ignored")

 // A nested consent loop can dismiss this request and start another. The
 // outer failure must never clear the replacement request's state.
 let reentrant = ViewerSession()
 reentrant.followUpDraft = "First request"
 beforeStart = {
  beforeStart = nil
  reentrant.cancelFollowUp()
  reentrant.followUpDraft = "Replacement request"
  reentrant.submitFollowUp()
  throw HelperFailure(message: "Obsolete request failed")
 }
 reentrant.submitFollowUp()
 let replacement = requests.last!
 check(reentrant.followUpRunID != nil && reentrant.followUpError == nil && replacement.resumed, "Reentrant request survives an obsolete outer failure")
 replacement.completion(.success("Replacement answer"))
 replacement.completion(.success("Duplicate callback"))
 await drain()
 check(reentrant.config.conversation?.turns.count == 1 && reentrant.config.conversation?.turns.first?.answer == "Replacement answer", "Repeated provider completion cannot append duplicate replies")

 // click(link, session): Test rendered controls, forged links, partial
 // exchanges, save failures, and stale callbacks.
 func click(_ link: String, in session: ViewerSession) {
  let view = session.textView!
  let storage = view.textStorage!
  var index: Int?
  storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
   // Locate the first matching attributed action link for simulated clicks.
   if value as? String == link && index == nil { index = range.location }
  }
  check(index != nil, "Native conversation action is rendered: " + link.components(separatedBy: ":")[0])
  check(session.handleFollowUpLink(link, in: view, at: index!), "Native action is handled inside the result")
 }
 let removal = ViewerSession()
 let firstTurn = ResultFollowUpTurn(question: "Question one", answer: "Answer one", modelID: "cloud", modelName: "Cloud")
 let secondTurn = ResultFollowUpTurn(question: "Question two", answer: "Answer two", modelID: "other", modelName: "Other Provider")
 removal.config.conversation?.turns = [firstTurn, secondTurn]
 removal.savedLibraryID = "deletion"
 removal.applyResultText()
 click("langmin-followup-copy:" + firstTurn.id, in: removal)
 check(removal.copied == firstTurn.answer, "Copy reply still copies only its answer")
 let forged = "langmin-followup-delete-reply:" + firstTurn.id
 let forgedIndex = removal.textView!.textStorage!.length
 removal.textView!.textStorage!.append(NSAttributedString(string: "Delete", attributes: [.link: forged]))
 _ = removal.handleFollowUpLink(forged, in: removal.textView!, at: forgedIndex)
 check(removal.config.conversation?.turns == [firstTurn, secondTurn], "Model-authored action URLs cannot delete messages")
 click(forged, in: removal)
 check(removal.config.conversation?.turns[0].answer == "" && removal.config.conversation?.turns[0].question == firstTurn.question, "Delete reply removes only its answer")
 check(!removal.textView!.string.contains(firstTurn.answer) && !removal.exportedResultMarkdown.contains(firstTurn.answer) && !removal.plainTextForClipboard().contains(firstTurn.answer), "Deleted answer disappears from rendering and both exports")
 click("langmin-followup-delete-question:" + secondTurn.id, in: removal)
 check(removal.config.conversation?.turns[1].question == "" && removal.config.conversation?.turns[1].answer == secondTurn.answer, "Delete question retains its answer")
 check(!removal.textView!.string.contains(secondTurn.question) && removal.textView!.string.contains(secondTurn.answer), "Remaining answer renders without the deleted question label")
 check(LibraryStore.saved["deletion"] == removal.config.conversation, "Individual deletions persist through conversation encoding")
 LibraryStore.fails = true
 click("langmin-followup-delete-question:" + firstTurn.id, in: removal)
 check(removal.config.conversation?.turns[0].question == firstTurn.question && removal.followUpError?.contains("could not be deleted") == true, "Failed saved deletion retains the message and reports the failure")
 LibraryStore.fails = false
 removal.followUpDraft = "Continue with remaining messages."
 removal.submitFollowUp()
 let outdated = requests.last!
 check(!outdated.prompt.input.contains(firstTurn.answer) && !outdated.prompt.input.contains(secondTurn.question) && !scanned.contains(firstTurn.answer), "Subsequent requests and secret scan exclude deleted text")
 check(outdated.prompt.conversationMessages.map(\.role) == [.user, .assistant, .user, .assistant, .user, .assistant, .user], "Partial exchanges preserve valid provider role boundaries")
 click("langmin-followup-delete-question:" + firstTurn.id, in: removal)
 outdated.completion(.success("Obsolete answer"))
 await drain()
 check(outdated.cancelled && removal.config.conversation?.turns.count == 1 && removal.config.conversation?.turns.first?.id == secondTurn.id, "Deletion cancels work using old history and late completion cannot restore it")
 check(removal.followUpDraft == "Continue with remaining messages.", "Cancelling old-context generation preserves the draft for retry")
 removal.submitFollowUp()
 let pending = requests.last!
 let pendingText = removal.textView!.string as NSString
 let pendingHeader = pendingText.range(of: "You", options: .backwards).location
 check(!pendingText.substring(from: pendingHeader).contains("Delete"), "Pending question has no delete control before its answer is complete")
 removal.cancelFollowUp()
 pending.completion(.success("Cancelled pending reply"))
 await drain()
 check(pending.cancelled && !removal.followUpDraft.isEmpty && removal.followUpPendingQuestion == nil && removal.config.conversation?.turns.count == 1, "Stop still cancels a pending question and keeps its draft")
 removal.submitFollowUp()
 requests.last!.completion(.success("Finished reply"))
 await drain()
 let completedID = removal.config.conversation!.turns.last!.id
 click("langmin-followup-delete-question:" + completedID, in: removal)
 click("langmin-followup-delete-reply:" + completedID, in: removal)
 click("langmin-followup-delete-reply:" + secondTurn.id, in: removal)
 check(removal.config.conversation?.turns.isEmpty == true && LibraryStore.saved["deletion"]?.turns.isEmpty == true, "Deleting both sides removes the empty exchange from saved history")
 check(removal.exportedResultMarkdown == removal.content && removal.plainTextForClipboard() == removal.content, "A fully deleted conversation exports only the original result")

 // hover(snippet, view): Show controls only for the hovered message without
 // moving the surrounding text.
 func hover(_ snippet: String?, in view: FixtureConversationTextView) {
  // Move the fixture pointer onto the requested rendered text.
  if let snippet {
   let range = (view.string as NSString).range(of: snippet)
   check(range.location != NSNotFound, "Hover target exists")
   let manager = view.layoutManager!, container = view.textContainer!
   manager.ensureLayout(for: container)
   let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
   let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
   view.fixtureMouseLocation = NSPoint(x: view.textContainerOrigin.x + rect.midX, y: view.textContainerOrigin.y + rect.midY)
  } else {
      // Clear simulated pointer location when testing the absence of hover.
   view.fixtureMouseLocation = nil
  }
  view.updateFollowUpActionHover(at: view.fixtureMouseLocation, force: true, showAll: false)
 }
 // visibleActions(view): Collect only currently visible follow-up action links.
 func visibleActions(in view: NSTextView) -> Set<String> {
  var links = Set<String>()
  let storage = view.textStorage!
  storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
   // Ignore hidden or unrelated attributed links when checking available actions.
   if let link = value as? String, link.hasPrefix("langmin-followup-"),
      let color = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor,
      color.alphaComponent > 0 { links.insert(link) }
  }
  return links
 }
 let hovering = ViewerSession()
 hovering.config.conversation?.turns = [firstTurn, secondTurn]
 hovering.applyResultText()
 let hoverView = hovering.textView as! FixtureConversationTextView
 let originalString = hoverView.string
 hoverView.layoutManager!.ensureLayout(for: hoverView.textContainer!)
 let originalHeight = hoverView.layoutManager!.usedRect(for: hoverView.textContainer!).height
 check(visibleActions(in: hoverView).isEmpty, "Completed controls are hidden before hovering")
 hover(firstTurn.question, in: hoverView)
 check(visibleActions(in: hoverView) == ["langmin-followup-delete-question:" + firstTurn.id], "Question block hover reveals only its Delete control")
 hoverView.fixtureMouseLocation!.x = hoverView.bounds.maxX - 10
 hoverView.updateFollowUpActionHover(at: hoverView.fixtureMouseLocation)
 check(visibleActions(in: hoverView).count == 1, "Blank space beside question text belongs to the same hover block")
 hover(firstTurn.answer, in: hoverView)
 check(visibleActions(in: hoverView) == ["langmin-followup-copy:" + firstTurn.id, "langmin-followup-edit:" + firstTurn.id, "langmin-followup-delete-reply:" + firstTurn.id], "Reply block hover reveals its Copy, Edit and Delete controls")
 hoverView.layoutManager!.ensureLayout(for: hoverView.textContainer!)
 check(hoverView.string == originalString && hoverView.layoutManager!.usedRect(for: hoverView.textContainer!).height == originalHeight, "Hover changes neither text nor layout height")
 hover(nil, in: hoverView)
 check(visibleActions(in: hoverView).isEmpty, "Leaving the block hides all follow-up controls")
 hover(hovering.content, in: hoverView)
 check(visibleActions(in: hoverView).isEmpty, "Original result hover does not expose follow-up controls")
 hovering.followUpPendingQuestion = "Pending follow-up"
 hovering.followUpRunID = UUID()
 hovering.applyResultText()
 hover("Pending follow-up", in: hoverView)
 check(visibleActions(in: hoverView).isEmpty, "Hovering a pending question never reveals Delete")
 hovering.followUpPendingQuestion = nil
 hovering.followUpRunID = nil
 hovering.applyResultText()
 hoverView.setFrameSize(NSSize(width: 320, height: 700))
 hover(secondTurn.answer, in: hoverView)
 check(visibleActions(in: hoverView) == ["langmin-followup-copy:" + secondTurn.id, "langmin-followup-edit:" + secondTurn.id, "langmin-followup-delete-reply:" + secondTurn.id], "Hover follows the message after resizing and reflow")
 hoverView.updateFollowUpActionHover(at: nil, force: true, showAll: true)
 check(visibleActions(in: hoverView).count == 8, "VoiceOver can expose every completed message action")
 hover(nil, in: hoverView)
 let hoverScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
 hoverScroll.documentView = hoverView
 hover(secondTurn.answer, in: hoverView)
 check(visibleActions(in: hoverView).isEmpty, "Offscreen message controls remain hidden")
 hoverScroll.contentView.scroll(to: NSPoint(x: 0, y: hoverView.fixtureMouseLocation!.y - 30))
 await drain()
 check(visibleActions(in: hoverView) == ["langmin-followup-copy:" + secondTurn.id, "langmin-followup-edit:" + secondTurn.id, "langmin-followup-delete-reply:" + secondTurn.id], "Scrolling re-evaluates the block without a mouse-move event")

 // Native key events belong to the focused composer even with audio loaded.
 let keyboardWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
 keyboardWindow.isReleasedWhenClosed = false
 let keyboardSession = ViewerSession()
 keyboardSession.installFollowUpComposer(in: keyboardWindow.contentView!)
 keyboardWindow.contentView!.layoutSubtreeIfNeeded()
 let editor = keyboardSession.followUpComposer!.input
 keyboardWindow.makeFirstResponder(editor)
 let delegate = Delegate()
 delegate.activeSession = keyboardSession
 // key(code, characters, [modifiers = []]): Create a key event addressed to the
 // fixture's keyboard window.
 func key(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
  NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: keyboardWindow.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
 }
 // Verify that Space and arrow keys remain with the focused follow-up editor.
 for event in [key(49, " "), key(123, "\u{f702}"), key(124, "\u{f703}")] {
  let targeted = FixtureEvent()
  targeted.fixtureWindow = keyboardWindow
  targeted.fixtureKeyCode = event.keyCode
  check(delegate.handleKeyDown(targeted) != nil && keyboardSession.playbackActions == 0, "Typing Space and arrows does not trigger playback")
 }
 var submissions = 0
 keyboardSession.followUpComposer!.onSubmit = { submissions += 1 }
 editor.keyDown(with: key(36, "\r"))
 editor.keyDown(with: key(36, "\r", .command))
 check(submissions == 2, "Return and Command-Return submit a follow-up")
 editor.keyDown(with: key(36, "\r", .shift))
 check(submissions == 2 && editor.string.contains("\n"), "Shift-Return inserts a newline")
 keyboardSession.followUpComposer!.update(draft: "Waiting", busy: true, model: "Cloud", error: nil)
 editor.keyDown(with: key(36, "\r"))
 check(submissions == 2, "Repeated Return cannot accidentally cancel a pending reply")
 keyboardWindow.close()

 // Anchor the animation to the pending glyph. Animation must not rebuild reply text; resizing must
 // reposition it.
 let activityWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
 activityWindow.isReleasedWhenClosed = false
 let pendingSession = ViewerSession()
 let pendingBody = pendingSession.textView as! ResultConversationTextView
 pendingBody.isHorizontallyResizable = false
 pendingBody.textContainer?.widthTracksTextView = true
 pendingBody.autoresizingMask = [.width]
 activityWindow.contentView = pendingBody
 pendingSession.followUpPendingQuestion = "Could you rewrite that answer with a much shorter and friendlier explanation?"
 pendingSession.applyResultText()
 let activity = pendingBody.followUpActivity!
 activity.updateAnimation(reduceMotion: false)
 let dots = activity.layer!.sublayers!
 let animations = dots.compactMap { $0.animation(forKey: "typing") as? CAAnimationGroup }
 check(animations.count == 3 && animations.allSatisfy { $0.repeatCount == .infinity }, "Three dots animate continuously while waiting")
 check(animations[0].beginTime < animations[1].beginTime && animations[1].beginTime < animations[2].beginTime, "Staggered animation makes a traveling wave")
 check(!pendingBody.string.contains("Replying…") && pendingBody.string.contains("friendlier"), "Animated activity replaces the static body label")
 let oldY = activity.frame.minY
 pendingBody.setFrameSize(NSSize(width: 240, height: 400))
 pendingBody.updateFollowUpActivity()
 check(activity.frame.minY > oldY && activity.frame.maxX <= pendingBody.bounds.width, "Activity follows wrapping in a narrow result")
 check(pendingBody.followUpActivity === activity, "Layout keeps the same animation and phase")
 activity.updateAnimation(reduceMotion: true)
 check(dots.allSatisfy { $0.animationKeys()?.isEmpty != false }, "Reduce Motion stops every dot animation")
 activity.updateAnimation(reduceMotion: false)
 pendingSession.followUpPendingQuestion = nil
 pendingSession.applyResultText()
 check(pendingBody.followUpActivity == nil && activity.superview == nil && dots.allSatisfy { $0.animationKeys()?.isEmpty != false }, "Completion removes the indicator and stops its animation")
 activityWindow.close()

 // Render narrow and wide layouts in both appearances without accessing the running app.
 for width in [320, 700] {
  // Exercise each conversation layout in light and dark appearances.
  for dark in [false, true] {
   let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
   host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
   host.wantsLayer = true
   host.layer?.backgroundColor = (dark ? NSColor(calibratedWhite: 0.09, alpha: 1) : .white).cgColor
   let session = ViewerSession()
   session.installFollowUpComposer(in: host)
   // Scope the pending conversation used by the layout snapshot.
   do {
    session.config.conversation?.turns = [ResultFollowUpTurn(question: "Can that store deliver to Serbia?", answer: "Check the store's current international shipping policy and the delivery options for this product. Availability may depend on the seller and destination.", modelID: "cloud", modelName: "Cloud")]
    session.followUpPendingQuestion = "Make that answer shorter."
    session.followUpRunID = UUID()
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 96, width: width, height: 504))
    scroll.drawsBackground = false
    let body = session.textView!
    body.frame = NSRect(x: 0, y: 0, width: width, height: 504)
    body.drawsBackground = false
    body.isEditable = false
    body.isVerticallyResizable = true
    body.textContainerInset = NSSize(width: 22, height: 24)
    body.textContainer?.widthTracksTextView = true
    body.textContainer?.containerSize = NSSize(width: width - 44, height: Int.max)
    scroll.documentView = body
    host.addSubview(scroll)
    session.applyResultText()
   }
   host.layoutSubtreeIfNeeded()
   let composer = session.followUpComposer!
   check(composer.frame.width == CGFloat(width) && composer.frame.height == 96, "Composer fits result width")
   composer.input.string = "Can Best Buy deliver to Serbia?"
   composer.textDidChange(Notification(name: NSText.didChangeNotification, object: composer.input))
   check(session.followUpDraft == composer.input.string, "Composer updates its session draft")
   // Use the dark variant to additionally exercise the busy composer state.
   if dark { composer.update(draft: session.followUpDraft, busy: true, model: "Cloud", error: nil) }
   check(composer.input.isEditable != dark, "Busy composer prevents duplicate editing while keeping cancel available")
   check(composer.modelButton.isEnabled != dark, "Model picker is available between replies and disabled while sending")
   let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
   host.cacheDisplay(in: host.bounds, to: bitmap)
   try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("followup-\(width)-\(dark ? "dark" : "light").png"))
   let conversationView = session.textView as! FixtureConversationTextView
   // Check paragraph actions independently on user questions and assistant replies.
   for (kind, snippet) in [("question", "Can that store deliver to Serbia?"), ("reply", "Check the store's current")] {
    hover(snippet, in: conversationView)
    host.displayIfNeeded()
    let hoverBitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: hoverBitmap)
    try hoverBitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("followup-hover-\(kind)-\(width)-\(dark ? "dark" : "light").png"))
   }
   hover(nil, in: conversationView)
   host.displayIfNeeded()
   composer.update(draft: "", busy: false, model: "Cloud", error: nil)
   let send = composer.subviews.compactMap { $0 as? ResultFollowUpSendButton }.first!
   check(!send.isEnabled && !send.isBusy, "Empty draft keeps its send action disabled")
   let emptyBitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
   host.cacheDisplay(in: host.bounds, to: emptyBitmap)
   try emptyBitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("followup-empty-\(width)-\(dark ? "dark" : "light").png"))
   // Exercise long model names and errors at the narrowest composer width.
   if width == 320 {
    composer.update(draft: session.followUpDraft, busy: false, model: "A custom model with an exceptionally long name", error: "The selected provider is unavailable. Try another model.")
    host.layoutSubtreeIfNeeded()
    check(composer.frame.height == 114 && composer.modelButton.isEnabled && composer.modelButton.frame.maxX < host.bounds.width, "Failure keeps the picker visible and fits long model names")
    let failureBitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: failureBitmap)
    try failureBitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("followup-error-\(dark ? "dark" : "light").png"))
   }
  }
 }
 print("\(checks) follow-up checks passed; no model calls or credentials used")
}
var finished = false
Task { @MainActor in
 // Run the asynchronous cases and report unexpected failures.
 do { try await tests() } catch { fputs("Unexpected failure: \(error)\n", stderr); exit(1) }
 finished = true
}
// Keep the main run loop responsive until asynchronous fixture work finishes.
while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
'''
source = source.replace('// ACTUAL_PLAYBACK_KEY_ROUTER', block('    func handleKeyDown(_ event: NSEvent) -> NSEvent?'))
source = source.replace('// ACTUAL_PLAIN_TEXT_EXPORT', block('    func plainTextForClipboard()'))
source = source.replace('// ACTUAL_PARAGRAPH_STYLE', block('    func viewerParagraphStyle('))
source = source.replace('// ACTUAL_EXPLANATION_PROMPT', block('struct ExplanationPrompt {'))
source = source.replace('// ACTUAL_LANGUAGE_LEVEL', STORAGE[STORAGE.index('let defaultLanguageLevel ='):STORAGE.index('// Human-readable list used in secret-protection alerts.')])
with tempfile.TemporaryDirectory(prefix='langmin-followup-tests-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', *swift_fixture_args(), '-O', '-module-cache-path', cache, '-target', f'{platform.machine()}-apple-macos14.0',
                    str(folder / 'main.swift'), str(app_path('ResultConversation.swift')),
                    str(app_path('ResultFollowUp.swift')), '-o', str(folder / 'tests')], check=True)
    subprocess.run([str(folder / 'tests'), directory], check=True, timeout=60)
    # Retain rendered artifacts only when a destination was explicitly requested.
    if target := os.environ.get('LANGMIN_TEST_ARTIFACTS'):
        output = Path(target)
        output.mkdir(parents=True, exist_ok=True)
        # Copy rendered fixture artifacts to the explicitly requested output directory.
        for artifact in folder.glob('followup-*.png'):
            shutil.copyfile(artifact, output / artifact.name)
