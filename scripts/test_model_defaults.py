#!/usr/bin/env python3
"""Exercise Settings reset and Setup Assistant model selection with in-memory collaborators.

Production preference collection and wizard completion run without windows, real preferences,
credentials, provider calls, or login-item registration.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

from source_files import ROOT, app_path, app_source, swift_fixture_args
MAIN = app_source('main.swift')
WIZARD = app_source('SetupWizard.swift')


# block(source, marker): Extract one brace-balanced production declaration for
# this isolated Swift fixture.
def block(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    # Include nested blocks when finding the end of the extracted declaration.
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


source = r'''
import Foundation
// Represent model choices with the same fields used by Settings.
struct PreferenceOption { let id: String; let title: String; let note: String }
// Supply a dependency’s type identity without adding behavior to this fixture.
struct GlobalShortcut {}
let defaultGlobalShortcuts: [String: GlobalShortcut] = [:]
let defaultLanguageLevel = "off"
// Provide the image-provider choices needed by preference defaults.
enum DictionaryIllustrationProvider { case off, openAI }
// localized(key, english): Resolve labels through the fixture’s controlled
// localization.
func localized(_ key: String, _ english: String) -> String { english }
'''
constants = MAIN[MAIN.index('let customModelID ='):MAIN.index('// All app windows share')]
# The machine's preferred languages do not affect this model-selection regression.
constants = constants.replace(block(constants, 'var defaultTranslationTargetID:'),
                              'let defaultTranslationTargetID = "es"')
source += constants
source += MAIN[MAIN.index('let explanationModelOptions:'):MAIN.index('// Check local-model availability')]
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['enum PreferenceKey {', 'struct AppPreferences {', 'func encodeTextModelList(',
               'func encodeLanguageList(', 'func enabledExplanationModelOptions(',
               'func defaultEnabledExplanationModel(']:
    source += block(MAIN, marker) + '\n'

source += r'''
var saved = AppPreferences()
// loadAppPreferences(): Provide the preferences configured by this fixture.
func loadAppPreferences() -> AppPreferences { saved }
// displayedExplanationModelOptions([customName = ""], [extraModels = []]): Use
// the fixed model list so default selection stays reproducible.
func displayedExplanationModelOptions(customName: String = "", extraModels: [String] = []) -> [PreferenceOption] {
 explanationModelOptions
}
// Keep reset and setup preferences in memory.
final class MemoryStore {
 var values: [String: Any] = [:]
 // set(value, key): Record saved values without changing the user’s
 // preferences.
 func set(_ value: Any, forKey key: String) { values[key] = value }
}
let preferencesStore = MemoryStore()
// Represent checkbox state without creating native controls.
enum State { case on, off }
// Supply the text, selection, and state properties used by setup and reset.
final class Control {
 var stringValue = "", string = "", state = State.off
 var selectedIDs: [String] = []
 var shortcut: GlobalShortcut?
 var selectedItem: MenuItem?
 var menu: [PreferenceOption] = []
}
// Represent a selected popup item by its displayed title.
struct MenuItem { let title: String }
// preferenceID(title, options): Resolve a fixture menu title back to its stored
// preference ID.
func preferenceID(from title: String, options: [PreferenceOption]) -> String? {
 options.first { $0.title == title }?.id
}
// setPopupSelection(control, id, options, fallbackID): Apply the requested
// option or its fallback to the fixture control.
func setPopupSelection(_ control: Control, id: String?, options: [PreferenceOption], fallbackID: String) {
 let option = options.first { $0.id == id } ?? options.first { $0.id == fallbackID }
 control.selectedItem = option.map { MenuItem(title: $0.title) }
}
// Record window closure without opening a real window.
final class Window { var closed = false; /* close(): Record that the fixture panel was closed. */ func close() { closed = true } }
// Return a controlled reset-confirmation response without showing a dialog.
final class NSAlert {
 // Represent the confirmation choices used by the production reset handler.
 enum Response { case alertFirstButtonReturn, alertSecondButtonReturn }
 static var response = Response.alertSecondButtonReturn
 var messageText = "", informativeText = ""
 // addButton(withTitle): Keep this production dependency inactive in the
 // isolated fixture.
 func addButton(withTitle: String) {}
 // runModal(): Return the response selected by the test case.
 func runModal() -> Response { Self.response }
}
// Expose the launcher model control to the production reset path.
final class Launcher {
 var modelBox: Control! = Control()
 var model: String? { preferenceID(from: modelBox.selectedItem?.title ?? "", options: explanationModelOptions) }
 // launcherModelMenu(options): Return fixture model choices unchanged.
 func launcherModelMenu(options: [PreferenceOption]) -> [PreferenceOption] { options }
 // updateModelFooter(): Keep this production dependency inactive in the
 // isolated fixture.
 func updateModelFooter() {}
}
// Record setup requests and expose the fixture launcher.
final class AppDelegate {
 let launcherController = Launcher()
 var setupCount = 0
 // showSetupAssistant(sender): Count setup requests without opening the real
 // assistant.
 func showSetupAssistant(_ sender: Any?) { setupCount += 1 }
}
// Provide an application delegate without launching AppKit.
enum NSApp { static let delegate: AnyObject? = AppDelegate() }
// Stand in for login-item services so setup cannot alter host registration.
enum SMAppService {
 // Keep the simulated login item enabled.
 enum Status { case enabled }
 static let mainApp = Service()
 // Expose the status expected by the setup completion path.
 struct Service {
  var status: Status { .enabled }
  // register(): Fail if a test tries to register a real login item.
  func register() throws { fatalError("Unexpected login-item registration") }
 }
}
var appleAvailable = true
// appleIntelligenceIsAvailable(): Return the Apple Intelligence availability
// selected by the test.
func appleIntelligenceIsAvailable() -> Bool { appleAvailable }
// saveAPIKey(key, account, providerName): Fail if reset or setup unexpectedly
// tries to save credentials.
func saveAPIKey(_ key: String, account: String, providerName: String) throws {
 fatalError("Unexpected credential access")
}
let windowShapeOptions: [PreferenceOption] = [], fontSizeOptions: [PreferenceOption] = []
let autoNarrateModeOptions: [PreferenceOption] = []
// currentReaderOptions(): Leave reader discovery outside the model-default
// test.
func currentReaderOptions() -> [PreferenceOption] { [] }
// selectedPreferenceID(from, options, fallbackID): Use the supplied fallback
// for unrelated preference controls.
func selectedPreferenceID(from: Control, options: [PreferenceOption], fallbackID: String) -> String { fallbackID }
// selectedReaderChoiceID(control): Keep voice selection disabled in this
// fixture.
func selectedReaderChoiceID(_ control: Control) -> String { "none" }
// normalizedWindowShape(value): Leave unrelated window-shape normalization
// outside the fixture.
func normalizedWindowShape(_ value: String) -> String { value }
// parsedFontSize(value, fallback): Parse the numeric font value needed by
// preference saving.
func parsedFontSize(_ value: String, fallback: Double) -> Double { Double(value) ?? fallback }
// decodeExtraModels(value): Keep custom model decoding outside the
// default-model cases.
func decodeExtraModels(_ value: String) -> [String] { [] }
// Expose illustration preferences without building their native controls.
struct IllustrationControls {
 var provider = DictionaryIllustrationProvider.off, automatic = false
}
// Keep speech preferences independent of the writing-model choices under test.
enum SpeechProvider: String { case apple, openAI }
struct TranscriptionControls {
 var provider = SpeechProvider.apple
 var language = "auto"
}
'''
source += 'extension Launcher {\n' + block(MAIN, '    func refreshModelOptions(') + '\n}\n'
source += r'''
// Host the production reset handler and its preference controls.
final class SettingsFixture {
 var launcherChoicesResetRequested = false
 var window: Window? = Window()
 var populated: AppPreferences?
 var illustrationSettings = IllustrationControls()
 var transcriptionSettings = TranscriptionControls()
 var shortcutButtons: [String: Control] = [:], autoNarrateModeButtons: [String: Control] = [:]
 // populateFields(preferences): The form is isolated; tests below exercise the
 // actual collection of its values and hidden defaults.
 func populateFields(_ preferences: AppPreferences) {
  populated = preferences
  transcriptionSettings.provider = SpeechProvider(rawValue: preferences.transcriptionProvider) ?? .apple
  transcriptionSettings.language = preferences.transcriptionLanguage
 }
'''
collector = block(MAIN, '    func collectPreferences()')
controls = sorted(set(re.findall(r'\b\w+(?:Box|Field|View|Button)\b', collector)))
source += '\n'.join(f' var {name} = Control()' for name in controls) + '\n'
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['    func collectPreferences()', '    func nonEmpty(',
               '    @objc func resetDefaults(', '    @objc func cancel(']:
    # Objective-C action dispatch is irrelevant to the preferences transaction.
    source += block(MAIN, marker).replace('@objc ', '') + '\n'
source += '}\n'
source += r'''
// Host setup completion with controlled providers and checkbox state.
final class WizardFixture {
 static let completedKey = "didCompleteSetupWizard"
 // Represent the setup fields needed to choose a default provider.
 struct Provider { let id: String, modelID: String; let account: String? = nil; let title = "Fixture" }
 var providers: [Provider] = []
 var providerChecks: [String: Control] = [:], providerKeyFields: [String: Control] = [:]
 var translationTargetsControl: Control?, extraLanguagesControl: Control?
 var pronunciationVoicePopup: Control?, loginItemCheckbox: Control?
 var window: Window? = Window()
}
// Attach the extracted production setup completion method to the fixture.
extension WizardFixture {
'''
source += block(WIZARD, '    private func finish()').replace('private ', '') + '\n}\n'
source += r'''
var checks = 0
// check(condition, message): Report failed fixture expectations with their case
// names.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
 // Stop at the first failed model-default expectation.
 if !condition() { fatalError(message) }
 checks += 1
}
let apple = appleIntelligenceModelID, deepSeek = "deepseek:deepseek-chat"
check(AppPreferences().explanationModel == apple, "Fresh installs default to Apple Intelligence")
let form = SettingsFixture()
saved.explanationModel = deepSeek
saved.preferredTextModels = [deepSeek]
saved.explanationEffort = "detailed"
saved.extraLanguages = ["ru", "sr"]
saved.languageLevel = "b2"
form.populated = saved
check(form.collectPreferences().explanationModel == deepSeek, "An ordinary save preserves the chosen model")
check(form.collectPreferences().preferredTextModels == [deepSeek], "An ordinary save preserves enabled models")
check(form.collectPreferences().extraLanguages == ["ru", "sr"], "An ordinary save preserves launcher language choices")
form.transcriptionSettings.provider = .openAI
form.transcriptionSettings.language = "fr_FR"
check(form.collectPreferences().transcriptionProvider == "openAI", "Save uses the independent speech-provider draft")
check(form.collectPreferences().transcriptionLanguage == "fr_FR", "Save uses the chosen audio language")

form.resetDefaults(nil)
check(form.populated?.explanationModel == apple, "Reset populates the default form")
check(saved.explanationModel == deepSeek, "Reset stays a draft until Save")
let reset = form.collectPreferences()
check(reset.explanationModel == apple, "Saving Reset replaces a saved DeepSeek default with Apple")
check(reset.preferredTextModels == defaultPreferredTextModelIDs, "Reset restores Apple even when it was disabled")
check(defaultEnabledExplanationModel(reset) == apple, "The enabled-model fallback cannot select a cloud model after reset")
check(reset.explanationEffort == AppPreferences().explanationEffort, "Reset restores hidden style defaults")
check(reset.extraLanguages.isEmpty && reset.languageLevel == defaultLanguageLevel, "Reset restores hidden language defaults")
check(reset.transcriptionProvider == "apple" && reset.transcriptionLanguage == "auto", "Reset restores local speech and the Mac's language")
form.advancedCustomInstructionsView.string = "Keep British spelling."
check(form.collectPreferences().customInstructions == "Keep British spelling.", "Fields edited after Reset still save")
form.cancel(nil)
check(!form.launcherChoicesResetRequested && form.window!.closed, "Cancel discards the pending reset")
check(saved.explanationModel == deepSeek, "Cancel does not alter the saved model")
check(form.collectPreferences().explanationModel == deepSeek, "A cancelled reset cannot affect later ordinary saves")

// Setup is an alternative to saving the reset form, so it must not leave a competing draft open.
NSAlert.response = .alertFirstButtonReturn
form.window = Window()
form.resetDefaults(nil)
check(form.window!.closed && !form.launcherChoicesResetRequested, "Setup handoff closes and discards the reset draft")
check((NSApp.delegate as! AppDelegate).setupCount == 1, "Setup handoff opens the assistant")
check(saved.explanationModel == deepSeek, "Setup handoff waits for the assistant to save its choices")

// finishSetup(ids, available): Finish setup using the requested providers and
// local-model availability.
func finishSetup(_ ids: [String], available: Bool) {
 appleAvailable = available
 saved = AppPreferences()
 preferencesStore.values = [PreferenceKey.explanationModel: deepSeek, PreferenceKey.launcherExplanationModel: deepSeek]
 let wizard = WizardFixture()
 // Place Apple last to ensure priority comes from policy, not row order.
 wizard.providers = ids.map { WizardFixture.Provider(id: $0 == apple ? "apple" : $0, modelID: $0) }
 // Mark each supplied provider as selected in the setup fixture.
 for provider in wizard.providers {
  let control = Control(); control.state = .on
  wizard.providerChecks[provider.id] = control
 }
 wizard.finish()
 check(wizard.window!.closed, "Completed setup closes its window")
}
// Check that Apple remains the default when selected alongside a cloud provider.
for cloud in [deepSeek, "gpt-5.6-terra", "anthropic:claude-sonnet-5"] {
 finishSetup([cloud, apple], available: true)
 check(preferencesStore.values[PreferenceKey.explanationModel] as? String == apple, "Apple wins over a checked cloud provider")
 check(preferencesStore.values[PreferenceKey.launcherExplanationModel] as? String == apple, "Remembered models follow the new setup default")
 check((NSApp.delegate as! AppDelegate).launcherController.model == apple, "The visible launcher updates after setup")
}
finishSetup([deepSeek, apple], available: false)
check(preferencesStore.values[PreferenceKey.explanationModel] as? String == deepSeek, "Unavailable Apple falls back to a checked provider")
check(preferencesStore.values[PreferenceKey.preferredTextModels] as? String == deepSeek, "Unavailable Apple is not enabled")
finishSetup([deepSeek], available: true)
check(preferencesStore.values[PreferenceKey.explanationModel] as? String == deepSeek, "Explicitly deselecting Apple is respected")
finishSetup([apple], available: true)
check(preferencesStore.values[PreferenceKey.explanationModel] as? String == apple, "Apple-only setup remains local")
finishSetup([], available: true)
check(preferencesStore.values[PreferenceKey.explanationModel] as? String == deepSeek, "No checked providers preserves existing settings")
check(preferencesStore.values[PreferenceKey.preferredTextModels] == nil, "An empty selection does not overwrite the shortlist")
let launcher = (NSApp.delegate as! AppDelegate).launcherController
launcher.refreshModelOptions(selecting: deepSeek)
launcher.refreshModelOptions()
check(launcher.model == deepSeek, "An ordinary picker refresh preserves its selection")
launcher.refreshModelOptions(selecting: apple)
check(launcher.model == apple, "An explicit setup refresh replaces the previous selection")
print("\(checks) model default checks passed; no real preferences, UI, credentials or providers used")
'''

with tempfile.TemporaryDirectory(prefix='langmin-model-default-tests-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', *swift_fixture_args(), '-module-cache-path', cache, str(folder / 'main.swift'),
                    '-o', str(folder / 'tests')], check=True, cwd=ROOT)
    subprocess.run([str(folder / 'tests')], check=True, timeout=30, cwd=ROOT)
