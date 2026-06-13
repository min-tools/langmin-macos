// LangminStorage.swift
// Storage, provider, and safety helpers for the app.

import Foundation

// MARK: - Provider endpoints and pinned API versions
//
// Keep default endpoints and versioned tool identifiers here. Advanced settings can override them.
let openAIResponsesEndpoint = URL(string: "https://api.openai.com/v1/responses")!
let openAISpeechEndpoint = URL(string: "https://api.openai.com/v1/audio/speech")!
let anthropicMessagesEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
let geminiAPIBaseURL = "https://generativelanguage.googleapis.com/v1beta/models"
// Grok uses chat completions for text and /tts for speech.
let grokAPIBaseURL = "https://api.x.ai/v1"
// DeepSeek's API speaks the OpenAI chat-completions protocol for text.
let deepSeekAPIBaseURL = "https://api.deepseek.com/v1"

// isGrokVoice(id): Route grok: voice IDs to xAI speech.
func isGrokVoice(_ id: String) -> Bool {
    id.hasPrefix("grok:")
}

// grokVoiceID(id): Remove the internal Grok prefix before passing a voice ID to
// the provider.
func grokVoiceID(from id: String) -> String {
    isGrokVoice(id) ? String(id.dropFirst("grok:".count)) : id
}

// isAppleVoice(id): Route apple: voice IDs to on-device speech.
func isAppleVoice(_ id: String) -> Bool {
    id.hasPrefix("apple:")
}

// appleVoiceIdentifier(id): Remove the internal Apple prefix before looking up
// the system voice.
func appleVoiceIdentifier(from id: String) -> String {
    isAppleVoice(id) ? String(id.dropFirst("apple:".count)) : id
}

// Resolve a voice's provider, including legacy Apple identifiers without a prefix.
enum NarrationProvider {
    // Use the installed system voice catalog and on-device speech synthesis.
    case apple
    // Use OpenAI's speech endpoint.
    case openAI
    // Use xAI's speech endpoint and Grok voice catalog.
    case grok
}

// narrationProvider(voice): Resolve the narration provider from the stored
// voice-ID convention.
func narrationProvider(for voice: String) -> NarrationProvider {
    // A Grok-prefixed voice selects the xAI narration provider.
    if isGrokVoice(voice) {
        return .grok
    }
    // An Apple-prefixed voice selects on-device narration.
    if isAppleVoice(voice) {
        return .apple
    }
    return .openAI
}

// One xAI voice from GET /v1/tts/voices.
struct GrokVoice {
    let id: String
    let name: String
    let language: String
    let gender: String?
    let age: String?
}

// Cache the voice catalog as JSON. Use built-in voices until a catalog is available.
let grokVoicesCacheKey = "grokVoicesCache"

// parseGrokVoices(data): Decode valid Grok catalog entries and ignore malformed
// or incomplete records.
func parseGrokVoices(_ data: Data) -> [GrokVoice] {
    // Require a JSON object containing a voice array before reading Grok catalog entries.
    guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let voices = object["voices"] as? [[String: Any]]
    // Treat an invalid catalog payload as an empty catalog.
    else {
        return []
    }
    return voices.compactMap { entry in
        // Keep only catalog entries with usable voice identifiers and names.
        guard
            let id = entry["voice_id"] as? String, !id.isEmpty,
            let name = entry["name"] as? String, !name.isEmpty
        // Discard an incomplete catalog entry rather than creating an unusable menu choice.
        else {
            return nil
        }
        return GrokVoice(
            id: id,
            name: name,
            language: (entry["language"] as? String) ?? "multilingual",
            gender: entry["gender"] as? String,
            age: entry["age"] as? String
        )
    }
}

// cachedGrokVoices(): Read the cached Grok catalog without requesting a network
// refresh.
func cachedGrokVoices() -> [GrokVoice] {
    // Read cached Grok JSON only when the preference exists and decodes as UTF-8.
    guard
        let json = langminPreferencesStore().string(forKey: grokVoicesCacheKey),
        let data = json.data(using: .utf8)
    // An absent or undecodable cache supplies no voice entries.
    else {
        return []
    }
    return parseGrokVoices(data)
}

// storeGrokVoices(data): Store UTF-8 catalog JSON for later voice-menu
// population.
func storeGrokVoices(_ data: Data) {
    // Do not store catalog bytes that cannot be represented as UTF-8 JSON.
    guard let json = String(data: data, encoding: .utf8) else {
        return
    }
    langminPreferencesStore().set(json, forKey: grokVoicesCacheKey)
}

// Use the cached OpenAI catalog when available; otherwise use the built-in voices.
let openAIVoicesCacheKey = "openAIVoicesCache"

