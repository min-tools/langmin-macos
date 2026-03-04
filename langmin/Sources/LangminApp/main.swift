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

// Store shortcut modifiers in our own fixed bit format, independent of NSEvent's raw values.
struct GlobalShortcut: Equatable {
    static let command = 1
    static let option = 2
    static let control = 4
    static let shift = 8

    var keyCode: UInt32
    var modifiers: Int
    var key: String

    var encoded: String { "\(keyCode):\(modifiers):\(key)" }

    // init(keyCode, modifiers, key): Normalize the displayed key name while
    // retaining its hardware code and modifier mask.
    init(keyCode: UInt32, modifiers: Int, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = Self.canonicalKeyLabel(for: keyCode, fallback: key)
    }

    // canonicalKeyLabel(keyCode, fallback): Label shifted number-row keys with
    // their digits instead of punctuation.
    private static func canonicalKeyLabel(for keyCode: UInt32, fallback: String) -> String {
        // Use stable digit labels for hardware number keys regardless of keyboard-layout output.
        switch keyCode {
        // Label the hardware zero key consistently.
        case UInt32(kVK_ANSI_0): return "0"
        // Label the hardware one key consistently.
        case UInt32(kVK_ANSI_1): return "1"
        // Label the hardware two key consistently.
        case UInt32(kVK_ANSI_2): return "2"
        // Label the hardware three key consistently.
        case UInt32(kVK_ANSI_3): return "3"
        // Label the hardware four key consistently.
        case UInt32(kVK_ANSI_4): return "4"
        // Label the hardware five key consistently.
        case UInt32(kVK_ANSI_5): return "5"
        // Label the hardware six key consistently.
        case UInt32(kVK_ANSI_6): return "6"
        // Label the hardware seven key consistently.
        case UInt32(kVK_ANSI_7): return "7"
        // Label the hardware eight key consistently.
        case UInt32(kVK_ANSI_8): return "8"
        // Label the hardware nine key consistently.
        case UInt32(kVK_ANSI_9): return "9"
        // Use the supplied uppercase label for keys outside the fixed digit mapping.
        default: return fallback.uppercased()
        }
    }

    // init?(encoded): Restore a shortcut from the three fields stored in
    // preferences; reject malformed values.
    init?(encoded: String) {
        let parts = encoded.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        // Reject shortcut preferences without all three correctly typed fields.
        guard parts.count == 3, let code = UInt32(parts[0]), let modifiers = Int(parts[1]) else { return nil }
        self.init(keyCode: code, modifiers: modifiers, key: String(parts[2]))
    }

    var displayText: String {
        var result = ""
        // Include Control in the displayed modifier sequence.
        if modifiers & Self.control != 0 { result += "⌃" }
        // Include Option after Control in the displayed sequence.
        if modifiers & Self.option != 0 { result += "⌥" }
        // Include Shift before Command in the displayed sequence.
        if modifiers & Self.shift != 0 { result += "⇧" }
        // Place Command immediately before the displayed key.
        if modifiers & Self.command != 0 { result += "⌘" }
        return result + key
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        // Translate the stored Control bit into Carbon's registration mask.
        if modifiers & Self.control != 0 { result |= UInt32(controlKey) }
        // Translate the stored Option bit into Carbon's registration mask.
        if modifiers & Self.option != 0 { result |= UInt32(optionKey) }
        // Translate the stored Shift bit into Carbon's registration mask.
        if modifiers & Self.shift != 0 { result |= UInt32(shiftKey) }
        // Translate the stored Command bit into Carbon's registration mask.
        if modifiers & Self.command != 0 { result |= UInt32(cmdKey) }
        return result
    }

    var eventModifierFlags: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        // Translate the stored Control bit into AppKit event flags.
        if modifiers & Self.control != 0 { result.insert(.control) }
        // Translate the stored Option bit into AppKit event flags.
        if modifiers & Self.option != 0 { result.insert(.option) }
        // Translate the stored Shift bit into AppKit event flags.
        if modifiers & Self.shift != 0 { result.insert(.shift) }
        // Translate the stored Command bit into AppKit event flags.
        if modifiers & Self.command != 0 { result.insert(.command) }
        return result
    }
}

