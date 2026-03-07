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

// tintedSymbol(name, color, pointSize): Render an SF Symbol filled with a solid
// color for custom-drawn controls.
func tintedSymbol(_ name: String, color: NSColor, pointSize: CGFloat) -> NSImage? {
    // Return no tinted image when the system symbol cannot be loaded at the requested size.
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)) else {
        return nil
    }

    let image = NSImage(size: base.size)
    image.lockFocus()
    base.draw(at: .zero, from: NSRect(origin: .zero, size: base.size), operation: .sourceOver, fraction: 1)
    color.set()
    NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
    image.unlockFocus()
    image.isTemplate = false
    return image
}

// Settings navigation row with an icon and hover, selection, and keyboard focus highlights.
final class SettingsSidebarButton: NSButton {
    private let symbolName: String
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    var focusHandler: (() -> Void)?

    // init(title, symbolName, target, action): Store the icon and action;
    // custom drawing handles the row's appearance.
    init(title: String, symbolName: String, target: AnyObject?, action: Selector?) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.toggle)
        focusRingType = .none
        refusesFirstResponder = false
    }

    // init?(coder): This sidebar row is constructed in code with its title,
    // symbol, and action.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    // Measure at the selected font weight so the label fits in either state.
    override var intrinsicContentSize: NSSize {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(width) + 56, height: 36)
    }

    // becomeFirstResponder(): Notify the controller when keyboard focus reaches
    // this row.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // Notify the owner only after AppKit accepts keyboard focus.
        if accepted {
            focusHandler?()
            needsDisplay = true
        }
        return accepted
    }

    // resignFirstResponder(): Remove the keyboard outline when focus moves to
    // another control.
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }

    override var state: NSControl.StateValue {
        didSet {
            needsDisplay = true
        }
    }

    // updateTrackingAreas(): Keep the hover region aligned with the button's
    // current bounds.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Replace the previous tab-button hover region after layout changes.
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // mouseEntered(event): Redraw the tab with its hover background.
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    // mouseExited(event): Redraw the tab after the pointer leaves.
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    // viewDidChangeEffectiveAppearance(): Refresh custom drawing when the
    // system appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // draw(dirtyRect): Align every icon and label while retaining the same row
    // size for each state.
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)

        // Highlight the selected page and hovered row.
        if selected || isHovered {
            (selected ? NSColor.controlAccentColor.withAlphaComponent(0.14) : .labelColor.withAlphaComponent(0.05)).setFill()
            path.fill()

            // Add the selected tab's accent outline in addition to its background.
            if selected {
                NSColor.controlAccentColor.withAlphaComponent(0.34).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }

        // Keyboard focus stays visible even when it is on an unselected page.
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        }

        let tint: NSColor = selected ? .controlAccentColor : .secondaryLabelColor

        // Fit differently shaped symbols into the same leading icon slot.
        if let icon = tintedSymbol(symbolName, color: tint, pointSize: 16) {
            let scale = min(18 / icon.size.width, 18 / icon.size.height)
            let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
            let iconRect = NSRect(
                x: 14 + (18 - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            icon.draw(in: iconRect)
        }

        let font = NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: selected ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: 42, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}

// Library title bar button with an icon, saved count and chevron.
final class LibraryTitlebarButton: NSButton {
    // Show the saved count when nonzero. The launcher refreshes it from LibraryStore.
    var savedCount: Int = 0 {
        didSet {
            // Avoid recalculating Library button width when the saved count did not change.
            guard savedCount != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private let iconTextGap: CGFloat = 6
    private let iconPointSize: CGFloat = 13
    private let labelFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let countFont = NSFont.systemFont(ofSize: 13, weight: .regular)

    // init(target, action): Create the Library action with a custom label
    // instead of a native button title.
    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        title = ""
        self.target = target
        self.action = action
        isBordered = false
        focusRingType = .none
    }

    // init?(coder): This Library button is constructed in code with its action.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    // becomeFirstResponder(): Redraw the Library indicator when keyboard focus
    // arrives.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // Redraw the Library button after it successfully gains focus.
        if accepted {
            needsDisplay = true
        }
        return accepted
    }

    // resignFirstResponder(): Remove the focus appearance after AppKit accepts
    // the focus change.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        // Redraw the Library button after it successfully loses focus.
        if resigned {
            needsDisplay = true
        }
        return resigned
    }

    // "Library" (bold, label color) + " · N saved" + " ›" (both muted).
    private var attributedLabel: NSAttributedString {
        let focused = window?.firstResponder === self
        let primary = focused ? NSColor.controlAccentColor : NSColor.labelColor
        let muted = focused ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        let text = NSMutableAttributedString(string: "Library", attributes: [
            .font: labelFont, .foregroundColor: primary
        ])
        // Append a saved-item count only when the Library contains entries.
        if savedCount > 0 {
            text.append(NSAttributedString(string: " · " + String(format: localized("n_saved", "%d saved"), savedCount), attributes: [
                .font: countFont, .foregroundColor: muted
            ]))
        }
        text.append(NSAttributedString(string: "  ›", attributes: [
            .font: labelFont, .foregroundColor: muted
        ]))
        return text
    }

    private var iconWidth: CGFloat {
        tintedSymbol("books.vertical", color: .secondaryLabelColor, pointSize: iconPointSize)?.size.width ?? iconPointSize
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: iconWidth + iconTextGap + ceil(attributedLabel.size().width),
            height: NSView.noIntrinsicMetric
        )
    }

    // viewDidChangeEffectiveAppearance(): Refresh the Library label and symbol
    // colors for the current appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // draw(dirtyRect): Draw the Library label and icon with a visible
    // keyboard-focus state.
    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        let text = attributedLabel
        let textSize = text.size()
        let iconColor: NSColor = focused ? .controlAccentColor : .secondaryLabelColor
        let icon = tintedSymbol("books.vertical", color: iconColor, pointSize: iconPointSize)
        let iconW = icon?.size.width ?? iconPointSize

        var x: CGFloat = 0
        // Draw the Library symbol only when its image is available.
        if let icon {
            icon.draw(in: NSRect(
                x: x,
                y: ((bounds.height - icon.size.height) / 2).rounded(),
                width: icon.size.width,
                height: icon.size.height
            ))
        }
        x += iconW + iconTextGap
        text.draw(at: NSPoint(x: x, y: ((bounds.height - textSize.height) / 2).rounded()))
    }
}

