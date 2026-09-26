#!/usr/bin/env python3
"""Exercise the actual illustration helpers and Library asset methods offline.

AppKit/session collaborators are isolated below; provider requests use a
URLProtocol fixture and all working files stay in the task's temporary folder.
Run: python3 scripts/test_dictionary_illustration.py
"""
from pathlib import Path
import os
import platform
import subprocess
import tempfile

from source_files import ROOT, app_path, app_source, swift_fixture_args
MAIN = app_source('main.swift')
IMAGE = app_source('DictionaryIllustration.swift')


# block(source, marker): Extract one brace-balanced production declaration for
# this isolated Swift fixture.
def block(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    # Include nested blocks when finding the end of the extracted declaration.
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


PREAMBLE = r'''
import Cocoa
import ImageIO
import ImagePlayground
import UniformTypeIdentifiers
// Host the illustration text view without follow-up hover behavior.
class ResultConversationTextView: NSTextView {
 // updateFollowUpActionHover(point): Keep this production dependency inactive
 // in the isolated fixture.
 func updateFollowUpActionHover(at point: NSPoint) {}
}
let fixtureRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
// localized(key, english): Resolve labels through the fixture’s controlled
// localization.
func localized(_ key: String, _ english: String) -> String { english }
// Represent fixture failures using the app’s localized-error contract.
struct HelperFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
let languageLevelOptions: [String] = []
// preferenceDisplayValue(value, options): Provide the disabled-provider label
// used by this settings fixture.
func preferenceDisplayValue(for value: String, options: [String]) -> String { "Off" }
// Preferences stay in memory, including the production default/load/save paths extracted below.
final class FixturePreferencesStore {
 var values: [String: Any] = [:]
 // object(key): Read an untyped preference from fixture memory.
 func object(forKey key: String) -> Any? { values[key] }
 // string(key): Read a string preference without accessing user defaults.
 func string(forKey key: String) -> String? { values[key] as? String }
 // bool(key): Treat missing Boolean preferences as disabled.
 func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
 // set(value, key): Save preference changes only in fixture memory.
 func set(_ value: Any, forKey key: String) { values[key] = value }
}
let preferencesStore = FixturePreferencesStore()
// Supply the timing fields required by saved narration metadata.
struct NarrationChunkTiming: Codable { let start: Double; let text: String }
// Supply the text ranges used by narration-aware image layout.
struct NarrationSegment { let start: Double; let range: NSRange? }
// Represent the destination label required by image request code.
struct Destination { let displayName: String }
// remoteAIDestination(label, endpoint): Create a display-only destination
// without provider discovery.
func remoteAIDestination(label: String, endpoint: String) -> Destination { Destination(displayName: label) }
// confirmRemoteAISharingIfNeeded(destination): Fail if an isolated test
// unexpectedly opens sharing consent.
func confirmRemoteAISharingIfNeeded(_ destination: Destination) -> Bool { fatalError("Unexpected real consent") }
// confirmRemoteSecretWarningIfNeeded(input, provider): Fail if an isolated test
// unexpectedly opens secret-sharing consent.
func confirmRemoteSecretWarningIfNeeded(input: String, provider: String) -> Bool { fatalError("Unexpected real consent") }
// Supply the paid-feature identifier used by image generation.
enum ProFeature { case cloudModels }
// ensureProAccess(feature): Fail if the fixture unexpectedly enters the real
// purchase flow.
func ensureProAccess(_ feature: ProFeature) -> Bool { fatalError("Unexpected Pro gate") }
// loadOpenAIAPIKey(): Prevent this fixture from reading a real API key.
func loadOpenAIAPIKey() -> String { fatalError("Tests must not access credentials") }
// createLangminTemporaryDirectory(prefix): Keep generated image files inside
// the fixture’s temporary directory.
func createLangminTemporaryDirectory(prefix: String) throws -> URL {
    let url = fixtureRoot.appendingPathComponent(prefix + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
'''

STORE = '''
// Host the production Library methods with temporary storage and no audio persistence.
enum LibraryStore {
 // libraryDirectory(): Keep saved entries under the fixture root.
 static func libraryDirectory() -> URL { fixtureRoot.appendingPathComponent("Library") }
 // invalidateEntryCache(): Keep this production dependency inactive in the
 // isolated fixture.
 static func invalidateEntryCache() {}
 // loadPronunciations(id): Keep pronunciation loading outside the
 // image-persistence test.
 static func loadPronunciations(id: String) -> [String: URL] { [:] }
 // savePronunciations(clips, dir): Keep pronunciation saving outside the
 // image-persistence test.
 static func savePronunciations(_ clips: [(key: String, url: URL)], into dir: URL) -> [PronunciationRef] { [] }
'''
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in [
    '    static func entryDirectory(', '    static func save(config:',
    '    static func setIllustration(', '    static func setConversation(', '    static func viewerConfig(',
    '    private static func copyOptional(', '    private static func copy(fromPath:',
]:
    STORE += block(MAIN, marker) + '\n'
STORE += '}\n'

SESSION = r'''
// Host production illustration behavior with observable text, image, and error state.
final class ViewerSession: NSObject {
 var config: ViewerConfig
 var illustrationImage: NSImage?
 var illustrationTask: URLSessionDataTask?
 var illustrationRunID: UUID?
 var illustrationPresentation: DictionaryImagePresentation?
 var illustrationCleanupDir = ""
 var illustrationButton: NSButton?
 var resourcesReleased = false
 var savedLibraryID: String?
 var hostWindow: NSWindow?
 var window: NSWindow?
 var autoPlaysOnOpen = true
 // show(cascadeIndex): Keep this production dependency inactive in the isolated
 // fixture.
 func show(cascadeIndex: Int) {}
 // init(config, appDelegate): Accept the production initializer shape without
 // registering an app session.
 convenience init(config: ViewerConfig, appDelegate: AppDelegate) { self.init(config: config) }
 var content = "Love\n\nA feeling of deep affection for someone.\n\nExample: I love spending time with my family."
 var narrationSegments: [NarrationSegment] = []
 let textView: NSTextView? = ViewerResultTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 580))
 var rendersMarkdown = false
 var errors: [String] = []
 var activeAudioPath = ""
 var audioAvailable = false
 var diffOriginalContent = ""
 var diffRevisedContent = ""
 var pronounceCache: [String: URL] = [:]
 // init(config): Start the viewer with the supplied result configuration.
 init(config: ViewerConfig) { self.config = config }
 // stopHeadwordPronunciation(): Keep this production dependency inactive in the
 // isolated fixture.
 func stopHeadwordPronunciation() {}
 // clearNarrationHighlight(): Keep this production dependency inactive in the
 // isolated fixture.
 func clearNarrationHighlight() {}
 // applyNarrationCursorAttributes(segments): Keep this production dependency
 // inactive in the isolated fixture.
 func applyNarrationCursorAttributes(for segments: [NarrationSegment]) {}
 // presentViewerError(title, details): Capture errors for assertions instead of
 // presenting alerts.
 func presentViewerError(_ title: String, details: String) { errors.append(details) }
 // applyResultText(): Render the fixture content and apply the current
 // illustration to its layout.
 func applyResultText() {
   let paragraph = NSMutableParagraphStyle()
   paragraph.paragraphSpacing = 12
   let plain = NSAttributedString(string: content, attributes: [
     .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
   ])
   let text = rendersMarkdown ? markdownAttributedText(from: content) : plain
   textView!.textStorage!.setAttributedString(text)
   refreshIllustration()
 }
 // RENDERER
}
'''

APP = r'''
// Track whether an inline result has moved to its own viewer.
final class LauncherController {
 var inlineResultSession: ViewerSession?
 var detached: ViewerSession?
 // detachInlineResult(sender): Transfer the existing session so detachment
 // preserves its image state.
 func detachInlineResult(_ sender: Any?) {
   detached = inlineResultSession
   inlineResultSession = nil
 }
}
// Hold viewer sessions while exercising the production saved-entry path.
final class AppDelegate {
 var sessions: [ViewerSession] = []
 let launcherController = LauncherController()
 // setActiveSession(session): Keep this production dependency inactive in the
 // isolated fixture.
 func setActiveSession(_ session: ViewerSession) {}
}
'''
APP = APP.rstrip()[:-1] + block(MAIN, '    func openSavedEntry(') + '\n}\n'

SETTINGS = r'''
// Reuse the production form and tab layout without building the real Settings controller.
class SettingsSnapshotSurface: NSView {
 // draw(dirtyRect): Draw a consistent native background for settings snapshots.
 override func draw(_ dirtyRect: NSRect) {
  NSColor.windowBackgroundColor.setFill()
  dirtyRect.fill()
 }
}
// Supply tooltip layout properties without opening tooltip windows.
class TooltipInfoLabel: NSTextField {
 var tooltipMessage = ""; var tooltipYOffset: CGFloat = 0
 var tooltipAnchorXOffset: CGFloat = 0; var tooltipExtraXShift: CGFloat = 0
}
// Host the production settings layout with the Illustrations section selected.
final class SettingsLayoutFixture: NSObject {
 var sectionButtons: [PreferencesSection: NSButton] = [:]
 var selectedSection: PreferencesSection = .illustrations
 var advancedInstructionsSeparatorRow = NSView()
 var advancedInstructionsSeparator = NSBox()
 var settingsSeparators: [ObjectIdentifier: NSBox] = [:]
 var settingsInfoTooltips: [ObjectIdentifier: String] = [:]
 // Other Settings sections may register a collapsible narration row.
 var autoNarrateModesView: NSStackView?
 var autoNarrateModesRow: NSGridRow?
 // selectPreferencesSection(sender): Keep this production dependency inactive
 // in the isolated fixture.
 @objc func selectPreferencesSection(_ sender: NSButton) {}
'''
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['    func settingsSidebar()', '    func settingsSectionView(rows:', '    func label(_ title: String)']:
    SETTINGS += block(MAIN, marker) + '\n'
SETTINGS += 'static var contentSize: NSSize { SettingsLayout.contentSize }\n'
SETTINGS += '}\n'

TESTS = r'''
var checks = 0
// check(condition, message): Report failed fixture expectations with their case
// names.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
 // Stop at the first failed illustration expectation.
 if !condition() { fatalError(message) }
 checks += 1
}
// mustFail(message, body): Require invalid input to throw rather than return a
// usable result.
func mustFail(_ message: String, _ body: () throws -> Void) {
 // Count only the expected failure from the supplied invalid-input operation.
 do { try body(); fatalError(message) } catch { checks += 1 }
}
_ = NSApplication.shared
// Old provider choices must not retain implicit permission to generate a paid image.
check(!AppPreferences().dictionaryIllustrationAutomatic, "New preferences default to manual images")
check(!loadAppPreferences().dictionaryIllustrationAutomatic, "Missing automatic preference stays off")
// Check that no stored provider choice implicitly enables automatic generation.
for provider in DictionaryIllustrationProvider.allCases {
 preferencesStore.set(provider.rawValue, forKey: PreferenceKey.dictionaryIllustrationProvider)
 let run = LauncherRun(transformCompletion: nil, presentation: .standard)
 check(run.automaticIllustrationProvider(forDictionaryHeadword: "Karate") == .off,
       "Legacy provider selection cannot automatically generate an image")
}
var imagePreferences = loadAppPreferences()
imagePreferences.dictionaryIllustrationProvider = .openAI
imagePreferences.dictionaryIllustrationAutomatic = true
saveAppPreferences(imagePreferences)
check(loadAppPreferences().dictionaryIllustrationAutomatic, "Explicit automatic opt-in survives saving")
let automaticRun = LauncherRun(transformCompletion: nil, presentation: .standard)
check(automaticRun.automaticIllustrationProvider(forDictionaryHeadword: "Karate") == .openAI, "Opted-in Dictionary lookup uses the chosen image provider")
check(automaticRun.automaticIllustrationProvider(forDictionaryHeadword: nil) == .off, "Other modes never automatically generate images")
let serviceRun = LauncherRun(transformCompletion: { _, _ in }, presentation: .standard)
check(serviceRun.automaticIllustrationProvider(forDictionaryHeadword: "Karate") == .off, "Selected-text Services never create images")
imagePreferences.dictionaryIllustrationAutomatic = false
saveAppPreferences(imagePreferences)
check(automaticRun.automaticIllustrationProvider(forDictionaryHeadword: "Karate") == .off, "Disabling automation prevents a pending lookup from creating an image")
let manualRun = LauncherRun(transformCompletion: nil, presentation: .standard)
imagePreferences.dictionaryIllustrationAutomatic = true
saveAppPreferences(imagePreferences)
check(manualRun.automaticIllustrationProvider(forDictionaryHeadword: "Karate") == .off, "Enabling automation does not affect an already-running manual lookup")
imagePreferences.dictionaryIllustrationProvider = .apple
saveAppPreferences(imagePreferences)
check(automaticRun.dictionaryIllustrationProvider == .openAI, "A running lookup keeps its originally selected provider")

// Editing Settings is a draft; selecting a provider alone cannot opt in or write preferences.
let imageSettings = DictionaryIllustrationSettingsControls()
check(imageSettings.provider == .off && !imageSettings.automatic, "Settings starts in manual mode")
check(!imageSettings.automaticButton.isEnabled && imageSettings.focusViews.count == 1, "Automatic mode needs a provider and disabled controls leave the Tab order")
imageSettings.populate(provider: .openAI, automatic: false)
check(imageSettings.automaticButton.isEnabled && !imageSettings.automatic, "Selecting a provider leaves automatic images off")
check(imageSettings.providerNote.stringValue.contains("billed separately"), "Cloud billing is explained before opt-in")
imageSettings.automaticButton.state = .on
check(imageSettings.automatic && imageSettings.focusViews.count == 2, "The checkbox explicitly enables automatic mode")
check(loadAppPreferences().dictionaryIllustrationProvider == .apple, "Settings edits do not persist before Save")
imageSettings.providerBox.selectItem(at: 0)
imageSettings.providerChanged(nil)
check(!imageSettings.automatic && imageSettings.automaticButton.state == .off, "Choosing per-result generation clears automatic mode")
imageSettings.populate(provider: .openAI, automatic: false)
check(!imageSettings.automatic, "Reopening a cancelled draft restores the saved automatic value")
imageSettings.populate(provider: .off, automatic: false)
check(imageSettings.provider == .off && !imageSettings.automatic, "Reset Defaults restores manual images")
preferencesStore.values = [:]

// Render both appearance variants at the actual Settings width, including all eight tab buttons.
for dark in [false, true] {
 // Check settings availability for disabled and remote image providers.
 for provider in [DictionaryIllustrationProvider.off, .openAI] {
  let controls = DictionaryIllustrationSettingsControls()
  controls.populate(provider: provider, automatic: false)
  let fixture = SettingsLayoutFixture()
  let panel = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsLayoutFixture.contentSize), styleMask: [.titled], backing: .buffered, defer: false)
  panel.isReleasedWhenClosed = false
  panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
  panel.contentView = SettingsSnapshotSurface(frame: NSRect(origin: .zero, size: SettingsLayoutFixture.contentSize))
  let surface = panel.contentView!
  let sidebar = fixture.settingsSidebar()
  let page = fixture.settingsSectionView(rows: controls.rows)
  let heading = NSTextField(labelWithString: fixture.selectedSection.title)
  // Use the app's tab container so the test exercises its sizing priorities.
  let tabs = NSTabView()
  tabs.tabViewType = .noTabsNoBorder
  SettingsLayout.install(sidebar: sidebar, page: tabs, heading: heading, in: surface)
  surface.layoutSubtreeIfNeeded()
  let item = NSTabViewItem(identifier: PreferencesSection.illustrations.rawValue)
  item.view = page
  tabs.addTabViewItem(item)
  tabs.selectTabViewItem(item)
  surface.layoutSubtreeIfNeeded()
  check(abs(sidebar.frame.width - SettingsLayout.rowWidth) < 1, "The sidebar stays fixed beside the real tab view")
  check(surface.bounds.contains(sidebar.frame) && sidebar.frame.maxX < tabs.frame.minX, "Settings navigation fits beside the form")
  check(page.frame.width >= 531, "The compact Settings window leaves room for the illustration form")
  for button in fixture.sectionButtons.values {
   let titleWidth = (button.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
   check(titleWidth <= button.bounds.width - 56, "Sidebar labels retain their icon and text padding")
  }
  // Verify each form row fits inside the settings page.
  for (_, control) in controls.rows {
   let frame = control.convert(control.bounds, to: page)
   check(page.bounds.contains(frame), "Illustration Settings controls stay within the form")
   // Ensure explanatory labels have enough height for wrapped text.
   if let note = control as? NSTextField {
    check(note.frame.height >= note.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: note.frame.width, height: 1000)).height,
          "Provider guidance wraps without clipping")
   }
  }
  let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds)!
  surface.cacheDisplay(in: surface.bounds, to: bitmap)
  let name = "illustration-settings-\(provider.rawValue)-\(dark ? "dark" : "light").png"
  try bitmap.representation(using: .png, properties: [:])!.write(to: fixtureRoot.appendingPathComponent(name))
  panel.close()
 }
}

// A drawn fixture is sufficient for decoder and layout tests; no image model is invoked.
let fixture = NSImage(size: NSSize(width: 900, height: 600), flipped: false) { rect in
 NSColor(calibratedRed: 1, green: 0.91, blue: 0.83, alpha: 1).setFill(); rect.fill()
 let symbol = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)!
 let tint = NSImage(size: NSSize(width: 150, height: 140), flipped: false) { r in
   symbol.draw(in: r)
   NSColor(calibratedRed: 0.85, green: 0.31, blue: 0.32, alpha: 1).setFill()
   r.fill(using: .sourceIn)
   return true
 }
 tint.draw(in: NSRect(x: 340, y: 220, width: 220, height: 190))
 return true
}
let fixturePNG = NSBitmapImageRep(data: fixture.tiffRepresentation!)!.representation(using: .png, properties: [:])!
check(dictionaryIllustrationCaption(model: "gpt-image-2") == "OpenAI · gpt-image-2", "Caption identifies the recorded OpenAI image model")
check(dictionaryIllustrationCaption(model: "gpt-image-1") == "OpenAI · gpt-image-1", "Older images retain their actual model")
check(dictionaryIllustrationCaption(model: "Image Playground") == "Apple · Image Playground", "Apple attribution uses the provider exposed by its picker")
check(dictionaryIllustrationCaption(model: "future-model") == "future-model", "Unknown recorded models are shown without inventing a provider")
check(dictionaryIllustrationCaption(model: nil) == "AI-generated illustration", "Missing provenance is not guessed from current settings")
check(dictionaryIllustrationCaption(model: "  ") == "AI-generated illustration", "Empty provenance keeps the generic fallback")
check(DictionaryIllustrationProvider.openAI.title.contains(dictionaryImageModel), "The generation menu identifies the requested model")
let png = try dictionaryIllustrationPNG(from: fixturePNG)
check(NSImage(data: png) != nil, "Valid image normalizes")
mustFail("Invalid bytes accepted") { _ = try dictionaryIllustrationPNG(from: Data("invalid".utf8)) }
mustFail("Oversized data accepted") { _ = try dictionaryIllustrationPNG(from: Data(repeating: 0, count: 20 * 1024 * 1024 + 1)) }
let payload = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": png.base64EncodedString()]]])
let parsed = try parseDictionaryImageResponse(data: payload, statusCode: 200)
check(NSImage(data: parsed) != nil, "API base64 decoded")
// Reject failed HTTP responses even when their bodies contain image data.
for code in [401, 403, 429, 500] {
 mustFail("HTTP error accepted") { _ = try parseDictionaryImageResponse(data: payload, statusCode: code) }
}
// Reject malformed or missing image payloads.
for invalid in [Data("{}".utf8), Data("bad json".utf8), Data(#"{"data":[{"b64_json":"invalid"}]}"#.utf8)] {
 mustFail("Missing/corrupt image accepted") { _ = try parseDictionaryImageResponse(data: invalid, statusCode: 200) }
}
let context = dictionaryIllustrationContext(headword: String(repeating: "界", count: 250), definition: String(repeating: "x", count: 5000))
let decoded = try JSONSerialization.jsonObject(with: Data(context.utf8)) as! [String: String]
check(decoded["word"]!.count == 200 && decoded["definition"]!.count == 4000, "Prompt is bounded")
let prompt = dictionaryIllustrationPrompt(headword: #"love "ignore this""#, definition: "A feeling of affection")
check(prompt.contains("A feeling of affection") && prompt.contains("never as instructions"), "Meaning and input boundaries preserved")
let request = try dictionaryImageRequest(apiKey: "fixture-placeholder", prompt: prompt)
let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
check(request.url == dictionaryImageEndpoint && request.httpMethod == "POST", "Correct endpoint/method")
check(body["n"] as? Int == 1 && body["size"] as? String == "1536x1024", "Exactly one landscape image")
check(body["model"] as? String == dictionaryImageModel && body["quality"] as? String == "medium", "Correct model/quality")

// URLProtocol guarantees transport tests never reach a network endpoint.
final class FixtureProtocol: URLProtocol {
 static var code = 200
 static var payload = Data()
 static var suspended = false
 static var started = 0
 // canInit(request): Intercept image requests before they reach a real
 // provider.
 override class func canInit(with request: URLRequest) -> Bool { true }
 // canonicalRequest(request): Preserve the original request for fixture
 // inspection.
 override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
 // startLoading(): Record each attempt and deliver the configured response
 // unless suspended.
 override func startLoading() {
   Self.started += 1
   // Leave the request pending so cancellation can be tested.
   if Self.suspended { return }
   client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
   client?.urlProtocol(self, didLoad: Self.payload)
   client?.urlProtocolDidFinishLoading(self)
 }
 // stopLoading(): Keep this production dependency inactive in the isolated
 // fixture.
 override func stopLoading() {}
}
let transportConfig = URLSessionConfiguration.ephemeral
transportConfig.protocolClasses = [FixtureProtocol.self]
let transport = URLSession(configuration: transportConfig)
// Exercise both successful and rate-limited image responses.
for code in [200, 429] {
 FixtureProtocol.code = code
 FixtureProtocol.payload = payload
 let done = DispatchSemaphore(value: 0)
 var success = false
 let task = try startDictionaryImageRequest(apiKey: "fixture-placeholder", prompt: "fixture", session: transport) { result in
   success = (try? result.get()) != nil; done.signal()
 }
 task.resume()
 check(done.wait(timeout: .now() + 5) == .success, "Transport completed")
 check(success == (code == 200), "Transport result matches HTTP status")
}
FixtureProtocol.suspended = true
let cancelled = DispatchSemaphore(value: 0)
var cancellationCode: Int?
let cancellationTask = try startDictionaryImageRequest(apiKey: "fixture-placeholder", prompt: "fixture", session: transport) { result in
 // Capture the cancellation error delivered to the completion handler.
 if case .failure(let error) = result { cancellationCode = (error as NSError).code }
 cancelled.signal()
}
cancellationTask.resume()
cancellationTask.cancel()
check(cancelled.wait(timeout: .now() + 5) == .success && cancellationCode == NSURLErrorCancelled, "Transport cancels")
check(FixtureProtocol.started <= 3, "No automatic retries")
transport.invalidateAndCancel()

// Old entry JSON still decodes; new images survive save, update and reopen.
let textURL = fixtureRoot.appendingPathComponent("word.md")
try "# Love\n\nA feeling of affection.".write(to: textURL, atomically: true, encoding: .utf8)
let imageURL = fixtureRoot.appendingPathComponent("image.png")
try png.write(to: imageURL)
var config = ViewerConfig(textPath: textURL.path, fontSize: 16, audioPath: "", title: "Love", cleanupDir: "", dictionaryHeadword: "love", mode: "dictionary")
var entry = try LibraryStore.save(config: config)
check(entry.fontSize == 16 && LibraryStore.viewerConfig(for: entry)?.fontSize == 14, "Saved results use 14-point text without rewriting old metadata")
var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
json.removeValue(forKey: "illustrationFile"); json.removeValue(forKey: "illustrationModel")
let legacy = try JSONDecoder().decode(LibraryEntry.self, from: JSONSerialization.data(withJSONObject: json))
check(legacy.illustrationFile == nil && legacy.illustrationModel == nil && legacy.sourceImages == nil && legacy.conversation == nil, "Legacy entries decode without new fields")
let metadata = LibraryStore.entryDirectory(id: entry.id).appendingPathComponent("entry.json")
// reload(): Read persisted metadata to verify each Library image change.
func reload() throws -> LibraryEntry { try JSONDecoder().decode(LibraryEntry.self, from: Data(contentsOf: metadata)) }
try LibraryStore.setIllustration(id: entry.id, sourceURL: imageURL, model: "fixture-model")
entry = try reload()
let savedPath = LibraryStore.viewerConfig(for: entry)!.illustrationPath!
check(FileManager.default.fileExists(atPath: savedPath), "Late image persisted with saved entry")
check(entry.illustrationModel == "fixture-model", "Image provenance persists")
check(LibraryStore.viewerConfig(for: entry)?.illustrationModel == "fixture-model", "Library reopen passes the recorded model to its viewer")
try LibraryStore.setIllustration(id: entry.id, sourceURL: imageURL, model: "replacement")
entry = try reload()
check(!FileManager.default.fileExists(atPath: savedPath), "Replaced image is collected")
let previous = entry.illustrationFile!
mustFail("Missing source silently accepted") {
 try LibraryStore.setIllustration(id: entry.id, sourceURL: fixtureRoot.appendingPathComponent("missing.png"), model: "broken")
}
entry = try reload()
check(entry.illustrationFile == previous, "Failed update preserves old metadata")
try LibraryStore.setIllustration(id: entry.id, sourceURL: nil, model: nil)
entry = try reload()
check(entry.illustrationFile == nil, "Removal persists")
config.illustrationPath = imageURL.path
config.illustrationModel = "fixture-model"
let withImage = try LibraryStore.save(config: config)
check(LibraryStore.viewerConfig(for: withImage)?.illustrationPath != imageURL.path, "Library owns its image copy")

// Unsave must detach every asset before the Library copy disappears.
let reopen = ViewerSession(config: LibraryStore.viewerConfig(for: withImage)!)
reopen.config.diffOriginalPath = reopen.config.textPath
reopen.config.diffRevisedPath = reopen.config.textPath
reopen.diffOriginalContent = "Original text"
reopen.diffRevisedContent = ""
try reopen.detachLibraryBackedAssetsIfNeeded()
check(reopen.config.diffRevisedPath != nil, "Unsave retains Diff when the edited result is empty")
let detachedRevision = try String(contentsOfFile: reopen.config.diffRevisedPath!, encoding: .utf8)
check(detachedRevision == "", "The detached empty revision stays empty")
let detachedPath = reopen.config.illustrationPath!
check(detachedPath != LibraryStore.viewerConfig(for: withImage)!.illustrationPath!, "Unsave detaches the image")
try FileManager.default.removeItem(at: LibraryStore.entryDirectory(id: withImage.id))
check(FileManager.default.fileExists(atPath: detachedPath), "Open image survives deleting its Library copy")
let resaved = try LibraryStore.save(config: reopen.config)
check(LibraryStore.viewerConfig(for: resaved)?.illustrationPath != nil, "Unsaved entry can be saved with its picture again")
check(LibraryStore.viewerConfig(for: resaved)?.illustrationModel == "fixture-model", "Unsave and resave preserve image provenance")

// Source-page screenshots use the same Library lifecycle as result text.
let sourceImage = SourceImageAsset(id: "1", file: "source-image-1.png", sourceURL: URL(string: "https://example.test/image.png")!, pageURL: URL(string: "https://example.test/page")!)
try png.write(to: fixtureRoot.appendingPathComponent(sourceImage.file))
var pageConfig = config
pageConfig.sourceImages = [sourceImage]
pageConfig.mode = "summarize"
pageConfig.languageLevel = "a"
pageConfig.conversation = ResultConversation(originalRequest: "Explain this page", modelID: "fixture-model")
let pageEntry = try LibraryStore.save(config: pageConfig)
let savedPageConfig = LibraryStore.viewerConfig(for: pageEntry)!
check(savedPageConfig.sourceImages == [sourceImage], "Source-page image metadata survives Library reopen")
check(savedPageConfig.conversation == pageConfig.conversation, "Original request and model survive Library reopen")
check(savedPageConfig.languageLevel == "a", "Original Level A survives Library save and reopen")
var conversation = pageConfig.conversation!
conversation.turns.append(ResultFollowUpTurn(question: "Can that store deliver to Serbia?", answer: "Check the store's current delivery policy.", modelID: "fixture-model", modelName: "Fixture"))
try LibraryStore.setConversation(id: pageEntry.id, conversation: conversation)
let updatedPageEntry = try JSONDecoder().decode(LibraryEntry.self, from: Data(contentsOf: LibraryStore.entryDirectory(id: pageEntry.id).appendingPathComponent("entry.json")))
check(updatedPageEntry.conversation == conversation, "Completed exchanges persist with their original context")
check(LibraryStore.viewerConfig(for: updatedPageEntry)?.languageLevel == "a", "Appending a reply preserves the saved language level")
check(updatedPageEntry.title == pageEntry.title && updatedPageEntry.sourceImages == pageEntry.sourceImages && updatedPageEntry.illustrationFile == pageEntry.illustrationFile && updatedPageEntry.audioFile == pageEntry.audioFile, "Follow-up updates preserve title, images and narration metadata")
conversation.turns[0].answer = ""
try LibraryStore.setConversation(id: pageEntry.id, conversation: conversation)
let deletedReplyEntry = try JSONDecoder().decode(LibraryEntry.self, from: Data(contentsOf: LibraryStore.entryDirectory(id: pageEntry.id).appendingPathComponent("entry.json")))
check(LibraryStore.viewerConfig(for: deletedReplyEntry)?.conversation?.turns[0].answer == "" && deletedReplyEntry.conversation?.turns[0].question == conversation.turns[0].question, "Deleted reply stays absent after a real atomic Library save and reopen")
check(LibraryStore.viewerConfig(for: deletedReplyEntry)?.languageLevel == "a", "Deleting a reply preserves the saved language level")
let pageSession = ViewerSession(config: LibraryStore.viewerConfig(for: deletedReplyEntry)!)
try pageSession.detachLibraryBackedAssetsIfNeeded()
try FileManager.default.removeItem(at: LibraryStore.entryDirectory(id: pageEntry.id))
let detachedPageImage = URL(fileURLWithPath: pageSession.config.textPath).deletingLastPathComponent().appendingPathComponent(sourceImage.file)
check(FileManager.default.fileExists(atPath: detachedPageImage.path), "Unsave retains source-page pixels in the open session")
let savedAgain = try LibraryStore.save(config: pageSession.config)
check(LibraryStore.viewerConfig(for: savedAgain)?.sourceImages == [sourceImage], "Source-page images survive unsave and resave")
check(LibraryStore.viewerConfig(for: savedAgain)?.conversation == conversation, "Conversation survives unsave and resave with assets")
check(LibraryStore.viewerConfig(for: savedAgain)?.languageLevel == "a", "Level A survives unsave and resave with the conversation")

// A Library reopen reuses the inline session, including its in-flight image.
let appDelegate = AppDelegate()
let inline = ViewerSession(config: config)
inline.savedLibraryID = resaved.id
inline.illustrationRunID = UUID()
appDelegate.launcherController.inlineResultSession = inline
appDelegate.openSavedEntry(resaved)
check(appDelegate.launcherController.detached === inline, "Library reopen detaches its existing inline session")
check(appDelegate.sessions.isEmpty, "Library reopen avoids a duplicate session with stale asset paths")
check(inline.illustrationRunID != nil, "Library reopen preserves the pending cloud image")

// Session completion is identity-guarded and preserves the body/narration.
config.illustrationPath = nil
let viewer = ViewerSession(config: config)
viewer.applyResultText()
viewer.narrationSegments = [NarrationSegment(start: 0, range: NSRange(location: 6, length: 8))]
let firstRun = UUID()
viewer.illustrationRunID = firstRun
viewer.refreshIllustration()
check(viewer.textView!.string == viewer.content, "Image generation leaves loading status out of the definition")
check(viewer.textView!.string.contains("deep affection"), "Definition remains available")
viewer.savedLibraryID = resaved.id
viewer.finishIllustration(.success(png), runID: firstRun, model: "gpt-image-2")
check(viewer.illustrationImage != nil && viewer.illustrationRunID == nil, "Successful image installed")
check(viewer.textView!.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "OpenAI · gpt-image-2" }, "Visible caption uses the completed image's model")
check(viewer.textView!.subviews.compactMap { $0 as? NSImageView }.contains { $0.toolTip == "OpenAI · gpt-image-2" }, "Image tooltip includes provenance")
check(viewer.narrationSegments[0].range!.location == 6, "Narration offsets stay unchanged when an image arrives")
let acceptedPath = viewer.config.illustrationPath
viewer.finishIllustration(.success(png), runID: UUID(), model: "stale")
check(viewer.config.illustrationPath == acceptedPath, "Stale completion cannot replace an image")
let failedRun = UUID(); viewer.illustrationRunID = failedRun
viewer.finishIllustration(.failure(HelperFailure(message: "fixture failure")), runID: failedRun, model: "test")
check(viewer.config.illustrationPath == acceptedPath && viewer.errors == ["fixture failure"], "Failure keeps existing picture/text")
viewer.illustrationRunID = UUID(); let stopped = viewer.illustrationRunID!
viewer.cancelIllustrationChosen(nil)
viewer.finishIllustration(.success(png), runID: stopped, model: "cancelled")
check(viewer.config.illustrationPath == acceptedPath, "Cancelled completion ignored")
check(viewer.config.illustrationModel == "gpt-image-2", "Failed, stale, and cancelled completions keep the old model attribution")
viewer.removeIllustrationChosen(nil)
check(viewer.illustrationImage == nil && (viewer.textView as! DictionaryIllustrationTextView).dictionaryLayout == nil, "Removing a picture removes its card")
check(viewer.narrationSegments[0].range!.location == 6, "Narration range restores after removal")
viewer.resourcesReleased = true; let closed = UUID(); viewer.illustrationRunID = closed
viewer.finishIllustration(.success(png), runID: closed, model: "closed")
check(viewer.illustrationImage == nil, "Closed session ignores completion")

// Reading and selection must survive asynchronous picture/status changes.
let reading = ViewerSession(config: config)
reading.content = (1...70).map { "Meaning \($0): A clear example for this dictionary word." }.joined(separator: "\n")
let readingView = reading.textView!
let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
scroll.documentView = readingView
readingView.isVerticallyResizable = true
readingView.isHorizontallyResizable = false
readingView.textContainerInset = NSSize(width: 24, height: 24)
readingView.textContainer?.containerSize = NSSize(width: 512, height: CGFloat.greatestFiniteMagnitude)
readingView.textContainer?.widthTracksTextView = true
reading.applyResultText()
let wanted = "Meaning 40: A clear example"
let selected = (readingView.string as NSString).range(of: wanted)
readingView.setSelectedRange(selected)
readingView.scrollRangeToVisible(selected)
// selectedLineOffset(): Measure the selected line’s offset from the visible
// reading position.
func selectedLineOffset() -> CGFloat {
 let layout = readingView.layoutManager!
 layout.ensureLayout(for: readingView.textContainer!)
 let glyph = layout.glyphIndexForCharacter(at: readingView.selectedRange().location)
 return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + readingView.textContainerOrigin.y - scroll.contentView.bounds.minY
}
check(scroll.contentView.bounds.minY > 100, "Fixture is scrolled into the definition")
let transitions: [(NSImage?, UUID?)] = [(nil, UUID()), (NSImage(data: png), nil), (NSImage(data: png), UUID()), (NSImage(data: png), nil), (nil, nil)]
// Check that changing illustration state preserves the reading position.
for (picture, pending) in transitions {
 let offset = selectedLineOffset()
 reading.illustrationImage = picture
 reading.illustrationRunID = pending
 reading.refreshIllustration()
 check((readingView.string as NSString).substring(with: readingView.selectedRange()) == wanted, "Image/status change preserves selected words")
 check(abs(selectedLineOffset() - offset) < 1, "Image/status change preserves the reading position")
}

// Exercise TextKit wrapping beside and below the card at several pane widths/themes.
viewer.resourcesReleased = false; viewer.illustrationRunID = nil
viewer.illustrationImage = NSImage(data: png)
viewer.config.illustrationModel = "gpt-image-2"
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = viewer.textView
viewer.textView!.isEditable = false
viewer.textView!.textContainerInset = NSSize(width: 24, height: 24)
viewer.textView!.textContainer?.lineFragmentPadding = 0
viewer.rendersMarkdown = true
viewer.content = "# anchor\n\n## Noun /ˈæŋkər/\n\n1. A heavy metal object dropped from a boat to keep it in one place.\n> *The captain dropped the anchor in the bay.*\n\n2. A person who presents a news programme.\n> *She has been the evening news anchor for ten years.*\n\n**Synonyms:** mooring, hook, mainstay, presenter\n\n## Verb /ˈæŋkər/\n\n1. To hold something firmly in place.\n> *Heavy stones anchor the tent in the wind.*\n\n## СРПСКИ\n\n### Именица: сидро /sǐdro/\n\n1. Тежак метални предмет који држи брод на једном месту.\n> *Брод је бацио сидро у заливу.*"
// Check image geometry across narrow and wide viewer sizes.
for width in [320.0, 560.0, 720.0, 1024.0] {
 // Check geometry and rendering in both native appearances.
 for dark in [true, false] {
   viewer.textView!.frame.size = NSSize(width: width, height: 600)
   viewer.textView!.textContainer?.containerSize = NSSize(width: width - 48, height: .greatestFiniteMagnitude)
   viewer.textView!.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
   viewer.textView!.backgroundColor = dark ? NSColor(calibratedWhite: 0.085, alpha: 1) : .white
   viewer.applyResultText()
   let layout = viewer.textView!.layoutManager!
   layout.ensureLayout(for: viewer.textView!.textContainer!)
   let geometry = (viewer.textView as! DictionaryIllustrationTextView).dictionaryLayout!
   check(geometry.imageRect.maxX <= width - 48 && geometry.imageRect.height <= 300, "Card fits the pane and preserves compact image bounds")
   check(geometry.floatsBesideText == (width >= 720), "Only wide panes put the card beside the text")
   let first = layout.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
   check(viewer.textView!.textContainerOrigin.y == 24, "AppKit keeps the card's reserved space inside the visible document")
   check(viewer.textView!.frame.height >= layout.usedRect(for: viewer.textView!.textContainer!).maxY + 48,
         "The document includes the leading card space and the last line of text")
   check(geometry.floatsBesideText ? first.minY < 1 : first.minY >= geometry.exclusionRect.maxY,
         "Wide panes start text at the top; narrow panes start below the caption")
   var fullWidthBelow = false
   layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, used, _, _, _ in
     check(!used.intersects(geometry.exclusionRect), "No text overlaps the card or its padding")
     // Record that text can use the full width below the image exclusion area.
     if rect.minY >= geometry.exclusionRect.maxY && rect.width > geometry.exclusionRect.minX {
       fullWidthBelow = true
     }
   }
   check(fullWidthBelow, "Text uses the full pane width below the card")
   check(viewer.textView!.string == viewer.markdownAttributedText(from: viewer.content).string, "Layout does not add image labels or markers to copied text")
   let bitmap = viewer.textView!.bitmapImageRepForCachingDisplay(in: viewer.textView!.bounds)!
   viewer.textView!.cacheDisplay(in: viewer.textView!.bounds, to: bitmap)
   let name = "illustration-\(Int(width))-\(dark ? "dark" : "light").png"
   try bitmap.representation(using: .png, properties: [:])!.write(to: fixtureRoot.appendingPathComponent(name))
 }
}

// A changed, longer caption participates in the exclusion and document-height calculations.
viewer.config.illustrationModel = String(repeating: "Recorded model ", count: 12)
viewer.refreshIllustration()
let caption = viewer.textView!.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("Recorded model") }!
let captionGeometry = (viewer.textView as! DictionaryIllustrationTextView).dictionaryLayout!
check(captionGeometry.captionRect.height > 20, "Long model identifiers wrap below the image")
check(caption.frame.height >= captionGeometry.captionRect.height, "Long provenance remains visible within the caption")
check(viewer.textView!.frame.height >= captionGeometry.captionRect.maxY + 48, "Wrapped provenance fits in the scrollable document")
viewer.config.illustrationModel = "Image Playground"
viewer.refreshIllustration()
check(caption.stringValue == "Apple · Image Playground", "Replacing the model updates an existing caption")

// Reflow across the breakpoint keeps UTF-16 selections, links, and narration ranges intact.
let flowing = readingView as! DictionaryIllustrationTextView
reading.illustrationImage = NSImage(data: png)
reading.refreshIllustration()
let savedSelection = readingView.selectedRange()
readingView.textStorage?.addAttribute(.link, value: "langmin-pronounce:fixture", range: savedSelection)
// Check reading-position preservation through repeated viewer resizes.
for width in [1024.0, 500.0, 720.0, 1024.0] {
 let offset = selectedLineOffset()
 readingView.setFrameSize(NSSize(width: width, height: readingView.frame.height))
 readingView.layoutSubtreeIfNeeded()
 check(readingView.selectedRange() == savedSelection, "Resizing preserves selected UTF-16 ranges")
 check(readingView.textStorage?.attribute(.link, at: savedSelection.location, effectiveRange: nil) as? String == "langmin-pronounce:fixture", "Pronunciation links survive responsive reflow")
 check(abs(selectedLineOffset() - offset) < 1, "Resizing preserves the visible reading anchor")
}

// A short definition still scrolls far enough to show a tall card and caption.
for size in [NSSize(width: 600, height: 600), NSSize(width: 400, height: 900), NSSize(width: 1800, height: 400)] {
 let picture = NSImage(size: size)
 flowing.string = "A short definition."
 flowing.setDictionaryIllustration(picture, fontSize: 16)
 flowing.sizeToFit()
 let geometry = flowing.dictionaryLayout!
 check(flowing.frame.height >= geometry.captionRect.maxY + flowing.textContainerInset.height * 2,
       "Short results retain enough height for the image and caption")
 check(abs(geometry.imageRect.width / geometry.imageRect.height - size.width / size.height) < 0.001,
       "Square, portrait, and landscape images keep their aspect ratios")
}
flowing.setDictionaryIllustration(nil, fontSize: 16)
check(flowing.textContainer!.exclusionPaths.isEmpty && flowing.string == "A short definition.", "Removing the card restores full text width")
let largeType = DictionaryIllustrationLayout(width: 680, imageSize: NSSize(width: 600, height: 600), fontSize: 28, caption: "AI-generated illustration")
check(!largeType.floatsBesideText, "Large text keeps the stacked layout when a side column would be too narrow")
let pane = DictionaryIllustrationTextView(frame: NSRect(x: 0, y: 0, width: 1024, height: 400))
pane.isHorizontallyResizable = false
pane.isVerticallyResizable = true
pane.minSize = pane.frame.size
pane.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
pane.textContainerInset = NSSize(width: 32, height: 28)
pane.textContainer?.widthTracksTextView = true
pane.string = "A short definition."
pane.setDictionaryIllustration(NSImage(data: png), fontSize: 16)
pane.setFrameSize(NSSize(width: 400, height: 400))
pane.layoutSubtreeIfNeeded()
check(pane.frame.width == 400 && pane.dictionaryLayout?.floatsBesideText == false,
      "The app's initial minimum size does not prevent switching to a narrow pane")
print("\(checks) illustration checks passed; no credentials or live providers used")
'''

# Compile production definitions with isolated collaborators, without starting the app or accessing its
# data.
source = PREAMBLE
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['class FocusablePopUpButton:', 'final class FocusableButton:',
               'func tintedSymbol(', 'final class SettingsSidebarButton:', 'enum PreferencesSection:',
               'let langminControlBorderColor =', 'final class NativeSeparator:', 'enum SettingsLayout {',
               'func storedPreferenceString(', 'func storedPreferenceBool(',
               'enum LauncherRunPresentation', 'final class LauncherRun:']:
    source += block(MAIN, marker) + '\n'
# Use the actual image preference fields and persistence statements, isolating unrelated settings.
pref_keys = block(MAIN, 'enum PreferenceKey {')
pref_fields = block(MAIN, 'struct AppPreferences {')
source += 'enum PreferenceKey {\n' + '\n'.join(line for line in pref_keys.splitlines() if 'static let dictionaryIllustration' in line) + '\n}\n'
source += 'struct AppPreferences {\n' + '\n'.join(line for line in pref_fields.splitlines() if 'var dictionaryIllustration' in line) + '\n}\n'
loader = block(MAIN, 'func loadAppPreferences(')
image_loader = loader[loader.index('        dictionaryIllustrationProvider:'):loader.index('        transcriptionProvider:')].rstrip().removesuffix(',')
source += 'func loadAppPreferences() -> AppPreferences { AppPreferences(\n' + image_loader + '\n) }\n'
saver = block(MAIN, 'func writePreferences(')
source += 'func saveAppPreferences(_ preferences: AppPreferences) {\n' + '\n'.join(line for line in saver.splitlines() if 'preferencesStore.set(preferences.dictionaryIllustration' in line) + '\n}\n'
source += block(MAIN, 'extension NSAttributedString.Key {') + '\n'
source += block(MAIN, 'class ViewerResultTextView:') + '\n'
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['struct ViewerConfig {', 'struct PronunciationRef:', 'struct LibraryEntry:', 'func openAIErrorMessage(']:
    source += block(MAIN, marker) + '\n'
SESSION = SESSION.rstrip()[:-1] + block(MAIN, '    func detachLibraryBackedAssetsIfNeeded()') + '\n}\n'
renderer = MAIN[MAIN.index('    struct MarkdownFence {'):MAIN.index('    // Restore the normal generated result view.')]
renderer += MAIN[MAIN.index('    func markdownAttributedText(from markdown:'):MAIN.index('    // Build the always-visible result toolbar.')]
SESSION = SESSION.replace('// RENDERER', renderer)
source += app_source('ResultTextFormatting.swift') + '\n'
source += next(line for line in MAIN.splitlines() if line.startswith('let defaultExplanationFontSize:')) + '\n'
source += STORE + SESSION + APP + IMAGE + SETTINGS + TESTS
with tempfile.TemporaryDirectory(prefix='langmin-illustration-tests-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = Path(os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules')))
    subprocess.run(['swiftc', *swift_fixture_args(), '-module-cache-path', str(cache), '-target', f'{platform.machine()}-apple-macos14.0', str(folder / 'main.swift'), str(app_path('WebPageSource.swift')), str(app_path('ResultConversation.swift')), '-o', str(folder / 'tests')], check=True, cwd=ROOT)
    subprocess.run([str(folder / 'tests'), directory], check=True, timeout=45, cwd=ROOT)
    # Keep visual fixtures only when an artifact directory was requested.
    if target := os.environ.get('LANGMIN_TEST_ARTIFACTS'):
        import shutil
        output = Path(target)
        output.mkdir(parents=True, exist_ok=True)
        # Copy rendered fixture artifacts to the explicitly requested output directory.
        for image in folder.glob('illustration-*.png'):
            shutil.copyfile(image, output / image.name)