// Leave Open Clipboard unassigned. Library and clipboard actions use global Control-Shift shortcuts.
let globalClipboardShortcutActions = ["compose", "proofread", "rewrite", "explain", "summarize", "translate", "dictionary"]
let globalShortcutActions = ["library"] + globalClipboardShortcutActions
let configurableShortcutActions = globalShortcutActions

// Report rejected shortcuts separately from failure to install the hotkey event handler.
struct GlobalHotKeyRegistrationOutcome {
    let rejectedActions: [String]
    let infrastructureUnavailable: Bool
}

let defaultGlobalShortcuts: [String: GlobalShortcut] = [
    "library": GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_L),
        modifiers: GlobalShortcut.control | GlobalShortcut.shift,
        key: "L"
    ),
    "proofread": GlobalShortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: GlobalShortcut.control | GlobalShortcut.shift, key: "1"),
    "rewrite": GlobalShortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: GlobalShortcut.control | GlobalShortcut.shift, key: "2"),
    "explain": GlobalShortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: GlobalShortcut.control | GlobalShortcut.shift, key: "3"),
    "summarize": GlobalShortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: GlobalShortcut.control | GlobalShortcut.shift, key: "4"),
    "translate": GlobalShortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: GlobalShortcut.control | GlobalShortcut.shift, key: "5"),
    "dictionary": GlobalShortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: GlobalShortcut.control | GlobalShortcut.shift, key: "6")
]

let shortcutPreferenceKeys: [String: String] = [
    "library": PreferenceKey.shortcutLibrary,
    "compose": PreferenceKey.shortcutCompose,
    "proofread": PreferenceKey.shortcutProofread,
    "rewrite": PreferenceKey.shortcutRewrite,
    "explain": PreferenceKey.shortcutExplain,
    "summarize": PreferenceKey.shortcutSummarize,
    "translate": PreferenceKey.shortcutTranslate,
    "dictionary": PreferenceKey.shortcutDictionary
]

// migrateCommandOpenClipboardShortcut(): Clear the old Command-O default once.
// Preserve custom shortcuts and allow later reassignment.
func migrateCommandOpenClipboardShortcut() {
    // Apply the shortcut-preference migration only once.
    guard !preferencesStore.bool(forKey: PreferenceKey.commandOpenShortcutMigrationCompleted) else { return }
    let formerDefault = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_O),
        modifiers: GlobalShortcut.command,
        key: "O"
    )
    // Clear only the exact former default, preserving a user's custom Compose shortcut.
    if preferencesStore.string(forKey: PreferenceKey.shortcutCompose) == formerDefault.encoded {
        preferencesStore.set("", forKey: PreferenceKey.shortcutCompose)
    }
    preferencesStore.set(true, forKey: PreferenceKey.commandOpenShortcutMigrationCompleted)
}

// migrateLibraryShortcutToGlobalDefault(): Replace only the old Library
// default; preserve custom and cleared shortcuts.
func migrateLibraryShortcutToGlobalDefault() {
    // Apply the Library-shortcut migration only once.
    guard !preferencesStore.bool(forKey: PreferenceKey.globalLibraryShortcutMigrationCompleted) else { return }
    let formerDefault = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_L),
        modifiers: GlobalShortcut.command,
        key: "L"
    )
    // Replace only the former Library default, preserving user-customized bindings.
    if preferencesStore.string(forKey: PreferenceKey.shortcutLibrary) == formerDefault.encoded {
        preferencesStore.set(defaultGlobalShortcuts["library"]?.encoded, forKey: PreferenceKey.shortcutLibrary)
    }
    preferencesStore.set(true, forKey: PreferenceKey.globalLibraryShortcutMigrationCompleted)
}

// Pair a display label with its API identifier.
struct PreferenceOption {
    let id: String
    let title: String
    let note: String

    var displayValue: String {
        title
    }

