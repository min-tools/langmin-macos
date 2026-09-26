#!/usr/bin/env python3
"""Exercise per-mode menus and launcher, shortcut, URL, and Service model routing.

Use isolated preferences, private pasteboards, and captured requests. No provider,
Keychain, account, or real clipboard history is accessed.
"""
from pathlib import Path
import os
import subprocess
import tempfile

from source_files import ROOT, app_source

MAIN = app_source('main.swift')


# block(marker): Compile actual production declarations in the isolated fixture.
def block(marker):
    start = MAIN.index(marker)
    end = MAIN.index('{', start) + 1
    depth = 1
    # Keep nested Swift declarations intact when finding the closing brace.
    while depth:
        depth += (MAIN[end] == '{') - (MAIN[end] == '}')
        end += 1
    return MAIN[start:end] + '\n'


source = r'''
import Cocoa
func localized(_ key: String, _ fallback: String) -> String { fallback }
let appleIntelligenceModelID = "apple:intelligence", customModelID = "custom"
let defaultExplanationModel = appleIntelligenceModelID
let defaultPreferredTextModelIDs = [appleIntelligenceModelID, "gpt-6-sol"]
let defaultTTSModel = "fixture", defaultRewriteStyle = "standard", defaultOutputLanguage = "auto"
let languageLevelModes: Set<String> = ["rewrite", "explain", "summarize", "translate", "dictionary"]
struct AppPreferences {
 var explanationModel = defaultExplanationModel
 var modeTextModels: [String: String] = [:]
 var modeThinking: [String: String] = [:]
 var openAIEndpointOverride = "", anthropicEndpointOverride = ""
 var preferredTextModels = defaultPreferredTextModelIDs
 var customModelName = "", customDisplayName = "", extraModels: [String] = []
 var launcherShowsModel = true
 var languageLevel = "off", rewriteStyle = "standard", dictionaryVoice = "none"
 var explainAnswerLanguage = "auto", summarizeAnswerLanguage = "auto"
 var extraLanguages: [String] = []
}
struct LauncherPreferences {
 var mode = "explain", explanationModel = "", languageLevel = "off"
 var rewriteStyle = "standard", explanationEffort = "normal", summaryStyle = "normal"
 var dictionaryStyle = "normal", translationTarget = "es"
}
var saved = AppPreferences(), remembered = LauncherPreferences()
func loadAppPreferences() -> AppPreferences { saved }
let openAIResponsesEndpoint = URL(string: "https://example.test/responses")!
let anthropicMessagesEndpoint = URL(string: "https://example.test/messages")!
func resolvedOverrideURL(_ value: String, default fallback: URL) -> URL { value.isEmpty ? fallback : URL(string: value)! }
struct TextConversationMessage { enum Role: String { case user, assistant }; let role: Role; let content: String }

func loadLauncherPreferences() -> LauncherPreferences { remembered }
func defaultTranslationTarget(from preferences: AppPreferences) -> String { "es" }
// Property-list round trips catch model assignments that cannot survive persistence.
func saveAppPreferences(_ value: AppPreferences) {
 saved = value
 let thinking = try! PropertyListSerialization.data(fromPropertyList: value.modeThinking, format: .binary, options: 0)
 saved.modeThinking = try! PropertyListSerialization.propertyList(from: thinking, options: [], format: nil) as! [String: String]
 let encoded = try! PropertyListSerialization.data(fromPropertyList: value.modeTextModels, format: .binary, options: 0)
 saved.modeTextModels = try! PropertyListSerialization.propertyList(from: encoded, options: [], format: nil) as! [String: String]
}
func saveLauncherPreferences(_ value: LauncherPreferences) { remembered = value }
'''
for marker in ['struct PreferenceOption {', 'enum TextModelProvider {',
               'func modelProviderSectionName(', 'func textProvider(', 'struct ExplanationPrompt {', 'func cloudThinkingOptions(', 'func cloudThinkingSelection(', 'func enabledExplanationModelOptions(',
               'func defaultEnabledExplanationModel(', 'func enabledExplanationModel(',
               'func preferenceID(', 'func preferenceDisplayValue(', 'func setPopupSelection(',
               'func selectedPreferenceID(', 'enum PaletteAction {', 'struct PaletteItem {',
               'enum PaletteRow {', 'struct PalettePage {', 'final class PaletteRowButton:',
               'func tintedSymbol(', 'struct HelperFailure:', 'private final class ServiceTextResultBox',
               'final class TextRequestHandle {']:
    source += block(marker).replace('private final class ServiceTextResultBox', 'final class ServiceTextResultBox')