// parseOpenAIVoiceNames(data): Accept voice strings or objects inside a voices
// or data array.
func parseOpenAIVoiceNames(_ data: Data) -> [String] {
    // Reject an OpenAI catalog that is not a JSON object.
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return []
    }
    let array = (object["voices"] as? [Any]) ?? (object["data"] as? [Any]) ?? []
    return array.compactMap { item in
        // Accept voice names supplied directly as strings.
        if let name = item as? String {
            return name
        }
        // Also accept object entries using the provider's supported voice-name keys.
        if let entry = item as? [String: Any] {
            return (entry["voice"] as? String) ?? (entry["id"] as? String) ?? (entry["name"] as? String)
        }
        return nil
    }
    .filter { !$0.isEmpty }
}

// cachedOpenAIVoiceNames(): Read cached OpenAI voice names without requesting a
// network refresh.
func cachedOpenAIVoiceNames() -> [String] {
    // Read the cached OpenAI catalog only when its stored JSON can be decoded.
    guard
        let json = langminPreferencesStore().string(forKey: openAIVoicesCacheKey),
        let data = json.data(using: .utf8)
    // An absent or undecodable cache supplies no voice names.
    else {
        return []
    }
    return parseOpenAIVoiceNames(data)
}

// storeOpenAIVoices(data): Store UTF-8 OpenAI voice JSON for later menu
// population.
func storeOpenAIVoices(_ data: Data) {
    // Leave the prior cache unchanged when the response cannot be stored as UTF-8 JSON.
    guard let json = String(data: data, encoding: .utf8) else {
        return
    }
    langminPreferencesStore().set(json, forKey: openAIVoicesCacheKey)
}
let anthropicAPIVersion = "2023-06-01"
let anthropicWebSearchToolType = "web_search_20250305"
let openAIWebSearchToolType = "web_search"

// resolvedOverride(override, fallback): A non-empty, trimmed Advanced override
// wins; otherwise the built-in default.
func resolvedOverride(_ override: String, default fallback: String) -> String {
    let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
}

// resolvedOverrideURL(override, fallback): Same, but for endpoints: an override
// that is not a valid URL falls back too.
func resolvedOverrideURL(_ override: String, default fallback: URL) -> URL {
    let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
    // Use the configured fallback when a saved endpoint is empty or cannot form a URL.
    guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
        return fallback
    }
    return url
}

// decodeExtraModels(value): Read one extra model per line so display labels can
// contain spaces or commas.
func decodeExtraModels(_ value: String) -> [String] {
    value
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

// encodeExtraModels(ids): Serialize extra model IDs one per line for the
// editable Settings field.
func encodeExtraModels(_ ids: [String]) -> String {
    ids.joined(separator: "\n")
}

// One user-defined Advanced model: a routing ID, a display label, and a
// provider name for listings.
struct ParsedExtraModel {
    let id: String
    let label: String
    let providerName: String
}

// extraModelProviderInfo(token): Map a provider token to its routing-ID prefix
// and a display name.
func extraModelProviderInfo(_ token: String) -> (prefix: String, name: String)? {
    // Normalize supported provider aliases before constructing an extra model ID.
    switch token.trimmingCharacters(in: .whitespaces).lowercased() {
    // Map OpenAI aliases to the shared OpenAI model prefix.
    case "openai", "gpt", "oai":
        return ("openai:", "OpenAI")
    // Map Anthropic aliases to the shared Anthropic model prefix.
    case "anthropic", "claude":
        return ("anthropic:", "Anthropic")
    // Map Google aliases to the shared Gemini model prefix.
    case "gemini", "google":
        return ("gemini:", "Google")
    // Leave unknown provider tokens unresolved for validation to report.
    default:
        return nil
    }
}

// parseExtraModel(line): Parse one Extra Models line. Accepted forms (by
// colon-separated field count):   model                         -> routed by
// its built-in prefix; label = id   provider:model                -> explicit
// provider; label = model   provider:label:model          -> explicit provider
// and friendly label A leading token that is not a known provider falls back to
// the raw-ID form.
func parseExtraModel(_ line: String) -> ParsedExtraModel? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    // Ignore blank lines in the extra-model field.
    guard !trimmed.isEmpty else {
        return nil
    }

    let parts = trimmed.components(separatedBy: ":")
    // Interpret recognized provider-prefixed entries using the final component as the model ID.
    if parts.count >= 2, let info = extraModelProviderInfo(parts[0]) {
        let model = parts[parts.count - 1].trimmingCharacters(in: .whitespaces)
        // Retain incomplete text for display so validation can explain the missing model component.
        guard !model.isEmpty else {
            return ParsedExtraModel(id: trimmed, label: trimmed, providerName: "Added")
        }
        let label = parts.count >= 3
            ? parts[1..<(parts.count - 1)].joined(separator: ":").trimmingCharacters(in: .whitespaces)
            : ""
        return ParsedExtraModel(
            id: info.prefix + model,
            label: label.isEmpty ? model : label,
            providerName: info.name
        )
    }

    return ParsedExtraModel(id: trimmed, label: trimmed, providerName: "Added")
}

