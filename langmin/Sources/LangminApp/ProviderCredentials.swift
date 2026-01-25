import Cocoa
import Security

// Connect Settings fields to provider-specific credential storage.
extension PreferencesController {
    // saveProviderSettingsKeys(): Read the provider key fields without exposing
    // saved Keychain values.
    func saveProviderSettingsKeys() throws {
        try saveOpenAIAPIKey(apiKeyField.stringValue)
        try saveAnthropicAPIKey(anthropicAPIKeyField.stringValue)
        try saveGeminiAPIKey(geminiAPIKeyField.stringValue)
        try saveGrokAPIKey(grokAPIKeyField.stringValue)
        try saveDeepSeekAPIKey(deepSeekAPIKeyField.stringValue)
        try saveCustomAPIKey(customAPIKeyField.stringValue)
    }
}
// apiKeychainQuery(account): Base query for one provider API key stored in the
// user's login Keychain.
func apiKeychainQuery(account: String) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainServiceName,
        kSecAttrAccount as String: account
    ]
}

// rememberedAPIKeyPresence(account): Cache only key presence so Settings can
// show saved/removed state without triggering Keychain access prompts. A
// missing value means the state is unknown.
func rememberedAPIKeyPresence(account: String) -> Bool? {
    let key = apiKeyPresencePreferencePrefix + account
    // Keep an unknown key-presence state distinct from a confirmed missing key.
    guard let value = preferencesStore.object(forKey: key) as? NSNumber else {
        return nil
    }
    return value.boolValue
}

// rememberAPIKeyPresence(present, account): Cache only whether a key exists so
// Settings can show its state without revealing the secret.
func rememberAPIKeyPresence(_ present: Bool, account: String) {
    preferencesStore.set(present, forKey: apiKeyPresencePreferencePrefix + account)
}

// keychainError(status, action): Convert Keychain failures into readable Cocoa
// errors for Settings alerts.
func keychainError(_ status: OSStatus, action: String) -> NSError {
    let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    return NSError(
        domain: keychainServiceName,
        code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: "Could not \(action): \(message)"]
    )
}

// loadAPIKey(account): Read one saved provider API key from Keychain.
func loadAPIKey(account: String) -> String {
    var query = apiKeychainQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    // Return no key when Keychain does not successfully provide the requested item.
    guard status == errSecSuccess else {
        // Cache absence only for a confirmed missing item, not every Keychain failure.
        if status == errSecItemNotFound {
            rememberAPIKeyPresence(false, account: account)
        }
        return ""
    }
    // Reject malformed credential data instead of exposing unreadable bytes as a key.
    guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
        return ""
    }
    let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
    rememberAPIKeyPresence(!normalized.isEmpty, account: account)
    return normalized
}