source += r'''
let catalog = [PreferenceOption(id: appleIntelligenceModelID, title: "Apple Intelligence", note: ""),
 PreferenceOption(id: "gpt-6-sol", title: "GPT-6 Sol", note: ""),
 PreferenceOption(id: "gpt-6-luna", title: "GPT-6 Luna", note: ""),
 PreferenceOption(id: "anthropic:claude-fable-5-1", title: "Claude Fable 5.1", note: ""),
 PreferenceOption(id: customModelID, title: "Custom", note: "")]
func displayedExplanationModelOptions(customName: String = "", extraModels: [String] = []) -> [PreferenceOption] { catalog }
let launcherModeOptions = ["proofread", "rewrite", "explain", "summarize", "translate", "dictionary"].map {
 PreferenceOption(id: $0, title: $0.capitalized, note: "")
}
let languageOptions = [PreferenceOption(id: "auto", title: "Automatic", note: "")]
let languageLevelOptions = ["off", "a", "b", "c"].map { PreferenceOption(id: $0, title: $0.uppercased(), note: "") }
let translationTargetOptions = [PreferenceOption(id: "es", title: "Spanish", note: "")]
func currentReaderOptions() -> [PreferenceOption] { [] }
func normalizedLanguageLevel(_ value: String) -> String { value }
func presentError(_ title: String, details: String) { fatalError("Unexpected error: \(details)") }
final class LauncherRun { init(transformCompletion: ((LauncherRun, Result<String, Error>) -> Void)?, presentation: LauncherRunPresentation) {} }
enum LauncherRunPresentation { case standard, clipboardHUD }
final class Delegate { var serviceTransformInFlight = false }
class Footer: NSButton { var footerTitle = "" }
struct Chip { let modeID: String }
final class Launcher: NSObject {
 var modelBox: NSPopUpButton! = NSPopUpButton(), levelBox: NSPopUpButton! = NSPopUpButton()
 var modelFooterButton: Footer! = Footer()
 var inputView = NSTextView(), window: NSWindow?
 var modeChips: [Chip] = [], selectedMode = "explain", isGenerating = false
 var pendingExplicitModelID: String?, pendingExplicitTranslationTargetID: String?
 var pendingTransformCompletion: ((LauncherRun, Result<String, Error>) -> Void)?
 var pendingRunPresentation = LauncherRunPresentation.standard
 var appDelegate: Delegate? = Delegate(), ttsModelForRun = ""
 var submissions: [(String, String)] = []
 override init() {
  super.init()
  modelBox.addItems(withTitles: catalog.map(\.title))
  levelBox.addItems(withTitles: languageLevelOptions.map(\.title))
  populateRunDefaults()
 }
 func pinnedModeIDs() -> [String] { launcherModeOptions.map(\.id) }
 func rebuildModeChips() {}
 func refreshChipDecorations() {}
 func updateQuestionPlaceholder(for mode: String) {}
 func updateLauncherWindowTitle(for mode: String) {}
 var restoredSecondary = "normal"
 func configureSecondaryPicker(mode: String, selectedID: String) { restoredSecondary = selectedID }
 func selectedSecondaryID(for mode: String) -> String { restoredSecondary }
 func defaultSecondaryID(for mode: String, preferences: AppPreferences) -> String { "normal" }
 func nonEmpty(_ value: String, fallback: String) -> String { value.isEmpty ? fallback : value }
 func updateFooterStatus(busy: Bool, text: String) {}
 func updateLauncherControlVisibility(preferences: AppPreferences) {}
 func refreshSendButtonState() {}
 func prepareForLaunch() { populateRunDefaults() }
 func show() { populateRunDefaults() }
 // Capture the actual submission model, replacing only network generation.
 func submit(_ sender: Any?) {
  submissions.append((selectedLauncherMode(), selectedModelIDForRun(preferences: saved)))
  pendingExplicitModelID = nil
  saveLauncherChoices()
 }
 func allModelsPage() -> PalettePage { PalettePage(rows: { _ in [] }) }
 func secondaryOptions(for mode: String) -> [PreferenceOption] { [] }
 func secondaryLabelTitle(for mode: String) -> String { "Style" }
 func selectedTranslationTargets() -> [String] { ["es"] }
 func recentTranslationTargetIDs(currentID: String) -> [String] { [currentID] }
 func toggleTranslationTarget(_ id: String) {}
 func setSecondaryFromPalette(mode: String, id: String) {}
 func selectedLanguageLevel(for mode: String) -> String { "off" }
 func extraLanguagesApply(to mode: String) -> Bool { ["explain", "summarize", "dictionary"].contains(mode) }
 func allLanguagesPage(mode: String) -> PalettePage { allModelsPage() }
 func answerLanguagePage(mode: String) -> PalettePage { allModelsPage() }
 func languageLevelPage(mode: String) -> PalettePage { allModelsPage() }
 func extraLanguagesPage() -> PalettePage { allModelsPage() }
 func dictionaryVoicePage() -> PalettePage { allModelsPage() }
'''
for marker in ['    func selectTextModel(', '    func modelSelectionPage(', '    func thinkingSelectionPage(', '    func selectThinking(',
               '    private func modelPaletteItem(', '    func chipOptionsPage(',
               '    func modeHasOptions(', '    func selectedModelIDForRun(',
               '    func globalModelIDForRun(', '    func selectedLauncherMode()',
               '    func applySelectedMode(', '    func collectLauncherPreferences()',
               '    func saveLauncherChoices()', '    func populateRunDefaults()', '    func secondarySelection(',
               '    func updateModelFooter()', '    func handleAutomation(']:
    source += block(marker)
