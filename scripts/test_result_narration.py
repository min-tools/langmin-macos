#!/usr/bin/env python3
"""Check conversation narration and sentence highlights with offline speech fixtures."""
from pathlib import Path
import os
import platform
import subprocess
import tempfile

from source_files import ROOT, app_path, app_source, swift_fixture_args
MAIN = app_source('main.swift')


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
import NaturalLanguage
let root = URL(fileURLWithPath: CommandLine.arguments[1])
// Control narration highlighting and model choice entirely inside the fixture.
struct Preferences { var narrationHighlightMode = false; var ttsModel = "fixture" }
var preferences = Preferences()
var sharingAllowed = true
var failTemporaryDirectory = false
// loadAppPreferences(): Provide the preferences configured by this fixture.
func loadAppPreferences() -> Preferences { preferences }
// Represent the speech providers exercised by narration routing tests.
enum NarrationProvider: String { case apple, grok, openAI }
// narrationProvider(voice): Resolve fixture voice names directly into their
// selected provider.
func narrationProvider(for voice: String) -> NarrationProvider { NarrationProvider(rawValue: voice)! }
// confirmRemoteNarrationSharingIfNeeded(provider): Return the test-controlled
// sharing decision without opening a dialog.
func confirmRemoteNarrationSharingIfNeeded(provider: NarrationProvider) -> Bool { sharingAllowed }
// loadGrokAPIKey(): Supply a non-secret xAI credential placeholder for offline
// request checks.
func loadGrokAPIKey() -> String { "fixture" }
// loadOpenAIAPIKey(): Supply a non-secret OpenAI credential placeholder.
func loadOpenAIAPIKey() -> String { "fixture" }
// appleVoiceIdentifier(voice): Preserve the fixture's Apple voice identifier.
func appleVoiceIdentifier(from voice: String) -> String { voice }
// grokVoiceID(voice): Preserve the fixture's Grok voice identifier.
func grokVoiceID(from voice: String) -> String { voice }
// ttsModel(voice, requestedModel): Keep the explicitly requested speech model
// in recorded requests.
func ttsModel(forVoice voice: String, requestedModel: String) -> String { requestedModel }
// narrationModelLabel(provider, model): Use a predictable narration-model label
// for metadata checks.
func narrationModelLabel(provider: NarrationProvider, model: String) -> String { model }
// refreshVoiceCatalogAfterUse(provider): Keep this production dependency
// inactive in the isolated fixture.
func refreshVoiceCatalogAfterUse(provider: NarrationProvider) {}
// createLangminTemporaryDirectory(prefix): Create isolated output directories
// with an injectable allocation failure.
func createLangminTemporaryDirectory(prefix: String) throws -> URL {
 // Exercise a narration failure before any request can be started.
 if failTemporaryDirectory { throw NSError(domain: "fixture", code: 1) }
 let url = root.appendingPathComponent(prefix + UUID().uuidString)
 try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
 return url
}
// Provide the minimal cancellable request interface used by production narration.
protocol NarrationRequestTask: AnyObject, Sendable { /* resume(): Start or resume the speech task supplied by the implementation. */ func resume(); /* cancel(): Cancel the speech task supplied by the implementation. */ func cancel() }
// Record a narration request and let the test decide when it finishes.
final class Request: NarrationRequestTask, @unchecked Sendable {
 let text: String, provider: NarrationProvider, output: URL
 let completion: (Result<Void, Error>) -> Void
 var resumed = false, cancelled = false
 // init(text, provider, output, completion): Capture request text, provider,
 // destination, and completion for later assertions.
 init(_ text: String, _ provider: NarrationProvider, _ output: URL, _ completion: @escaping (Result<Void, Error>) -> Void) {
  self.text = text; self.provider = provider; self.output = output; self.completion = completion
 }
 // resume(): Record that the narration request was resumed.
 func resume() { resumed = true }
 // cancel(): Record that narration cancellation reached the task.
 func cancel() { cancelled = true }
 // finish(): Write a stand-in audio file before reporting simulated success.
 func finish() throws { try Data([0]).write(to: output); completion(.success(())) }
}
// Supply the HUD playback dependency without starting a second audio engine.
final class ClipboardHUDPlayback {
 // clear(): Keep this production dependency inactive in the isolated fixture.
 func clear() {}
}
var requests: [Request] = []
// record(text, provider, output, completion): Append a simulated request to the
// fixture's request history.
func record(_ text: String, _ provider: NarrationProvider, _ output: URL, _ completion: @escaping (Result<Void, Error>) -> Void) -> NarrationRequestTask {
 let request = Request(text, provider, output, completion); requests.append(request); return request
}
// startAppleSpeechRequest(text, voiceIdentifier, outputURL, completion): Record
// Apple speech routing without invoking the system synthesizer.
func startAppleSpeechRequest(text: String, voiceIdentifier: String, outputURL: URL, completion: @escaping (Result<Void, Error>) -> Void) throws -> NarrationRequestTask {
 record(text, .apple, outputURL, completion)
}
// startGrokSpeechRequest(apiKey, text, voiceID, outputURL, completion): Record
// Grok speech routing without network access.
func startGrokSpeechRequest(apiKey: String, text: String, voiceID: String, outputURL: URL, completion: @escaping (Result<Void, Error>) -> Void) throws -> NarrationRequestTask {
 record(text, .grok, outputURL, completion)
}
// startSpeechRequest(apiKey, text, model, voice, outputURL, completion): Record
// OpenAI speech routing without contacting the provider.
func startSpeechRequest(apiKey: String, text: String, model: String, voice: String, outputURL: URL, completion: @escaping (Result<Void, Error>) -> Void) throws -> NarrationRequestTask {
 record(text, .openAI, outputURL, completion)
}
@MainActor var chunkRequests: [(chunks: [String], provider: NarrationProvider)] = []
// synthesizeChunkedNarration(chunks, voice, apiKey, provider, model, tempDir,
// registerTask): Record requested chunks and return deterministic audio with
// matching timing data.
func synthesizeChunkedNarration(chunks: [String], voice: String, apiKey: String, provider: NarrationProvider, model: String, tempDir: URL, registerTask: @escaping @Sendable (NarrationRequestTask) -> Void) async throws -> (audioURL: URL, timings: [NarrationChunkTiming]) {
 await MainActor.run { chunkRequests.append((chunks, provider)) }
 let audio = tempDir.appendingPathComponent("narration.m4a")
 try Data([0]).write(to: audio)
 return (audio, chunks.enumerated().map { NarrationChunkTiming(start: Double($0.offset), text: $0.element) })
}
// Retain only conversation and timing fields needed by these narration checks.
struct Config { var conversation: ResultConversation?; var audioTimings: [NarrationChunkTiming]? }
// Provide a text view while leaving unrelated follow-up activity inactive.
final class ResultConversationTextView: NSTextView { /* updateFollowUpActivity(): Keep follow-up UI refreshes inert in this isolated fixture. */ func updateFollowUpActivity() {} }
// Supply the tooltip field used by narration controls.
final class TooltipButton: NSButton { var tooltipMessage = "" }
// Remove fixture toolbar buttons through their real view hierarchy.
final class Toolbar { /* removeButton(button): Remove the fixture button from its parent view. */ func removeButton(_ button: NSButton) { button.removeFromSuperview() } }
// Suppress unrelated app-menu refreshes during narration tests.
final class Delegate { /* updateMenuForActiveWindow(): Avoid changing app menus during this isolated fixture. */ func updateMenuForActiveWindow() {} }
// Capture the timing metadata offered to Library persistence.
enum LibraryStore {
 static var saved: [NarrationChunkTiming]?
 // updateNarration(id, audioSourcePath, voice, model, timings): Record saved
 // timings without writing to the user's Library.
 static func updateNarration(id: String, audioSourcePath: String, voice: String?, model: String?, timings: [NarrationChunkTiming]?) { saved = timings }
}
// Host real narration methods with isolated requests, controls, and recorded errors.
final class ViewerSession: NSObject, @unchecked Sendable {
 var hudNarration: ClipboardHUDPlayback?
 var content = "Love means care.\n\nRussian\nЛюбовь означает заботу.\n\n## Sources\n[1] [Original source](https://example.test/original)"
 var config = Config(conversation: ResultConversation(originalRequest: "Explain love", modelID: "fixture", turns: [
  ResultFollowUpTurn(question: "", answer: "## Serbian\nLjubav znači brigu.\n\n## Sources\n[1] [Serbian source](https://example.test/serbian)", modelID: "fixture", modelName: "Fixture"),
  ResultFollowUpTurn(question: "Can you give an example?", answer: "Help someone who needs you.", modelID: "fixture", modelName: "Fixture"),
  ResultFollowUpTurn(question: "A question whose reply was deleted.", answer: "", modelID: "fixture", modelName: "Fixture"),
  ResultFollowUpTurn(question: "", answer: "", modelID: "fixture", modelName: "Fixture")
 ]))
 var followUpPendingQuestion: String?, followUpDraft = "Unsubmitted draft"
 var narrationTask: NarrationRequestTask?, narrationTasks: [NarrationRequestTask] = []
 var narrationRunID: UUID?
 var narrationVoiceUsed: String?, narrationModelUsed: String?
 var narrationButton: NSButton?
 var saveAudioToolbarButton: NSButton?, shareButton: NSButton?
 var resultToolbar: Toolbar?, appDelegate: Delegate?
 var activeAudioPath = "", generatedAudioCleanupDir = "", savedLibraryID: String? = "fixture"
 var audioAvailable: Bool { !activeAudioPath.isEmpty }
 var narrationSegments: [NarrationSegment] = []
 var errors: [String] = []
 let textView: NSTextView? = ResultConversationTextView()
 // setResultTitleMessage(message): Keep this production dependency inactive in
 // the isolated fixture.
 func setResultTitleMessage(_ message: String?) {}
 // updateNarrationStats(): Keep this production dependency inactive in the
 // isolated fixture.
 func updateNarrationStats() {}
 // updateResultActivityIndicator(): Keep this production dependency inactive in
 // the isolated fixture.
 func updateResultActivityIndicator() {}
 // revealAudioControls([autoplay = true]): Exercise save-button updates when
 // audio controls are revealed.
 func revealAudioControls(autoplay: Bool = true) { updateNarrationSaveButton() }
 // updateSaveToLibraryButton(): Keep this production dependency inactive in the
 // isolated fixture.
 func updateSaveToLibraryButton() {}
 // presentViewerError(title, details): Capture playback errors for assertions
 // instead of opening alerts.
 func presentViewerError(_ title: String, details: String) { errors.append(details) }
 // stopAudio(): Keep this production dependency inactive in the isolated
 // fixture.
 func stopAudio() {}
 // pauseAudio(): Keep this production dependency inactive in the isolated
 // fixture.
 func pauseAudio() {}
 // removeAudioControlsBar(): Keep this production dependency inactive in the
 // isolated fixture.
 func removeAudioControlsBar() {}
 // clearNarrationHighlight(): Keep this production dependency inactive in the
 // isolated fixture.
 func clearNarrationHighlight() {}
 // markdownAttributedText(text): Keep rendering plain so narration assertions
 // target source selection, not Markdown styling.
 func markdownAttributedText(from text: String) -> NSAttributedString { NSAttributedString(string: text) }
 // insertPronunciationSpeakers(text): Keep this production dependency inactive
 // in the isolated fixture.
 func insertPronunciationSpeakers(into text: NSMutableAttributedString) {}
 // refreshIllustration(): Keep this production dependency inactive in the
 // isolated fixture.
 func refreshIllustration() {}
 // appendFollowUps(text): Build a conversation display containing UI labels
 // that narration must exclude.
 func appendFollowUps(to text: NSMutableAttributedString) {
  // Append each completed question and answer with representative action labels.
  for turn in config.conversation?.turns ?? [] {
   // Render nonempty questions with the fixture's user and delete labels.
   if !turn.question.isEmpty { text.append(NSAttributedString(string: "\nYou   Delete\n" + turn.question)) }
   // Render nonempty answers with provider and action labels.
   if !turn.answer.isEmpty { text.append(NSAttributedString(string: "\nLangmin · Fixture   Copy reply   Delete reply\n" + turn.answer)) }
  }
  // Include pending text and its progress label to test spoken-source filtering.
  if let pending = followUpPendingQuestion { text.append(NSAttributedString(string: "\nYou\n" + pending + "\nReplying…")) }
 }
 // SESSION METHODS
}
'''
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['func isSourcesSectionStart(', 'func removingTrailingSourcesSection(', 'func speechReadyText(',
               'func narrationSpeechChunks(', 'func narrationChunkRange(', 'struct NarrationChunkTiming:', 'struct NarrationSegment {']:
    source += block(marker) + '\n'
methods = ['    var narrationSpeechText:', '    func generateNarration(', '    func generateChunkedNarration(',
           '    func finishChunkedNarration(', '    func persistNarrationToLibraryIfSaved(', '    func resolveNarrationSegments(',
           '    func applyNarrationCursorAttributes(', '    func removeNarrationCursorAttributes(', '    func applyResultText()',
           '    func dropExistingAudio(', '    func narrationTooltip()', '    @objc func narrationVoiceChosen(',
           '    var isGeneratingNarration =', '    var canSaveAudio:', '    func updateNarrationSaveButton()',
           '    func cancelNarrationGeneration()', '    @objc func removeNarrationChosen(']
source = source.replace('// SESSION METHODS', '\n'.join(block(marker) for marker in methods))
source += r'''
var checks = 0
// check(condition, message): Report failed fixture expectations with their case
// names.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
 // Stop this fixture when its named expectation does not hold.
 guard condition() else { fputs("FAILED: " + message + "\n", stderr); exit(1) }; checks += 1
}
// finish(viewer): Wait for narration completion without blocking the main
// actor.
@MainActor func finish(_ viewer: ViewerSession) async {
 // Bound the wait so a stuck generation fails the fixture.
 for _ in 0..<300 {
  // Return as soon as the viewer leaves its generating state.
  if !viewer.isGeneratingNarration { return }
  try? await Task.sleep(nanoseconds: 10_000_000)
 }
 fatalError("Narration did not finish")
}
// tests(): Exercise narration routing, replacement, and failure recovery on
// isolated viewers.
@MainActor func tests() async throws {
 _ = NSApplication.shared
 // Cover both whole-result audio and timed highlighting mode.
 for highlight in [false, true] {
  preferences.narrationHighlightMode = highlight
  // Run each narration mode against all supported speech providers.
  for provider in [NarrationProvider.apple, .grok, .openAI] {
   let viewer = ViewerSession()
   // A deleted question must not hide its retained answer, including after reopening.
   viewer.config.conversation = try JSONDecoder().decode(ResultConversation.self, from: JSONEncoder().encode(viewer.config.conversation!))
   viewer.followUpPendingQuestion = "Can you add another example?"
   viewer.applyResultText()
   let expected = viewer.narrationSpeechText
   check(expected.contains("Love means care.") && expected.contains("Любовь означает заботу.") && expected.contains("Ljubav znači brigu."), "Narration includes original and follow-up languages")
   check(expected.contains("Can you give an example?") && expected.contains("Help someone who needs you.") && expected.contains("A question whose reply was deleted."), "Remaining questions and answers are narrated")
   check(expected.hasSuffix("Can you add another example?"), "A submitted pending question is included at the end")
   check(!expected.contains("Sources") && !expected.contains("example.test") && !expected.contains("Copy reply") && !expected.contains("Replying") && !expected.contains("Unsubmitted"), "Narration omits sources, controls, loaders and the unsent draft")
   viewer.generateNarration(voice: provider.rawValue)
   viewer.config.conversation!.turns.append(ResultFollowUpTurn(question: "A later question.", answer: "A later answer.", modelID: "fixture", modelName: "Fixture"))
   viewer.followUpPendingQuestion = nil
   viewer.applyResultText()
   // Wait for chunked narration and check its timing-aware completion path.
   if highlight {
    await finish(viewer)
    let request = chunkRequests.last!
    check(request.provider == provider && request.chunks == narrationSpeechChunks(from: expected), "Sentence narration uses the captured conversation for " + provider.rawValue)
    check(LibraryStore.saved?.map(\.text) == request.chunks && viewer.config.audioTimings?.map(\.text) == request.chunks, "Current and saved timings belong to the new recording")
    let spoken = "Ljubav znači brigu."
    let timingIndex = viewer.config.audioTimings!.firstIndex { $0.text == spoken }!
    let range = viewer.narrationSegments[timingIndex].range!
    check((viewer.textView!.string as NSString).substring(with: range).contains("Ljubav znači brigu"), "Follow-up narration highlights its displayed sentence")
    let before = viewer.narrationSegments.first { segment in segment.range.map { (viewer.textView!.string as NSString).substring(with: $0).contains("Help someone") } ?? false }!.range!
    viewer.config.conversation!.turns[1].question = ""
    viewer.applyResultText()
    let after = viewer.narrationSegments.first { segment in segment.range.map { (viewer.textView!.string as NSString).substring(with: $0).contains("Help someone") } ?? false }!.range!
    check(after.location < before.location, "Deleting a question updates later highlight positions without regenerating audio")
    let reopened = ViewerSession()
    reopened.config = viewer.config
    reopened.config.audioTimings = try JSONDecoder().decode([NarrationChunkTiming].self, from: JSONEncoder().encode(viewer.config.audioTimings!))
    reopened.activeAudioPath = viewer.activeAudioPath
    reopened.applyResultText()
    check(reopened.narrationSegments[timingIndex].range != nil, "Reopened narration resolves follow-up highlights")
   } else {
       // Drive the recorded single-request path to completion explicitly.
    let request = requests.last!
    check(request.resumed && request.provider == provider && request.text == expected, "Single-request narration uses the captured conversation for " + provider.rawValue)
    try request.finish(); await finish(viewer)
   }
   check(viewer.audioAvailable && viewer.errors.isEmpty, "Narration completes without provider calls")
   let path = viewer.activeAudioPath
   let count = requests.count + chunkRequests.count
   viewer.applyResultText()
   check(viewer.activeAudioPath == path && requests.count + chunkRequests.count == count, "Conversation refresh leaves existing audio untouched")
   // Choosing a voice again explicitly replaces the snapshot with all current text.
   preferences.narrationHighlightMode = false
   let item = NSMenuItem(); item.representedObject = provider.rawValue
   let replacement = viewer.narrationSpeechText
   let oldTimings = viewer.config.audioTimings
   let saveButton = NSButton()
   let saveGroup = NSStackView(views: [NSButton(), saveButton])
   viewer.resultToolbar = Toolbar()
   viewer.saveAudioToolbarButton = saveButton
   viewer.narrationVoiceChosen(item)
   check(requests.last!.text == replacement && requests.last!.text.contains("A later answer."), "Explicit regeneration includes later messages")
   check(viewer.activeAudioPath == path && FileManager.default.fileExists(atPath: path), "Regeneration retains the previous recording until completion")
   check(viewer.config.audioTimings?.map(\.text) == oldTimings?.map(\.text), "Existing audio retains its matching highlights while replacement is pending")
   check(viewer.saveAudioToolbarButton === saveButton && !saveButton.isEnabled && saveGroup.arrangedSubviews.count == 2, "Save Audio stays in its group, disabled during regeneration")
   try requests.last!.finish(); await finish(viewer)
   check(viewer.activeAudioPath != path && viewer.config.audioTimings == nil && viewer.narrationSegments.isEmpty, "Successful replacement installs the new recording and its highlights")
   check(viewer.saveAudioToolbarButton === saveButton && saveButton.isEnabled && saveGroup.arrangedSubviews.count == 2, "Save Audio is enabled again without replacing its button")
   preferences.narrationHighlightMode = highlight
  }
 }
 // Failed or cancelled replacement restores Save Audio for the retained recording.
 preferences.narrationHighlightMode = false
 let viewer = ViewerSession()
 let oldDirectory = root.appendingPathComponent("original-audio")
 try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
 let oldAudio = oldDirectory.appendingPathComponent("original.mp3")
 try Data([0]).write(to: oldAudio)
 viewer.activeAudioPath = oldAudio.path
 viewer.generatedAudioCleanupDir = oldDirectory.path
 viewer.narrationVoiceUsed = "Original voice"
 let saveButton = NSButton()
 let group = NSStackView(views: [NSButton(), saveButton])
 viewer.resultToolbar = Toolbar()
 viewer.saveAudioToolbarButton = saveButton
 let voice = NSMenuItem(); voice.representedObject = "openAI"
 // checkRetained(reason): Verify that a failed replacement preserves the
 // previous audio and its controls.
 func checkRetained(_ reason: String) {
  check(viewer.activeAudioPath == oldAudio.path && FileManager.default.fileExists(atPath: oldAudio.path), reason + " keeps the old audio")
  check(viewer.saveAudioToolbarButton === saveButton && saveButton.isEnabled && group.arrangedSubviews.count == 2, reason + " restores the same Save Audio button")
  check(viewer.narrationVoiceUsed == "Original voice", reason + " preserves the old voice label")
 }
 sharingAllowed = false
 let beforeConsent = requests.count
 viewer.narrationVoiceChosen(voice)
 check(requests.count == beforeConsent && !viewer.isGeneratingNarration, "Declining sharing does not begin replacement")
 checkRetained("Declined sharing")
 sharingAllowed = true
 failTemporaryDirectory = true
 viewer.narrationVoiceChosen(voice)
 failTemporaryDirectory = false
 check(!viewer.isGeneratingNarration, "Failed request setup stops generation")
 checkRetained("Failed request setup")
 viewer.narrationVoiceChosen(voice)
 requests.last!.completion(.failure(NSError(domain: "fixture", code: 2)))
 await finish(viewer)
 checkRetained("Provider failure")
 viewer.narrationVoiceChosen(voice)
 requests.last!.completion(.success(()))
 await finish(viewer)
 checkRetained("Missing output")
 viewer.narrationVoiceChosen(voice)
 let cancelled = requests.last!
 viewer.removeNarrationChosen(nil)
 check(viewer.isGeneratingNarration && viewer.saveAudioToolbarButton === saveButton, "Removal cannot interrupt an active replacement")
 viewer.cancelNarrationGeneration()
 check(cancelled.cancelled, "Cancellation reaches the pending provider request")
 checkRetained("Cancellation")
 try cancelled.finish()
 try await Task.sleep(nanoseconds: 30_000_000)
 checkRetained("Late cancelled completion")
 // Sentence-based regeneration also keeps the same button through completion.
 preferences.narrationHighlightMode = true
 viewer.narrationVoiceChosen(voice)
 check(!saveButton.isEnabled && group.arrangedSubviews.count == 2, "Chunked regeneration disables Save Audio in place")
 await finish(viewer)
 check(viewer.activeAudioPath != oldAudio.path && !FileManager.default.fileExists(atPath: oldAudio.path), "Successful chunked replacement releases the previous generated file")
 check(viewer.saveAudioToolbarButton === saveButton && saveButton.isEnabled && group.arrangedSubviews.count == 2, "Chunked replacement reuses and enables Save Audio")
 viewer.removeNarrationChosen(nil)
 check(viewer.saveAudioToolbarButton == nil && group.arrangedSubviews.count == 1 && !viewer.audioAvailable, "Explicit removal removes narration and its Save Audio segment")
 check(speechReadyText(from: "<u>Edited words</u>.") == "Edited words.", "Underline markup is not narrated")
 check(speechReadyText(from: #"<span style="font-size: 12.0pt">Small text</span> <sup>[1]</sup>."#) == "Small text.", "Font-size and superscript markup are not narrated")
 check(speechReadyText(from: "Use [<code>value</code>](https://example.test/code).") == "Use value.", "Inline-code styling inside links is not narrated")
 check(speechReadyText(from: "Body.\n\n<span style=\"font-size: 12.0pt\">**Sources**</span>\n<span style=\"font-size: 11.0pt\">\\[1\\]</span> [Reference](https://example.test)") == "Body.", "Resizing a Sources heading keeps references out of narration")
 check(speechReadyText(from: #"[<b><i>Reference</i></b>](https://example.test)."#) == "Reference.", "Emphasis tags inside edited links are not narrated")
 check(speechReadyText(from: #"Edited words\."#) == "Edited words.", "Markdown escape characters are not narrated")
 print("\(checks) narration checks passed; no speech providers called")
}
// AppKit views need the application run loop on the main thread, including after async speech callbacks.
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
NSApp.finishLaunching()
Task { @MainActor in
 // Run the asynchronous narration checks and exit when they complete.
 do { try await tests(); exit(0) }
 // Report asynchronous fixture failures with a nonzero exit status.
 catch { fputs("\(error)\n", stderr); exit(1) }
}
NSApp.run()
'''
with tempfile.TemporaryDirectory(prefix='langmin-narration-tests-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', *swift_fixture_args(), '-module-cache-path', cache, '-target', f'{platform.machine()}-apple-macos14.0',
                    str(folder / 'main.swift'), str(app_path('ResultConversation.swift')),
                    '-o', str(folder / 'tests')], check=True)
    subprocess.run([str(folder / 'tests'), directory], check=True, timeout=60)
