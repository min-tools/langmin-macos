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

// extractTextFromPDF(url): Read embedded PDF text or OCR scanned pages, with a
// page limit to bound processing time.
func extractTextFromPDF(_ url: URL) throws -> String {
    // Reject a PDF that PDFKit cannot open.
    guard let document = PDFDocument(url: url) else {
        throw DroppedTextError.unreadable(url.lastPathComponent)
    }

    // Use embedded PDF text before trying the more expensive OCR fallback.
    if let text = document.string,
       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return text
    }

    let pageLimit = min(document.pageCount, 25)
    var pages: [String] = []
    // OCR only the bounded number of PDF pages allowed by this import path.
    for index in 0..<pageLimit {
        // Skip a page that PDFKit cannot retrieve.
        guard let page = document.page(at: index) else {
            continue
        }

        let bounds = page.bounds(for: .mediaBox)
        let renderScale: CGFloat = 2
        let image = page.thumbnail(
            of: NSSize(width: bounds.width * renderScale, height: bounds.height * renderScale),
            for: .mediaBox
        )
        // Skip page previews that cannot be converted to image pixels for OCR.
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            continue
        }

        let pageText = (try? recognizeText(in: cgImage)) ?? ""
        // Append only pages that produced nonempty recognized text.
        if !pageText.isEmpty {
            pages.append(pageText)
        }
    }

    return pages.joined(separator: "\n\n")
}

// recognizeTextInImageFile(url): OCR one image file via Vision.
func recognizeTextInImageFile(_ url: URL) throws -> String {
    // Require a decodable image before starting file-based OCR.
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    // Report an unreadable image instead of submitting invalid pixels to recognition.
    else {
        throw DroppedTextError.unreadable(url.lastPathComponent)
    }

    return try recognizeText(in: cgImage)
}

// recognizeText(cgImage): Use Vision's accurate recognition and automatic
// language detection.
func recognizeText(in cgImage: CGImage) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try handler.perform([request])

    // Rebuild reading order: group fragments by baseline, sort rows top to bottom,
    // then sort each row left to right.
    struct Fragment {
        let text: String
        let box: CGRect
    }

    let fragments: [Fragment] = (request.results ?? []).compactMap { observation in
        // Ignore OCR observations that have no recognized text candidate.
        guard let candidate = observation.topCandidates(1).first else {
            return nil
        }
        return Fragment(text: candidate.string, box: observation.boundingBox)
    }

    // Normalized Vision coordinates put the origin bottom-left, so a larger
    // midY means higher on the page.
    let topToBottom = fragments.sorted { $0.box.midY > $1.box.midY }
    var rows: [[Fragment]] = []
    // Group recognized fragments into visual rows from top to bottom.
    for fragment in topToBottom {
        // Compare a fragment with the last row's anchor before starting a new row.
        if let row = rows.last, let anchor = row.first {
            let tolerance = max(anchor.box.height, fragment.box.height) * 0.6
            // Treat fragments with similar vertical centers as part of the same text row.
            if abs(anchor.box.midY - fragment.box.midY) < tolerance {
                rows[rows.count - 1].append(fragment)
                continue
            }
        }
        rows.append([fragment])
    }

    let lines = rows.map { row in
        row.sorted { $0.box.minX < $1.box.minX }
            .map(\.text)
            .joined(separator: "  ")
    }
    return lines.joined(separator: "\n")
}

// Accept typed text, documents, image OCR, and audio transcripts in one editable input view.
final class LauncherInputView: NSTextView {
    var placeholderString = "" { didSet { needsDisplay = true; onPresentationChange?() } }
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    // Let the welcome view follow edits and imports without owning the text view's delegate.
    var onPresentationChange: (() -> Void)?
    var usesCenteredPlaceholder = false
    private(set) var isReceivingFileDrop = false {
        didSet { /* Refresh the drop appearance only when the hover state actually changes. */ if oldValue != isReceivingFileDrop { onPresentationChange?() } }
    }
    private var fileDropRegistered = false
    private var isExtractingDroppedText = false { didSet { needsDisplay = true; onPresentationChange?() } }
    private var audioImport: AudioFileImportController?
    var isImportingFiles: Bool { isExtractingDroppedText }

    // Programmatic prefills and resets must hide or restore the invitation, just like typing.
    override var string: String { didSet { needsDisplay = true; onPresentationChange?() } }