    var descriptiveDisplayValue: String {
        note.isEmpty ? title : "\(title) — \(note)"
    }
}

// tabDirection(event): Allow Tab navigation regardless of the system's Full
// Keyboard Access setting.
func tabDirection(for event: NSEvent) -> Bool? {
    // Only Tab can move through the custom logical focus order.
    guard event.keyCode == 48 else {
        return nil
    }

    let flags = event.modifierFlags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .capsLock, .function])

    // Unmodified Tab advances focus.
    if flags.isEmpty {
        return true
    }

    // Shift-Tab moves focus backward.
    if flags == [.shift] {
        return false
    }

    return nil
}

// Native text field with launcher-specific hover/focus background updates.
final class FocusableTextField: NSTextField {
    var focusHandler: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isMouseInside = false
    private var isEditingText = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override var isEnabled: Bool {
        didSet {
            updateLauncherAppearance()
        }
    }

    // init(frameRect): Apply the launcher's field appearance when the control
    // is created in code.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLauncherAppearance()
    }

    // init?(coder): Apply the same field appearance when AppKit decodes the
    // control.
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLauncherAppearance()
    }

    // becomeFirstResponder(): Notify the launcher after AppKit accepts keyboard
    // focus.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()

        // Notify the owner only after AppKit accepts focus.
        if accepted {
            focusHandler?()
            isEditingText = true
            updateLauncherAppearance()
        }

        return accepted
    }

    // resignFirstResponder(): Clear the editing appearance only after AppKit
    // allows focus to leave.
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()

        // Clear editing state only after AppKit accepts the focus change.
        if accepted {
            isEditingText = false
            updateLauncherAppearance()
        }

        return accepted
    }

    // updateTrackingAreas(): Replace hover tracking when the field's bounds
    // change.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove the old hover region before installing one for current bounds.
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect
        ]
        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        trackingArea = nextTrackingArea
    }

    // mouseEntered(event): Show the field's hover appearance while the pointer
    // is inside.
    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        updateLauncherAppearance()
    }

    // mouseExited(event): Remove the hover appearance when the pointer leaves.
    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        updateLauncherAppearance()
    }

    // viewDidChangeEffectiveAppearance(): Refresh field colors after a light or
    // dark appearance change.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLauncherAppearance()
    }

    // setEditing(editing): Keep AppKit delegate editing state in sync with
    // custom focus tracking.
    func setEditing(_ editing: Bool) {
        isEditingText = editing
        updateLauncherAppearance()
    }

    // configureLauncherAppearance(): Use a native rounded field with a focus
    // ring and launcher-specific background handling.
    private func configureLauncherAppearance() {
        bezelStyle = .roundedBezel
        controlSize = .regular
        drawsBackground = true
        focusRingType = .default
        updateLauncherAppearance()
    }

    // updateLauncherAppearance(): Show the editable surface on hover or focus,
    // and keep idle fields visually quiet.
    private func updateLauncherAppearance() {
        let focused = isEditingText || currentEditor() != nil

        // Show the field background only on hover or focus.
        if isEnabled, focused || isMouseInside {
            drawsBackground = true
            backgroundColor = langminFieldFillColor
        } else {
            // Keep an idle or disabled launcher field visually quiet.
            drawsBackground = false
        }
    }
}

// Popup button that reports focus changes to explicit Tab-order controllers.
class FocusablePopUpButton: NSPopUpButton {
    var focusHandler: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    // becomeFirstResponder(): Notify the owner when this control receives
    // keyboard focus.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()

        // Notify dependent controls only after focus is accepted.
        if accepted {
            focusHandler?()
        }

        return accepted
    }

    // acceptsFirstMouse(event): Clicking an inactive window should activate the
    // window, not open a menu.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        false
    }
}

// Button that participates in the same explicit keyboard traversal as popups.
final class FocusableButton: NSButton {
    var focusHandler: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    // becomeFirstResponder(): Notify the owner when this control receives
    // keyboard focus.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()

        // Notify dependent controls only after focus is accepted.
        if accepted {
            focusHandler?()
        }

        return accepted
    }
}