// extraModelValidationError(line): Validate one Extra Models line, returning a
// human-readable problem or nil. Accepts: model | provider:model |
// provider:label:model.
func extraModelValidationError(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    // Blank extra-model lines require no validation message.
    guard !trimmed.isEmpty else {
        return nil
    }

    let parts = trimmed.components(separatedBy: ":")

    // A bare model ID cannot contain spaces.
    if parts.count == 1 {
        // Explain when a space-containing bare entry looks like a label instead of an API model ID.
        if trimmed.contains(" ") {
            return "“\(trimmed)” looks like a label, not a model ID. Use provider:label:model."
        }
        return nil
    }

    let providerToken = parts[0].trimmingCharacters(in: .whitespaces)
    // Reject provider prefixes outside the supported extra-model providers.
    guard extraModelProviderInfo(providerToken) != nil else {
        return "“\(providerToken)” is not a known provider. Start the line with openai, anthropic, or gemini."
    }
    // Reject extra separators that make the provider, label, and model structure ambiguous.
    if parts.count > 3 {
        return "“\(trimmed)” has too many “:”. Use provider:label:model."
    }
    let model = parts[parts.count - 1].trimmingCharacters(in: .whitespaces)
    // Explain a missing model identifier after the final separator.
    if model.isEmpty {
        return "“\(trimmed)” is missing a model ID after the last “:”."
    }
    // Reject spaces inside the API model identifier.
    if model.contains(" ") {
        return "Model ID “\(model)” should not contain spaces."
    }
    return nil
}

// extraModelsValidationProblems(lines): All problems across the Extra Models
// lines, in order.
func extraModelsValidationProblems(_ lines: [String]) -> [String] {
    lines.compactMap { extraModelValidationError($0) }
}

// langminPreferencesStore(): Use the app's own preferences container; no App
// Group is needed.
func langminPreferencesStore() -> UserDefaults {
    .standard
}

// langminApplicationSupportDirectory(): Resolve app-owned support storage. In a
// signed App Store build Foundation automatically returns the app sandbox's
// Application Support directory.
func langminApplicationSupportDirectory() -> URL {
    let fallback = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    let base = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first ?? fallback
    return base.appendingPathComponent("Langmin", isDirectory: true)
}

// langminTemporaryDirectory(): Keep transient artifacts in app-owned storage
// until their viewer closes.
func langminTemporaryDirectory() -> URL {
    langminApplicationSupportDirectory()
        .appendingPathComponent("TemporaryItems", isDirectory: true)
}

// removeAbandonedLangminTemporaryItems(): Remove temporary results left by a
// crash before accepting new requests.
func removeAbandonedLangminTemporaryItems() {
    try? FileManager.default.removeItem(at: langminTemporaryDirectory())
}