// Draw a pinned mode with its icon, name, options and shortcut badge.
final class LauncherChipButton: NSButton {
    let modeID: String
    var focusHandler: (() -> Void)?
    // Extra label after the title, e.g. "→ Српски" on the Translate chip.
    var suffixText = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    // Shortcut badge, such as ⌃⇧1.
    var hotkeyBadge = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    // Selected chips with per-mode options show a chevron and open a menu.
    var showsChevron = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    // Reserve the chevron width so selecting a mode does not resize its chip.
    var reservesChevronSpace = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private let symbolName: String
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    private static let chipHeight: CGFloat = 38
    private static let horizontalPadding: CGFloat = 14
    private static let elementGap: CGFloat = 7

    // init(modeID, title, symbolName, target, action): Bind a launcher mode and
    // symbol to a custom-drawn action button.
    init(modeID: String, title: String, symbolName: String, target: AnyObject?, action: Selector?) {
        self.modeID = modeID
        self.symbolName = symbolName
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.toggle)
        focusRingType = .none
        wantsLayer = true
        layer?.masksToBounds = false
        // Supply an accessibility label because the chip draws its own title.
        setAccessibilityLabel("\(title) mode")
    }

    // init?(coder): Mode buttons require a mode ID and are constructed in code.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    private var titleFont: NSFont {
        NSFont.systemFont(ofSize: 13, weight: state == .on ? .semibold : .medium)
    }

    private var badgeFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // Lighten the accent in dark mode and darken it in light mode for readable labels.
    private var selectedTint: NSColor {
        let accent = NSColor.controlAccentColor
        return isDarkAppearance
            ? (accent.blended(withFraction: 0.35, of: .white) ?? accent)
            : (accent.blended(withFraction: 0.2, of: .black) ?? accent)
    }

    override var intrinsicContentSize: NSSize {
        var width = Self.horizontalPadding * 2
        width += tintedSymbol(symbolName, color: .labelColor, pointSize: 13)?.size.width ?? 0
        width += Self.elementGap
        width += ceil(displayTitle.size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width)
        // Reserve space for a shortcut badge only when the badge has text.
        if !hotkeyBadge.isEmpty {
            width += Self.elementGap + ceil((hotkeyBadge as NSString).size(withAttributes: [.font: badgeFont]).width)
        }
        // Reserve disclosure space for either a visible chevron or stable alignment with one.
        if showsChevron || reservesChevronSpace {
            width += Self.elementGap + 9
        }
        return NSSize(width: ceil(width), height: Self.chipHeight)
    }

    private var displayTitle: NSString {
        (suffixText.isEmpty ? title : "\(title) \(suffixText)") as NSString
    }

    // becomeFirstResponder(): Notify the launcher and redraw after the mode
    // button gains focus.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // Notify the launcher and redraw after this mode chip accepts focus.
        if accepted {
            focusHandler?()
            needsDisplay = true
        }
        return accepted
    }

    // resignFirstResponder(): Remove the mode button's focus highlight when
    // focus leaves.
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        // Remove the chip's focused appearance when focus successfully leaves.
        if accepted { needsDisplay = true }
        return accepted
    }

    // mouseDown(event): Give the clicked mode keyboard focus before AppKit
    // tracks the click.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        needsDisplay = true
        super.mouseDown(with: event)
    }

    // keyDown(event): Allow Return or Space to activate the focused mode
    // button.
    override func keyDown(with event: NSEvent) {
        // Return and Space activate the focused mode chip.
        if event.keyCode == 36 || event.keyCode == 49 {
            performClick(nil)
            return
        }
        super.keyDown(with: event)
    }

    override var state: NSControl.StateValue {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    // viewDidChangeEffectiveAppearance(): Redraw the mode button when system
    // colors change.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // updateTrackingAreas(): Rebuild the hover region to match the current
    // mode-button bounds.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Replace the chip's old tracking area before registering its current bounds.
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // mouseEntered(event): Show the mode button's hover state.
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    // mouseExited(event): Clear the mode button's hover state.
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    // draw(dirtyRect): Draw the mode's selection, focus, and disabled states
    // around its content.
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let focused = window?.firstResponder === self
        let enabledAlpha: CGFloat = isEnabled ? 1 : 0.45
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)

        // Tint the selected chip; reserve solid accent fill for Send.
        // Show keyboard focus by brightening the fill so it remains distinct from selection.
        let fill: NSColor
        // Use an accent background for the currently selected mode.
        if selected {
            fill = NSColor.controlAccentColor.withAlphaComponent((focused ? 0.28 : 0.18) * enabledAlpha)
        } else if isHovered && isEnabled {
            // Show a subtle hover fill for an enabled unselected mode.
            fill = NSColor.labelColor.withAlphaComponent(0.08)
        } else {
            // Use the normal background while preserving focus and disabled opacity cues.
            fill = NSColor.labelColor.withAlphaComponent((focused ? 0.11 : 0.045) * enabledAlpha)
        }
        fill.setFill()
        path.fill()

        let baseTint: NSColor = selected ? selectedTint : NSColor.labelColor
        let tint = baseTint.withAlphaComponent(enabledAlpha)
        let baseQuiet: NSColor = selected ? selectedTint : NSColor.tertiaryLabelColor
        let quiet = baseQuiet.withAlphaComponent(selected ? 0.62 * enabledAlpha : enabledAlpha)
        let attributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: tint]
        let text = displayTitle
        let textSize = text.size(withAttributes: attributes)
        var x = Self.horizontalPadding

        // Use a lighter icon on idle chips in light mode to match the label's visual weight.
        let iconTint = selected || isDarkAppearance ? tint : NSColor.secondaryLabelColor.withAlphaComponent(enabledAlpha)
        // Draw the mode icon only when the requested tinted symbol exists.
        if let icon = tintedSymbol(symbolName, color: iconTint, pointSize: 13) {
            icon.draw(in: NSRect(
                x: x,
                y: (bounds.height - icon.size.height) / 2,
                width: icon.size.width,
                height: icon.size.height
            ))
            x += icon.size.width + Self.elementGap
        }

        text.draw(at: NSPoint(x: x, y: (bounds.height - textSize.height) / 2), withAttributes: attributes)
        x += textSize.width

        // Draw the keyboard badge only when the chip has a shortcut hint.
        if !hotkeyBadge.isEmpty {
            let badgeAttributes: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: quiet]
            let badge = hotkeyBadge as NSString
            let badgeSize = badge.size(withAttributes: badgeAttributes)
            x += Self.elementGap
            badge.draw(at: NSPoint(x: x, y: (bounds.height - badgeSize.height) / 2), withAttributes: badgeAttributes)
            x += badgeSize.width
        }

        // Draw a disclosure indicator only for chips that actually expose additional choices.
        if showsChevron, let chevron = tintedSymbol("chevron.down", color: quiet, pointSize: 8.5) {
            x += Self.elementGap
            chevron.draw(in: NSRect(
                x: x,
                y: (bounds.height - chevron.size.height) / 2,
                width: chevron.size.width,
                height: chevron.size.height
            ))
        }
    }
}