source += r'''
}
var capturedServiceModels: [String] = [], consentModels: [String] = []
func confirmRemoteTextSharingIfNeeded(input: String, model: String, deadline: DispatchTime) -> Bool {
 consentModels.append(model); return true
}
func textRevisionPrompt(input: String, style: String, languageLevel: String = "off") -> ExplanationPrompt { ExplanationPrompt(instructions: "Proofread.", input: input) }
func cleanedTextTransformOutput(_ text: String, prompt: ExplanationPrompt) throws -> String { text }
func startTextRequest(model: String, prompt: ExplanationPrompt, emptyMessage: String, mode: String? = nil, completion: @escaping (Result<String, Error>) -> Void) throws -> TextRequestHandle {
 capturedServiceModels.append(model)
 return TextRequestHandle(resume: { completion(.success("Corrected fixture text")) }, cancel: {})
}
final class ServiceFixture {
 let launcherController = Launcher()
 var serviceTransformInFlight = false, suppressInitialLauncherReveal = false
 func setServiceError(_ pointer: AutoreleasingUnsafeMutablePointer<NSString?>, _ message: String) { pointer.pointee = message as NSString }
 func scheduleIdleTerminationAfterService() {}
'''
source += block('    func runReturningTextService(')
source += r'''
}
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
 guard condition() else { fatalError(message) }
 checks += 1
}
func items(_ page: PalettePage) -> [PaletteItem] {
 page.rows("").compactMap { if case .item(let item) = $0 { return item }; return nil }
}
let _ = NSApplication.shared
let luna = "gpt-6-luna", fable = "anthropic:claude-fable-5-1", sol = "gpt-6-sol"
saved.preferredTextModels = [appleIntelligenceModelID, sol, luna, fable]
let launcher = Launcher()
launcher.selectTextModel(sol)
launcher.selectTextModel(luna, for: "proofread")
launcher.selectTextModel(fable, for: "explain")
check(saved.modeTextModels == ["proofread": luna, "explain": fable], "Mode choices survive preference serialization independently")
check(saved.explanationModel == sol && remembered.explanationModel == sol, "Per-mode choices cannot overwrite the global or remembered model")
check(launcher.modelFooterButton.footerTitle == "GPT-6 Sol", "The footer continues to display the global model")
// Remembered mode, style, language and level survive a new launcher instance.
remembered.mode = "rewrite"; remembered.rewriteStyle = "humanize"; remembered.languageLevel = "b"
let restored = Launcher()
check(restored.selectedLauncherMode() == "rewrite" && restored.restoredSecondary == "humanize", "Reopening always restores the last mode and rewrite style")
check(selectedPreferenceID(from: restored.levelBox, options: languageLevelOptions, fallbackID: "off") == "b", "Reopening restores the last reading level")
remembered.mode = "translate"; remembered.translationTarget = "fr"
let restoredTranslation = Launcher()
check(restoredTranslation.restoredSecondary == "fr", "Reopening always restores the translation target")
remembered = LauncherPreferences()
// All six chips expose a scoped model page, including previously optionless Proofread.
for mode in launcherModeOptions.map(\.id) {
 check(launcher.modeHasOptions(mode), "Every mode has an options menu")
 let row = items(launcher.chipOptionsPage(for: mode)).first { $0.id == "mode-model" }!
 guard case .push(let page) = row.action!() else { fatalError("Model row must open a submenu") }
 let choices = items(page)
 check(Set(choices.map(\.id)) == Set(saved.preferredTextModels), "Mode menus only contain the enabled shortlist")
 check(!choices.contains { $0.id == "all-models" }, "Mode menus cannot modify the master shortlist")
 let expected = mode == "proofread" ? luna : mode == "explain" ? fable : sol
 check(choices.filter(\.checked).map(\.id) == [expected], "Each menu checks its own effective model")
 check(row.detail == catalog.first { $0.id == expected }!.title, "The parent menu identifies this mode's model")
 launcher.applySelectedMode(mode)
 check(launcher.selectedModelIDForRun(preferences: saved) == expected, "Manual submission resolves the mode's model")
 launcher.handleAutomation(text: "Fixture input", mode: mode, run: true, presentation: .clipboardHUD)
 check(launcher.submissions.last!.1 == expected, "Clipboard shortcuts use the requested mode rather than the previously selected mode")
}
// Every supported model's mode menu exposes a persistent thinking submenu.
for mode in launcherModeOptions.map(\.id) {
 let row = items(launcher.chipOptionsPage(for: mode)).first { $0.id == "mode-thinking" }!
 check(row.detail == "Automatic", "Fresh mode choices default to Automatic thinking")
 guard case .push(let page) = row.action!() else { fatalError("Thinking must open a submenu") }
 let expectedChoices = mode == "explain" ? ["automatic", "low", "medium", "high"] : ["automatic", "off", "low", "medium", "high"]
 check(items(page).map(\.id) == expectedChoices, "Thinking shows only this model's supported levels")
 _ = items(page).first { $0.id == "high" }!.action!()
 check(saved.modeThinking[mode] == "high", "Thinking choices survive preference serialization")
 check(items(launcher.chipOptionsPage(for: mode)).first { $0.id == "mode-thinking" }!.detail == "High", "The chip dropdown displays its saved choice")
}
launcher.pendingExplicitModelID = sol
_ = items(launcher.thinkingSelectionPage(mode: "proofread")).first { $0.id == "low" }!.action!()
check(launcher.pendingExplicitModelID == sol, "Changing thinking preserves a pending URL model override")
launcher.pendingExplicitModelID = nil
check(saved.modeThinking["proofread"] == "low" && saved.modeThinking["rewrite"] == "high", "Each chip has an independent thinking preference")
_ = items(launcher.thinkingSelectionPage(mode: "proofread")).first { $0.id == "off" }!.action!()
check(saved.modeThinking["proofread"] == "off", "Off is stored explicitly")
// A model change can invalidate a previously open Off action.
let staleOff = items(launcher.thinkingSelectionPage(mode: "proofread")).first { $0.id == "off" }!.action!
launcher.selectTextModel(fable, for: "proofread")
check(items(launcher.thinkingSelectionPage(mode: "proofread")).filter(\.checked).map(\.id) == ["low"], "Off falls back to Low on an always-thinking model")
_ = staleOff()
check(saved.modeThinking["proofread"] == "off", "An unsupported stale choice cannot overwrite saved thinking")
launcher.selectTextModel(luna, for: "proofread")
check(items(launcher.thinkingSelectionPage(mode: "proofread")).filter(\.checked).map(\.id) == ["off"], "Switching back restores the saved Off choice")
_ = items(launcher.thinkingSelectionPage(mode: "proofread")).first { $0.id == "medium" }!.action!()
check(saved.modeThinking["proofread"] == "medium", "Medium is stored explicitly")
saved.modeThinking["proofread"] = "xhigh"
check(items(launcher.thinkingSelectionPage(mode: "proofread")).filter(\.checked).map(\.id) == ["high"], "Removed Extra High choices now select High")
saved.modeThinking["proofread"] = "future-value"
check(items(launcher.thinkingSelectionPage(mode: "proofread")).filter(\.checked).map(\.id) == ["automatic"], "Unknown saved choices fall back to Automatic")
let staleThinking = items(launcher.thinkingSelectionPage(mode: "proofread")).first { $0.id == "high" }!.action!
saved.openAIEndpointOverride = "https://custom.test/responses"
check(!items(launcher.chipOptionsPage(for: "proofread")).contains { $0.id == "mode-thinking" }, "Custom endpoint overrides do not offer unsupported thinking controls")
_ = staleThinking()
check(saved.modeThinking["proofread"] == "future-value", "A stale thinking menu cannot change an unsupported endpoint")
saved.openAIEndpointOverride = ""
launcher.isGenerating = true
_ = staleThinking()
check(saved.modeThinking["proofread"] == "future-value", "Busy launchers reject thinking changes")
launcher.isGenerating = false
launcher.selectThinking(.high, for: "unknown")
check(saved.modeThinking["unknown"] == nil, "Unknown modes cannot save thinking preferences")
// Use actual palette actions and keep the other mode's model unchanged.
_ = items(launcher.modelSelectionPage(mode: "rewrite")).first { $0.id == luna }!.action!()
check(saved.modeTextModels["rewrite"] == luna && saved.modeTextModels["explain"] == fable, "A menu action edits only its own mode")
check(items(launcher.modelSelectionPage()).contains { $0.id == "all-models" }, "Only the master menu exposes All models")
// Saved assignments must outlive the launcher and preserve per-mode settings.
let reopened = Launcher()
reopened.handleAutomation(text: "Fixture", mode: "proofread", run: true)
check(reopened.submissions.last!.1 == luna, "Reopening retains per-mode assignments")
reopened.handleAutomation(text: "Fixture", mode: "explain", run: true, model: luna)
check(reopened.submissions.last!.1 == luna, "An enabled URL model overrides this single request")
check(saved.modeTextModels["explain"] == fable && saved.explanationModel == sol, "URL models do not change persistent choices")
reopened.handleAutomation(text: "Fixture", mode: "explain", run: true)
check(reopened.submissions.last!.1 == fable, "The next shortcut returns to its saved model")
reopened.handleAutomation(text: "Fixture", mode: "explain", run: true, model: "not-enabled")
check(reopened.submissions.last!.1 == fable, "A disabled URL model cannot bypass the shortlist")
reopened.handleAutomation(text: "Fixture", mode: "explain", run: false, model: luna)
check(reopened.selectedModelIDForRun(preferences: saved) == luna, "A compose URL retains its temporary model until submission")
reopened.applySelectedMode("proofread")
check(reopened.pendingExplicitModelID == nil, "Changing modes clears an earlier URL override")
// Disabling an assigned model must immediately affect menus and all entry paths.
let staleAction = items(reopened.modelSelectionPage(mode: "dictionary")).first { $0.id == fable }!.action!
saved.preferredTextModels.removeAll { $0 == fable }
_ = staleAction()
check(saved.modeTextModels["dictionary"] == nil, "An already-open menu cannot select a newly disabled model")
reopened.handleAutomation(text: "Fixture", mode: "explain", run: true)
check(reopened.submissions.last!.1 == sol, "A disabled assignment falls back to the global model")
saved.preferredTextModels.append(fable)
check(enabledExplanationModel(for: "explain", preferences: saved) == fable, "Re-enabling a model restores its assignment")
saved.modeTextModels["dictionary"] = "removed-model"
check(enabledExplanationModel(for: "dictionary", preferences: saved) == sol, "A removed model cannot be used")
saved.modeTextModels["dictionary"] = customModelID
saved.preferredTextModels.append(customModelID)
check(enabledExplanationModel(for: "dictionary", preferences: saved) == sol, "An unconfigured custom endpoint stays unavailable")
saved.customModelName = "fixture-model"
check(enabledExplanationModel(for: "dictionary", preferences: saved) == customModelID, "A configured, enabled custom model can be assigned")
// Returning-text Services bypass the launcher; exercise their real request path.
let service = ServiceFixture()
let pasteboard = NSPasteboard(name: NSPasteboard.Name("tools.min.langmin.mode-model-tests.\(UUID().uuidString)"))
for mode in ["proofread", "rewrite"] {
 pasteboard.clearContents()
 pasteboard.setString("Fixture input", forType: .string)
 var error: NSString?
 service.runReturningTextService(pasteboard, mode: mode, error: &error)
 check(error == nil && pasteboard.string(forType: .string) == "Corrected fixture text", "Service returns fixture output on its private pasteboard")
 check(capturedServiceModels.last == luna && consentModels.last == luna, "Service consent and generation use the same assigned model")
}
pasteboard.releaseGlobally()
// A global selection is an explicit all-mode reset.
_ = items(reopened.modelSelectionPage()).first { $0.id == appleIntelligenceModelID }!.action!()
check(saved.modeTextModels.isEmpty && saved.explanationModel == appleIntelligenceModelID, "The master menu clears every individual assignment")
check(saved.modeThinking["rewrite"] == "high", "Global model changes retain independent thinking choices")
check(!items(reopened.chipOptionsPage(for: "rewrite")).contains { $0.id == "mode-thinking" }, "Apple Intelligence does not offer cloud thinking controls")

for mode in launcherModeOptions.map(\.id) {
 reopened.handleAutomation(text: "Fixture", mode: mode, run: true)
 check(reopened.submissions.last!.1 == appleIntelligenceModelID, "Every shortcut uses the new global model")
}
let afterRemembering = Launcher()
check(afterRemembering.globalModelIDForRun(preferences: saved) == appleIntelligenceModelID, "Reopening cannot revive the previous global model")
let before = saved.modeTextModels
reopened.isGenerating = true
reopened.selectTextModel(fable, for: "explain")
check(saved.modeTextModels == before, "Busy launchers reject model changes")
reopened.isGenerating = false
reopened.selectTextModel(fable, for: "unknown")
check(saved.modeTextModels == before, "Unknown modes cannot create assignments")
print("\(checks) per-mode model checks passed; no provider or user preferences accessed")
'''
with tempfile.TemporaryDirectory(prefix='langmin-mode-model-tests-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', '-module-cache-path', cache, str(folder / 'main.swift'), '-o', str(folder / 'tests')], check=True)
    subprocess.run([str(folder / 'tests')], check=True, timeout=60)
