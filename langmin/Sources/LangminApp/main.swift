// Langmin's AppKit app, launcher and result windows.

import AVFoundation
import Carbon
import Cocoa
import Foundation
import FoundationModels
import NaturalLanguage
import PDFKit
import ServiceManagement
import UniformTypeIdentifiers
import Vision

// localized(key, english): Use stable localization keys with inline English
// fallbacks. Translations live in
// Resources/<language>.lproj/Localizable.strings.
func localized(_ key: String, _ english: String) -> String {
    NSLocalizedString(key, value: english, comment: "")
}

// Keep display strings and icon lookup names in one place.
let appName = "Langmin"
let privacyPolicyURL = URL(string: "https://min.tools/langmin/privacy/")!
let appIconName = "LangminIcon"
let appIdentifier = LangminEdition.bundleIdentifier
let keychainServiceName = appIdentifier
let keychainOpenAIAPIKeyAccount = "OPENAI_API_KEY"
let keychainAnthropicAPIKeyAccount = "ANTHROPIC_API_KEY"
let keychainGeminiAPIKeyAccount = "GEMINI_API_KEY"
let keychainGrokAPIKeyAccount = "GROK_API_KEY"
let keychainDeepSeekAPIKeyAccount = "DEEPSEEK_API_KEY"
let keychainCustomAPIKeyAccount = "CUSTOM_API_KEY"
let apiKeyPresencePreferencePrefix = "apiKeyPresence."
let customModelID = "custom"
let defaultCustomBaseURL = ""
let defaultCustomModelName = ""
let defaultCustomDisplayName = ""
let openRequestScheme = LangminEdition.urlScheme
let appleIntelligenceModelID = "apple-intelligence"
let defaultExplanationModel = appleIntelligenceModelID
let defaultTTSModel = "gpt-4o-mini-tts"
let defaultTTSVoice = "ash"
let defaultExplanationEffort = "standard"
let defaultRewriteStyle = "rephrase"
let defaultSummaryStyle = "standard"
let defaultDictionaryStyle = "standard"
// Default to the user's language. Compute after initialization so the language catalog is available.
var defaultTranslationTargetID: String {
    // Prefer the first supported non-English language in the user's system language order.
    for identifier in Locale.preferredLanguages {
        // Skip locale identifiers that do not resolve to a language code.
        guard let code = Locale(identifier: identifier).language.languageCode?.identifier else {
            continue
        }
        // Keep English as the fallback rather than the first inferred translation target.
        guard code != "en" else { continue }
        // Use the system language only if it exists in the supported target options.
        if translationTargetOptions.contains(where: { $0.id == code }) {
            return code
        }
    }
    // English-only systems still need a concrete target to start from.
    return "es"
}
// Default narration voice; "none" opens results without generating audio.
let defaultLauncherReader = "none"
// Dictionary pronunciation voice; "none" prompts for a voice on the first click.
let defaultDictionaryVoice = "none"
let defaultPreferredReaderVoices = [
    "grok:iris",
    "grok:altair",
    "nova",
    "cedar",
    "apple:com.apple.voice.compact.en-US.Samantha",
    "apple:com.apple.voice.compact.en-GB.Daniel"
]
let defaultOutputLanguage = "auto"
let defaultWindowShape = "landscape"
let defaultExplanationFontSize: Double = 16
let defaultWebResearchEnabled = true
let defaultSecretProtectionEnabled = true
let defaultTextWatermarkCleaningEnabled = true
let defaultResultDiffEnabled = true
let defaultResultToolbarShowsSaveText = true
let defaultResultToolbarShowsSaveAudio = true
let defaultResultToolbarShowsCopy = true
let defaultResultToolbarShowsShare = true
let defaultResultToolbarShowsNarration = true
let defaultResultToolbarShowsHighlight = true
let defaultResultToolbarShowsStats = true
let defaultResultStatsShowsTTS = false
let defaultNarrationHighlightMode = false
let defaultNarrationPlaybackRate: Float = 1
let defaultLauncherShowsSecondaryOptions = true
let defaultLauncherShowsTranslationTarget = true
let defaultLauncherShowsModel = true
// Hide the separate language-level picker by default; level choices remain in each mode's menu.
let defaultLauncherShowsLevel = false
let defaultLauncherClearsInputAfterSubmit = true
let defaultMenuBarEnabled = true
let defaultExtraLanguages = ""
// Modes that support automatic narration.
let autoNarrateModeIDs = ["explain", "proofread", "rewrite", "summarize", "translate", "dictionary"]
let defaultAutoNarrateModes = "explain"
let defaultExtraLanguagesInDictionary = true
let defaultExtraLanguagesInTranslate = false
let defaultExtraLanguagesInExplain = false
let defaultExtraLanguagesInSummarize = false
let minimumExplanationFontSize: Double = 12
let maximumExplanationFontSize: Double = 36
let speechRequestTimeout: TimeInterval = 180
let nativeTrafficLightInsetAdjustment: CGFloat = 2
// Leading inset for custom launcher and result title text.
let plainTitleGap: CGFloat = 10
var nativeTrafficLightOriginalCloseX: [ObjectIdentifier: CGFloat] = [:]

// All app windows share one native preferences suite.
let preferencesStore = langminPreferencesStore()