// Word document formats supported by NSAttributedString.
private let wordProcessingExtensions: Set<String> = ["doc", "docx"]

// droppedFileSupportsTextExtraction(url): True when the launcher can pull
// readable text out of a dropped file.
func droppedFileSupportsTextExtraction(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    // Audio enters the asynchronous speech path rather than a document text decoder.
    if droppedFileSupportsAudioTranscription(url) { return true }
    // Accept known word-processing formats that need attributed-text extraction.
    if wordProcessingExtensions.contains(ext) {
        return true
    }

    // Reject file extensions that cannot be resolved to a supported content type.
    guard let type = UTType(filenameExtension: ext) else {
        return false
    }

    return type.conforms(to: .pdf)
        || type.conforms(to: .image)
        || type.conforms(to: .text)
        || type.conforms(to: .rtf)
        || type.conforms(to: .rtfd)
}

// Distinguish an unreadable dropped file from one that contains no usable text.
enum DroppedTextError: LocalizedError {
    // Represent a file whose contents could not be decoded.
    case unreadable(String)
    // Represent a readable file with no usable extracted text.
    case empty(String)

    var errorDescription: String? {
        // Choose a file-specific error message for failed or empty extraction.
        switch self {
        // Name the dropped file that could not be read.
        case .unreadable(let name):
            return "\(name) could not be read."
        // Name the file that produced no readable text.
        case .empty(let name):
            return "No readable text was found in \(name)."
        }
    }
}

