#!/usr/bin/env python3
"""Run every mode through production submission, prompts, routing, and delivery.

Only provider transport, preferences, consent UI, and result windows are replaced.
The fixture never reads credentials or sends text to a provider. Files and private
pasteboards belong to the fixture and are removed on exit.
"""
from pathlib import Path
import os
import subprocess
import tempfile

from source_files import ROOT, app_source

MAIN = app_source('main.swift')
CLOUD = app_source('CloudText.swift')
SHARED = (ROOT / 'langmin/Sources/LangminShared/LangminStorage.swift').read_text()


# block(text, marker): Extract the production declaration with its nested blocks.
def block(text, marker):
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end] + '\n'


source = r'''
import Cocoa
import NaturalLanguage
func localized(_ key: String, _ fallback: String) -> String { fallback }
let appleIntelligenceModelID = "apple:intelligence", customModelID = "custom"
let openAIResponsesEndpoint = URL(string: "https://openai.fixture.invalid/responses")!
let anthropicMessagesEndpoint = URL(string: "https://claude.fixture.invalid/messages")!
func resolvedOverrideURL(_ value: String, default fallback: URL) -> URL { value.isEmpty ? fallback : URL(string: value)! }
let defaultExplanationModel = appleIntelligenceModelID, defaultOutputLanguage = "auto"
let defaultRewriteStyle = "rephrase", defaultTTSVoice = "none"
let defaultPreferredTextModelIDs = [appleIntelligenceModelID, "gpt-6-sol"]
let languageLevelIDs = ["off", "a", "b", "c"]
let languageLevelModes: Set<String> = ["rewrite", "explain", "summarize", "translate", "dictionary"]
let modes = ["proofread", "rewrite", "explain", "summarize", "translate", "dictionary"]
let modelIDs = [appleIntelligenceModelID, "gpt-6-luna", "anthropic:claude-fable-5-1", "gemini:gemini-fixture", "grok:grok-fixture", "deepseek:deepseek-fixture", customModelID]
struct AppPreferences {
 var explanationModel = "gpt-6-luna", modeTextModels: [String: String] = [:]
 var modeThinking: [String: String] = [:]
 var openAIEndpointOverride = "", anthropicEndpointOverride = ""
 var preferredTextModels = modelIDs, extraModels: [String] = []
 var customModelName = "fixture-model", customDisplayName = "Fixture", customBaseURL = "https://fixture.invalid/v1"
 var languageLevel = "b", rewriteStyle = "rephrase", customInstructions = ""
 var explainAnswerLanguage = "en", summarizeAnswerLanguage = "en"
 var translationTargets = ["es", "fr"], extraLanguages = ["de"]
 var webResearchEnabled = true
 var autoNarrateModes: [String] = []
}
struct LauncherPreferences { var mode = "explain" }
var saved = AppPreferences()
func loadAppPreferences() -> AppPreferences { saved }
func loadLauncherPreferences() -> LauncherPreferences { LauncherPreferences() }

'''
source += app_source('ResultConversation.swift')
title_start = MAIN.index('let titleBoundaryTrimCharacters =')
source += MAIN[title_start:MAIN.index('\n\n', title_start)] + '\n'
for marker in ['struct PreferenceOption {', 'struct ExplanationPrompt {', 'struct HelperFailure:',
               'struct LauncherCancellationError:', 'struct TranslationSkipped:',
               'enum TextModelProvider {', 'final class TextRequestHandle {',
               'func textProvider(', 'func modelSupportsWebResearch(', 'func cloudThinkingOptions(', 'func cloudThinkingSelection(',
               'func enabledExplanationModelOptions(', 'func defaultEnabledExplanationModel(',
               'func enabledExplanationModel(', 'func preferenceDisplayValue(', 'func preferenceID(',
               'func selectedPreferenceID(', 'func setPopupSelection(',
               'func promptApplyingCustomInstructions(', 'func languageName(', 'func detectLanguagePrefix(',
               'func preferredOutputLanguage(', 'func translationLanguageCode(', 'func promptLanguageNames(',
               'func extraLanguageNames(', 'func extraLanguagesInstruction(', 'func explanationLanguageRule(',
               'func explanationPrompt(', 'func textRevisionPrompt(', 'func translationSourceLanguageInstructions(',
               'func translationPrompt(', 'func summaryPrompt(', 'func dictionaryPrompt(',
               'func watermarkCleanedGeneratedText(', 'func cleanedLiteralTransformOutput(', 'func cleanedTextTransformOutput(', 'func startTextRequest(',
               'struct StructuredJSONObjectBody {', 'func fencedResponseBody(', 'func jsonObjectBody(', 'func jsonObjectBodies(', 'func cleanTopicTitle(']:
    source += block(MAIN, marker)