// Preference keys stay explicit so Settings migrations remain predictable.
enum PreferenceKey {
    static let explanationModel = "explanationModel"
    static let preferredTextModels = "preferredTextModels"
    static let customBaseURL = "customBaseURL"
    static let customModelName = "customModelName"
    static let customDisplayName = "customDisplayName"
    static let ttsModel = "ttsModel"
    static let ttsVoice = "ttsVoice"
    static let explanationEffort = "explanationEffort"
    static let rewriteStyle = "rewriteStyle"
    static let summaryStyle = "summaryStyle"
    static let dictionaryStyle = "dictionaryStyle"
    static let translationTarget = "translationTarget"
    static let launcherReader = "launcherReader"
    static let dictionaryVoice = "dictionaryVoice"
    static let dictionaryIllustrationProvider = "dictionaryIllustrationProvider"
    static let dictionaryIllustrationAutomatic = "dictionaryIllustrationAutomatic"
    static let transcriptionProvider = "transcriptionProvider"
    static let transcriptionLanguage = "transcriptionLanguage"
    static let preferredReaderVoices = "preferredReaderVoices"
    // Read the legacy language key only as a fallback for per-mode settings.
    static let outputLanguage = "outputLanguage"
    static let explainAnswerLanguage = "explainAnswerLanguage"
    static let summarizeAnswerLanguage = "summarizeAnswerLanguage"
    static let webResearchEnabled = "webResearchEnabled"
    static let secretProtectionEnabled = "secretProtectionEnabled"
    static let textWatermarkCleaningEnabled = "textWatermarkCleaningEnabled"
    static let resultDiffEnabled = "resultDiffEnabled"
    static let resultToolbarShowsSaveText = "resultToolbarShowsSaveText"
    static let resultToolbarShowsSaveAudio = "resultToolbarShowsSaveAudio"
    static let resultToolbarShowsCopy = "resultToolbarShowsCopy"
    static let resultToolbarShowsShare = "resultToolbarShowsShare"
    static let resultToolbarShowsNarration = "resultToolbarShowsNarration"
    static let resultToolbarShowsHighlight = "resultToolbarShowsHighlight"
    static let resultToolbarShowsStats = "resultToolbarShowsStats"
    static let resultStatsShowsTTS = "resultStatsShowsTTS"
    static let narrationHighlightMode = "narrationHighlightMode"
    static let narrationPlaybackRate = "narrationPlaybackRate"
    static let windowShape = "windowShape"
    static let libraryDetached = "libraryDetached"
    static let explanationFontSize = "explanationFontSize"
    static let rememberLauncherChoices = "rememberLauncherChoices"
    static let launcherShowsSecondaryOptions = "launcherShowsSecondaryOptions"
    static let launcherShowsTranslationTarget = "launcherShowsTranslationTarget"
    static let launcherShowsModel = "launcherShowsModel"
    static let languageLevel = "languageLevel"
    static let launcherShowsLevel = "launcherShowsLevel"
    static let launcherClearsInputAfterSubmit = "launcherClearsInputAfterSubmit"
    static let extraLanguages = "extraLanguages"
    static let extraLanguagesInDictionary = "extraLanguagesInDictionary"
    static let extraLanguagesInTranslate = "extraLanguagesInTranslate"
    static let extraLanguagesInExplain = "extraLanguagesInExplain"
    static let extraLanguagesInSummarize = "extraLanguagesInSummarize"
    static let autoNarrateModes = "autoNarrateModes"
    static let launcherMode = "launcherMode"
    static let launcherExplanationModel = "launcherExplanationModel"
    static let launcherExplanationEffort = "launcherExplanationEffort"
    static let launcherRewriteStyle = "launcherRewriteStyle"
    static let launcherSummaryStyle = "launcherSummaryStyle"
    static let launcherDictionaryStyle = "launcherDictionaryStyle"
    static let launcherTranslationTarget = "launcherTranslationTarget"
    static let launcherLanguageLevel = "launcherLanguageLevel"
    static let launcherPinnedModes = "launcherPinnedModes"
    static let launcherRecentTranslationTargets = "launcherRecentTranslationTargets"
    static let advancedOpenAIEndpoint = "advancedOpenAIEndpoint"
    static let advancedAnthropicEndpoint = "advancedAnthropicEndpoint"
    static let advancedGeminiEndpoint = "advancedGeminiEndpoint"
    static let advancedAnthropicVersion = "advancedAnthropicVersion"
    static let advancedAnthropicWebSearchToolType = "advancedAnthropicWebSearchToolType"
    static let advancedCustomInstructions = "advancedCustomInstructions"
    static let advancedExtraModels = "advancedExtraModels"
    static let menuBarEnabled = "menuBarEnabled"
    static let shortcutCompose = "shortcutCompose"
    static let shortcutProofread = "shortcutProofread"
    static let shortcutRewrite = "shortcutRewrite"
    static let shortcutExplain = "shortcutExplain"
    static let shortcutSummarize = "shortcutSummarize"
    static let shortcutTranslate = "shortcutTranslate"
    static let shortcutDictionary = "shortcutDictionary"
    static let shortcutLibrary = "shortcutLibrary"
    static let commandOpenShortcutMigrationCompleted = "commandOpenShortcutMigrationCompleted"
    static let globalLibraryShortcutMigrationCompleted = "globalLibraryShortcutMigrationCompleted"
}
