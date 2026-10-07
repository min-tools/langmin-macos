#!/usr/bin/env python3
"""Test real clipboard-action routing with an in-memory clipboard and no windows or providers."""
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
    return MAIN[start:end] + '\n'


source = r'''
import Foundation
// localized(key, english): Use English labels so routing assertions are
// independent of the workstation language.
func localized(_ key: String, _ english: String) -> String { english }
// Supply a screen identity without accessing real display state.
final class NSScreen {}
// Keep app preferences in memory.
struct Preferences {}
// Supply a predictable fallback launcher mode.
struct LauncherPreferences { var mode = "explain" }
// loadAppPreferences(): Return fixture preferences without reading user
// defaults.
func loadAppPreferences() -> Preferences { Preferences() }
// loadLauncherPreferences(): Return the fixture's launcher mode without
// accessing saved choices.
func loadLauncherPreferences() -> LauncherPreferences { LauncherPreferences() }
// Model clipboard contents and change counts entirely in memory.
final class NSPasteboard {
 // This fixture exercises only plain-text clipboard delivery.
 enum PasteboardType { case string }
 static let general = NSPasteboard()
 var text = "", changeCount = 0
 // string(forType): Expose the current simulated clipboard text.
 func string(forType: PasteboardType) -> String? { text }
 // clearContents(): Model a clipboard clear as a visible change-count
 // increment.
 func clearContents() { text = ""; changeCount += 1 }
 // setString(value, forType): Model a successful text write and its
 // change-count increment.
 func setString(_ value: String, forType: PasteboardType) -> Bool {
  text = value; changeCount += 1; return true
 }
}
// Provide the two choices used by the overwrite confirmation.
enum ModalResponse { case alertFirstButtonReturn, alertSecondButtonReturn }
var alertCount = 0
var alertResponse = ModalResponse.alertSecondButtonReturn
// Record confirmation dialogs without opening native windows.
final class NSAlert {
 var messageText = "", informativeText = ""
 // addButton(withTitle): Accept button setup without creating real controls.
 func addButton(withTitle: String) {}
 // runModal(): Count each simulated dialog and return its configured answer.
 @discardableResult func runModal() -> ModalResponse { alertCount += 1; return alertResponse }
}
// Keep application activation from affecting workstation focus.
final class Application { /* activate(ignoringOtherApps): Avoid changing the active app during the clipboard fixture. */ func activate(ignoringOtherApps: Bool) {} }
let NSApp = Application()
// Retain the original request passed into result metadata.
struct ResultConversation { var originalRequest: String }
// Provide a narration handoff identity without generating audio.
final class ClipboardHUDPlayback {}
// Represent the completion styles used by the HUD routing code.
enum ClipboardHUDCompletionStyle { case success, neutral, cancelled, failure }
// Track cancellation and presentation for one simulated launcher request.
final class LauncherRun {
 var cancelled = false
 var conversation: ResultConversation?
 var presentation = LauncherRunPresentation.standard
 var hudToken: UUID?
 var acceptsCancellation = true
}
// Capture automation requests and expose their completion callback to the test.
final class LauncherController {
 var lastRunTextModel = "Captured model", pendingRunLanguageLevel = "b"
 var action = "", runs = false
 var presentation = LauncherRunPresentation.standard
 var completion: ((LauncherRun, Result<String, Error>) -> Void)?
 var run = LauncherRun()
 var activeRun: LauncherRun?
 var cancellations = 0
 var requests = 0, errors: [String] = []
 // handleAutomation(text, mode, run, presentation, transformCompletion): Record
 // requested mode, presentation, and callback instead of contacting an AI
 // provider.
 func handleAutomation(text: String, mode: String, run: Bool, presentation: LauncherRunPresentation = .standard,
                       transformCompletion: ((LauncherRun, Result<String, Error>) -> Void)? = nil) {
  action = mode; runs = run; self.presentation = presentation; completion = transformCompletion
  self.run = LauncherRun(); self.run.conversation = ResultConversation(originalRequest: text)
  self.run.presentation = presentation; activeRun = self.run
  requests += 1
 }
 // handleClipboardRequest(text, mode, presentation, completion): Capture the
 // separate background route without borrowing the main editor.
 func handleClipboardRequest(text: String, mode: String, presentation: LauncherRunPresentation,
                             completion: @escaping (LauncherRun, Result<String, Error>) -> Void) {
  handleAutomation(text: text, mode: mode, run: true, presentation: presentation, transformCompletion: completion)
 }
 // cancelGeneration(expectedRun): Only the matching worker may be cancelled.
 func cancelGeneration(expectedRun: LauncherRun) {
  guard activeRun === expectedRun else { return }
  expectedRun.cancelled = true; activeRun = nil; cancellations += 1
 }
 // featureTitle(mode): Use a predictable mode label for result assertions.
 func featureTitle(for mode: String) -> String { mode.capitalized }
 // presentError(title, details): Collect error details for assertions instead
 // of presenting alerts.
 func presentError(_ title: String, details: String) { errors.append(details) }
}
// Capture the HUD payload, including its optional result and Open action.
struct Completion {
 var message: String, detail: String?
 var style: ClipboardHUDCompletionStyle
 var resultText: String?
 var open: ((ClipboardHUDPlayback) -> Void)?
 var retry: (() -> Void)?
}
// Record metadata passed from a completed HUD into a detached result.
struct OpenedResult {
 var text: String, mode: String, model: String?, level: String, headword: String?, conversation: ResultConversation?
}
// Model HUD ownership and cancellation without displaying a panel.
final class HUD {
 var cancel: (() -> Void)?
 var begins = 0
 func begin(title: String, modelName: String, status: String, screen: NSScreen?, cancel: @escaping () -> Void) -> UUID {
  self.cancel = cancel; begins += 1; return UUID()
 }
}
final class MenuItem { var isHidden = false, isEnabled = true }
// Host production clipboard routing with in-memory collaborators.
final class Delegate {
 let launcherController = LauncherController()
 let clipboardController = LauncherController()
 let clipboardHUDController = HUD()
 var cancelClipboardActionItem: MenuItem? = MenuItem()
 var completed: Completion?
 var opened: OpenedResult?
 // completeClipboardHUD(run, message, [detail = nil], style, dismissAfter,
 // [retry = nil], [resultText = nil], [open = nil]): Capture the requested HUD
 // completion rather than displaying it.
 func completeClipboardHUD(for run: LauncherRun, message: String, detail: String? = nil,
     style: ClipboardHUDCompletionStyle, dismissAfter: Double, retry: (() -> Void)? = nil,
     resultText: String? = nil, open: ((ClipboardHUDPlayback) -> Void)? = nil) {
  completed = Completion(message: message, detail: detail, style: style, resultText: resultText, open: open, retry: retry)
 }
 // suspendClipboardHUD(run): Suppress native HUD suspension in the routing
 // fixture.
 func suspendClipboardHUD(for run: LauncherRun) {}
 // resumeClipboardHUD(run, status): Suppress native HUD resumption while
 // preserving the production call path.
 func resumeClipboardHUD(for run: LauncherRun, status: String) {}
 // updateClipboardHUD(run, status): Ignore transient status drawing; completion
 // payloads are asserted separately.
 func updateClipboardHUD(for run: LauncherRun, status: String) {}
 // dismissClipboardHUD(run): Keep HUD dismissal from creating or closing native
 // panels.
 func dismissClipboardHUD(for run: LauncherRun) {}
 // snapshotPasteboardItems(pasteboard): Snapshot the simulated clipboard for
 // restoration checks.
 func snapshotPasteboardItems(_ pasteboard: NSPasteboard) -> [String] { [pasteboard.text] }
 // restorePasteboardItems(items, pasteboard): Restore the fixture clipboard
 // from its saved text snapshot.
 func restorePasteboardItems(_ items: [String], to pasteboard: NSPasteboard) -> Bool { pasteboard.text = items[0]; return true }
 // openDetachedResultWindow(text, mode, narration, [textModel = nil],
 // [languageLevel = "off"], [dictionaryHeadword = nil], [conversation = nil]):
 // Capture detached result content and metadata instead of opening a window.
 func openDetachedResultWindow(text: String, mode: String, narration: ClipboardHUDPlayback,
     textModel: String? = nil, languageLevel: String = "off", dictionaryHeadword: String? = nil,
     conversation: ResultConversation? = nil) {
  opened = OpenedResult(text: text, mode: mode, model: textModel, level: languageLevel,
                        headword: dictionaryHeadword, conversation: conversation)
 }
 // ACTION METHODS
}
'''
source = source.replace('// ACTION METHODS', '\n'.join(block(marker) for marker in [
    '    func performClipboardAction(', '    func clipboardHUDTitle(', '    func clipboardHUDVerb(',
    '    func showClipboardHUDIfNeeded(', '    @objc func cancelCurrentClipboardAction('
]).replace('@objc ', ''))
source += '\n'.join(block(marker) for marker in [
    'enum LauncherRunPresentation {', 'struct HelperFailure:', 'struct LauncherCancellationError:', 'struct TranslationSkipped:'
])
source += r'''
var checks = 0
// check(value, message): Count assertions and report the first failed routing
// expectation.
func check(_ value: @autoclosure () -> Bool, _ message: String) {
 // Stop the fixture immediately when an expectation fails.
 guard value() else { fputs("FAILED: \(message)\n", stderr); exit(1) }
 checks += 1
}

// Exercise clipboard delivery for every supported text mode.
for mode in ["proofread", "rewrite", "explain", "summarize", "translate", "dictionary"] {
 let app = Delegate(), board = NSPasteboard.general
 board.text = "Karate"
 app.performClipboardAction(mode)
 check(app.launcherController.requests == 0, "\(mode) never submits text through the main editor")
 check(app.clipboardController.runs && app.clipboardController.completion != nil, "\(mode) has a completion destination")
 // Require clipboard requests to choose HUD presentation.
 if case .clipboardHUD = app.clipboardController.presentation { checks += 1 }
 // Fail if any mode bypasses the expected HUD route.
 else { check(false, "\(mode) starts in the HUD") }
 let reads = !["proofread", "rewrite"].contains(mode)
 // A reading result must not ask to overwrite text copied during generation.
 if reads { board.text = "New clipboard text"; board.changeCount += 1 }
 let alertsBefore = alertCount
 app.clipboardController.completion?(app.clipboardController.run, .success("Generated result"))
 check(alertCount == alertsBefore && app.opened == nil, "\(mode) completes without a modal dialog or automatic window")
 // Reading modes must preserve newer clipboard text and expose an Open action.
 if reads {
  check(board.text == "New clipboard text" && app.completed?.resultText == "Generated result" && app.completed?.open != nil,
        "\(mode) stays in the HUD and preserves the clipboard")
  // Opening later must retain the generating request's identity, even after launcher choices change.
  app.clipboardController.lastRunTextModel = "Another model"
  app.clipboardController.pendingRunLanguageLevel = "c"
  app.completed?.open?(ClipboardHUDPlayback())
  check(app.opened?.text == "Generated result" && app.opened?.mode == mode && app.opened?.model == "Captured model"
        && app.opened?.level == "b" && app.opened?.conversation?.originalRequest == "Karate",
        "\(mode) opens the original result and metadata")
  check(app.opened?.headword == (mode == "dictionary" ? "Karate" : nil), "Only Dictionary carries a pronunciation headword")
 } else {
     // Proofread and Rewrite must copy transformed text with a transient confirmation.
  check(board.text == "Generated result" && app.completed?.message == "Copied" && app.completed?.resultText == nil
        && app.completed?.open == nil, "\(mode) copies with a brief confirmation only")
 }
}

// Check declined overwrite confirmation for both clipboard-transform modes.
for mode in ["proofread", "rewrite"] {
 let app = Delegate(), board = NSPasteboard.general
 board.text = "Original"
 app.performClipboardAction(mode)
 check(app.launcherController.requests == 0, "\(mode) never submits text through the main editor")
 board.text = "New clipboard text"; board.changeCount += 1
 alertResponse = .alertSecondButtonReturn
 app.clipboardController.completion?(app.clipboardController.run, .success("Generated result"))
 check(board.text == "New clipboard text" && app.completed?.style == .neutral, "\(mode) still respects the clipboard-conflict choice")
}

// Check failure presentation for representative readable-result modes.
for mode in ["explain", "dictionary", "translate"] {
 let app = Delegate()
 NSPasteboard.general.text = "Original"
 app.performClipboardAction(mode)
 check(app.launcherController.requests == 0, "\(mode) never submits text through the main editor")
 let error = "Apple Intelligence does not support output in Russian. Choose another text model."
 app.clipboardController.completion?(app.clipboardController.run, .failure(HelperFailure(message: error)))
 check(app.completed?.message == error && app.completed?.style == .failure && app.completed?.retry != nil,
       "\(mode) delivers the full unsupported-language error to the HUD")
 check(NSPasteboard.general.text == "Original" && app.opened == nil, "\(mode) failure preserves the clipboard and opens no window")
 app.completed?.retry?()
 check(app.clipboardController.requests == 2, "\(mode) Retry starts the same action again")
}

let cancelled = Delegate()
NSPasteboard.general.text = "Original"
cancelled.performClipboardAction("dictionary")
cancelled.clipboardController.run.cancelled = true
cancelled.clipboardController.completion?(cancelled.clipboardController.run, .success("Late result"))
check(cancelled.completed == nil && NSPasteboard.general.text == "Original", "Cancelled requests cannot publish a late result")

// HUD and menu cancellation target only the shortcut, even with an editor run.
let cancelling = Delegate()
cancelling.launcherController.handleAutomation(text: "Draft", mode: "rewrite", run: true)
cancelling.performClipboardAction("proofread")
let editorRun = cancelling.launcherController.run
let clipboardRun = cancelling.clipboardController.run
cancelling.showClipboardHUDIfNeeded(for: editorRun, modelName: "Editor", status: "Working")
check(cancelling.clipboardHUDController.begins == 0, "Editor requests cannot take over clipboard progress")
cancelling.showClipboardHUDIfNeeded(for: clipboardRun, modelName: "Clipboard", status: "Working")
check(cancelling.clipboardHUDController.begins == 1 && clipboardRun.hudToken != nil, "The worker owns the clipboard HUD")
let oldCancel = cancelling.clipboardHUDController.cancel
oldCancel?()
check(cancelling.clipboardController.cancellations == 1 && cancelling.launcherController.cancellations == 0,
      "HUD cancellation leaves the editor request running")
cancelling.performClipboardAction("proofread")
oldCancel?()
check(cancelling.clipboardController.cancellations == 1, "An old HUD cannot cancel a newer clipboard request")
cancelling.cancelCurrentClipboardAction(nil)
check(cancelling.clipboardController.cancellations == 2 && !editorRun.cancelled,
      "Menu cancellation also leaves the editor untouched")

let compose = Delegate()
compose.performClipboardAction("compose")
check(compose.clipboardController.requests == 0, "Compose does not start background work")
check(!compose.launcherController.runs && compose.launcherController.completion == nil, "Compose still opens the input without executing a request")
print("\(checks) clipboard routing checks passed; no clipboard, windows, preferences or providers used")
'''

with tempfile.TemporaryDirectory(prefix='langmin-clipboard-delivery-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', *swift_fixture_args(), '-O', '-module-cache-path', cache, '-target',
                    f'{platform.machine()}-apple-macos14.0', str(folder / 'main.swift'), '-o', str(folder / 'tests')], check=True)
    subprocess.run([str(folder / 'tests')], check=True, timeout=30)