for marker in ['func normalizedLanguageLevel(', 'func languageLevelInstruction(', 'func applyLanguageLevel(']:
    source += block(SHARED, marker)
source += MAIN[MAIN.index('let languageOptions:'):MAIN.index('// Override the UI language')]
source += MAIN[MAIN.index('func structuredExplanationCandidates('):MAIN.index('// Text, assets and settings for one result session.')]
source += block(CLOUD, 'func startCloudTextRequest(')
# Include source enrichment because it also decodes Explain envelopes.
for marker in ['func webCitationLabel(', 'func escapedMarkdownLinkLabel(', 'func appendingWebSources(\n']:
    source += block(CLOUD, marker)
for marker in ['func removingTrailingSourcesSection(', 'func isSourcesSectionStart(']:
    source += block(MAIN, marker)
source += block(MAIN, 'private final class ServiceTextResultBox').replace('private final', 'final')
source += r'''
let catalog = modelIDs.map { PreferenceOption(id: $0, title: $0, note: "") }
let launcherModeOptions = modes.map { PreferenceOption(id: $0, title: $0, note: "") }
let languageLevelOptions = languageLevelIDs.map { PreferenceOption(id: $0, title: $0, note: "") }
func displayedExplanationModelOptions(customName: String, extraModels: [String]) -> [PreferenceOption] { catalog }
var hasFixtureCredential = true
func loadOpenAIAPIKey() -> String { hasFixtureCredential ? "fixture" : "" }
func loadAnthropicAPIKey() -> String { loadOpenAIAPIKey() }
func loadGeminiAPIKey() -> String { loadOpenAIAPIKey() }
func loadGrokAPIKey() -> String { loadOpenAIAPIKey() }
func loadDeepSeekAPIKey() -> String { loadOpenAIAPIKey() }
func loadCustomAPIKey() -> String { loadOpenAIAPIKey() }
let grokAPIBaseURL = "https://grok.fixture.invalid/v1", deepSeekAPIBaseURL = "https://deepseek.fixture.invalid/v1"
struct Request { let provider: String, model: String; let prompt: ExplanationPrompt; let research: Bool }
var requests: [Request] = [], consentModels: [String] = []
var response: Result<String, Error> = .success("Fixture answer")
var allowConsent = true, holdResponse = false
var heldCompletion: ((Result<String, Error>) -> Void)?
// capture records the final provider-specific model after production dispatch.
func capture(_ provider: String, _ model: String, _ prompt: ExplanationPrompt, _ research: Bool,
             _ completion: @escaping (Result<String, Error>) -> Void) -> TextRequestHandle {
 requests.append(Request(provider: provider, model: model, prompt: prompt, research: research))
 return TextRequestHandle(resume: {
  if holdResponse { heldCompletion = completion } else { completion(response) }
 }, cancel: {})
}
func startOpenAITextRequest(apiKey: String, model: String, prompt: ExplanationPrompt, emptyMessage: String, research: Bool,
                           completion: @escaping (Result<String, Error>) -> Void) throws -> TextRequestHandle {
 capture("OpenAI", model, prompt, research, completion)
}
func startAnthropicTextRequest(apiKey: String, model: String, prompt: ExplanationPrompt, emptyMessage: String, research: Bool,
                              completion: @escaping (Result<String, Error>) -> Void) throws -> TextRequestHandle {
 capture("Anthropic", model, prompt, research, completion)
}
func startGeminiTextRequest(apiKey: String, model: String, prompt: ExplanationPrompt, emptyMessage: String, research: Bool,
                           completion: @escaping (Result<String, Error>) -> Void) throws -> TextRequestHandle {
 capture("Google", model, prompt, research, completion)
}
func startOpenAICompatibleTextRequest(baseURL: String, apiKey: String, model: String, prompt: ExplanationPrompt,
                                     emptyMessage: String, providerLabel: String = "Custom",
                                     completion: @escaping (Result<String, Error>) -> Void) throws -> TextRequestHandle {
 capture(providerLabel, model, prompt, false, completion)
}
@available(macOS 26.0, *)
func appleIntelligenceText(prompt: ExplanationPrompt) async throws -> String {
 requests.append(Request(provider: "Apple", model: appleIntelligenceModelID, prompt: prompt, research: false))
 return try response.get()
}
func confirmRemoteTextSharingIfNeeded(input: String, model: String, deadline: DispatchTime? = nil) -> Bool {
 consentModels.append(model); return allowConsent
}
func presentError(_ title: String, details: String) { fatalError("Unexpected alert: \(title): \(details)") }
let fixtureRoot = URL(fileURLWithPath: CommandLine.arguments[1])
func createLangminTemporaryDirectory(prefix: String) throws -> URL {
 let url = fixtureRoot.appendingPathComponent(prefix + UUID().uuidString)
 try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
 return url
}
func ttsModel(forVoice: String, requestedModel: String) -> String { requestedModel }
func appWindowTitle(mode: String, title: String) -> String { mode + ": " + title }
struct SourcePage { let title: String }
enum LauncherRunPresentation { case standard, clipboardHUD }
final class LauncherRun {
 var conversation: ResultConversation?, sourcePage: SourcePage?
 var transformCompletion: ((LauncherRun, Result<String, Error>) -> Void)?
 let presentation: LauncherRunPresentation
 let explicitTranslationTargetID: String?
 init(transformCompletion: ((LauncherRun, Result<String, Error>) -> Void)?, presentation: LauncherRunPresentation,
      explicitTranslationTargetID: String? = nil) {
  self.transformCompletion = transformCompletion; self.presentation = presentation
  self.explicitTranslationTargetID = explicitTranslationTargetID
 }
}
final class InputView: NSTextView { var isImportingFiles = false }
final class EditSession { func confirmEndingTextEdit() -> Bool { true } }
final class Delegate {
 var serviceTransformInFlight = false
 func showClipboardHUDIfNeeded(for run: LauncherRun, modelName: String, status: String) {}
}
// These result sinks capture real generated files without opening user windows.
final class Launcher: NSObject {
 var modelBox: NSPopUpButton! = NSPopUpButton(), levelBox: NSPopUpButton! = NSPopUpButton()
 var inputView = InputView(), window: NSWindow?, inlineResultSession: EditSession?
 var selectedMode = "explain", secondary = "standard", isGenerating = false
 var pendingExplicitModelID: String?, pendingExplicitTranslationTargetID: String?
 var pendingTransformCompletion: ((LauncherRun, Result<String, Error>) -> Void)?
 var pendingRunPresentation = LauncherRunPresentation.standard
 var pendingDictionaryHeadword: String?, pendingRunMode = "", pendingRunLanguageLevel = "off"
 var activeRun: LauncherRun?, activeTempDir: URL?, activeTextTask: TextRequestHandle?
 var appDelegate: Delegate? = Delegate(), lastEscapePress: TimeInterval = 0
 var lastRunTextModel = "", ttsModelForRun = "fixture"
 var output = "", finishedRun: LauncherRun?, errors: [Error] = [], progressModels: [String] = []
 var diffFiles: (String?, String?) = (nil, nil)
 override init() {
  super.init()
  modelBox.addItems(withTitles: catalog.map(\.title)); levelBox.addItems(withTitles: languageLevelIDs)
  populateRunDefaults()
 }
 func populateRunDefaults() {
  applySelectedMode("explain")
  setPopupSelection(modelBox, id: saved.explanationModel, options: enabledExplanationModelOptions(saved), fallbackID: defaultEnabledExplanationModel(saved))
  setPopupSelection(levelBox, id: saved.languageLevel, options: languageLevelOptions, fallbackID: "off")
 }
 func applySelectedMode(_ mode: String) {
  selectedMode = mode; pendingExplicitModelID = nil; pendingExplicitTranslationTargetID = nil
 }
 func prepareForLaunch() {}
 func show() { populateRunDefaults() }
 func defaultSecondaryID(for mode: String, preferences: AppPreferences) -> String {
  mode == "translate" ? preferences.translationTargets[0] : mode == "rewrite" ? preferences.rewriteStyle : "standard"
 }
 func configureSecondaryPicker(mode: String, selectedID: String) { secondary = selectedID }
 func selectedSecondaryID(for mode: String) -> String { secondary }
 func refreshSendButtonState() {}
 func saveLauncherChoices() {}
 func selectedReaderIDForRun(preferences: AppPreferences) -> String { "none" }
 func setGenerating(_ generating: Bool, status: String) { isGenerating = generating }
 func progressStatus(for mode: String, secondary: String, model: String) -> String {
  progressModels.append(model); return mode
 }
 func updateGenerationProgress(_ run: LauncherRun, status: String) {}
 func modeName(for mode: String) -> String { mode }
 func resultTitle(for mode: String, secondary: String, output: String) -> String { mode }
 func featureTitle(for mode: String) -> String { mode }
 func prepareLinkedSourceIfNeeded(input: String, mode: String, model: String, run: LauncherRun, tempDir: URL,
                                  continuation: @escaping () -> Void) -> Bool { false }
 func linkedPagePrompt(_ prompt: ExplanationPrompt, run: LauncherRun, detailed: Bool) -> ExplanationPrompt { prompt }
 func linkedPageResult(_ text: String, run: LauncherRun, detailed: Bool, tempDir: URL) async throws -> String { text }
 func finishGeneratedExplanation(textPath: String, audioPath: String, title: String, cleanupDir: String, run: LauncherRun,
                                 diffOriginalPath: String? = nil, diffRevisedPath: String? = nil) {
  output = try! String(contentsOfFile: textPath, encoding: .utf8)
  diffFiles = (diffOriginalPath, diffRevisedPath); finishedRun = run
  activeRun = nil; isGenerating = false
 }
 func generateSpeechThenOpen(text: String, model: String, voice: String, textPath: String, title: String, tempDir: URL,
                             run: LauncherRun, diffOriginalPath: String? = nil, diffRevisedPath: String? = nil) {
  fatalError("Narration disabled in fixture")
 }
 func completeTransformRun(_ run: LauncherRun, text: String, tempDir: URL) {
  finishedRun = run; output = text; activeRun = nil; isGenerating = false
  run.transformCompletion?(run, .success(text)); run.transformCompletion = nil
 }
 func failLauncherRun(_ run: LauncherRun, error: Error, title: String?, tempDir: URL?) {
  guard activeRun === run else { return }
  errors.append(error); activeRun = nil; isGenerating = false
  run.transformCompletion?(run, .failure(error)); run.transformCompletion = nil
 }
'''
for marker in ['    func selectedLauncherMode()', '    func selectedModelIDForRun(',
               '    func globalModelIDForRun(', '    func selectedLanguageLevel(',
               '    func handleAutomation(', '    @objc func submit(', '    func textTransformPrompt(',
               '    func generateTextTransform(', '    func generateExplanation(', '    func writeDiffFilesIfNeeded(']:
    source += block(MAIN, marker)
