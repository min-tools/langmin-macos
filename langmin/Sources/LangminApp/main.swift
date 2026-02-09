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
