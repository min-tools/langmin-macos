#!/usr/bin/env python3
"""Exercise text and explanation delivery with offline model responses."""
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
import Foundation
// localized(key, english): Resolve labels through the fixture’s controlled
// localization.
func localized(_ key: String, _ english: String) -> String { english }
// watermarkCleanedGeneratedText(input): Leave text unchanged so this fixture
// isolates behavior outside Unicode cleanup.
func watermarkCleanedGeneratedText(_ input: String) -> String { input }
// Represent only the role and content needed by generated conversation metadata.
struct TextConversationMessage {
 // Distinguish user source from assistant output in the fixture transcript.
 enum Role: String { case user, assistant }
 let role: Role
 let content: String
}
// Control research without accessing app settings.
struct Preferences {
 var explainAnswerLanguage = "en", webResearchEnabled = false
 var extraLanguages: [String] = []
}
// loadAppPreferences(): Provide the preferences configured by this fixture.
func loadAppPreferences() -> Preferences { Preferences() }
// appWindowTitle(mode, title): Provide predictable window titles without the
// production title-formatting dependency.
func appWindowTitle(mode: String, title: String) -> String { title }
// Exercise normal launcher presentation separately from clipboard HUD delivery.
enum LauncherRunPresentation { case standard, clipboardHUD }
// Retain a page title when testing linked-result completion.
struct SourcePage { var title: String }
// Track request ownership and completion state in the isolated launcher flow.
final class LauncherRun {
 var sourcePage: SourcePage?
 var presentation: LauncherRunPresentation = .standard
 var explicitTranslationTargetID: String?
 var transformCompletion: ((LauncherRun, Result<String, Error>) -> Void)?
 var acceptsCancellation = true
}
// Observe input clearing without editing the real launcher or user data.
final class InputView {
 var text = "Fixture input"
 // clearUndoably(): Record successful clearing; native Undo is tested separately.
 func clearUndoably() { text = "" }
}
// Represent the failure style used by skipped-translation HUD notices.
enum HUDStyle { case failure }
// Capture HUD notices without displaying real panels.
final class Delegate {
 var notices: [String] = []
 // disableClipboardHUDCancellation(run): Keep this production dependency
 // inactive in the isolated fixture.
 func disableClipboardHUDCancellation(for run: LauncherRun) {}
 // dismissClipboardHUD(run): Keep this production dependency inactive in the
 // isolated fixture.
 func dismissClipboardHUD(for run: LauncherRun) {}
 // completeClipboardHUD(run, message, style, dismissAfter): Record the
 // completion message delivered through the HUD path.
 func completeClipboardHUD(for run: LauncherRun, message: String, style: HUDStyle, dismissAfter: Double) {
  notices.append(message)
 }
 // terminateIfIdle(): Keep this production dependency inactive in the isolated
 // fixture.
 func terminateIfIdle() {}
}
'''
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['struct ExplanationPrompt {', 'struct HelperFailure:', 'struct LauncherCancellationError:',
               'struct TranslationSkipped:', 'func cleanedLiteralTransformOutput(',
               'func cleanedTextTransformOutput(', 'final class TextRequestHandle {']:
    source += block(marker) + '\n'
source += r'''
var providerResponse: Result<String, Error> = .success("")
var requestCompletion: ((Result<String, Error>) -> Void)?
var completesImmediately = true
// startTextRequest(model, prompt, emptyMessage, [research = false],
// completion): Complete with the fixture's configured response instead of
// contacting a model.
func startTextRequest(model: String, prompt: ExplanationPrompt, emptyMessage: String, research: Bool = false, mode: String? = nil,
                      completion: @escaping (Result<String, Error>) -> Void) throws -> TextRequestHandle {
 requestCompletion = completion
 return TextRequestHandle(resume: { /* Deliver a synchronous response only when that fixture mode is enabled. */ if completesImmediately { completion(providerResponse) } }, cancel: {})
}
// modelSupportsWebResearch(model): Keep web research outside the
// translation-routing fixture.
func modelSupportsWebResearch(_ model: String) -> Bool { false }
// extraLanguageNames(languages): Pass language names through unchanged for
// isolated flow checks.
func extraLanguageNames(_ languages: [String]) -> [String] { languages }
// explanationPrompt(question, effort, outputLanguage, research, extraLanguages,
// languageLevel): Supply a predictable structured explanation prompt for the
// shared completion path.
func explanationPrompt(question: String, effort: String, outputLanguage: String, research: Bool,
                       extraLanguages: [String], languageLevel: String) -> ExplanationPrompt {
 ExplanationPrompt(instructions: "Explain", input: question)
}
// parseExplanationResponse(response): Parsing is covered by the rendering
// suite; this fixture exercises delivery after parsing.
func parseExplanationResponse(_ response: String) -> (topicTitle: String, explanation: String) {
 let json = try! JSONSerialization.jsonObject(with: Data(response.utf8)) as! [String: String]
 return (json["title"]!, json["explanation"]!)
}
// Host production generation and completion methods with observable side effects.
final class LauncherController {
 var activeRun: LauncherRun?
 var activeTextTask: TextRequestHandle?
 var activeDataTask: Int?
 var activeDataTasks: [Int] = []
 var activeTempDir: URL?
 var isGenerating = true
 var inputView = InputView()
 var pendingDictionaryHeadword: String?
 var appDelegate: Delegate? = Delegate()
 var prompt = ExplanationPrompt(instructions: "Translate", input: "Изворни текст", translationSkipMarker: "fixture-skip-marker")
 var alerts: [(String, String)] = []
 var narrationCalls = 0, openCalls = 0, materializeCalls = 0, diffCalls = 0
 // textTransformPrompt(input, mode, secondary, languageLevel,
 // explicitTranslationTargetID): Return the prompt configured by the current
 // translation case.
 func textTransformPrompt(input: String, mode: String, secondary: String, languageLevel: String,
                          explicitTranslationTargetID: String?) -> ExplanationPrompt { prompt }
 // linkedPagePrompt(prompt, run, detailed): Keep page prompt context unchanged
 // in this flow-only fixture.
 func linkedPagePrompt(_ prompt: ExplanationPrompt, run: LauncherRun, detailed: Bool) -> ExplanationPrompt { prompt }
 // prepareLinkedSourceIfNeeded(input, mode, model, run, tempDir, continuation):
 // Skip page fetching so the test controls response materialization directly.
 func prepareLinkedSourceIfNeeded(input: String, mode: String, model: String, run: LauncherRun,
                                 tempDir: URL, continuation: @escaping () -> Void) -> Bool { false }
 // updateGenerationProgress(run, status): Keep this production dependency
 // inactive in the isolated fixture.
 func updateGenerationProgress(_ run: LauncherRun, status: String) {}
 // progressStatus(mode, secondary, model): Suppress progress wording unrelated
 // to completion behavior.
 func progressStatus(for mode: String, secondary: String, model: String) -> String { "" }
 // modeName(mode): Use a stable translation mode label for error assertions.
 func modeName(for mode: String) -> String { "Translate" }
 // featureTitle(mode): Use the same stable feature label in HUD notices.
 func featureTitle(for mode: String) -> String { "Translate" }
 // resultTitle(mode, secondary, output): Supply a fixed result title for
 // generated translation files.
 func resultTitle(for mode: String, secondary: String, output: String) -> String { "Translation" }
 // setGenerating(value, status): Record transitions into and out of generation.
 func setGenerating(_ value: Bool, status: String) { isGenerating = value }
 // presentError(title, details): Collect visible error titles and details for
 // assertions.
 func presentError(_ title: String, details: String) { alerts.append((title, details)) }
 // linkedPageResult(text, run, detailed, tempDir): Count result materialization
 // so skipped text cannot accidentally produce assets.
 func linkedPageResult(_ text: String, run: LauncherRun, detailed: Bool, tempDir: URL) async throws -> String {
  materializeCalls += 1
  return text
 }
 // writeDiffFilesIfNeeded(input, transformed, mode, tempDir): Count diff
 // preparation calls without creating comparison files.
 func writeDiffFilesIfNeeded(input: String, transformed: String, mode: String, tempDir: URL) throws -> (original: String?, revised: String?) {
  diffCalls += 1
  return (nil, nil)
 }
 // generateSpeechThenOpen(text, model, voice, textPath, title, tempDir, run,
 // [diffOriginalPath = nil], [diffRevisedPath = nil]): Record pre-open
 // narration requests instead of generating speech.
 func generateSpeechThenOpen(text: String, model: String, voice: String, textPath: String, title: String,
                            tempDir: URL, run: LauncherRun, diffOriginalPath: String? = nil, diffRevisedPath: String? = nil) {
  narrationCalls += 1; isGenerating = false
 }
 // finishGeneratedExplanation(textPath, audioPath, title, cleanupDir, run,
 // [diffOriginalPath = nil], [diffRevisedPath = nil]): Record result
 // presentation without opening a viewer.
 func finishGeneratedExplanation(textPath: String, audioPath: String, title: String, cleanupDir: String,
                                 run: LauncherRun, diffOriginalPath: String? = nil, diffRevisedPath: String? = nil) {
  openCalls += 1; isGenerating = false
 }
'''
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['    func generateTextTransform(', '    func generateExplanation(', '    func failLauncherRun(', '    func completeTransformRun(']:
    source += block(marker) + '\n'
source += r'''
}
var checks = 0
// check(condition, message): Report failed fixture expectations with their case
// names.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
 // Stop this fixture when its named expectation does not hold.
 guard condition() else { fputs("FAILED: " + message + "\n", stderr); exit(1) }
 checks += 1
}
// waitUntil(finished): Wait for production asynchronous completion with a fixed
// deadline.
func waitUntil(_ finished: () -> Bool) {
 let deadline = Date().addingTimeInterval(3)
 // Pump the main run loop while waiting for the transform to finish.
 while !finished() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
 check(finished(), "The transform completes without blocking the main thread")
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
// directory(): Create a separate temporary directory for each generated-result
// case.
func directory() throws -> URL {
 let url = root.appendingPathComponent(UUID().uuidString)
 try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
 return url
}
// start(controller, run, directory, [audio = true]): Initialize request
// ownership before running the production transform path.
func start(_ controller: LauncherController, _ run: LauncherRun, at directory: URL, audio: Bool = true) {
 controller.activeRun = run
 controller.activeTempDir = directory
 controller.generateTextTransform(input: controller.prompt.input, mode: "translate", secondary: "sr",
                                  model: "offline", wantsAudio: audio, ttsModel: "offline", voice: "offline",
                                  tempDir: directory, run: run)
}

// Both delivery paths stop before output files, narration, or success callbacks.
for clipboard in [false, true] {
 // Recognize both plain and fenced versions of the internal translation skip marker.
 for response in ["fixture-skip-marker", "```\nfixture-skip-marker\n```"] {
  let controller = LauncherController(), run = LauncherRun(), folder = try directory()
  var clipboardText = "Original clipboard", deliveredError: Error?, calls = 0
  // Use HUD presentation for clipboard variants of the skipped-result case.
  if clipboard {
   run.presentation = .clipboardHUD
   run.transformCompletion = { _, result in
    calls += 1
    // Capture either transformed text or its distinct failure outcome.
    switch result {
    // Record delivered text so accidental clipboard changes can be detected.
    case .success(let text): clipboardText = text
    // Record the failure type supplied to the transform caller.
    case .failure(let error): deliveredError = error
    }
   }
  }
  providerResponse = .success(response)
  start(controller, run, at: folder)
  waitUntil { !controller.isGenerating }
  check(clipboardText == "Original clipboard", "Skipped output cannot replace the clipboard")
  check(controller.inputView.text == "Fixture input", "Skipped requests retain the input")
  check(controller.narrationCalls == 0 && controller.openCalls == 0 && controller.diffCalls == 0,
        "Skipping creates no narration, result window, or diff")
  check(controller.materializeCalls == 0, "Skipping stops before output asset processing")
  check(!FileManager.default.fileExists(atPath: folder.path), "Skipping removes the run's temporary directory")
  check(controller.activeRun == nil && controller.activeTextTask == nil && controller.activeTempDir == nil,
        "Skipping releases the active run and request")
  // Clipboard callers should receive exactly one TranslationSkipped outcome.
  if clipboard {
   check(calls == 1 && deliveredError is TranslationSkipped, "The clipboard gets one distinct skipped outcome")
  } else {
      // Normal launcher callers should receive the user-facing skipped-translation explanation.
   check(controller.alerts.first?.0 == "Translation skipped" && controller.alerts.first?.1 == "Already in this language.",
         "The launcher shows a skip notice rather than a translation error")
  }
 }
}

// A remaining translation follows the normal clipboard path with formatting intact.
let translated = "## Русский\n\nПервый абзац.\n\nВторой абзац."
// Isolate the clipboard callback and temporary files for successful translation.
do {
 let controller = LauncherController(), run = LauncherRun(), folder = try directory()
 var clipboardText = "Original clipboard"
 run.transformCompletion = { _, result in clipboardText = (try? result.get()) ?? "failure" }
 providerResponse = .success(translated)
 start(controller, run, at: folder)
 waitUntil { !controller.isGenerating }
 check(clipboardText == translated, "The remaining translation is delivered intact")
 check(controller.inputView.text.isEmpty, "Successful delivery always clears the submitted input")
 check(!FileManager.default.fileExists(atPath: folder.path), "Successful clipboard delivery cleans its temporary directory")
}
// Deliver the translated result with either manual or automatic narration.
for audio in [false, true] {
 let controller = LauncherController(), run = LauncherRun(), folder = try directory()
 providerResponse = .success(translated)
 start(controller, run, at: folder, audio: audio)
 waitUntil { !controller.isGenerating }
 let saved = try String(contentsOf: folder.appendingPathComponent("result.txt"), encoding: .utf8)
 check(saved == translated + "\n", "Result files retain the remaining translation")
 check(controller.openCalls == (audio ? 0 : 1) && controller.narrationCalls == (audio ? 1 : 0),
       "Normal window and automatic narration paths still run")
}

// Explain and Dictionary deliver readable text through the HUD callback, even with auto-audio on.
for mode in ["explain", "dictionary"] {
 // Check successful result completion across both narration preferences.
 for audio in [false, true] {
  let controller = LauncherController(), run = LauncherRun(), folder = try directory()
  var delivered = "", completions = 0
  run.presentation = .clipboardHUD
  run.transformCompletion = { _, result in delivered = (try? result.get()) ?? "failure"; completions += 1 }
  controller.activeRun = run
  controller.activeTempDir = folder
  // Explain receives the structured response expected by its parser.
  if mode == "explain" {
   providerResponse = .success(#"{"title":"Ice","explanation":"Ice is less dense than water."}"#)
   controller.generateExplanation(question: "Why does ice float?", effort: "short", model: "offline",
       wantsAudio: audio, ttsModel: "offline", voice: "offline", tempDir: folder, run: run)
  } else {
      // Dictionary receives a Markdown entry through the ordinary transform path.
   providerResponse = .success("# Karate\n\nA martial art.")
   controller.generateTextTransform(input: "Karate", mode: mode, secondary: "short", model: "offline",
       wantsAudio: audio, ttsModel: "offline", voice: "offline", tempDir: folder, run: run)
  }
  waitUntil { !controller.isGenerating }
  check(completions == 1 && delivered == (mode == "explain" ? "Ice\n\nIce is less dense than water." : "# Karate\n\nA martial art."),
        "\(mode) delivers one complete, readable result rather than provider JSON")
  check(controller.openCalls == 0 && controller.narrationCalls == 0, "\(mode) waits in the HUD before any window or automatic narration")
  check(controller.inputView.text.isEmpty, "Successful HUD delivery clears the submitted input")
  check(controller.activeRun == nil && controller.activeTempDir == nil && !FileManager.default.fileExists(atPath: folder.path),
        "\(mode) releases generation state and temporary files after HUD delivery")
 }
}

// Failures and cancellations keep input available for editing or retrying.
for error: Error in [HelperFailure(message: "Fixture provider failure"), LauncherCancellationError()] {
 let controller = LauncherController(), run = LauncherRun(), folder = try directory()
 providerResponse = .failure(error)
 start(controller, run, at: folder)
 waitUntil { !controller.isGenerating }
 check(controller.inputView.text == "Fixture input", "Failed and cancelled requests retain their input")
 check(controller.openCalls == 0 && controller.narrationCalls == 0, "Failures do not present a successful result")
}

// Late responses from a cancelled run cannot complete a newer request.
do {
 let controller = LauncherController(), run = LauncherRun(), folder = try directory()
 completesImmediately = false
 start(controller, run, at: folder)
 let replacement = LauncherRun()
 controller.activeRun = replacement
 requestCompletion?(.success("fixture-skip-marker"))
 waitUntil { !FileManager.default.fileExists(atPath: folder.path) }
 check(controller.activeRun === replacement && controller.alerts.isEmpty, "Late skips cannot change the newer run")
 check(controller.openCalls == 0 && controller.narrationCalls == 0, "Late skips create no result or audio")
 check(controller.inputView.text == "Fixture input", "Late callbacks cannot clear a newer request's input")
}
print("\(checks) text delivery checks passed; no model, clipboard, or speech services used")
'''

with tempfile.TemporaryDirectory(prefix='langmin-translation-flow-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', *swift_fixture_args(), '-O', '-module-cache-path', cache,
                    '-target', f'{platform.machine()}-apple-macos14.0',
                    str(folder / 'main.swift'), '-o', str(folder / 'tests')], check=True)
    subprocess.run([str(folder / 'tests'), directory], check=True, timeout=30)