source += r'''
}
final class Service {
 let launcherController = Launcher()
 var serviceTransformInFlight = false, suppressInitialLauncherReveal = false
 func setServiceError(_ pointer: AutoreleasingUnsafeMutablePointer<NSString?>, _ message: String) { pointer.pointee = message as NSString }
 func scheduleIdleTerminationAfterService() {}
'''
source += block(MAIN, '    func runReturningTextService(')
source += block(MAIN, '    func runReceivingService(')
source += r'''
}
var checks = 0
// check(condition, message): Fail with the violated mode contract.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
 guard condition() else { fatalError(message) }
 checks += 1
}
// waitFor(condition): Pump AppKit until completion, failing instead of hanging.
func waitFor(_ condition: () -> Bool) {
 let end = Date().addingTimeInterval(5)
 while !condition() && Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
 check(condition(), "Asynchronous request finished within its deadline")
}
// fixtureResponse(mode): Give Explain its JSON envelope and other modes plain text.
func fixtureResponse(_ mode: String) -> String {
 mode == "explain" ? "{\"title\":\"Fixture title\",\"explanation\":\"Fixture answer\"}" : "Fixture answer"
}
// verify(launcher, mode, model, sourceText): Check transport and completed result agree.
func verify(_ launcher: Launcher, mode: String, model: String, sourceText: String) {
 let request = requests.last!
 let expectedModel = model == customModelID ? saved.customModelName : textProvider(for: model).model
 let providerNames = ["Apple", "OpenAI", "Anthropic", "Google", "Grok", "DeepSeek", "Custom"]
 check(request.provider == providerNames[modelIDs.firstIndex(of: model)!], "\(mode): dispatch reaches the assigned provider")
 check(request.model == expectedModel, "\(mode): provider receives the assigned model \(model)")
 check(request.prompt.input == sourceText, "\(mode): source text reaches the actual prompt intact")
 let supportsThinking = ["gpt-6-luna", "anthropic:claude-fable-5-1"].contains(model)
 check(request.prompt.thinking == (supportsThinking ? .automatic : nil), "\(mode): supported models retain Automatic until the adapter resolves the task")
 check(consentModels.last == model, "\(mode): consent uses the same provider as generation")
 check(launcher.finishedRun?.conversation?.modelID == model, "\(mode): saved conversation retains the selected model")
 check(launcher.lastRunTextModel == model && launcher.progressModels.allSatisfy { $0 == model }, "\(mode): result and progress labels identify the actual model")
 check(launcher.output.contains("Fixture answer") && launcher.errors.isEmpty, "\(mode): actual response processing delivers output")
 check(request.research == (mode == "explain" && modelSupportsWebResearch(model)), "\(mode): research follows the assigned provider's capability")
 switch mode {
 case "proofread": check(request.prompt.appleSourceTask == .proofread, "Proofread keeps its correction-only prompt")
 case "rewrite": check(request.prompt.appleSourceTask == .rephrase, "Rewrite keeps its chosen style")
 case "translate": check(request.prompt.appleFormat == .translation && Set(request.prompt.requestedOutputLanguageCodes) == ["es", "fr"], "Translate keeps both saved targets")
 case "summarize": check(request.prompt.appleSourceTask == .summarize, "Summarize keeps its own prompt")
 case "dictionary": check(request.prompt.appleFormat == .dictionary, "Dictionary keeps structured entry instructions")
 default: check(request.prompt.appleFormat == .explanation, "Explain uses the structured explanation prompt")
 }
 check(request.prompt.instructions.contains("CEFR") == (mode != "proofread"), "\(mode): language-level support survives model selection")
}
let _ = NSApplication.shared
let input = "A public fixture sentence for model routing."
// Exercise every mode against every provider through the real submit path.
for model in modelIDs {
 for mode in modes {
  saved.modeTextModels = [mode: model]; response = .success(fixtureResponse(mode))
  let launcher = Launcher()
  launcher.applySelectedMode(mode)
  launcher.configureSecondaryPicker(mode: mode, selectedID: launcher.defaultSecondaryID(for: mode, preferences: saved))
  launcher.inputView.string = input
  let before = requests.count
  launcher.submit(nil)
  waitFor { !launcher.isGenerating }
  // Older supported systems must reject Apple without trying a remote provider.
  if model == appleIntelligenceModelID {
   if #available(macOS 26.0, *) {} else {
    check(requests.count == before && launcher.errors.count == 1, "Apple requires macOS 26 without a remote fallback")
    continue
   }
  }
  check(requests.count == before + 1, "\(mode): one provider request, no hidden fallback")
  verify(launcher, mode: mode, model: model, sourceText: input)
  check((launcher.diffFiles.0 != nil) == ["proofread", "rewrite"].contains(mode), "\(mode): result diff files remain mode-specific")
 }
}
// All shortcut/HUD modes and Services must reach the same request model.
let pasteboard = NSPasteboard(name: .init("tools.min.langmin.submission-tests.\(UUID().uuidString)"))
for (index, mode) in modes.enumerated() {
 let model = modelIDs[index + 1]
 saved.modeTextModels[mode] = model; response = .success(fixtureResponse(mode))
 let launcher = Launcher()
 var delivered: String?
 launcher.handleAutomation(text: input, mode: mode, run: true, presentation: .clipboardHUD,
                           transformCompletion: { _, result in delivered = try? result.get() })
 waitFor { !launcher.isGenerating }
 verify(launcher, mode: mode, model: model, sourceText: input)
 check(delivered?.contains("Fixture answer") == true, "\(mode): shortcut completion receives readable output")
 let service = Service()
 pasteboard.clearContents(); pasteboard.setString(input, forType: .string)
 var error: NSString?
 let before = requests.count
 if ["proofread", "rewrite"].contains(mode) {
  service.runReturningTextService(pasteboard, mode: mode, error: &error)
  check(pasteboard.string(forType: .string) == "Fixture answer", "\(mode): returning Service replaces only its private pasteboard")
 } else {
  service.runReceivingService(pasteboard, mode: mode, error: &error)
  if mode == "translate" {
   check(requests.count == before, "Translate Service waits for the user's submit")
   service.launcherController.submit(nil)
  }
  waitFor { !service.launcherController.isGenerating }
  verify(service.launcherController, mode: mode, model: model, sourceText: input)
 }
 check(error == nil && requests.count == before + 1, "\(mode): Service completes exactly one request")
 check(requests.last!.prompt.thinking == (["gpt-6-luna", "anthropic:claude-fable-5-1"].contains(model) ? .automatic : nil), "\(mode): Services share the window and HUD thinking default")
 check(requests.last!.model == (model == customModelID ? saved.customModelName : textProvider(for: model).model), "\(mode): Service dispatches to its assigned provider")
}
// All entry paths must honor a saved choice after reopening.
for mode in modes {
 saved.modeTextModels[mode] = "gpt-6-luna"
 for choice in ["off", "low", "medium", "high", "xhigh", "less", "more", "automatic", "max", "invalid", ""] {
  saved.modeThinking[mode] = choice
  let expected = ExplanationPrompt.Thinking(rawValue: choice) ?? (["more", "xhigh"].contains(choice) ? .high : choice == "less" ? .low : .automatic)
  response = .success(fixtureResponse(mode))
  for presentation: LauncherRunPresentation in [.standard, .clipboardHUD] {
   let launcher = Launcher()
   launcher.handleAutomation(text: input, mode: mode, run: true, presentation: presentation)
   waitFor { !launcher.isGenerating }
   check(requests.last!.prompt.thinking == expected, "\(mode): window and shortcut requests capture the persisted thinking choice")
  }
  if ["proofread", "rewrite"].contains(mode) {
   let service = Service()
   pasteboard.clearContents(); pasteboard.setString(input, forType: .string)
   var error: NSString?
   service.runReturningTextService(pasteboard, mode: mode, error: &error)
   check(error == nil && requests.last!.prompt.thinking == expected, "\(mode): returning Services capture the thinking choice")
  }
  var followUp = ExplanationPrompt(instructions: "Answer the follow-up.", input: "Why?")
  followUp.conversationMessages = [.init(role: .user, content: "Why?")]
  _ = try startTextRequest(model: "gpt-6-luna", prompt: followUp, emptyMessage: "empty", research: true, mode: mode) { _ in }
  check(requests.last!.prompt.thinking == expected, "\(mode): explicit choices reach follow-up and research requests")
 }
}
saved.modeThinking = [:]
pasteboard.releaseGlobally()
// Explicit URL model/target overrides are request-local and survive asynchronous startup.
saved.modeTextModels["translate"] = "anthropic:claude-fable-5-1"
let url = Launcher()
response = .success("Fixture answer")
url.handleAutomation(text: input, mode: "translate", run: false, language: "es", model: "gpt-6-luna")
url.submit(nil)
waitFor { !url.isGenerating }
check(requests.last!.model == "gpt-6-luna" && requests.last!.prompt.requestedOutputLanguageCodes == ["es"], "URL overrides model and target for one request")
check(url.finishedRun?.conversation?.modelID == "gpt-6-luna" && url.pendingExplicitModelID == nil, "URL model is captured in the result and consumed")
check(saved.modeTextModels["translate"] == "anthropic:claude-fable-5-1", "URL cannot rewrite a mode assignment")
url.handleAutomation(text: input, mode: "translate", run: true)
waitFor { !url.isGenerating }
check(requests.last!.model == "claude-fable-5-1" && requests.last!.prompt.requestedOutputLanguageCodes.count == 2, "Next shortcut restores the saved model and targets")
// Every generation mode cleans output before window or HUD delivery.
for mode in modes {
 saved.modeTextModels[mode] = "gpt-6-luna"
 for presentation: LauncherRunPresentation in [.standard, .clipboardHUD] {
  response = .success(fixtureResponse(mode).replacingOccurrences(of: "Fixture answer", with: "Fixture an\u{200B}swer"))
  let clean = Launcher()
  clean.handleAutomation(text: input, mode: mode, run: true, presentation: presentation)
  waitFor { !clean.isGenerating }
  check(clean.output.contains("Fixture answer") && !clean.output.contains("\u{200B}") && clean.errors.isEmpty,
        "\(mode): cleanup is always applied before delivering window and shortcut results")
 }
}
// Consent denial, missing keys, empty responses and provider failures cannot silently retry elsewhere.
for mode in modes {
 saved.modeTextModels[mode] = "anthropic:claude-fable-5-1"
 for failure in ["consent", "credential", "empty", "provider"] {
  allowConsent = failure != "consent"; hasFixtureCredential = failure != "credential"
  response = failure == "empty" ? .success("") : .failure(HelperFailure(message: "Fixture provider failure"))
  let launcher = Launcher(), before = requests.count
  launcher.handleAutomation(text: input, mode: mode, run: true)
  waitFor { !launcher.isGenerating }
  check(launcher.output.isEmpty && launcher.errors.count == 1, "\(mode): \(failure) stops without delivering a wrong result")
  check(requests.count == before + (["consent", "credential"].contains(failure) ? 0 : 1), "\(mode): \(failure) does not fall back to another model")
 }
}
allowConsent = true; hasFixtureCredential = true; response = .success("Fixture answer")

// Reproduce a provider JSON failure without reading credentials or making a request.
let malformedExplanations = [
 #"{"title":"Love","explanation":""Love" is a feeling.\n\nA bond."}"#,
 "{\"title\":\"Love\",\"explanation\":\"First paragraph.\nSecond paragraph.\"}",
 #"{"title":"Love","explanation":"A cut-off answer"#,
 #"{"title":"Love","explanation":""}"#,
 #"{"title":"Love"}"#,
 #"{"title":"Love","explanation":42}"#,
 "```json\n{\"title\":\"Love\",\"explanation\":\"cut off\n```",
 #"Here is the answer: {"title":"Love","explanation":""Love" is an emotion."}"#,
 #""{}""#
]
saved.modeTextModels["explain"] = "deepseek:deepseek-fixture"
for malformed in malformedExplanations {
 for hud in [false, true] {
  response = .success(malformed)
  let launcher = Launcher(), before = requests.count
  var delivered: Result<String, Error>?
  launcher.handleAutomation(text: "What is love?", mode: "explain", run: true,
                            presentation: hud ? .clipboardHUD : .standard,
                            transformCompletion: hud ? { _, result in delivered = result } : nil)
  waitFor { !launcher.isGenerating }
  check(launcher.output.isEmpty && launcher.errors.count == 1, "Malformed Explain JSON fails without displaying its wrapper")
  check(requests.count == before + 1, "Invalid formatting does not silently switch providers")
  if hud {
   if case .failure? = delivered {} else { fatalError("HUD must receive the decoding failure, not JSON text") }
  }
 }
}
// Valid strings decode once: quotes, paragraph breaks, code escapes and Unicode survive.
let explanationText = #"""
"Love" is a feeling.

Keep `\n` and `C:\new\file.txt` literal. Любовь. 愛.
"""#
let validExplanation = String(data: try JSONSerialization.data(withJSONObject: ["title": "Understanding Love", "explanation": explanationText]), encoding: .utf8)!
let doubleEncoded = String(data: try JSONEncoder().encode(validExplanation), encoding: .utf8)!
for value in [validExplanation, "```json\n" + validExplanation + "\n```", doubleEncoded,
              "Here is the answer:\n" + validExplanation, "[" + validExplanation + "]"] {
 let parsed = try parseExplanationResponse(value)
 check(parsed.topicTitle == "Understanding Love" && parsed.explanation == explanationText, "Explain unwraps JSON without corrupting the answer's literal escapes")
 response = .success(value)
 let launcher = Launcher()
 launcher.handleAutomation(text: "What is love?", mode: "explain", run: true)
 waitFor { !launcher.isGenerating }
 check(launcher.output == "Understanding Love\n\n" + explanationText + "\n" && launcher.errors.isEmpty,
       "A valid response after a malformed one delivers only the readable title and answer")
}
let plainExplanation = try parseExplanationResponse("A plain explanation with `code`.")
check(plainExplanation.explanation == "A plain explanation with `code`.", "Plain Markdown fallback remains readable")

// Legacy multilingual wrappers and ordinary JSON examples still produce readable prose.
let nested = try parseExplanationResponse(#"{"title":"Love","explanation":{"main":"Main answer.","French":"Réponse française."}}"#)
check(nested.explanation == "Main answer.\n\n### French\n\nRéponse française.", "Nested language fields remain readable")
let multiple = try parseExplanationResponse(#"{"title":"Love","explanation":"Main answer."}"# + "\n\n### French\n\n" + #"{"title":"Amour","explanation":"Réponse française."}"#)
check(multiple.explanation == nested.explanation, "Separate language objects keep their headings and order")
let jsonExamples = [
 #"A data example: {"value":42}."#,
 "[JSON](https://example.test/json) is a data format.",
 "[1] A reference introduces this explanation.",
 #"A JSON object such as {"title":"Book"} stores a named value."#,
 #"The field `"explanation":` holds the answer."#,
 "The title field stores the book's name.\n\n```json\n{\"title\":\"Book\"}\n```\n\nIt must be a string.",
 "An API response can look like this:\n\n```json\n{\"title\":\"Love\",\"explanation\":\"An emotion.\"}\n```",
 "```json\n{\"title\":\"Book\"}\n```\n\nThe title field holds the book's name."
]
for example in jsonExamples {
 let parsed = try parseExplanationResponse(example)
 check(parsed.topicTitle.isEmpty && parsed.explanation == example,
       "Prose and code examples containing envelope field names remain intact")
}
// Citation enrichment must not turn a broken response into a valid outer envelope.
let citations = [(title: "Fixture source", url: "https://example.test/reference")]
for malformed in malformedExplanations {
 check(appendingWebSources(to: malformed, citations: citations, requireMarkers: false) == malformed,
       "Sources leave malformed envelopes for the delivery path to reject")
}
// JSON examples remain answer content both inside envelopes and after citations.
for example in jsonExamples {
 let wrapped = String(data: try JSONSerialization.data(withJSONObject: ["title": "JSON fields", "explanation": example]), encoding: .utf8)!
 let parsed = try parseExplanationResponse(wrapped)
 check(parsed.explanation == example, "Valid envelope content is not parsed again as a protocol wrapper")
 let enriched = appendingWebSources(to: example, citations: citations, requireMarkers: false)
 let parsedSources = try parseExplanationResponse(enriched)
 check(parsedSources.explanation.hasPrefix(example) && parsedSources.explanation.contains("### Sources"),
       "Citation enrichment preserves the explanation and its JSON examples")
}
let cited = appendingWebSources(to: validExplanation, citations: citations, requireMarkers: false)
let parsedCited = try parseExplanationResponse(cited)
check(parsedCited.topicTitle == "Understanding Love" && parsedCited.explanation.hasPrefix(explanationText)
      && parsedCited.explanation.contains("[1] [Fixture source](https://example.test/reference)"),
      "Valid Explain JSON retains readable content and provider citation links")
response = .success("Fixture answer")
// A late response cannot replace a newer run's output or metadata.
let stale = Launcher()
holdResponse = true
stale.handleAutomation(text: input, mode: "rewrite", run: true)
waitFor { heldCompletion != nil }
let oldCompletion = heldCompletion!
stale.activeRun = nil; stale.isGenerating = false
holdResponse = false
stale.handleAutomation(text: input, mode: "translate", run: true)
waitFor { !stale.isGenerating }
let finished = stale.finishedRun
oldCompletion(.success("Obsolete answer"))
_ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
check(stale.finishedRun === finished && !stale.output.contains("Obsolete"), "Late responses cannot overwrite the new result")
print("\(checks) full mode submission checks passed (offline provider transport)")
'''


# main(): Compile and run the native fixture in its own temporary directory.
if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='langmin-mode-submission-', dir='/private/tmp') as directory:
        folder = Path(directory)
        (folder / 'main.swift').write_text(source)
        cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
        subprocess.run(['swiftc', '-module-cache-path', cache, str(ROOT / 'langmin/Sources/LangminApp/TextWatermarkCleaner.swift'), str(folder / 'main.swift'), '-o', str(folder / 'tests')], check=True)
        subprocess.run([str(folder / 'tests'), str(folder)], check=True, timeout=90)