    // becomeFirstResponder(): Notify the launcher when its input gains keyboard
    // focus.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // Report input focus only after AppKit accepts it.
        if accepted { onFocusChange?(true) }
        return accepted
    }

    // resignFirstResponder(): Notify the launcher when its input loses keyboard
    // focus.
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        // Report input blur only after AppKit accepts the focus change.
        if accepted { onFocusChange?(false) }
        return accepted
    }

    // keyDown(event): Keep text undo local and handle the launcher's submit
    // shortcut before ordinary typing.
    override func keyDown(with event: NSEvent) {
        // Keep undo and redo in the focused launcher input.
        if handleFocusedTextUndoRedoShortcut(event, in: self) {
            return
        }

        // Check submission modifiers only for Return.
        if event.keyCode == 36 {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Submit with Command-Return or Control-Return while preserving ordinary newlines.
            if modifiers.contains(.command) || modifiers.contains(.control) {
                onSubmit?()
                return
            }
        }
        super.keyDown(with: event)
    }

    // performKeyEquivalent(event): Give the focused input first refusal on undo
    // and redo menu shortcuts.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Consume local undo and redo before they reach other menu handlers.
        if handleFocusedTextUndoRedoShortcut(event, in: self) {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    // didChangeText(): Refresh the empty-state placeholder after each edit.
    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        onPresentationChange?()
    }

    // viewDidMoveToWindow(): Add file types without replacing NSTextView's
    // registrations for text drags.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Register file dragging once without dropping the text view's existing drag types.
        if !fileDropRegistered {
            registerForDraggedTypes(registeredDraggedTypes + [.fileURL])
            fileDropRegistered = true
        }
    }

    // extractableFileURLs(pasteboard): Read only file URLs whose formats
    // Langmin can turn into text.
    private func extractableFileURLs(in pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] ?? []
        return urls.filter(droppedFileSupportsTextExtraction)
    }

    // draggingEntered(sender): Advertise a copy drop for extractable files;
    // defer other drag types to AppKit.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isReceivingFileDrop = !extractableFileURLs(in: sender.draggingPasteboard).isEmpty
        return isReceivingFileDrop ? .copy : super.draggingEntered(sender)
    }

    // draggingUpdated(sender): Keep the drag cursor in sync with the
    // pasteboard's extractable content.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isReceivingFileDrop = !extractableFileURLs(in: sender.draggingPasteboard).isEmpty
        return isReceivingFileDrop ? .copy : super.draggingUpdated(sender)
    }

    // draggingExited(sender): Restore the idle invitation when files leave the
    // editor without being dropped.
    override func draggingExited(_ sender: NSDraggingInfo?) {
        isReceivingFileDrop = false
        super.draggingExited(sender)
    }

    // performDragOperation(sender): Insert document text or audio transcripts
    // at the drop location; preserve ordinary text dragging.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { isReceivingFileDrop = false }
        let urls = extractableFileURLs(in: sender.draggingPasteboard)
        // Use normal text-view dragging when no extractable file URLs were supplied.
        guard !urls.isEmpty else {
            return super.performDragOperation(sender)
        }

        let point = convert(sender.draggingLocation, from: nil)
        insertExtractedText(from: urls, at: characterIndexForInsertion(at: point))
        return true
    }

    // validateUserInterfaceItem(item): Enable Paste for supported documents,
    // images, and audio files.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        // Enable Paste when the pasteboard contains supported files or image content for extraction.
        if item.action == #selector(NSText.paste(_:)), pasteboardCarriesExtractableContent(.general) {
            return true
        }

        return super.validateUserInterfaceItem(item)
    }

    // pasteboardCarriesExtractableContent(pasteboard): Recognize file or image
    // content that needs extraction instead of plain-text paste.
    private func pasteboardCarriesExtractableContent(_ pasteboard: NSPasteboard) -> Bool {
        !extractableFileURLs(in: pasteboard).isEmpty
            || (pasteboard.string(forType: .string) == nil && pasteboardImage(pasteboard) != nil)
    }

    // paste(sender): Turn pasted documents, images, and recordings into text;
    // paste ordinary text directly.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general

        let urls = extractableFileURLs(in: pasteboard)
        if !urls.isEmpty {
            // Pasted file URLs may lack sandbox access. Check before extraction and suggest dragging the
            // file instead.
            let anyReadable = urls.contains { FileManager.default.isReadableFile(atPath: $0.path) }
            // Explain when pasted files contain no supported readable content.
            guard anyReadable else {
                let alert = NSAlert()
                alert.messageText = urls.count == 1
                    ? localized("pasted_file_denied", "Langmin can't access the pasted file")
                    : localized("pasted_files_denied", "Langmin can't access the pasted files")
                alert.informativeText = localized("pasted_files_denied_body", "macOS did not grant access to these files. Drag them into this window instead.")
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            insertExtractedText(from: urls, at: selectedRange().location)
            return
        }
        // Use OCR for a pasted image only when there is no plain-text pasteboard value.
        if pasteboard.string(forType: .string) == nil, let image = pasteboardImage(pasteboard) {
            insertRecognizedText(from: image, at: selectedRange().location)
            return
        }

        super.paste(sender)
    }

    // pasteboardImage(pasteboard): Decode pasteboard image data into pixels for
    // local text recognition.
    private func pasteboardImage(_ pasteboard: NSPasteboard) -> CGImage? {
        // Prefer directly supplied PNG or TIFF bytes when decoding a pasteboard image.
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: data),
           let cgImage = rep.cgImage {
            return cgImage
        }

        // Try NSImage for promised or less common pasteboard image formats.
        guard let image = NSImage(pasteboard: pasteboard) else {
            return nil
        }

        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // insertExtractedText(urls, index): Read dropped files with a progress
    // message and insert their combined text.
    private func insertExtractedText(from urls: [URL], at index: Int) {
        // Mixed batches keep their drop order while audio uses a cancellable progress sheet.
        if urls.contains(where: droppedFileSupportsAudioTranscription) {
            // Avoid overlapping imports and require a window to host the progress sheet.
            guard !isExtractingDroppedText, let window else { return }
            let preferences = loadAppPreferences()
            isExtractingDroppedText = true
            isEditable = false
            let controller = AudioFileImportController(
                parent: window, urls: urls,
                provider: .resolved(preferences.transcriptionProvider), language: preferences.transcriptionLanguage
            ) { [weak self] pieces, failures in
                // Ignore completion if the input view has already been released.
                guard let self else { return }
                self.isExtractingDroppedText = false
                self.isEditable = true
                self.audioImport = nil
                self.finishDropInsertion(pieces: pieces, failures: failures, at: index)
            }
            audioImport = controller
            controller.start()
            return
        }
        let progressText = urls.count == 1
            ? "Reading text from \(urls[0].lastPathComponent)..."
            : "Reading text from \(urls.count) files..."

        runTextExtraction(progressText: progressText, at: index) {
            var pieces: [String] = []
            var failures: [String] = []
            // Extract each dropped file independently so one failure does not discard readable siblings.
            for url in urls {
                // Extract each dropped file independently and collect any file-specific failure.
                do {
                    pieces.append(try extractTextFromDroppedFile(url))
                } catch {
                    // Collect per-file errors while continuing with the remaining dropped files.
                    failures.append(error.localizedDescription)
                }
            }
            return (pieces, failures)
        }
    }

    // insertRecognizedText(image, index): Run local OCR on a pasted image and
    // report recognition or empty-text errors.
    private func insertRecognizedText(from image: CGImage, at index: Int) {
        runTextExtraction(progressText: "Recognizing text in pasted image...", at: index) {
            // Attempt OCR for pasted image content before returning the combined extraction result.
            do {
                let text = try recognizeText(in: image)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Report an image whose OCR result contains only whitespace.
                guard !text.isEmpty else {
                    return ([], ["No readable text was found in the pasted image."])
                }
                return ([text], [])
            } catch {
                // Return recognition failure details through the shared extraction-result path.
                return ([], [error.localizedDescription])
            }
        }
    }

    // runTextExtraction(progressText, index, work): Run extraction off the main
    // thread and keep the field read-only until it finishes.
    private func runTextExtraction(
        progressText: String,
        at index: Int,
        work: @escaping () -> ([String], [String])
    ) {
        // Do not start a second extraction while one is already inserting dropped content.
        guard !isExtractingDroppedText else {
            return
        }

        isExtractingDroppedText = true
        isEditable = false
        let restoredPlaceholder = placeholderString
        placeholderString = progressText

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (pieces, failures) = work()

            DispatchQueue.main.async {
                // Ignore extraction completion after the input view is released.
                guard let self else {
                    return
                }

                self.isExtractingDroppedText = false
                self.isEditable = true
                self.placeholderString = restoredPlaceholder
                self.finishDropInsertion(pieces: pieces, failures: failures, at: index)
            }
        }
    }

    // finishDropInsertion(pieces, failures, index): Insert with undo support
    // and blank lines separating the extracted text from existing input.
    private func finishDropInsertion(pieces: [String], failures: [String], at index: Int) {
        // Insert successfully extracted pieces even when other files in the batch failed.
        if !pieces.isEmpty {
            let existing = string as NSString
            let insertion = min(index, existing.length)
            let newline = ("\n" as NSString).character(at: 0)
            var text = pieces.joined(separator: "\n\n")
            // Separate inserted text from preceding content when there is no existing newline boundary.
            if insertion > 0 && existing.character(at: insertion - 1) != newline {
                text = "\n\n" + text
            }
            // Separate inserted text from following content when there is no existing newline boundary.
            if insertion < existing.length && existing.character(at: insertion) != newline {
                text += "\n\n"
            }

            setSelectedRange(NSRange(location: insertion, length: 0))
            insertText(text, replacementRange: NSRange(location: insertion, length: 0))
            window?.makeFirstResponder(self)
        }

        // Show collected extraction errors after inserting any successful text.
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = failures.count == 1
                ? "Could not read a dropped file"
                : "Could not read some dropped files"
            alert.informativeText = failures.joined(separator: "\n")
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    // clearUndoably([actionName = "Clear Text"]): Clear the input through the
    // text system so the user can undo it.
    func clearUndoably(actionName: String = "Clear Text") {
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        // Do not create an undo operation for clearing an already empty input.
        guard fullRange.length > 0 else {
            return
        }

        // Respect text-system approval before recording and applying the clear operation.
        if shouldChangeText(in: fullRange, replacementString: "") {
            replaceCharacters(in: fullRange, with: "")
            didChangeText()
            setSelectedRange(NSRange(location: 0, length: 0))
            undoManager?.setActionName(actionName)
        }
    }

    // draw(dirtyRect): Draw a plain prompt during extraction or when no
    // centered invitation is installed.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Draw placeholder text only when the input is empty and a prompt was supplied.
        guard string.isEmpty, !placeholderString.isEmpty,
              !usesCenteredPlaceholder || isImportingFiles else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        let padding = textContainer?.lineFragmentPadding ?? 0
        placeholderString.draw(
            at: NSPoint(x: textContainerInset.width + padding, y: textContainerInset.height),
            withAttributes: attributes
        )
    }
}

// Rounded surface around the launcher input that shows an accent focus ring.
final class LauncherFieldContainer: NSView {
    var isFocused = false { didSet { needsDisplay = true } }
    var isDropTarget = false { didSet { needsDisplay = true } }