// extractTextFromDroppedFile(url): Extract document text, using OCR for images
// and scanned PDFs.
func extractTextFromDroppedFile(_ url: URL) throws -> String {
    let ext = url.pathExtension.lowercased()
    let type = UTType(filenameExtension: ext)

    let text: String
    // Use PDF text extraction for documents identified as PDFs.
    if type?.conforms(to: .pdf) == true {
        text = try extractTextFromPDF(url)
    } else if type?.conforms(to: .image) == true {
        // Use local OCR for image files.
        text = try recognizeTextInImageFile(url)
    // Use attributed-text import for rich-text and supported word-processing documents.
    } else if type?.conforms(to: .rtf) == true
        || type?.conforms(to: .rtfd) == true
        || wordProcessingExtensions.contains(ext) {
        // Report documents that AppKit cannot import as attributed text.
        guard let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else {
            throw DroppedTextError.unreadable(url.lastPathComponent)
        }
        text = attributed.string
    } else {
        // Use plain-text decoding for the remaining supported text formats.
        text = try readPlainTextFile(url)
    }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Report an empty result after trimming incidental whitespace from extracted content.
    guard !trimmed.isEmpty else {
        throw DroppedTextError.empty(url.lastPathComponent)
    }

    return trimmed
}

// readPlainTextFile(url): Read a text file as UTF-8 first, then fall back to
// encoding detection.
func readPlainTextFile(_ url: URL) throws -> String {
    // Prefer explicit UTF-8 decoding for ordinary text files.
    if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
        return utf8
    }

    var encoding = String.Encoding.utf8
    // Report a read failure when automatic encoding detection also fails.
    guard let detected = try? String(contentsOf: url, usedEncoding: &encoding) else {
        throw DroppedTextError.unreadable(url.lastPathComponent)
    }

    return detected
}