// loadProviderAPIKey(account, environmentName): Prefer Keychain. Debug builds
// also accept provider environment variables; Release builds do not.
func loadProviderAPIKey(account: String, environmentName: String) -> String {
    let savedKey = loadAPIKey(account: account)
    // Prefer a saved Keychain credential over the development fallback.
    if !savedKey.isEmpty {
        return savedKey
    }

    // Development builds may use an explicitly configured environment credential fallback.
    #if DEBUG
    return (ProcessInfo.processInfo.environment[environmentName] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // Release builds require the normal credential storage path.
    #else
    return ""
    #endif
}

// loadOpenAIAPIKey(): Read the saved OpenAI API key without exposing it in
// settings files.
func loadOpenAIAPIKey() -> String {
    loadProviderAPIKey(
        account: keychainOpenAIAPIKeyAccount,
        environmentName: "OPENAI_API_KEY"
    )
}

// loadAnthropicAPIKey(): Read the saved Anthropic API key without exposing it
// in settings files.
func loadAnthropicAPIKey() -> String {
    loadProviderAPIKey(
        account: keychainAnthropicAPIKeyAccount,
        environmentName: "ANTHROPIC_API_KEY"
    )
}

// saveAPIKey(value, account, providerName): Store or replace one provider API
// key in Keychain.
func saveAPIKey(_ value: String, account: String, providerName: String) throws {
    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
    // Treat an empty Settings field as no replacement; deletion uses a separate explicit action.
    guard !key.isEmpty else {
        return
    }

    var query = apiKeychainQuery(account: account)
    let attributes = [kSecValueData as String: Data(key.utf8)]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

    // Record presence and finish when updating the existing Keychain item succeeds.
    if updateStatus == errSecSuccess {
        rememberAPIKeyPresence(true, account: account)
        return
    }

    // Create a new item only when the update failed because the item did not exist.
    guard updateStatus == errSecItemNotFound else {
        throw keychainError(updateStatus, action: "update the \(providerName) API key")
    }

    query[kSecValueData as String] = Data(key.utf8)
    let addStatus = SecItemAdd(query as CFDictionary, nil)
    // Report a failed Keychain insertion without marking a key as saved.
    guard addStatus == errSecSuccess else {
        throw keychainError(addStatus, action: "save the \(providerName) API key")
    }
    rememberAPIKeyPresence(true, account: account)
}

// saveOpenAIAPIKey(value): Store or replace the OpenAI API key in Keychain.
func saveOpenAIAPIKey(_ value: String) throws {
    try saveAPIKey(value, account: keychainOpenAIAPIKeyAccount, providerName: "OpenAI")
}

// saveAnthropicAPIKey(value): Store or replace the Anthropic API key in
// Keychain.
func saveAnthropicAPIKey(_ value: String) throws {
    try saveAPIKey(value, account: keychainAnthropicAPIKeyAccount, providerName: "Anthropic")
}

// loadGeminiAPIKey(): Read the saved Google Gemini API key without exposing it
// in settings files.
func loadGeminiAPIKey() -> String {
    loadProviderAPIKey(
        account: keychainGeminiAPIKeyAccount,
        environmentName: "GEMINI_API_KEY"
    )
}

// saveGeminiAPIKey(value): Store or replace the Google Gemini API key in
// Keychain.
func saveGeminiAPIKey(_ value: String) throws {
    try saveAPIKey(value, account: keychainGeminiAPIKeyAccount, providerName: "Gemini")
}

// loadGrokAPIKey(): Read the saved xAI (Grok) API key without exposing it in
// settings files.
func loadGrokAPIKey() -> String {
    loadProviderAPIKey(
        account: keychainGrokAPIKeyAccount,
        environmentName: "GROK_API_KEY"
    )
}

// saveGrokAPIKey(value): Store or replace the xAI (Grok) API key in Keychain.
func saveGrokAPIKey(_ value: String) throws {
    try saveAPIKey(value, account: keychainGrokAPIKeyAccount, providerName: "xAI")
}

// loadDeepSeekAPIKey(): Read the saved DeepSeek API key without exposing it in
// settings files.
func loadDeepSeekAPIKey() -> String {
    loadProviderAPIKey(
        account: keychainDeepSeekAPIKeyAccount,
        environmentName: "DEEPSEEK_API_KEY"
    )
}

// saveDeepSeekAPIKey(value): Store or replace the DeepSeek API key in Keychain.
func saveDeepSeekAPIKey(_ value: String) throws {
    try saveAPIKey(value, account: keychainDeepSeekAPIKeyAccount, providerName: "DeepSeek")
}

// deleteAPIKey(account, providerName): Remove a saved provider API key from
// Keychain. Missing items are already gone.
func deleteAPIKey(account: String, providerName: String) throws {
    let status = SecItemDelete(apiKeychainQuery(account: account) as CFDictionary)
    // Treat an already absent item as successfully removed; report other deletion errors.
    guard status == errSecSuccess || status == errSecItemNotFound else {
        throw keychainError(status, action: "remove the \(providerName) API key")
    }
    rememberAPIKeyPresence(false, account: account)
}

// deleteOpenAIAPIKey(): Delete the OpenAI credential through the shared
// Keychain deletion path.
func deleteOpenAIAPIKey() throws {
    try deleteAPIKey(account: keychainOpenAIAPIKeyAccount, providerName: "OpenAI")
}

// deleteAnthropicAPIKey(): Delete the Anthropic credential through the shared
// Keychain deletion path.
func deleteAnthropicAPIKey() throws {
    try deleteAPIKey(account: keychainAnthropicAPIKeyAccount, providerName: "Anthropic")
}

// deleteGeminiAPIKey(): Delete the Gemini credential through the shared
// Keychain deletion path.
func deleteGeminiAPIKey() throws {
    try deleteAPIKey(account: keychainGeminiAPIKeyAccount, providerName: "Gemini")
}

// deleteGrokAPIKey(): Delete the xAI credential through the shared Keychain
// deletion path.
func deleteGrokAPIKey() throws {
    try deleteAPIKey(account: keychainGrokAPIKeyAccount, providerName: "xAI")
}

// deleteDeepSeekAPIKey(): Delete the DeepSeek credential through the shared
// Keychain deletion path.
func deleteDeepSeekAPIKey() throws {
    try deleteAPIKey(account: keychainDeepSeekAPIKeyAccount, providerName: "DeepSeek")
}

// loadCustomAPIKey(): Optional API key for a custom OpenAI-compatible endpoint
// (empty for local servers).
func loadCustomAPIKey() -> String {
    loadProviderAPIKey(account: keychainCustomAPIKeyAccount, environmentName: "LANGMIN_CUSTOM_API_KEY")
}

// saveCustomAPIKey(value): Save a custom endpoint key through the shared
// credential-storage path.
func saveCustomAPIKey(_ value: String) throws {
    try saveAPIKey(value, account: keychainCustomAPIKeyAccount, providerName: "Custom")
}

// deleteCustomAPIKey(): Delete the custom endpoint credential through the
// shared Keychain deletion path.
func deleteCustomAPIKey() throws {
    try deleteAPIKey(account: keychainCustomAPIKeyAccount, providerName: "Custom")
}
