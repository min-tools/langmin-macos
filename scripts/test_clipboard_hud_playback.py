#!/usr/bin/env python3
"""Check HUD playback, window transfer and Library copies without live providers or audible output.

The native audio-export check needs access to macOS codec services.
"""
from pathlib import Path
import os
import platform
import shutil
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


hud = app_source('ClipboardProgressHUD.swift')
# Expose state only in this fixture. Keep the real HUD layout and lifecycle methods.
hud = hud.replace('private ', '').replace('import AVFoundation', '')
hud = hud.replace('AVAudioPlayer', 'FixtureAudioPlayer')
hud = hud.replace('NSPasteboard.general', 'FixturePasteboard.general')
# Exercise completion and reset without showing a panel over the user's workspace.
hud = hud.replace('panel?.makeKeyAndOrderFront(nil)', '')
hud = hud.replace('        showPanel()', '        // Fixture stays off screen.')

source = r'''
import Cocoa
import AVFoundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
// localized(key, english): Resolve labels through the fixture’s controlled
// localization.
func localized(_ key: String, _ english: String) -> String { english }
// normalizedGeneratedMarkdown(text): Keep fixture Markdown unchanged;
// normalization is exercised in its own tests.
func normalizedGeneratedMarkdown(_ text: String) -> String { text }
// Represent fixture failures using the app’s localized-error contract.
struct HelperFailure: LocalizedError {
 let message: String
 var errorDescription: String? { message }
}
// Keep clipboard writes in memory so playback tests cannot change the user's clipboard.
final class FixturePasteboard {
 static let general = FixturePasteboard()
 var text: String?
 // clearContents(): Clear only the fixture's simulated clipboard.
 func clearContents() { text = nil }
 // setString(text, forType): Record copied text for the paragraph-action
 // assertions.
 func setString(_ text: String, forType: NSPasteboard.PasteboardType) { self.text = text }
}
// Control the selected voice and model independently of saved app preferences.
struct Preferences { var ttsVoice = "openAI"; var ttsModel = "fixture-model" }
var preferences = Preferences()
var allowed = true, missingKey = false, failDirectory = false, failStart = false
var consentAction: (() -> Void)?
// loadAppPreferences(): Provide the preferences configured by this fixture.
func loadAppPreferences() -> Preferences { preferences }
// Represent all providers covered by HUD speech routing.
enum NarrationProvider: String { case apple, grok, openAI }
// narrationProvider(voice): Use fixture voice names as explicit provider
// identifiers.
func narrationProvider(for voice: String) -> NarrationProvider { NarrationProvider(rawValue: voice)! }
// confirmRemoteNarrationSharingIfNeeded(provider): Return configured consent
// and optionally simulate changes while the consent dialog is open.
func confirmRemoteNarrationSharingIfNeeded(provider: NarrationProvider) -> Bool { consentAction?(); return allowed }
// loadGrokAPIKey(): Simulate either a missing xAI key or a non-secret
// placeholder credential.
func loadGrokAPIKey() -> String { missingKey ? "" : "fixture" }
// loadOpenAIAPIKey(): Simulate the same credential states for OpenAI.
func loadOpenAIAPIKey() -> String { missingKey ? "" : "fixture" }
// appleVoiceIdentifier(voice): Keep the Apple voice identifier unchanged for
// request assertions.
func appleVoiceIdentifier(from voice: String) -> String { voice }
// grokVoiceID(voice): Keep the Grok voice identifier unchanged for request
// assertions.
func grokVoiceID(from voice: String) -> String { voice }
// ttsModel(voice, requestedModel): Use the requested fixture model without
// consulting a provider catalog.
func ttsModel(forVoice voice: String, requestedModel: String) -> String { requestedModel }
// narrationModelLabel(provider, model): Expose provider and model together in
// recorded narration metadata.
func narrationModelLabel(provider: NarrationProvider, model: String) -> String { provider.rawValue + ":" + model }
// createLangminTemporaryDirectory(prefix): Create output under the fixture root
// with an injectable directory failure.
func createLangminTemporaryDirectory(prefix: String) throws -> URL {
 // Exercise failures that occur before a speech request can be created.
 if failDirectory { throw HelperFailure(message: "Fixture directory failure") }
 let directory = root.appendingPathComponent(prefix + UUID().uuidString)
 try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
 return directory
}
// Provide the resume/cancel interface required by the real playback controller.
protocol NarrationRequestTask: AnyObject, Sendable { /* resume(): Start or resume the speech task supplied by the implementation. */ func resume(); /* cancel(): Cancel the speech task supplied by the implementation. */ func cancel() }
// Record a speech request and let the test control its completion timing.
final class Request: NarrationRequestTask, @unchecked Sendable {
 let text: String, provider: NarrationProvider, voice: String, model: String, output: URL
 let completion: (Result<Void, Error>) -> Void
 var resumed = false, cancelled = false
 // init(text, provider, voice, model, output, completion): Capture the complete
 // request payload and its completion callback.
 init(_ text: String, _ provider: NarrationProvider, _ voice: String, _ model: String, _ output: URL,
      _ completion: @escaping (Result<Void, Error>) -> Void) {
  self.text = text; self.provider = provider; self.voice = voice; self.model = model
  self.output = output; self.completion = completion
 }
 // resume(): Record that production code started this simulated request.
 func resume() { resumed = true }
 // cancel(): Record cancellation without invoking a real speech service.
 func cancel() { cancelled = true }
 // finish(): Complete the simulated request, including a possible late file
 // write.
 func finish() throws {
  // Deliberately recreate a cancelled request's file to exercise late completion cleanup.
  try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data([1, 2, 3]).write(to: output)
  completion(.success(()))
 }
}
var requests: [Request] = []
// record(text, provider, voice, model, output, completion): Create a recorded
// request or inject a setup failure before returning a task.
func record(_ text: String, _ provider: NarrationProvider, _ voice: String, _ model: String, _ output: URL,
            _ completion: @escaping (Result<Void, Error>) -> Void) throws -> NarrationRequestTask {
 // Exercise errors thrown while constructing the provider request.
 if failStart { throw HelperFailure(message: "Fixture request failure") }
 let request = Request(text, provider, voice, model, output, completion)
 requests.append(request)
 return request
}
// startAppleSpeechRequest(text, voiceIdentifier, outputURL, completion): Record
// Apple speech arguments instead of invoking local synthesis.
func startAppleSpeechRequest(text: String, voiceIdentifier: String, outputURL: URL,
                            completion: @escaping (Result<Void, Error>) -> Void) throws -> NarrationRequestTask {
 try record(text, .apple, voiceIdentifier, "", outputURL, completion)
}
// startGrokSpeechRequest(apiKey, text, voiceID, outputURL, completion): Record
// Grok speech arguments without contacting xAI.
func startGrokSpeechRequest(apiKey: String, text: String, voiceID: String, outputURL: URL,
                           completion: @escaping (Result<Void, Error>) -> Void) throws -> NarrationRequestTask {
 try record(text, .grok, voiceID, "", outputURL, completion)
}
// startSpeechRequest(apiKey, text, model, voice, outputURL, completion): Record
// OpenAI speech arguments without network access.
func startSpeechRequest(apiKey: String, text: String, model: String, voice: String, outputURL: URL,
                       completion: @escaping (Result<Void, Error>) -> Void) throws -> NarrationRequestTask {
 try record(text, .openAI, voice, model, outputURL, completion)
}
// Match the completion and decode-error callbacks used by the playback controller.
protocol FixtureAudioPlayerDelegate: AnyObject {
 // audioPlayerDidFinishPlaying(player, flag): Allow tests to signal that
 // simulated playback finished.
 func audioPlayerDidFinishPlaying(_ player: FixtureAudioPlayer, successfully flag: Bool)
 // audioPlayerDecodeErrorDidOccur(player, error): Allow tests to inject an
 // audio-decoding error.
 func audioPlayerDecodeErrorDidOccur(_ player: FixtureAudioPlayer, error: Error?)
}
// Model audio playback state and injectable player failures without playing sound.
final class FixtureAudioPlayer {
 weak var delegate: FixtureAudioPlayerDelegate?
 static var failDecode = false, failPlay = false
 var stopped = false, playing = false
 let data: Data
 // init(data): Capture audio bytes and optionally simulate decoder rejection.
 init(data: Data) throws {
  // Exercise a generated clip that the player cannot decode.
  if Self.failDecode { throw HelperFailure(message: "Fixture decode failure") }
  self.data = data
 }
 // init(url): Load fixture audio bytes through the same path-based initializer
 // shape.
 convenience init(contentsOf url: URL) throws { try self.init(data: Data(contentsOf: url)) }
 // play(): Simulate success or failure when playback starts.
 func play() -> Bool { playing = !Self.failPlay; return playing }
 // stop(): Record stopping and clear the simulated playing state.
 func stop() { stopped = true; playing = false }
}
var mergeInputs: [[URL]] = []
var mergeOutputs: [URL] = []
var mergeFailure = false
var useRealMerge = false
var mergeContinuation: CheckedContinuation<Void, Never>?
var holdMerge = false
// mergeNarrationChunks(urls, output): Record merge inputs and choose simulated
// or real audio-export behavior explicitly.
@MainActor func mergeNarrationChunks(_ urls: [URL], to output: URL) async throws -> [TimeInterval] {
 mergeInputs.append(urls)
 mergeOutputs.append(output)
 // Run the real merger only for the dedicated audio-export checks.
 if useRealMerge {
  // Run the native merge so the fixture exercises real audio export.
  do { return try await realMergeNarrationChunks(urls, to: output) }
  // Print the native export error before propagating it to the fixture.
  catch { print("Audio export error:", error as NSError); throw error }
 }
 // Pause merging to exercise cancellation and handoff races.
 if holdMerge { await withCheckedContinuation { mergeContinuation = $0 } }
 // Inject an export failure after the handoff has begun.
 if mergeFailure { throw HelperFailure(message: "Fixture merge failure") }
 var data = Data()
 // Combine fixture bytes in clip order for ordinary deterministic handoff checks.
 for url in urls { data.append(try Data(contentsOf: url)) }
 try data.write(to: output)
 return urls.indices.map { Double($0) * 2.5 }
}
'''
source += block('struct NarrationChunkTiming:') + '\n'
source += block('func narrationMergeError(') + '\n'
source += block('func mergeNarrationChunks(').replace('func mergeNarrationChunks(', 'func realMergeNarrationChunks(') + '\n'
source += block('let langminControlBorderColor =') + '\n'
source += block('final class NativeSeparator:') + '\n'
source += hud
source += r'''
// Supply the source-image metadata shape without image-validation dependencies.
struct SourceImageAsset: Codable { var isValid: Bool { true } }
// Retain the conversation origin passed into a detached result.
struct ResultConversation: Codable { var originalRequest = "" }
// copySourceImageAssets(assets, from, to): Pass fixture image references
// through unchanged; asset copying is tested separately.
func copySourceImageAssets(_ assets: [SourceImageAsset]?, from: URL, to: URL) throws -> [SourceImageAsset]? { assets }
// appWindowTitle(mode, title): Provide predictable window titles without the
// production title-formatting dependency.
func appWindowTitle(mode: String, title: String) -> String { mode + " — " + title }
'''
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['struct ViewerConfig {', 'struct LibraryEntry:', 'struct PronunciationRef:']:
    source += block(marker) + '\n'