    // viewDidChangeEffectiveAppearance(): Refresh the pane fill and outline
    // when the window changes appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // draw(dirtyRect): Draw the launcher's rounded input surface and focus
    // outline.
    override func draw(_ dirtyRect: NSRect) {
        let isHighlighted = isFocused || isDropTarget
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Match the titlebar and menu dividers with a pixel-aligned hairline in light mode.
        let usesHairline = !isHighlighted && !isDark
        let neutralWidth: CGFloat = usesHairline ? 1 / (window?.backingScaleFactor ?? 2) : 1
        let inset: CGFloat = usesHairline ? 1 - neutralWidth / 2 : 1
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 12, yRadius: 12)
        // Give both light-mode panes a pale-gray well against the white window.
        let fill = isDark ? langminFieldFillColor : NSColor(calibratedWhite: 0.97, alpha: 1)
        fill.setFill()
        path.fill()

        // Highlight keyboard focus and accepted file drags with the same accent outline.
        if isHighlighted {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
        } else {
            // Use a neutral outline when input focus is elsewhere.
            langminControlBorderColor.setStroke()
            path.lineWidth = neutralWidth
        }
        path.stroke()
    }
}

// Draw launcher pickers as full fields.
final class LauncherPopUpButton: FocusablePopUpButton {
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 48) }

    // init(buttonFrame, flag): Disable AppKit's focus ring because this popup
    // draws its own focus state.
    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        focusRingType = .none
    }

    // init?(coder): Apply the same custom focus treatment to decoded popup
    // controls.
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        focusRingType = .none
    }

    // becomeFirstResponder(): Redraw the popup when it gains keyboard focus.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // Redraw the popup after it accepts keyboard focus.
        if accepted { needsDisplay = true }
        return accepted
    }

    // resignFirstResponder(): Redraw the popup after keyboard focus leaves.
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        // Redraw the popup after it accepts losing keyboard focus.
        if accepted { needsDisplay = true }
        return accepted
    }

    // mouseDown(event): Focus the popup before opening its menu so keyboard
    // navigation remains consistent.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        needsDisplay = true
        super.mouseDown(with: event)
    }

    // updateTrackingAreas(): Keep popup hover tracking aligned with its current
    // bounds.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Replace the popup's previous hover region after layout changes.
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

    // mouseEntered(event): Show the popup's hover state.
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    // mouseExited(event): Clear the popup's hover state.
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    // viewDidChangeEffectiveAppearance(): Refresh the popup's custom colors
    // after an appearance change.
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    // draw(dirtyRect): Draw the popup's background, label, and arrow with
    // matching focus and disabled states.
    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        let enabledAlpha: CGFloat = isEnabled ? 1 : 0.45
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)

        // Match the mode chips' neutral fill and brighten it for keyboard focus.
        NSColor.labelColor.withAlphaComponent((focused ? 0.11 : 0.045) * enabledAlpha).setFill()
        path.fill()

        let textColor = (isEnabled ? NSColor.labelColor : NSColor.secondaryLabelColor)
            .withAlphaComponent(enabledAlpha)
        let font = font ?? NSFont.systemFont(ofSize: 17)
        let title = titleOfSelectedItem ?? self.title
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let textRect = NSRect(
            x: 18,
            y: max(0, (bounds.height - textSize.height) / 2 - 1),
            width: max(0, bounds.width - 58),
            height: textSize.height + 3
        )
        (title as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)

        // Draw the popup arrow only when its system symbol is available.
        if let icon = tintedSymbol("chevron.down", color: textColor, pointSize: 12) {
            icon.draw(in: NSRect(
                x: bounds.width - icon.size.width - 18,
                y: (bounds.height - icon.size.height) / 2,
                width: icon.size.width,
                height: icon.size.height
            ))
        }
    }
}

// Draw a compact rounded tooltip with a small pointer toward its owner.
final class TooltipBubbleView: NSView {
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 6
    private static let arrowHeight: CGFloat = 7
    private static let arrowHalfWidth: CGFloat = 8
    private static let cornerRadius: CGFloat = 10
    private static let maxTextWidth: CGFloat = 380

    private let message: String
    private let darkAppearance: Bool
    // The arrow faces the owner: up for a bubble below it, down for one above.
    private let pointsUp: Bool
    private var arrowX: CGFloat

    // init(message, darkAppearance, [maxBubbleWidth = nil], [pointsUp =
    // false]): Size a tooltip to its message and remember which edge should
    // carry the arrow.
    init(message: String, darkAppearance: Bool, maxBubbleWidth: CGFloat? = nil, pointsUp: Bool = false) {
        self.message = message
        self.darkAppearance = darkAppearance
        self.pointsUp = pointsUp
        let size = Self.preferredSize(for: message, maxBubbleWidth: maxBubbleWidth)
        self.arrowX = size.width / 2
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
    }