// createLangminTemporaryDirectory(prefix): Create one private run directory for
// generated result files.
func createLangminTemporaryDirectory(prefix: String) throws -> URL {
    let baseURL = langminTemporaryDirectory()
    try FileManager.default.createDirectory(
        at: baseURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )

    let url = baseURL
        .appendingPathComponent("\(prefix).\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    return url
}

// A possible secret found in text awaiting remote-sharing approval.
struct LangminSecretFinding {
    let kind: String
}

// Common high-risk secret patterns found in developer and support workflows.
private let langminSecretPatterns: [(kind: String, pattern: String)] = [
    ("OpenAI API key", #"sk-[A-Za-z0-9_-]{20,}"#),
    ("Anthropic API key", #"sk-ant-[A-Za-z0-9_-]{20,}"#),
    ("Google API key", #"\bAIza[0-9A-Za-z_-]{35}"#),
    ("Google API key", #"\bAQ\.[A-Za-z0-9_-]{20,}"#),
    ("Google OAuth token", #"\bya29\.[A-Za-z0-9_-]{20,}"#),
    ("GitHub token", #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}\b"#),
    ("GitHub token", #"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#),
    ("AWS access key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
    ("private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
    ("bearer token", #"(?i)\bAuthorization:\s*Bearer\s+[A-Za-z0-9._~+/=-]{16,}"#),
    ("password in URL", #"[A-Za-z][A-Za-z0-9+.-]*://[^:\s/@]+:[^@\s]+@"#),
    ("secret assignment", #"(?i)\b(?:api[_-]?key|secret|token|password|passwd|pwd|access[_-]?token|client[_-]?secret)\b\s*[:=]\s*["']?[^"'\s]{8,}"#)
]

// langminSecretFindings(text): Check text for common secret patterns before
// sending it to a remote provider.
func langminSecretFindings(in text: String) -> [LangminSecretFinding] {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    var seenKinds: Set<String> = []
    var findings: [LangminSecretFinding] = []

    // Check each supported secret pattern independently.
    for pattern in langminSecretPatterns {
        // Require a valid pattern and a matching range before reporting a secret category.
        guard
            let regex = try? NSRegularExpression(pattern: pattern.pattern),
            regex.firstMatch(in: text, range: range) != nil,
            !seenKinds.contains(pattern.kind)
        // Skip patterns that fail to compile or do not match the text.
        else {
            continue
        }

        seenKinds.insert(pattern.kind)
        findings.append(LangminSecretFinding(kind: pattern.kind))
    }

    return findings
}

// MARK: - Response language level (CEFR)
//
// Language level controls vocabulary and grammar; Style controls depth. Off applies no constraint. A, B,
// and C use the corresponding CEFR bands.
let defaultLanguageLevel = "off"
let languageLevelIDs = ["off", "a", "b", "c"]

// The modes a level constraint applies to — everything except Proofread, whose
// job is only to fix errors in the user's own text.
let languageLevelModes: Set<String> = ["explain", "rewrite", "summarize", "translate", "dictionary"]

// languageLevelDisplayName(id): Convert a saved language-level ID into its
// compact menu label.
func languageLevelDisplayName(_ id: String) -> String {
    // Choose a display label from the saved language-level ID.
    switch id.lowercased() {
    // Describe basic language-level wording.
    case "a": return "A · Basic"
    // Describe intermediate language-level wording.
    case "b": return "B · Intermediate"
    // Describe advanced language-level wording.
    case "c": return "C · Advanced"
    // Treat other level IDs as disabled in the menu.
    default: return "Off"
    }
}

// normalizedLanguageLevel(value): Normalize any stored/flag value to a known
// level id ("off" when unrecognized).
func normalizedLanguageLevel(_ value: String) -> String {
    let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return languageLevelIDs.contains(lowered) ? lowered : "off"
}

// languageLevelInstruction(level): Constrain vocabulary and grammar within the
// answer's language. Off and unknown values add no instruction.
func languageLevelInstruction(_ level: String) -> String {
    // Add wording instructions only for a recognized selected language level.
    switch normalizedLanguageLevel(level) {
    // Ask for basic vocabulary while preserving facts and protected source content.
    case "a":
        return "Language level: CEFR A (basic). Use everyday words and short, simple sentences; explain essential difficult terms briefly. Simplify wording, not facts. Preserve quotations, code, identifiers and dictionary headwords."
    // Ask for intermediate vocabulary without changing meaning or protected source content.
    case "b":
        return "Language level: CEFR B (intermediate). Use common vocabulary and moderately varied sentences; explain necessary jargon. Preserve meaning, quotations, code, identifiers and dictionary headwords."
    // Allow advanced vocabulary while retaining clarity and natural wording.
    case "c":
        return "Language level: CEFR C (advanced). Use precise, varied vocabulary and fluent sentence structures where useful. Stay clear and natural; complexity is optional."
    // Add no level instructions when the feature is off.
    default:
        return ""
    }
}

// applyLanguageLevel(instructions, level): Apply the language-level instruction
// consistently across supported modes.
func applyLanguageLevel(to instructions: String, level: String) -> String {
    let rule = languageLevelInstruction(level)
    return rule.isEmpty ? instructions : instructions + "\n\n" + rule
}

// langminSecretSummary(findings):
// Human-readable list used in secret-protection alerts.
func langminSecretSummary(_ findings: [LangminSecretFinding]) -> String {
    let kinds = findings.map(\.kind).sorted()

    // Join detected secret-category names into a readable warning phrase.
    switch kinds.count {
    // Use a general phrase when no specific category name is available.
    case 0:
        return "a possible secret"
    // Use the sole category name without a conjunction.
    case 1:
        return kinds[0]
    // Join two category names with a single conjunction.
    case 2:
        return "\(kinds[0]) and \(kinds[1])"
    // Use a comma-separated list for three or more categories.
    default:
        return "\(kinds.dropLast().joined(separator: ", ")), and \(kinds.last!)"
    }
}