source += '''
// Use a task-owned Library directory for persistence and deletion checks.
enum LibraryStore {
 // entryDirectory(id): Resolve each fixture entry beneath its isolated Library
 // root.
 static func entryDirectory(id: String) -> URL { root.appendingPathComponent("library").appendingPathComponent(id) }
 // invalidateEntryCache(): Keep this production dependency inactive in the
 // isolated fixture.
 static func invalidateEntryCache() {}
 // delete(id): Delete only the entry directory created by this fixture.
 static func delete(id: String) { try? FileManager.default.removeItem(at: entryDirectory(id: id)) }
'''
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['    static func save(config:', '    private static func copy(', '    private static func copyOptional(',
               '    private static func savePronunciations(', '    static func viewerConfig(',
               '    static func updateNarration(', '    private static func writeEntry(']:
    source += block(marker) + '\n'
source += '}\n'
source += r'''
// Record result metadata and errors without constructing the full launcher.
final class FixtureLauncher {
 var lastRunTextModel = "fixture"
 var errors: [String] = []
 // resultTitle(mode, secondary, output): Use a fixed result title so handoff
 // assertions target metadata transfer.
 func resultTitle(for mode: String, secondary: String, output: String) -> String { "Fixture result" }
 // featureTitle(mode): Use the raw mode identifier as a deterministic feature
 // label.
 func featureTitle(for mode: String) -> String { mode }
 // presentError(title, details): Collect launcher error details for assertions.
 func presentError(_ title: String, details: String) { errors.append(details) }
 // libraryDidChange(): Keep this production dependency inactive in the isolated
 // fixture.
 func libraryDidChange() {}
}
// Own simulated viewer sessions during HUD-to-window transfer tests.
final class FixtureDelegate {
 let launcherController = FixtureLauncher()
 var sessions: [ViewerSession] = []
 // resultSession(textPath, audioPath, title, cleanupDir, textModel,
 // [dictionaryHeadword = nil], mode, [languageLevel = "off"]): Create the
 // lightweight viewer with the exact metadata passed by the handoff.
 func resultSession(textPath: String, audioPath: String, title: String, cleanupDir: String,
                    textModel: String?, dictionaryHeadword: String? = nil, mode: String, languageLevel: String = "off") -> ViewerSession {
  ViewerSession(config: ViewerConfig(textPath: textPath, fontSize: 13, audioPath: audioPath,
                title: title, cleanupDir: cleanupDir, textModel: textModel, dictionaryHeadword: dictionaryHeadword,
                mode: mode, languageLevel: languageLevel), appDelegate: self)
 }
 // presentResultSession(session): Record presentation without opening a full
 // result window.
 func presentResultSession(_ session: ViewerSession) { sessions.append(session) }
 // removeSession(session): Release the recorded session when its close path
 // finishes.
 func removeSession(_ session: ViewerSession) { sessions.removeAll { $0 === session } }
 // OPEN METHOD
}
// Supply the tooltip property expected by result controls.
final class TooltipButton: NSButton { var tooltipMessage = "" }
// Supply the same tooltip property for title-bar controls.
final class TitlebarTooltipButton: NSButton { var tooltipMessage = "" }
// toolbarSymbolImage(name, tooltip, pointSize): Omit toolbar images because
// this fixture checks transfer ownership rather than icon drawing.
func toolbarSymbolImage(_ name: String, tooltip: String, pointSize: CGFloat) -> NSImage? { nil }
// Suppress palette closing as an unrelated viewer dependency.
final class FixturePanel { /* closePalette(): Keep palette dismissal inert in this isolated fixture. */ func closePalette() {} }
// Accept editor-toolbar changes without constructing the real toolbar.
final class FixtureToolbar { /* setEditingControls(controls): Ignore editor controls that the playback fixture does not exercise. */ func setEditingControls(_ controls: NSView?) {} }
// Host production narration-transfer and cleanup methods with recorded viewer state.
final class ViewerSession: NSObject {
 var textEditor: NSView?
 var resultToolbar: FixtureToolbar?
 var editorHiddenViews: [NSView] = []
 var config: ViewerConfig
 var content: String
 weak var appDelegate: FixtureDelegate?
 var resourcesReleased = false
 var hudNarration: ClipboardHUDPlayback?
 var narrationRunID: UUID?
 var narrationTask: NarrationRequestTask?
 var narrationTasks: [NarrationRequestTask] = []
 var narrationVoiceUsed: String?, narrationModelUsed: String?
 var narrationSegments: [NarrationChunkTiming] = []
 var narrationButton: NSButton? = NSButton()
 var saveToLibraryButton: NSButton? = NSButton()
 var isGeneratingNarration = false
 var generatedAudioCleanupDir = ""
 var activeAudioPath = ""
 var savedLibraryID: String?
 var pronounceCache: [String: URL] = [:]
 var pronunciationCleanupDirs: Set<String> = []
 var diffOriginalContent = "", diffRevisedContent = ""
 var followUpModelPanel: FixturePanel?
 var illustrationCleanupDir = ""
 var trafficLightReinsetWorkItem: DispatchWorkItem?
 var headwordRunID: UUID?, headwordTask: NarrationRequestTask?, headwordPlayer: FixtureAudioPlayer?
 var autoplayed = false, revealed = false
 var errors: [String] = []
 var audioAvailable: Bool { !activeAudioPath.isEmpty && FileManager.default.fileExists(atPath: activeAudioPath) }
 // init(config, appDelegate): Load the transferred config and retain the
 // fixture delegate.
 init(config: ViewerConfig, appDelegate: FixtureDelegate) {
  self.config = config
  self.appDelegate = appDelegate
  content = (try? String(contentsOfFile: config.textPath, encoding: .utf8)) ?? ""
  activeAudioPath = config.audioPath
  super.init()
 }
 // resolveNarrationSegments(timings): Keep timing data unchanged so handoff
 // ownership can be asserted directly.
 func resolveNarrationSegments(_ timings: [NarrationChunkTiming]) -> [NarrationChunkTiming] { timings }
 // revealAudioControls([autoplay = true]): Record whether controls were
 // revealed and whether autoplay was requested.
 func revealAudioControls(autoplay: Bool = true) { revealed = true; autoplayed = autoplay }
 // presentViewerError(title, details): Collect viewer errors instead of
 // presenting modal alerts.
 func presentViewerError(_ title: String, details: String) { errors.append(details) }
 // updateNarrationStats(): Keep this production dependency inactive in the
 // isolated fixture.
 func updateNarrationStats() {}
 // setResultTitleMessage(text): Keep this production dependency inactive in the
 // isolated fixture.
 func setResultTitleMessage(_ text: String?) {}
 // cancelFollowUp(): Keep this production dependency inactive in the isolated
 // fixture.
 func cancelFollowUp() {}
 // cancelIllustration(): Keep this production dependency inactive in the
 // isolated fixture.
 func cancelIllustration() {}
 // removeModifierKeyMonitor(): Keep this production dependency inactive in the
 // isolated fixture.
 func removeModifierKeyMonitor() {}
 // stopAudio(): Keep this production dependency inactive in the isolated
 // fixture.
 func stopAudio() {}
 // hidePronounceSpinner(): Keep this production dependency inactive in the
 // isolated fixture.
 func hidePronounceSpinner() {}
 // SESSION METHODS
}
'''
source = source.replace('// OPEN METHOD', block('    func openDetachedResultWindow(')
                        .replace('NSApp.activate(ignoringOtherApps: true)', ''))