    // init?(coder): Tooltips are created in code with their message and
    // placement settings.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // preferredSize(message, [maxBubbleWidth = nil]): Size short tooltips to
    // their text and wrap longer ones.
    static func preferredSize(for message: String, maxBubbleWidth: CGFloat? = nil) -> NSSize {
        let textWidthLimit = max(
            96,
            min(maxTextWidth, (maxBubbleWidth ?? .greatestFiniteMagnitude) - horizontalPadding * 2)
        )
        let rect = attributedMessage(message).boundingRect(
            with: NSSize(width: textWidthLimit, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let naturalWidth = ceil(rect.width) + horizontalPadding * 2
        let bubbleWidth = min(naturalWidth, maxBubbleWidth ?? naturalWidth)

        return NSSize(
            width: bubbleWidth,
            height: ceil(rect.height) + verticalPadding * 2 + arrowHeight
        )
    }

    // pointArrow(proposedX): Aim the tooltip at its owner without letting the
    // arrow overlap rounded corners.
    func pointArrow(at proposedX: CGFloat) {
        arrowX = Self.clampedArrowX(proposedX, bubbleWidth: bounds.width)
        needsDisplay = true
    }

    // clampedArrowX(proposedX, bubbleWidth): Clamp the arrow center to the
    // straight part of the bubble edge.
    private static func clampedArrowX(_ proposedX: CGFloat, bubbleWidth: CGFloat) -> CGFloat {
        let padding: CGFloat = 3
        let minimumX = cornerRadius + arrowHalfWidth + padding
        let maximumX = max(minimumX, bubbleWidth - cornerRadius - arrowHalfWidth - padding)
        return min(max(proposedX, minimumX), maximumX)
    }

    // attributedMessage(message, [color = .labelColor]): Use the same tooltip
    // font for measurement and drawing.
    private static func attributedMessage(_ message: String, color: NSColor = .labelColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping

        return NSAttributedString(
            string: message,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    // draw(dirtyRect): Paint an inverted-contrast bubble: light in dark mode,
    // dark in light mode.
    override func draw(_ dirtyRect: NSRect) {
        let arrowHeight = Self.arrowHeight
        let bubbleRect = NSRect(
            x: 0,
            y: pointsUp ? 0 : arrowHeight,
            width: bounds.width,
            height: bounds.height - arrowHeight
        )
        // The arrow tip sits on the edge facing the owner: the view's bottom when
        // the bubble is above it, its top when the bubble is below it.
        let apexY = pointsUp ? bounds.maxY - 0.5 : bounds.minY + 0.5
        let background = darkAppearance
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            : NSColor(calibratedWhite: 0.12, alpha: 0.96)
        let border = darkAppearance
            ? NSColor.black.withAlphaComponent(0.12)
            : NSColor.white.withAlphaComponent(0.16)
        let foreground = darkAppearance ? NSColor.black : NSColor.white
        let arrowX = Self.clampedArrowX(arrowX, bubbleWidth: bounds.width)
        let arrowHalfWidth = Self.arrowHalfWidth
        let radius = min(Self.cornerRadius, bubbleRect.width / 2, bubbleRect.height / 2)
        let path = CGMutablePath()

        // Trace the rounded body counterclockwise, notching the arrow into the
        // bottom edge (bubble above owner) or the top edge (bubble below owner).
        path.move(to: CGPoint(x: bubbleRect.minX + radius, y: bubbleRect.minY))
        // Draw the arrow on the lower edge when the bubble points downward.
        if !pointsUp {
            path.addLine(to: CGPoint(x: arrowX - arrowHalfWidth, y: bubbleRect.minY))
            path.addLine(to: CGPoint(x: arrowX, y: apexY))
            path.addLine(to: CGPoint(x: arrowX + arrowHalfWidth, y: bubbleRect.minY))
        }
        path.addLine(to: CGPoint(x: bubbleRect.maxX - radius, y: bubbleRect.minY))
        path.addArc(
            center: CGPoint(x: bubbleRect.maxX - radius, y: bubbleRect.minY + radius),
            radius: radius,
            startAngle: -.pi / 2,
            endAngle: 0,
            clockwise: false
        )
        path.addLine(to: CGPoint(x: bubbleRect.maxX, y: bubbleRect.maxY - radius))
        path.addArc(
            center: CGPoint(x: bubbleRect.maxX - radius, y: bubbleRect.maxY - radius),
            radius: radius,
            startAngle: 0,
            endAngle: .pi / 2,
            clockwise: false
        )
        // Draw the arrow on the upper edge when the bubble points upward.
        if pointsUp {
            path.addLine(to: CGPoint(x: arrowX + arrowHalfWidth, y: bubbleRect.maxY))
            path.addLine(to: CGPoint(x: arrowX, y: apexY))
            path.addLine(to: CGPoint(x: arrowX - arrowHalfWidth, y: bubbleRect.maxY))
        }
        path.addLine(to: CGPoint(x: bubbleRect.minX + radius, y: bubbleRect.maxY))
        path.addArc(
            center: CGPoint(x: bubbleRect.minX + radius, y: bubbleRect.maxY - radius),
            radius: radius,
            startAngle: .pi / 2,
            endAngle: .pi,
            clockwise: false
        )
        path.addLine(to: CGPoint(x: bubbleRect.minX, y: bubbleRect.minY + radius))
        path.addArc(
            center: CGPoint(x: bubbleRect.minX + radius, y: bubbleRect.minY + radius),
            radius: radius,
            startAngle: .pi,
            endAngle: .pi * 1.5,
            clockwise: false
        )
        path.closeSubpath()

        // Render the tooltip path only while a graphics context is available.
        if let context = NSGraphicsContext.current?.cgContext {
            context.addPath(path)
            context.setFillColor(background.cgColor)
            context.fillPath()

            context.addPath(path)
            context.setStrokeColor(border.cgColor)
            context.setLineWidth(1)
            context.strokePath()
        }

        let attributed = Self.attributedMessage(message, color: foreground)
        let textRect = bubbleRect.insetBy(
            dx: Self.horizontalPadding,
            dy: Self.verticalPadding
        )
        attributed.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

private let tooltipWindowInset: CGFloat = 18
private let tooltipOwnerGap: CGFloat = -6

// tooltipMaxBubbleWidth(hostWindow): Reserve margins within the host window
// while allowing a minimum readable tooltip width.
private func tooltipMaxBubbleWidth(in hostWindow: NSWindow) -> CGFloat {
    max(96, hostWindow.frame.width - tooltipWindowInset * 2)
}

// tooltipPlacement(owner, hostWindow, size, [anchorXOffset = 0], [yOffset =
// tooltipOwnerGap], [extraXShift = 0], [placeBelow = false], [containerFrame =
// nil], [windowEdgeInset = tooltipWindowInset]): Place the tooltip near its
// owner while keeping the bubble inside the host window.
private func tooltipPlacement(
    for owner: NSView,
    in hostWindow: NSWindow,
    size: NSSize,
    anchorXOffset: CGFloat = 0,
    yOffset: CGFloat = tooltipOwnerGap,
    extraXShift: CGFloat = 0,
    placeBelow: Bool = false,
    constrainingTo containerFrame: NSRect? = nil,
    // How close the bubble may sit to the window edge. Small for edge controls
    // (e.g. the titlebar bookmark) so the arrow can reach a control near the corner.
    windowEdgeInset: CGFloat = tooltipWindowInset
) -> (origin: NSPoint, arrowX: CGFloat) {
    let localRect = owner.convert(owner.bounds, to: nil)
    let screenRect = hostWindow.convertToScreen(localRect)
    let anchorX = screenRect.midX + anchorXOffset
    let windowFrame = containerFrame ?? hostWindow.frame
    let minimumX = windowFrame.minX + windowEdgeInset
    let maximumX = windowFrame.maxX - windowEdgeInset - size.width
    let minimumY = windowFrame.minY + windowEdgeInset
    let maximumY = windowFrame.maxY - windowEdgeInset - size.height

    var origin = NSPoint(
        x: anchorX - size.width / 2,
        // Above the owner (arrow down) by default; below it (arrow up) when asked —
        // titlebar controls sit too high for a bubble to fit above them.
        y: placeBelow ? (screenRect.minY - size.height - yOffset) : (screenRect.maxY + yOffset)
    )

    // Clamp the bubble horizontally when it fits inside the available window width.
    if maximumX >= minimumX {
        origin.x = min(max(origin.x, minimumX), maximumX)
    } else {
        // Center an oversized bubble when the window cannot contain its preferred width.
        origin.x = windowFrame.midX - size.width / 2
    }

    // Optional nudge that may extend past the window edge, but stays on screen.
    if extraXShift != 0 {
        origin.x += extraXShift
        // Apply a second horizontal constraint using the display's visible frame.
        if let screenFrame = hostWindow.screen?.visibleFrame {
            let screenMin = screenFrame.minX + tooltipWindowInset
            let screenMax = screenFrame.maxX - tooltipWindowInset - size.width
            // Clamp to the screen when the bubble fits between its reserved margins.
            if screenMax >= screenMin {
                origin.x = min(max(origin.x, screenMin), screenMax)
            }
        }
    }

    // Clamp vertically when the available frame can contain the bubble height.
    if maximumY >= minimumY {
        origin.y = min(max(origin.y, minimumY), maximumY)
    }

    return (origin, anchorX - origin.x)
}

// buttonTooltip(owner, hostWindow, message, container, [windowEdgeInset =
// tooltipWindowInset]): Fit result-button tooltips inside the inline pane or
// the standalone window's content area.
private func buttonTooltip(
    for owner: NSView, in hostWindow: NSWindow, message: String,
    container: NSView?, windowEdgeInset: CGFloat = tooltipWindowInset
) -> (bubble: TooltipBubbleView, origin: NSPoint) {
    let containerFrame = container.map { hostWindow.convertToScreen($0.convert($0.bounds, to: nil)) }
        ?? hostWindow.convertToScreen(hostWindow.contentLayoutRect)
    let inset = container == nil ? windowEdgeInset : tooltipWindowInset
    // Leave room for the pointer near side edges and keep the bubble clear of rounded corners.
    var availableFrame = containerFrame.insetBy(dx: min(inset, 4), dy: inset)
    // Restrict tooltip placement to the overlap between its host bounds and visible display.
    if let screenFrame = hostWindow.screen?.visibleFrame, availableFrame.intersects(screenFrame) {
        availableFrame = availableFrame.intersection(screenFrame)
    }
    let maxWidth = max(96, availableFrame.width)
    let size = TooltipBubbleView.preferredSize(for: message, maxBubbleWidth: maxWidth)
    let ownerFrame = hostWindow.convertToScreen(owner.convert(owner.bounds, to: nil))
    let gap: CGFloat = 4
    let above = availableFrame.maxY - ownerFrame.maxY - gap
    let below = ownerFrame.minY - availableFrame.minY - gap
    // Prefer above when it fits; otherwise choose the larger space and clamp to the container.
    let placeBelow = size.height > above && (size.height <= below || below > above)
    let bubble = TooltipBubbleView(
        message: message,
        darkAppearance: owner.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
        maxBubbleWidth: maxWidth,
        pointsUp: placeBelow
    )
    let placement = tooltipPlacement(
        for: owner, in: hostWindow, size: size, yOffset: gap,
        placeBelow: placeBelow, constrainingTo: availableFrame, windowEdgeInset: 0
    )
    bubble.pointArrow(at: placement.arrowX)
    return (bubble, placement.origin)
}

// Info label with a tooltip matched to the app's other controls.
final class TooltipInfoLabel: NSTextField {
    var tooltipMessage = ""
    var tooltipAnchorXOffset: CGFloat = -10
    var tooltipYOffset: CGFloat = tooltipOwnerGap
    var tooltipMaximumWidth: CGFloat?
    var tooltipExtraXShift: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    private var tooltipWindow: NSPanel?

    // init(): Create a noneditable information marker with custom tooltip
    // handling.
    init() {
        super.init(frame: .zero)
        stringValue = "ⓘ"
        isBezeled = false
        isBordered = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        alignment = .center
        textColor = .secondaryLabelColor
        font = NSFont.systemFont(ofSize: 12, weight: .medium)
    }

    // init?(coder): Information markers are configured in code rather than
    // decoded from a nib.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // updateTrackingAreas(): Keep information-marker hover tracking aligned
    // with its current bounds.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Replace the information marker's old tracking area after layout changes.
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // mouseEntered(event): Show the explanatory tooltip when the pointer enters
    // the information marker.
    override func mouseEntered(with event: NSEvent) {
        showTooltip()
    }

    // mouseExited(event): Dismiss the information tooltip when the pointer
    // leaves.
    override func mouseExited(with event: NSEvent) {
        hideTooltip()
    }

    // viewDidMoveToWindow(): Dismiss any tooltip when the information marker
    // leaves its window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Dismiss the tooltip when its marker leaves the window.
        if window == nil {
            hideTooltip()
        }
    }

    // showTooltip(): Position the bubble above the icon while keeping it inside
    // the owner window.
    private func showTooltip() {
        hideTooltip()

        // Show information only when the marker has a host window and nonempty help text.
        guard let hostWindow = window, !tooltipMessage.isEmpty else {
            return
        }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let maxBubbleWidth = tooltipMaximumWidth.map {
            min($0, tooltipMaxBubbleWidth(in: hostWindow))
        } ?? tooltipMaxBubbleWidth(in: hostWindow)
        let bubbleView = TooltipBubbleView(
            message: tooltipMessage,
            darkAppearance: isDark,
            maxBubbleWidth: maxBubbleWidth
        )
        let size = bubbleView.frame.size
        let placement = tooltipPlacement(
            for: self,
            in: hostWindow,
            size: size,
            anchorXOffset: tooltipAnchorXOffset,
            yOffset: tooltipYOffset,
            extraXShift: tooltipExtraXShift
        )
        bubbleView.pointArrow(at: placement.arrowX)

        let panel = NSPanel(
            contentRect: NSRect(origin: placement.origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.contentView = bubbleView
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.orderFront(nil)
        tooltipWindow = panel
    }

    // hideTooltip(): Remove the transient tooltip window when hover ends or the
    // owner closes.
    private func hideTooltip() {
        tooltipWindow?.orderOut(nil)
        tooltipWindow = nil
    }
}

// Toolbar buttons use the same custom tooltip bubble as info labels.
final class TooltipButton: NSButton {
    var drawsOutline = true
    var contentOffset = NSPoint.zero
    var tooltipMessage = "" {
        didSet {
            // Refresh an already visible tooltip when its content changes.
            if tooltipWindow != nil {
                showTooltip()
            }
        }
    }
    weak var tooltipContainerView: NSView?
    private var trackingArea: NSTrackingArea?
    private var tooltipWindow: NSPanel?
    private var isMouseInside = false

    override var isHighlighted: Bool {
        didSet {
            refreshBackground()
        }
    }

    override var isOpaque: Bool {
        false
    }

    // viewDidChangeEffectiveAppearance(): Redraw the outline and interaction
    // fill after an appearance change.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackground()
    }

    // Remove the button cell's alignment insets so Auto Layout sizes the actual
    // bounds and keeps the background square.
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets()
    }

    // updateTrackingAreas(): Update hover tracking for the tooltip button's
    // current bounds.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Replace the tooltip button's tracking area after its bounds change.
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // mouseEntered(event): Show the button's hover feedback and explanatory
    // tooltip together.
    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        refreshBackground()
        showTooltip()
    }

    // mouseExited(event): Clear hover feedback and dismiss the tooltip when the
    // pointer leaves.
    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        refreshBackground()
        hideTooltip()
    }

    // viewDidMoveToWindow(): Close any tooltip when the button is removed from
    // its window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Dismiss the button's tooltip when its view leaves the window.
        if window == nil {
            hideTooltip()
        }
    }

    fileprivate var interactionFillColor: NSColor? {
        // Use pressed feedback while AppKit marks the button highlighted.
        if isHighlighted {
            return NSColor.controlAccentColor.withAlphaComponent(0.12)
        }
        return isMouseInside ? NSColor.controlAccentColor.withAlphaComponent(0.06) : nil
    }

    // refreshBackground(): Invalidate the button and, for grouped buttons, the
    // shared background that draws its state.
    private func refreshBackground() {
        needsDisplay = true
        // Ask the group to redraw hover or pressed state when it owns the button's outline.
        if !drawsOutline { superview?.needsDisplay = true }
    }

    // draw(dirtyRect): Draw a standalone outline when needed, then render the
    // button's content.
    override func draw(_ dirtyRect: NSRect) {
        // Groups draw the shared background, including each button's hover and pressed fill.
        if drawsOutline {
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            (interactionFillColor ?? NSColor.windowBackgroundColor.withAlphaComponent(0.35)).setFill()
            path.fill()
            langminControlBorderColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        // Adjust the label or icon without moving its outline, hover fill or hit area.
        if contentOffset != .zero {
            NSGraphicsContext.saveGraphicsState()
            let offset = NSAffineTransform()
            offset.translateX(by: contentOffset.x, yBy: isFlipped ? -contentOffset.y : contentOffset.y)
            offset.concat()
            super.draw(dirtyRect)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // Let AppKit draw content types outside this button's custom symbol treatment.
            super.draw(dirtyRect)
        }
    }

    // showTooltip(): Keep the bubble within its result pane or standalone
    // window.
    private func showTooltip() {
        hideTooltip()

        // Require a host window and explanatory text before showing a button tooltip.
        guard let hostWindow = window, !tooltipMessage.isEmpty else {
            return
        }

        let tooltip = buttonTooltip(
            for: self, in: hostWindow, message: tooltipMessage, container: tooltipContainerView
        )
        let bubbleView = tooltip.bubble
        let size = bubbleView.frame.size

        let panel = NSPanel(
            contentRect: NSRect(origin: tooltip.origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.contentView = bubbleView
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.orderFront(nil)
        tooltipWindow = panel
    }

    // hideTooltip(): Remove the transient tooltip window when hover ends or the
    // owner closes.
    private func hideTooltip() {
        tooltipWindow?.orderOut(nil)
        tooltipWindow = nil
    }
}

// Unbordered title-bar actions use the shared tooltip placement.
final class TitlebarTooltipButton: NSButton {
    var tooltipMessage = "" {
        didSet {
            // Refresh a visible tooltip when the action label changes.
            if tooltipWindow != nil {
                showTooltip()
            }
        }
    }
    weak var tooltipContainerView: NSView?
    private var trackingArea: NSTrackingArea?
    private var tooltipWindow: NSPanel?

    override var isHidden: Bool {
        didSet {
            // Hide a tooltip when its owning view becomes hidden.
            if isHidden { hideTooltip() }
        }
    }

    // updateTrackingAreas(): Keep text-tooltip hover tracking aligned with the
    // view's current bounds.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Replace the text-tooltip owner's old tracking region.
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // mouseEntered(event): Show the text tooltip when the pointer enters its
    // owner.
    override func mouseEntered(with event: NSEvent) {
        showTooltip()
    }

    // mouseExited(event): Dismiss the text tooltip when the pointer leaves its
    // owner.
    override func mouseExited(with event: NSEvent) {
        hideTooltip()
    }

    // viewDidMoveToWindow(): Dismiss the text tooltip if its owner no longer
    // belongs to a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Dismiss the text tooltip when its owner leaves the window.
        if window == nil {
            hideTooltip()
        }
    }

    // showTooltip(): Use the shared fit decision; a titlebar naturally leaves
    // room only below.
    private func showTooltip() {
        hideTooltip()

        // Require a host window and nonempty content before presenting the text tooltip.
        guard let hostWindow = window, !tooltipMessage.isEmpty else {
            return
        }

        let tooltip = buttonTooltip(
            for: self, in: hostWindow, message: tooltipMessage, container: tooltipContainerView,
            windowEdgeInset: 0
        )
        let bubbleView = tooltip.bubble
        let size = bubbleView.frame.size

        let panel = NSPanel(
            contentRect: NSRect(origin: tooltip.origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.contentView = bubbleView
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.orderFront(nil)
        tooltipWindow = panel
    }

    // hideTooltip(): Hide and release the tooltip window without affecting its
    // owner.
    private func hideTooltip() {
        tooltipWindow?.orderOut(nil)
        tooltipWindow = nil
    }
}

// Built-in text models for the model pickers.
let explanationModelOptions: [PreferenceOption] = [
    PreferenceOption(id: "gpt-6-astra", title: "GPT-6 Astra", note: "web research"),
    PreferenceOption(id: "gpt-5.6-sol", title: "GPT-5.6 Sol", note: "web research"),
    PreferenceOption(id: "gpt-5.6-terra", title: "GPT-5.6 Terra", note: "web research"),
    PreferenceOption(id: "gpt-5.6-luna", title: "GPT-5.6 Luna", note: "web research"),
    PreferenceOption(id: "gpt-5.5", title: "GPT-5.5", note: "web research"),
    PreferenceOption(id: "gpt-5.4", title: "GPT-5.4", note: "web research"),
    PreferenceOption(id: "gpt-5.4-mini", title: "GPT-5.4 Mini", note: "web research"),
    PreferenceOption(id: "gpt-5.4-nano", title: "GPT-5.4 Nano", note: "web research"),
    PreferenceOption(id: "gpt-4.1", title: "GPT-4.1", note: "web research"),
    PreferenceOption(id: "gpt-4.1-mini", title: "GPT-4.1 Mini", note: "web research"),
    PreferenceOption(id: "anthropic:claude-fable-5-1", title: "Claude Fable 5.1", note: "web research"),
    PreferenceOption(id: "anthropic:claude-fable-5", title: "Claude Fable 5", note: "web research"),
    PreferenceOption(id: "anthropic:claude-sonnet-5", title: "Claude Sonnet 5", note: "web research"),
    PreferenceOption(id: "anthropic:claude-sonnet-4-5", title: "Claude Sonnet 4.5", note: "web research"),
    PreferenceOption(id: "anthropic:claude-haiku-4-5", title: "Claude Haiku", note: "web research"),
    PreferenceOption(id: "anthropic:claude-opus-4-1", title: "Claude Opus 4.1", note: "web research"),
    PreferenceOption(id: "gemini:gemini-2.5-pro", title: "Gemini 2.5 Pro", note: "web research"),
    PreferenceOption(id: "gemini:gemini-2.5-flash", title: "Gemini 2.5 Flash", note: "web research"),
    PreferenceOption(id: "gemini:gemini-2.5-flash-lite", title: "Gemini Flash Lite", note: "web research"),
    PreferenceOption(id: "grok:grok-4", title: "Grok 4", note: "xAI"),
    PreferenceOption(id: "grok:grok-3-mini", title: "Grok 3 Mini", note: "xAI"),
    PreferenceOption(id: "deepseek:deepseek-chat", title: "DeepSeek Chat", note: "chat"),
    PreferenceOption(id: "deepseek:deepseek-reasoner", title: "DeepSeek Reasoner", note: "reasoning"),
    PreferenceOption(id: appleIntelligenceModelID, title: "Apple Intelligence", note: "on this Mac"),
    PreferenceOption(id: customModelID, title: "Custom Endpoint", note: "OpenAI-compatible endpoint")
]

// Default to one balanced model per provider. Enable Custom Endpoint only after a model name is set.
let defaultPreferredTextModelIDs = [
    "gpt-5.6-terra",
    "anthropic:claude-sonnet-5",
    "gemini:gemini-2.5-flash",
    "grok:grok-4",
    "deepseek:deepseek-chat",
    appleIntelligenceModelID
]

// appleIntelligenceIsAvailable():
// Check local-model availability for the picker and setup. Recheck when starting a request.
func appleIntelligenceIsAvailable() -> Bool {
    // The on-device model API is available only on supported macOS versions.
    guard #available(macOS 26.0, *) else { return false }
    // Report availability only when Apple's model is ready to answer.
    if case .available = SystemLanguageModel.default.availability {
        return true
    }
    return false
}

// explanationModelOptionsDisplaying(customName): Apply the custom model name
// and show Apple Intelligence availability.
func explanationModelOptionsDisplaying(customName: String) -> [PreferenceOption] {
    let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
    let appleAvailable = appleIntelligenceIsAvailable()
    return explanationModelOptions.map { option in
        // Use the configured display name for the custom model choice.
        if option.id == customModelID, !name.isEmpty {
            return PreferenceOption(id: option.id, title: name, note: option.note)
        }
        // Explain local unavailability beside the Apple model option.
        if option.id == appleIntelligenceModelID, !appleAvailable {
            return PreferenceOption(id: option.id, title: option.title, note: "not available on this Mac")
        }
        return option
    }
}

// Mark user-added models with an asterisk.
let extraModelMarker = " *"

// displayedExplanationModelOptions(customName, extraModels): Insert user-added
// models after their provider's built-in models and mark them with an asterisk.
func displayedExplanationModelOptions(customName: String, extraModels: [String]) -> [PreferenceOption] {
    var options = explanationModelOptionsDisplaying(customName: customName)
    // Insert each valid configured extra model into the provider-ordered menu.
    for line in extraModels {
        // Ignore blank or unparseable extra-model entries.
        guard let parsed = parseExtraModel(line) else {
            continue
        }
        let option = PreferenceOption(
            id: parsed.id,
            title: parsed.label + extraModelMarker,
            note: "added in Advanced"
        )
        let provider = textProvider(for: parsed.id).provider
        // Insert added models after the existing choices from the same provider.
        if let lastMatch = options.lastIndex(where: {
            $0.id != customModelID && textProvider(for: $0.id).provider == provider
        }) {
            options.insert(option, at: lastMatch + 1)
        } else if let customIndex = options.firstIndex(where: { $0.id == customModelID }) {
            // Otherwise place added models before the custom endpoint choice when it exists.
            options.insert(option, at: customIndex)
        } else {
            // Append the model when there is no provider group or custom choice to anchor it.
            options.append(option)
        }
    }
    return options
}

// displayedExplanationModelOptions([customName = nil]): Build model display
// options from the currently saved custom name and extra models.
func displayedExplanationModelOptions(customName: String? = nil) -> [PreferenceOption] {
    let preferences = loadAppPreferences()
    return displayedExplanationModelOptions(
        customName: customName ?? preferences.customDisplayName,
        extraModels: preferences.extraModels
    )
}

// enabledExplanationModelOptions([preferences = nil]): Keep enabled models in
// catalog order. Hide an unconfigured Custom Endpoint and repair an empty or
// stale list.
func enabledExplanationModelOptions(_ preferences: AppPreferences? = nil) -> [PreferenceOption] {
    let preferences = preferences ?? loadAppPreferences()
    let allOptions = displayedExplanationModelOptions(
        customName: preferences.customDisplayName,
        extraModels: preferences.extraModels
    )
    let selected = Set(preferences.preferredTextModels)
    let hasCustomModel = !preferences.customModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let enabled = allOptions.filter {
        selected.contains($0.id) && ($0.id != customModelID || hasCustomModel)
    }
    // Use the enabled shortlist when it contains valid models.
    if !enabled.isEmpty {
        return enabled
    }

    let defaults = Set(defaultPreferredTextModelIDs)
    return allOptions.filter { defaults.contains($0.id) }
}

// defaultEnabledExplanationModel(preferences): Keep the preferred model when
// enabled; otherwise choose from the enabled models.
func defaultEnabledExplanationModel(_ preferences: AppPreferences) -> String {
    let enabledIDs = enabledExplanationModelOptions(preferences).map(\.id)
    // Keep the saved preferred model when it is still enabled.
    if enabledIDs.contains(preferences.explanationModel) {
        return preferences.explanationModel
    }
    // Prefer the built-in default when it appears in the enabled set.
    if enabledIDs.contains(defaultExplanationModel) {
        return defaultExplanationModel
    }
    return enabledIDs.first ?? defaultExplanationModel
}

// Built-in OpenAI speech models.
let ttsModelOptions: [PreferenceOption] = [
    PreferenceOption(id: "gpt-4o-mini-tts", title: "GPT-4o Mini TTS", note: "voice instructions"),
    PreferenceOption(id: "tts-1", title: "TTS-1", note: "lower latency"),
    PreferenceOption(id: "tts-1-hd", title: "TTS-1 HD", note: "legacy HD voice")
]

// Built-in OpenAI voices and display names.
let voiceOptions: [PreferenceOption] = [
    PreferenceOption(id: "marin", title: "Marin", note: "Warm and conversational"),
    PreferenceOption(id: "cedar", title: "Cedar", note: "Calm and clear"),
    PreferenceOption(id: "coral", title: "Coral", note: "Warm and friendly"),
    PreferenceOption(id: "alloy", title: "Alloy", note: "Neutral"),
    PreferenceOption(id: "ash", title: "Ash", note: "Clear and steady"),
    PreferenceOption(id: "ballad", title: "Ballad", note: "Smooth and expressive"),
    PreferenceOption(id: "echo", title: "Echo", note: "Deep and resonant"),
    PreferenceOption(id: "fable", title: "Fable", note: "Expressive storytelling"),
    PreferenceOption(id: "nova", title: "Nova", note: "Bright and energetic"),
    PreferenceOption(id: "onyx", title: "Onyx", note: "Deep and serious"),
    PreferenceOption(id: "sage", title: "Sage", note: "Calm and measured"),
    PreferenceOption(id: "shimmer", title: "Shimmer", note: "Soft and upbeat"),
    PreferenceOption(id: "verse", title: "Verse", note: "Expressive")
]

// openAIVoiceOptions(): Use fetched OpenAI voices when available, with built-in
// voices as a fallback. Keep known descriptions.
func openAIVoiceOptions() -> [PreferenceOption] {
    let names = cachedOpenAIVoiceNames()
    // Use the built-in OpenAI voice options when no cached catalog names are available.
    guard !names.isEmpty else {
        return voiceOptions
    }
    return names.map { name in
        let id = name.lowercased()
        // Retain known voice labels and notes when matching them against the refreshed catalog.
        if let known = voiceOptions.first(where: { $0.id == id }) {
            return known
        }
        return PreferenceOption(id: id, title: name.capitalized, note: "")
    }
}

// Built-in fallback xAI Grok voices used until the live catalog is fetched.
let grokVoiceOptions: [PreferenceOption] = [
    PreferenceOption(id: "grok:iris", title: "Iris", note: "Multilingual"),
    PreferenceOption(id: "grok:altair", title: "Altair", note: "Multilingual"),
    PreferenceOption(id: "grok:eve", title: "Eve", note: "Multilingual"),
    PreferenceOption(id: "grok:ara", title: "Ara", note: "Multilingual"),
    PreferenceOption(id: "grok:leo", title: "Leo", note: "Multilingual"),
    PreferenceOption(id: "grok:rex", title: "Rex", note: "Multilingual"),
    PreferenceOption(id: "grok:sal", title: "Sal", note: "Multilingual")
]

// Exclude language headings from pronunciation targets. Initialize lazily because
// the language catalog is declared later in this file.
enum LanguageHeadingNames {
    static let all: Set<String> = {
        var names = Set<String>()
        let english = Locale(identifier: "en")
        // Build the language-name set from system-recognized language codes.
        for code in Locale.LanguageCode.isoLanguageCodes {
            // Include only language codes with an English display name.
            if let name = english.localizedString(forLanguageCode: code.identifier) {
                names.insert(name.lowercased())
            }
        }
        // Include app-specific language option names in the same recognition set.
        for option in languageOptions {
            names.insert(option.title.lowercased())
        }
        return names
    }()
}

let readerNoneOption = PreferenceOption(id: "none", title: "None", note: "")

// Group voices by provider and indent language groups beneath them.
struct ReaderVoiceSection {
    let header: String
    let options: [PreferenceOption]
    var indentLevel: Int = 0
}

// readerLanguageName(code): Friendly language name for a voice's code (handles
// region suffixes like zh-CN).
func readerLanguageName(_ code: String) -> String {
    // Use the catalog's multilingual label instead of treating it as a locale code.
    if code == "multilingual" {
        return "Multilingual"
    }
    let base = code.split(separator: "-").first.map(String.init) ?? code
    let name = languageName(for: base)
    return name.isEmpty ? code : name
}

// grokVoiceNote(voice): Describe a Grok voice's language and other catalog
// details for voice menus.
func grokVoiceNote(_ voice: GrokVoice) -> String {
    // Describe multilingual Grok voices without attaching a single-language label.
    if voice.language == "multilingual" {
        return "Multilingual"
    }
    var parts: [String] = []
    // Include a supplied nonempty gender description in the voice note.
    if let gender = voice.gender, !gender.isEmpty {
        parts.append(gender.capitalized)
    }
    // Include a supplied nonempty age description in the voice note.
    if let age = voice.age, !age.isEmpty {
        parts.append(age)
    }
    parts.append(readerLanguageName(voice.language))
    return parts.joined(separator: " · ")
}

// grokVoicePreferenceOption(voice): Use a provider-prefixed ID so Grok voices
// cannot collide with other catalogs.
func grokVoicePreferenceOption(_ voice: GrokVoice) -> PreferenceOption {
    PreferenceOption(id: "grok:\(voice.id)", title: voice.name, note: grokVoiceNote(voice))
}

// isAppleNoveltyVoice(voice): Identify novelty voices using Apple's voice
// traits rather than guessing from their names.
func isAppleNoveltyVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
    voice.voiceTraits.contains(.isNoveltyVoice)
}

// Cache installed Apple voices; enumerating the system catalog is expensive.
// Exclude novelty voices and refresh the cache when Settings opens.
private let appleVoiceCacheLock = NSLock()
private var cachedAppleVoicesStorage: [AVSpeechSynthesisVoice]?

// appleVoices(): Return a synchronized cache of installed voices to avoid
// repeatedly enumerating the system catalog.
func appleVoices() -> [AVSpeechSynthesisVoice] {
    appleVoiceCacheLock.lock()
    // Release the voice-cache lock even when returning an already cached catalog.
    defer { appleVoiceCacheLock.unlock() }
    // Return the cached installed Apple voices instead of re-enumerating the system catalog.
    if let cached = cachedAppleVoicesStorage {
        return cached
    }
    let voices = AVSpeechSynthesisVoice.speechVoices().filter { !isAppleNoveltyVoice($0) }
    cachedAppleVoicesStorage = voices
    return voices
}

// invalidateAppleVoiceCache(): Reload the voice catalog on the next access so
// newly installed voices appear in Settings.
func invalidateAppleVoiceCache() {
    appleVoiceCacheLock.lock()
    cachedAppleVoicesStorage = nil
    appleVoiceCacheLock.unlock()
}

// appleVoiceNote(voice): Add quality and region labels to distinguish voices
// that share a name.
func appleVoiceNote(_ voice: AVSpeechSynthesisVoice) -> String {
    var parts: [String] = []
    // Describe improved Apple voice quality when the catalog provides it.
    switch voice.quality {
    // Mark enhanced-quality voices in their menu note.
    case .enhanced:
        parts.append("Enhanced")
    // Mark premium-quality voices in their menu note.
    case .premium:
        parts.append("Premium")
    // Leave default-quality voices without an extra quality label.
    default:
        break
    }
    let language = readerLanguageName(voice.language)
    let localeComponents = voice.language.split(separator: "-")
    // Include a locale region when the voice identifier supplies one.
    if localeComponents.count > 1, let region = localeComponents.last {
        parts.append("\(language) (\(region))")
    } else {
        // Use the language label alone when no region is present.
        parts.append(language)
    }
    return parts.joined(separator: " · ")
}

// appleVoicePreferenceOption(voice): Pair an Apple voice's stable identifier
// with its display name and descriptive note.
func appleVoicePreferenceOption(_ voice: AVSpeechSynthesisVoice) -> PreferenceOption {
    PreferenceOption(id: "apple:\(voice.identifier)", title: voice.name, note: appleVoiceNote(voice))
}

// appleVoiceSections(): Group installed Apple voices by language under one
// provider header.
func appleVoiceSections() -> [ReaderVoiceSection] {
    let voices = appleVoices()
    // Omit Apple provider sections when no installed voices exist.
    guard !voices.isEmpty else {
        return []
    }

    var sections: [ReaderVoiceSection] = [
        ReaderVoiceSection(header: "Apple", options: [])
    ]
    let grouped = Dictionary(grouping: voices) { readerLanguageName($0.language) }
    // Build Apple language sections in a consistent sorted order.
    for language in grouped.keys.sorted() {
        let options = grouped[language]!
            .sorted { $0.name < $1.name }
            .map(appleVoicePreferenceOption)
        sections.append(ReaderVoiceSection(header: language, options: options, indentLevel: 1))
    }
    return sections
}

// grokVoiceSections(): Group Grok voices by the catalog's language metadata.
func grokVoiceSections() -> [ReaderVoiceSection] {
    let voices = cachedGrokVoices()
    // Provide the catalog's fallback group when no cached Grok voices are available.
    guard !voices.isEmpty else {
        return [
            ReaderVoiceSection(header: "Grok", options: []),
            ReaderVoiceSection(header: "Multilingual", options: grokVoiceOptions, indentLevel: 1)
        ]
    }

    // Nest language groups under one Grok header.
    var sections = [ReaderVoiceSection(header: "Grok", options: [])]
    let multilingual = voices.filter { $0.language == "multilingual" }
    // Keep multilingual voices in their own group before language-specific choices.
    if !multilingual.isEmpty {
        sections.append(ReaderVoiceSection(
            header: "Multilingual",
            options: multilingual.map(grokVoicePreferenceOption),
            indentLevel: 1
        ))
    }
    let grouped = Dictionary(grouping: voices.filter { $0.language != "multilingual" }) {
        readerLanguageName($0.language)
    }
    // Build language-specific Grok groups in a consistent order.
    for language in grouped.keys.sorted() {
        let options = grouped[language]!
            .sorted { $0.name < $1.name }
            .map(grokVoicePreferenceOption)
        sections.append(ReaderVoiceSection(header: language, options: options, indentLevel: 1))
    }
    return sections
}

// readerVoiceSections(): Show None first, followed by Grok, OpenAI and
// installed Apple voices.
func readerVoiceSections() -> [ReaderVoiceSection] {
    var sections = [ReaderVoiceSection(header: "", options: [readerNoneOption])]
    // Group cloud voices by provider before listing installed Apple voices.
    sections.append(contentsOf: grokVoiceSections())
    sections.append(ReaderVoiceSection(header: "OpenAI", options: []))
    sections.append(ReaderVoiceSection(
        header: "Multilingual",
        options: openAIVoiceOptions(),
        indentLevel: 1
    ))
    sections.append(contentsOf: appleVoiceSections())
    return sections
}

// currentReaderOptions(): Flat reader options (None + every voice) for
// selection/ID mapping.
func currentReaderOptions() -> [PreferenceOption] {
    readerVoiceSections().flatMap { $0.options }
}

// readerSectionHeaderItem(title): A native section-header menu item.
func readerSectionHeaderItem(_ title: String) -> NSMenuItem {
    NSMenuItem.sectionHeader(title: title)
}

// makeReaderMenu([style = nil]): Build the Reader popup menu with a provider
// header above each voice group. `style` applies per-item attributed styling
// (Settings) or nothing (launcher).
func makeReaderMenu(style: ((NSMenuItem) -> Void)? = nil) -> NSMenu {
    let menu = NSMenu()
    // Build provider and language sections in catalog order.
    for section in readerVoiceSections() {
        // Add a section header only when it has display text.
        if !section.header.isEmpty {
            let headerItem = readerSectionHeaderItem(section.header)
            headerItem.indentationLevel = section.indentLevel
            menu.addItem(headerItem)
        }
        // Add each section's voice choices beneath its header.
        for option in section.options {
            let item = NSMenuItem(title: option.descriptiveDisplayValue, action: nil, keyEquivalent: "")
            item.indentationLevel = section.indentLevel
            style?(item)
            menu.addItem(item)
        }
    }
    return menu
}

// makeReaderChoiceMenu([allowed = []]): Build a voice menu using IDs, since
// display names can repeat. Indent voices beneath provider/language headers
// without attributedTitle, which suppresses indentation. An empty allowed set
// shows all voices. Always include None and omit empty groups.
func makeReaderChoiceMenu(allowed: Set<String> = []) -> NSMenu {
    // voiceItem(option, indentLevel): Build an indented voice menu item
    // carrying the stable selection ID.
    func voiceItem(_ option: PreferenceOption, indentLevel: Int) -> NSMenuItem {
        let item = NSMenuItem(title: option.descriptiveDisplayValue, action: nil, keyEquivalent: "")
        item.representedObject = option.id
        item.indentationLevel = indentLevel
        return item
    }

    let menu = NSMenu()
    menu.addItem(voiceItem(readerNoneOption, indentLevel: 0))

    // Filter each section's own options to the shortlist (None handled above).
    let sections = readerVoiceSections().map { section -> (section: ReaderVoiceSection, options: [PreferenceOption]) in
        var options = section.options.filter { $0.id != readerNoneOption.id }
        // Filter voices only when the user configured a nonempty shortlist.
        if !allowed.isEmpty {
            options = options.filter { allowed.contains($0.id) }
        }
        return (section, options)
    }

    var index = 0
    // Build one top-level provider group and its remaining language sections at a time.
    while index < sections.count {
        let top = sections[index]
        var childEndIndex = index + 1
        var nonEmptyChildren: [(header: String, indentLevel: Int, options: [PreferenceOption])] = []
        // Collect child sections until the next provider-level header.
        while childEndIndex < sections.count, sections[childEndIndex].section.indentLevel > 0 {
            let child = sections[childEndIndex]
            // Keep only language sections that still contain allowed voices.
            if !child.options.isEmpty {
                nonEmptyChildren.append((child.section.header, child.section.indentLevel, child.options))
            }
            childEndIndex += 1
        }

        // Show a provider header only when its own or descendant voices remain visible.
        if !top.section.header.isEmpty, !top.options.isEmpty || !nonEmptyChildren.isEmpty {
            let headerItem = readerSectionHeaderItem(top.section.header)
            headerItem.indentationLevel = top.section.indentLevel
            menu.addItem(headerItem)
        }
        // Add voices listed directly under the provider header.
        for option in top.options {
            menu.addItem(voiceItem(option, indentLevel: top.section.indentLevel + 1))
        }
        // Add the nonempty language subsections beneath their provider.
        for child in nonEmptyChildren {
            let headerItem = readerSectionHeaderItem(child.header)
            headerItem.indentationLevel = child.indentLevel
            menu.addItem(headerItem)
            // Add each allowed voice beneath its language header.
            for option in child.options {
                menu.addItem(voiceItem(option, indentLevel: child.indentLevel + 1))
            }
        }
        index = childEndIndex
    }
    return menu
}