methods = ['    func adoptHUDNarration(', '    func finishChunkedNarration(',
           '    func persistNarrationToLibraryIfSaved(', '    func cancelNarrationGeneration()',
           '    func releaseResources()', '    func windowWillClose(',
           '    @objc func saveToLibraryFromToolbar(', '    func updateSaveToLibraryButton()',
           '    func detachLibraryBackedAssetsIfNeeded()']
source = source.replace('// SESSION METHODS', '\n'.join(block(marker) for marker in methods))
source += r'''
_ = NSApplication.shared
var checks = 0
// check(value, message): Report failed fixture expectations with their case
// names.
func check(_ value: @autoclosure () -> Bool, _ message: String) {
 // Stop this fixture when its named expectation does not hold.
 guard value() else { fputs("FAILED: \(message)\n", stderr); exit(1) }
 checks += 1
}
// drain(): Drain queued main-thread callbacks with a bounded run loop.
func drain() {
 var drained = false
 DispatchQueue.main.async { drained = true }
 let deadline = Date().addingTimeInterval(2)
 // Wait only until the queued sentinel runs or the fixture deadline expires.
 while !drained && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
 check(drained, "Main queue completed pending callbacks")
}
// exists(url): Check whether a task-owned output file still exists.
func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
// waitFor(condition): Wait for an asynchronous handoff with a fixed deadline.
func waitFor(_ condition: () -> Bool) {
 let deadline = Date().addingTimeInterval(3)
 // Keep AppKit responsive while waiting for the handoff condition.
 while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
 check(condition(), "Asynchronous handoff completed")
}
let playback = ClipboardHUDPlayback()
var completions: [Error?] = []
playback.onFinish = { completions.append($0) }
// Check argument routing and playback for every speech provider.
for voice in ["apple", "grok", "openAI"] {
 preferences.ttsVoice = voice
 playback.play("Честа питања 👨‍👩‍👧‍👦")
 let request = requests.last!
 check(request.provider.rawValue == voice && request.voice == voice, "Selected Reader voice and provider")
 check(request.text == "Честа питања 👨‍👩‍👧‍👦" && request.resumed, "Exact paragraph text reaches speech request")
 check(request.output.pathExtension == (voice == "apple" ? "caf" : "mp3"), "Provider audio format")
 // OpenAI requests must retain the explicitly chosen speech model.
 if voice == "openAI" { check(request.model == "fixture-model", "Selected speech model") }
 try request.finish(); drain()
 let player = playback.player!
 check(player.playing && player.data == Data([1, 2, 3]), "Playback starts from the generated clip")
 check(exists(request.output), "Completed clip stays available in the HUD")
 player.delegate?.audioPlayerDidFinishPlaying(player, successfully: true)
 check(player.stopped && playback.player == nil && completions.last! == nil, "Completion releases playback")
 let requestCount = requests.count
 playback.play("Честа питања 👨‍👩‍👧‍👦")
 check(requests.count == requestCount && playback.player != nil, "Repeated playback reuses the clip")
 playback.stop()
}

playback.play("First")
let first = requests.last!
playback.play("Second")
let second = requests.last!
check(first.cancelled && !exists(first.output.deletingLastPathComponent()), "Switching paragraphs cancels and cleans the old request")
try first.finish(); drain()
check(playback.player == nil && playback.request === second && !exists(first.output), "Late audio never starts or replaces the current request")
try second.finish(); drain()
let oldPlayer = playback.player!
playback.play("Third")
let third = requests.last!
oldPlayer.delegate?.audioPlayerDecodeErrorDidOccur(oldPlayer, error: nil)
check(oldPlayer.stopped && playback.request === third, "Old player callbacks cannot stop new playback")
playback.stop()
try third.finish(); drain()
check(third.cancelled && playback.player == nil && !exists(third.output), "Stopping during generation prevents late playback")

let count = requests.count
allowed = false
playback.play("Declined")
allowed = true
check(requests.count == count && playback.runID == nil && completions.last! == nil, "Declined consent resets controls without sending text")
consentAction = { playback.stop() }
playback.play("Dismissed during consent")
consentAction = nil
check(requests.count == count && playback.runID == nil, "Dismissal during consent prevents a request")
missingKey = true
playback.play("Missing key")
check(requests.count == count && completions.last! != nil, "Missing cloud key reports an error")
preferences.ttsVoice = "apple"
playback.play("Local voice")
check(requests.count == count + 1, "Apple playback does not require a key")
playback.stop(); missingKey = false

// Exercise each distinct preparation, transport, decode, and playback failure.
for failure in ["directory", "request", "network", "missing audio", "decode", "play"] {
 failDirectory = failure == "directory"
 failStart = failure == "request"
 FixtureAudioPlayer.failDecode = failure == "decode"
 FixtureAudioPlayer.failPlay = failure == "play"
 let previousCompletions = completions.count
 playback.play("Failure fixture")
 // Complete only requests that survived directory and request setup.
 if !failDirectory && !failStart {
  let request = requests.last!
  // Inject a provider transport failure through its completion callback.
  if failure == "network" { request.completion(.failure(HelperFailure(message: "Offline"))) }
  // Model a success callback that never produced an audio file.
  else if failure == "missing audio" { request.completion(.success(())) }
  // Other failure cases first produce a normal output clip.
  else { try request.finish() }
  drain()
  check(!exists(request.output.deletingLastPathComponent()), "Failure removes temporary audio: \(failure)")
 }
 check(completions.count == previousCompletions + 1 && completions.last! != nil, "Failure reports once: \(failure)")
 check(playback.runID == nil && playback.player == nil && playback.request == nil, "Failure resets playback: \(failure)")
}
failDirectory = false; failStart = false
FixtureAudioPlayer.failDecode = false; FixtureAudioPlayer.failPlay = false
var transient: ClipboardHUDPlayback? = ClipboardHUDPlayback()
transient!.play("Released HUD")
let orphan = requests.last!
transient = nil
try orphan.finish(); drain()
check(orphan.cancelled && !exists(orphan.output), "Releasing playback cancels and cleans late output")

// Render the reported CJK explanation with real Markdown citations and paragraph actions.
let linkedHUD = ClipboardProgressHUDController()
linkedHUD.buildPanel(reduceTransparency: true)
linkedHUD.activeToken = UUID()
let linkedMarkdown = #"""
### Kangxi radical “fly”

⾶ is **KANGXI RADICAL FLY**, Unicode **U+2FB6**. It represents the traditional Chinese character 飛, meaning “to fly” or “flying”, and is **Kangxi radical 183**, consisting of nine strokes. It is mainly used as a dictionary-indexing radical rather than as an ordinary standalone Chinese word. ([unicode.org](https://www.unicode.org/charts/nameslist/n_2F00.html?utm_source=openai))

The simplified counterpart of 飛 is 飞.

### Sources
[1] [Unicode character names](https://www.unicode.org/charts/nameslist/n_2F00.html?utm_source=openai)
"""#
linkedHUD.complete(token: linkedHUD.activeToken, message: "Explain", detail: "Fixture model", style: .success,
                   dismissAfter: 0, resultText: linkedMarkdown, open: { _ in })
let linkedView = linkedHUD.resultTextView!
let linkedText = linkedView.textStorage!
check(!linkedView.string.contains("](https:") && !linkedView.string.contains("utm_source"), "The HUD shows link labels instead of raw Markdown URLs")
check(linkedView.string.contains("⾶") && linkedView.string.contains("飛") && linkedView.string.contains("飞"), "Rendering preserves distinct CJK characters")
let expectedURL = URL(string: "https://www.unicode.org/charts/nameslist/n_2F00.html?utm_source=openai")!
for label in ["unicode.org", "Unicode character names"] {
 let range = (linkedText.string as NSString).range(of: label)
 check(linkedText.attribute(.link, at: range.location, effectiveRange: nil) as? URL == expectedURL, "Inline and Sources links keep the complete destination")
}
let escaped = linkedHUD.renderedResult(#"[A \[B\]](https://example.com/Fly_(radical)) and `x_y`"#)
check(escaped.string.contains("A [B]") && escaped.string.contains("x_y"), "Escaped labels and inline code render literally")
check(escaped.attribute(.link, at: 0, effectiveRange: nil) as? URL == URL(string: "https://example.com/Fly_(radical)"), "Balanced parentheses stay in link destinations")
let codeIndex = (escaped.string as NSString).range(of: "x_y").location
check((escaped.attribute(.font, at: codeIndex, effectiveRange: nil) as? NSFont)?.isFixedPitch == true, "Inline code has monospaced typography")
let unsafeLinks = linkedHUD.renderedResult("[File](file:///private/tmp/fixture.txt) [Action](langmin://run) [Mail](mailto:hello@example.com)")
check(unsafeLinks.attribute(.link, at: 0, effectiveRange: nil) == nil, "Local files are not actionable generated links")
check(unsafeLinks.attribute(.link, at: (unsafeLinks.string as NSString).range(of: "Action").location, effectiveRange: nil) == nil, "App-internal URLs are not actionable generated links")
check(unsafeLinks.attribute(.link, at: (unsafeLinks.string as NSString).range(of: "Mail").location, effectiveRange: nil) as? URL == URL(string: "mailto:hello@example.com"), "Email links remain supported")
let headingLink = linkedHUD.renderedResult("### [Unicode](https://example.com/CaseSensitive)")
check(headingLink.string == "UNICODE\n" && (headingLink.attribute(.link, at: 0, effectiveRange: nil) as? URL)?.path == "/CaseSensitive", "Heading capitalization never alters a link destination")
for line in ["- A bullet", "12. A numbered item", "[1] [Source](https://example.com)"] {
 let rendered = linkedHUD.renderedResult(line)
 let style = rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
 check(rendered.string.contains("\t") && style.headIndent > style.firstLineHeadIndent,
       "Wrapped list and source lines align after their markers")
}
linkedHUD.panel?.contentView?.layoutSubtreeIfNeeded()
let linkedLayout = linkedView.layoutManager!
linkedLayout.ensureLayout(for: linkedView.textContainer!)
let bodyRange = (linkedView.string as NSString).range(of: "⾶ is")
let bodyGlyphs = linkedLayout.glyphRange(forCharacterRange: bodyRange, actualCharacterRange: nil)
let firstLine = linkedLayout.lineFragmentUsedRect(forGlyphAt: bodyGlyphs.location, effectiveRange: nil)
linkedView.updateHover(at: NSPoint(x: 2, y: firstLine.midY))
check(abs(linkedView.playButton.frame.midY - firstLine.midY) < 0.5, "Paragraph controls align with the first CJK text line")
linkedView.copyHoveredParagraph(nil)
check(FixturePasteboard.general.text?.contains("⾶ is KANGXI RADICAL FLY") == true, "Copy uses the rendered paragraph without losing Unicode")

// Save both appearances without opening links or changing the user's active window.
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
 linkedHUD.panel?.appearance = NSAppearance(named: appearance)
 let card = linkedHUD.panel!.contentView!
 card.layoutSubtreeIfNeeded()
 let bitmap = card.bitmapImageRepForCachingDisplay(in: card.bounds)!
 linkedHUD.panel!.appearance!.performAsCurrentDrawingAppearance { card.cacheDisplay(in: card.bounds, to: bitmap) }
 try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(appearance == .aqua ? "hud-links-light.png" : "hud-links-dark.png"))
}
// Rebuilding the native material must re-render the original Markdown, not the visible labels.
linkedHUD.builtForReducedTransparency = nil
linkedHUD.accessibilityDisplayOptionsChanged(Notification(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification))
let rebuiltText = linkedHUD.resultTextView!.textStorage!
let rebuiltLink = (rebuiltText.string as NSString).range(of: "unicode.org")
check(linkedHUD.resultMarkdown == linkedMarkdown && rebuiltText.attribute(.link, at: rebuiltLink.location, effectiveRange: nil) as? URL == expectedURL,
      "An accessibility rebuild retains Markdown and clickable links")
linkedHUD.dismiss(token: linkedHUD.activeToken, animated: false)
check(linkedHUD.resultMarkdown == nil, "Dismissal clears the retained Markdown")

// Build the real HUD without showing it or loading the application's saved state.
let hud = ClipboardProgressHUDController()
hud.ensurePanel()
hud.activeToken = UUID()
hud.setResult("## Русский\nЧастые вопросы\n## Српски\nЧеста питања\nЧеста питања")
hud.panel?.contentView?.layoutSubtreeIfNeeded()
let view = hud.resultTextView!
view.layoutManager!.ensureLayout(for: view.textContainer!)
// point(text, [last = false]): Find a rendered text point for paragraph hover
// and click assertions.
func point(_ text: String, last: Bool = false) -> NSPoint {
 let range = (view.string as NSString).range(of: text, options: last ? .backwards : [])
 let glyphs = view.layoutManager!.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
 let rect = view.layoutManager!.boundingRect(forGlyphRange: glyphs, in: view.textContainer!)
 return NSPoint(x: view.textContainerOrigin.x + rect.minX + 2, y: view.textContainerOrigin.y + rect.midY)
}
view.updateHover(at: point("РУССКИЙ"))
check(view.copyButton.isHidden && view.playButton.isHidden, "Language headings have no paragraph actions")
view.updateHover(at: point("Частые вопросы"))
check(!view.copyButton.isHidden && !view.playButton.isHidden, "Hover reveals copy and playback")
check(view.playButton.frame.maxX < view.copyButton.frame.minX, "Paragraph buttons do not overlap")
check(view.playButton.frame.minX >= view.bounds.width - ClipboardHUDMetrics.resultTrailingReserve, "Buttons stay in the reserved margin")
view.copyHoveredParagraph(nil)
check(FixturePasteboard.general.text == "Частые вопросы", "Copy still includes only the hovered paragraph")
view.playHoveredParagraph(nil)
check(requests.last!.text == "Частые вопросы" && !view.stopButton.isHidden && view.playButton.isHidden, "Play targets only the hovered paragraph")
let originalStop = view.stopButton.frame
view.hideIfIdle()
check(!view.stopButton.isHidden && view.playButton.isHidden, "Stop remains reachable off hover")
view.updateHover(at: point("Честа питања"))
check(!view.playButton.isHidden && view.stopButton.frame == originalStop, "Another paragraph can be played while Stop stays beside the active one")
let pending = requests.last!
view.playHoveredParagraph(nil)
check(pending.cancelled && requests.last!.text == "Честа питања", "Switching paragraph controls cancels previous speech")
view.updateHover(at: point("Честа питања", last: true))
check(!view.playButton.isHidden, "Identical paragraph text still has separate controls")
view.stopPlayback(nil)
check(view.stopButton.isHidden && !view.playButton.isHidden, "Stop restores the hovered Play control")

// Exercise every HUD lifecycle change that should clear paragraph interaction state.
for action in ["replace", "suspend", "dismiss", "rebuild"] {
 hud.activeToken = UUID()
 view.updateHover(at: point("Честа питања"))
 view.playHoveredParagraph(nil)
 let request = requests.last!
 // Apply the selected lifecycle change to the current HUD.
 switch action {
 // Replacing result text must invalidate old paragraph targets.
 case "replace": hud.setResult("New result")
 // Suspension hides paragraph actions while the HUD is inactive.
 case "suspend": hud.suspend(token: hud.activeToken)
 // Dismissal clears interaction state along with the panel.
 case "dismiss": hud.dismiss(token: hud.activeToken, animated: false)
 // Rebuilding the panel must discard references to its old paragraph views.
 default: hud.builtForReducedTransparency = nil; hud.ensurePanel()
 }
 try request.finish(); drain()
 check(request.cancelled && hud.playback.player == nil && !exists(request.output), "HUD lifecycle stops speech: \(action)")
 // Text replacement specifically resets targets on the retained text view.
 if action == "replace" {
  check(view.hoveredRange == nil && view.copyButton.isHidden && view.playButton.isHidden && view.stopButton.isHidden, "Replacing text resets all paragraph targets")
  hud.setResult("## Српски\nЧеста питања\nЧеста питања")
 }
}

// Empty content, margins and trailing newlines must never access an invalid glyph or range.
view.resetParagraphActions()
view.string = ""
view.updateHover(at: NSPoint(x: 400, y: 200))
check(view.paragraphText(in: NSRange(location: NSNotFound, length: 1)) == nil, "Stale paragraph ranges are rejected")
check(view.paragraphText(in: NSRange(location: 0, length: Int.max)) == nil, "Oversized ranges are rejected")
view.string = "\n"
// Blank content and points in margins must not expose paragraph actions.
for point in [NSPoint(x: -10, y: -10), NSPoint(x: 400, y: 200), NSPoint(x: 0, y: 0)] { view.updateHover(at: point) }
check(view.playButton.isHidden && view.copyButton.isHidden, "Blank text and margins have no actions")

// Progress expands for the model; failures show their complete explanation without hovering.
let statusHUD = ClipboardProgressHUDController()
let statusToken = statusHUD.begin(title: "Explaining", modelName: "Apple Intelligence", status: "Working", screen: nil, cancel: {})
statusHUD.panel?.contentView?.layoutSubtreeIfNeeded()
// Check that status text fits its allocated width.
for label in [statusHUD.titleLabel!, statusHUD.statusLabel!] {
 let naturalWidth = (label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width
 check(label.frame.width >= floor(naturalWidth), "The complete mode and Apple Intelligence name fit in the progress row")
}
let unsupported = "Apple Intelligence on this Mac does not support output in Russian. Remove that language or choose another text model."
statusHUD.complete(token: statusToken, message: unsupported, style: .failure, dismissAfter: 0.01, retry: {})
statusHUD.panel?.contentView?.layoutSubtreeIfNeeded()
check(statusHUD.titleLabel?.stringValue == "Request failed" && statusHUD.resultTextView?.string == unsupported, "Errors have a short title and complete visible detail")
check(statusHUD.stateIcon?.toolTip == unsupported && statusHUD.stateIcon?.accessibilityLabel() == unsupported, "Warning icon exposes the full error to hover and accessibility")
check(statusHUD.dismissalWorkItem == nil && statusHUD.dismissButton?.isHidden == false, "Failures wait for explicit dismissal")
check(statusHUD.openButton?.isHidden == true && statusHUD.resultTextView?.textStorage?.attribute(.hudCopyableParagraph, at: 0, effectiveRange: nil) == nil, "Error text has no Open or narration actions")
statusHUD.complete(token: statusToken, message: String(repeating: unsupported + "\n", count: 30), style: .failure, dismissAfter: 0.01)
check(statusHUD.resultHeightConstraint?.constant == ClipboardHUDMetrics.resultTextMaxHeight && statusHUD.dismissalWorkItem == nil, "Long errors scroll within a bounded panel and also stay open without Retry")
let nextToken = statusHUD.begin(title: "Looking up", modelName: "Apple Intelligence", status: "Working", screen: nil, cancel: {})
check(statusHUD.failureMessage == nil && statusHUD.stateIcon?.toolTip == nil && statusHUD.resultScroll?.isHidden == true, "A new request clears old errors and tooltips")
statusHUD.complete(token: statusToken, message: unsupported, style: .failure, dismissAfter: 0)
check(statusHUD.failureMessage == nil && statusHUD.activeToken == nextToken, "An older request cannot replace the current HUD")
statusHUD.dismiss(token: nextToken, animated: false)

let errorPreview = ClipboardProgressHUDController()
errorPreview.buildPanel(reduceTransparency: true)
errorPreview.activeToken = UUID()
errorPreview.complete(token: errorPreview.activeToken, message: unsupported, style: .failure, dismissAfter: 0, retry: {})
// Capture actionable error presentation in both system appearances.
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
 errorPreview.panel?.appearance = NSAppearance(named: appearance)
 let card = errorPreview.panel!.contentView!
 card.layoutSubtreeIfNeeded()
 let bitmap = card.bitmapImageRepForCachingDisplay(in: card.bounds)!
 errorPreview.panel!.appearance!.performAsCurrentDrawingAppearance { card.cacheDisplay(in: card.bounds, to: bitmap) }
 try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(appearance == .aqua ? "hud-error-light.png" : "hud-error-dark.png"))
}

let preview = ClipboardProgressHUDController()
preview.ensurePanel()
preview.setResult("## Русский\nЧастые вопросы\n## Српски\nЧеста питања")
preview.panel?.contentView?.layoutSubtreeIfNeeded()
let previewView = preview.resultTextView!
let layout = previewView.layoutManager!
layout.ensureLayout(for: previewView.textContainer!)
let range = (previewView.string as NSString).range(of: "Частые вопросы")
let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
let rect = layout.boundingRect(forGlyphRange: glyphRange, in: previewView.textContainer!)
previewView.updateHover(at: NSPoint(x: rect.minX + 2, y: rect.midY))
// Capture successful HUD content in light and dark appearances.
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
 preview.panel?.appearance = NSAppearance(named: appearance)
 let image = NSImage(size: previewView.bounds.size, flipped: true) { _ in
  preview.panel!.appearance!.performAsCurrentDrawingAppearance {
   NSColor.textBackgroundColor.setFill()
   previewView.bounds.fill()
   let glyphs = layout.glyphRange(for: previewView.textContainer!)
   layout.drawBackground(forGlyphRange: glyphs, at: previewView.textContainerOrigin)
   layout.drawGlyphs(forGlyphRange: glyphs, at: previewView.textContainerOrigin)
   // Render paragraph controls individually for icon-size inspection.
   for button in [previewView.playButton, previewView.copyButton] {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: button.frame.minX, yBy: button.frame.minY)
    transform.concat()
    button.draw(button.bounds)
    NSGraphicsContext.restoreGraphicsState()
   }
  }
  return true
 }
 let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
 let name = appearance == .aqua ? "hud-playback-light.png" : "hud-playback-dark.png"
 try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
}

let app = FixtureDelegate()
app.openDetachedResultWindow(text: "# Karate\nA martial art.", mode: "dictionary", narration: ClipboardHUDPlayback(),
                            textModel: "Captured model", languageLevel: "b", dictionaryHeadword: "Karate",
                            conversation: ResultConversation(originalRequest: "Karate"))
let dictionaryWindow = app.sessions.last!
check(dictionaryWindow.config.dictionaryHeadword == "Karate" && dictionaryWindow.config.textModel == "Captured model"
      && dictionaryWindow.config.languageLevel == "b" && dictionaryWindow.config.conversation?.originalRequest == "Karate",
      "Opening a HUD result retains the original model, reading level, headword and conversation")
dictionaryWindow.releaseResources()
app.sessions.removeAll()
let resultText = "## Русский\nЧастые вопросы\n## Српски\nЧеста питања"
// transferHUD(): Create a completed, readable HUD ready for a controlled window
// handoff.
func transferHUD() -> ClipboardProgressHUDController {
 let hud = ClipboardProgressHUDController()
 hud.ensurePanel()
 hud.activeToken = UUID()
 hud.setResult(resultText)
 hud.openAction = { playback in app.openDetachedResultWindow(text: resultText, mode: "translate", narration: playback) }
 return hud
}
// recordClip(hud, text, location): Start a clip and return the simulated
// request for controlled completion.
@discardableResult func recordClip(_ hud: ClipboardProgressHUDController, _ text: String, at location: Int) throws -> Request {
 hud.playback.play(text, at: location)
 let request = requests.last!
 try request.finish(); drain()
 return request
}
// close(session): Run the viewer's normal close cleanup and release its
// recorded session.
func close(_ session: ViewerSession) {
 session.windowWillClose(Notification(name: NSWindow.willCloseNotification))
}

// Read in reverse order, then open: the recording follows the document, not click order.
let handoffHUD = transferHUD()
preferences.ttsVoice = "grok"
let serbian = try recordClip(handoffHUD, "Честа питања", at: 50)
preferences.ttsVoice = "apple"
let russian = try recordClip(handoffHUD, "Частые вопросы", at: 10)
let hudPlayer = handoffHUD.playback.player!
let beforeOpenRequests = requests.count
handoffHUD.openPressed(nil)
let transferred = app.sessions.last!
check(hudPlayer.stopped && !handoffHUD.isActive, "Open stops HUD playback and transfers ownership")
check(transferred.isGeneratingNarration && transferred.saveToLibraryButton?.isEnabled == false, "Library save waits until all transferred audio is ready")
transferred.saveToLibraryFromToolbar(nil)
check(transferred.savedLibraryID == nil, "A pending handoff cannot save an incomplete recording")
waitFor { !transferred.isGeneratingNarration }
check(requests.count == beforeOpenRequests, "Opening never regenerates completed narration")
check(transferred.audioAvailable && transferred.revealed && !transferred.autoplayed, "Transferred recording is available and paused")
check(mergeInputs.last == [russian.output, serbian.output], "Clips merge in paragraph order")
check(transferred.config.audioTimings?.map(\.text) == ["Частые вопросы", "Честа питања"], "Each narrated paragraph keeps its timing")
check(transferred.config.audioTimings?.map(\.start) == [0, 2.5], "Merged audio offsets reach the viewer")
check(transferred.narrationVoiceUsed == nil && transferred.narrationModelUsed == nil, "Mixed voices are not labelled as one voice")
check(!exists(russian.output) && !exists(serbian.output), "Transferred source clips are removed after merging")
let transferredAudio = URL(fileURLWithPath: transferred.activeAudioPath)
let transferredData = try Data(contentsOf: transferredAudio)
check(transferredData == Data([1, 2, 3, 1, 2, 3]), "Both clips are in the transferred recording")
handoffHUD.activeToken = UUID()
handoffHUD.setResult("Another HUD result")
handoffHUD.dismiss(token: handoffHUD.activeToken, animated: false)
check(exists(transferredAudio), "A later HUD cannot delete a window's narration")

// Saving to the Library writes independent copies. Closing the original and reopened windows cannot delete them.
transferred.saveToLibraryFromToolbar(nil)
let savedID = transferred.savedLibraryID!
let entryURL = LibraryStore.entryDirectory(id: savedID).appendingPathComponent("entry.json")
let entry = try JSONDecoder().decode(LibraryEntry.self, from: Data(contentsOf: entryURL))
let savedAudio = LibraryStore.entryDirectory(id: savedID).appendingPathComponent(entry.audioFile!)
check(exists(savedAudio) && entry.audioTimings?.count == 2, "Library save keeps all transferred audio and timings")
let temporaryText = URL(fileURLWithPath: transferred.config.textPath)
close(transferred)
check(!exists(transferredAudio) && !exists(temporaryText) && exists(savedAudio), "Closing deletes temporary files and keeps the Library copy")
let reopened = ViewerSession(config: LibraryStore.viewerConfig(for: entry)!, appDelegate: app)
check(reopened.audioAvailable && reopened.config.audioTimings?.map(\.text) == entry.audioTimings?.map(\.text), "Reopening a saved result restores narration")
close(reopened)
check(exists(savedAudio) && exists(entryURL), "Closing a reopened Library result preserves its files")

// A single clip transfers unchanged; an unsaved window owns and deletes it.
let singleHUD = transferHUD()
let single = try recordClip(singleHUD, "Частые вопросы", at: 10)
singleHUD.openPressed(nil)
let singleWindow = app.sessions.last!
waitFor { !singleWindow.isGeneratingNarration }
check(singleWindow.narrationVoiceUsed == "apple" && singleWindow.config.audioTimings?.count == 1, "Single-voice metadata and timing survive Open")
check(URL(fileURLWithPath: singleWindow.activeAudioPath).pathExtension == "caf", "One clip is copied without conversion")
let singleAudio = URL(fileURLWithPath: singleWindow.activeAudioPath)
close(singleWindow)
check(!exists(singleAudio) && !exists(single.output), "Closing an unsaved window removes all narration")

// Open while generating preserves the request, without playing in the now-hidden HUD.
let pendingHUD = transferHUD()
let ready = try recordClip(pendingHUD, "Частые вопросы", at: 10)
pendingHUD.playback.play("Честа питања", at: 50)
let pendingClip = requests.last!
let outgoing = pendingHUD.playback
pendingHUD.openPressed(nil)
let pendingWindow = app.sessions.last!
check(!pendingClip.cancelled && pendingWindow.isGeneratingNarration, "Open transfers an in-flight speech request")
try pendingClip.finish(); drain()
waitFor { !pendingWindow.isGeneratingNarration }
check(outgoing.player == nil && pendingWindow.config.audioTimings?.count == 2, "Pending clip joins earlier narration without HUD autoplay")
close(pendingWindow)
check(!exists(ready.output) && !exists(pendingClip.output), "Closing clears completed and transferred pending clips")

let closingHUD = transferHUD()
let completedBeforeClose = try recordClip(closingHUD, "Частые вопросы", at: 10)
closingHUD.playback.play("Честа питања", at: 50)
let cancelledClip = requests.last!
closingHUD.openPressed(nil)
let closingWindow = app.sessions.last!
close(closingWindow)
try cancelledClip.finish(); drain()
check(cancelledClip.cancelled && !exists(cancelledClip.output) && !exists(completedBeforeClose.output), "Closing during generation cancels requests and removes every clip")
check(!closingWindow.audioAvailable && closingWindow.errors.isEmpty, "Late completion cannot modify a closed window")

// A failed final request still transfers earlier completed narration.
let partialHUD = transferHUD()
try recordClip(partialHUD, "Частые вопросы", at: 10)
partialHUD.playback.play("Честа питања", at: 50)
let failedClip = requests.last!
partialHUD.openPressed(nil)
let partialWindow = app.sessions.last!
failedClip.completion(.failure(HelperFailure(message: "Fixture unavailable voice")))
drain(); waitFor { !partialWindow.isGeneratingNarration }
check(partialWindow.audioAvailable && partialWindow.config.audioTimings?.count == 1, "Earlier clips survive a later request failure")
check(partialWindow.errors == ["Fixture unavailable voice"] && partialWindow.saveToLibraryButton?.isEnabled == true, "Partial success reports the error and can be saved")
close(partialWindow)

// Closing during a merge must clean up both source clips and any late export output.
let mergingHUD = transferHUD()
let mergingFirst = try recordClip(mergingHUD, "Частые вопросы", at: 10)
let mergingSecond = try recordClip(mergingHUD, "Честа питања", at: 50)
holdMerge = true
mergingHUD.openPressed(nil)
let mergingWindow = app.sessions.last!
waitFor { mergeContinuation != nil }
let cancelledOutput = mergeOutputs.last!
close(mergingWindow)
check(!exists(cancelledOutput.deletingLastPathComponent()), "Closing immediately removes the export directory")
mergeContinuation?.resume(); mergeContinuation = nil; holdMerge = false
waitFor { !exists(cancelledOutput.deletingLastPathComponent()) }
check(!exists(mergingFirst.output) && !exists(mergingSecond.output) && !mergingWindow.audioAvailable, "Cancelled merge leaves no narration files")

let failedHUD = transferHUD()
let failedFirst = try recordClip(failedHUD, "Частые вопросы", at: 10)
let failedSecond = try recordClip(failedHUD, "Честа питања", at: 50)
mergeFailure = true
failedHUD.openPressed(nil)
let failedWindow = app.sessions.last!
waitFor { !failedWindow.isGeneratingNarration }
mergeFailure = false
check(failedWindow.errors == ["Fixture merge failure"] && !failedWindow.audioAvailable, "Merge failure is reported without unusable audio")
check(!exists(failedFirst.output) && !exists(failedSecond.output), "Failed handoff releases temporary clips")
close(failedWindow)

let dismissedHUD = transferHUD()
let discarded = try recordClip(dismissedHUD, "Частые вопросы", at: 10)
dismissedHUD.setResult(resultText, preservingNarration: true)
check(exists(discarded.output), "Appearance rebuild retains completed narration")
dismissedHUD.dismiss(token: dismissedHUD.activeToken, animated: false)
check(!exists(discarded.output), "Dismissing a HUD clears its completed narration")
let failedOpenHUD = transferHUD()
let failedOpenClip = try recordClip(failedOpenHUD, "Частые вопросы", at: 10)
let windowsBeforeFailure = app.sessions.count
failDirectory = true
failedOpenHUD.openPressed(nil)
failDirectory = false
check(app.sessions.count == windowsBeforeFailure && !exists(failedOpenClip.output), "Failed window creation cleans transferred audio")

playback.clear()
check(!playback.hasNarration, "Clearing playback removes its retained clips")

// writeSilentClip(url, frames): Exercise the real macOS audio exporter with
// silent CAF clips; never send a speech request or play sound.
func writeSilentClip(to url: URL, frames: AVAudioFrameCount) throws {
 let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
 let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
 buffer.frameLength = frames
 buffer.floatChannelData![0].initialize(repeating: 0, count: Int(frames))
 let file = try AVAudioFile(forWriting: url, settings: format.settings)
 try file.write(from: buffer)
}
useRealMerge = true
preferences.ttsVoice = "apple"
let realHUD = transferHUD()
// Merge real generated CAF fixtures with distinct lengths and non-Latin paragraph text.
for (text, location, frames) in [("Частые вопросы", 10, 2400), ("Честа питања", 50, 4800)] {
 realHUD.playback.play(text, at: location)
 let request = requests.last!
 try writeSilentClip(to: request.output, frames: AVAudioFrameCount(frames))
 let inputAudio = try AVAudioPlayer(contentsOf: request.output)
 check(inputAudio.duration > 0, "Silent fixture is a valid audio clip")
 request.completion(.success(())); drain()
}
realHUD.openPressed(nil)
let realWindow = app.sessions.last!
waitFor { !realWindow.isGeneratingNarration }
check(realWindow.errors.isEmpty && realWindow.audioAvailable, "Real CAF clips export successfully to window narration: \(realWindow.errors)")
let realAudio = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: realWindow.activeAudioPath))
check(abs(realAudio.duration - 0.75) < 0.1, "Export contains both clips and the paragraph pause")
check(abs(realWindow.config.audioTimings![1].start - 0.55) < 0.001, "Real exported timings match clip durations")
realWindow.saveToLibraryFromToolbar(nil)
let realEntryDir = LibraryStore.entryDirectory(id: realWindow.savedLibraryID!)
let realEntry = try JSONDecoder().decode(LibraryEntry.self, from: Data(contentsOf: realEntryDir.appendingPathComponent("entry.json")))
close(realWindow)
let savedRealAudio = try AVAudioPlayer(contentsOf: realEntryDir.appendingPathComponent(realEntry.audioFile!))
check(abs(savedRealAudio.duration - realAudio.duration) < 0.001, "Saved recording remains decodable after temporary files are deleted")
print("\(checks) HUD playback and transfer checks passed")
'''

with tempfile.TemporaryDirectory(prefix='langmin-hud-playback-tests-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', *swift_fixture_args(), '-O', '-module-cache-path', cache, '-target', f'{platform.machine()}-apple-macos14.0',
                    str(folder / 'main.swift'), '-o', str(folder / 'tests')], check=True)
    subprocess.run([str(folder / 'tests'), directory], check=True, timeout=60)
    # Retain rendered artifacts only when a destination was explicitly requested.
    if target := os.environ.get('LANGMIN_TEST_ARTIFACTS'):
        output = Path(target)
        output.mkdir(parents=True, exist_ok=True)
        # Copy rendered fixture artifacts to the explicitly requested output directory.
        for artifact in folder.glob('*.png'):
            shutil.copyfile(artifact, output / artifact.name)
