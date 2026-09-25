import Cocoa

// openAIErrorMessage(data): Pull a user-facing OpenAI error message out of a
// JSON error response.
func openAIErrorMessage(from data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        // Non-JSON body (a proxy or gateway may return plain text or HTML).
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (!text.isEmpty && text.count <= 300 && !text.hasPrefix("<")) ? text : nil
    }

    // OpenAI / LM Studio shape: { "error": { "code", "message" } }.
    if let error = object["error"] as? [String: Any] {
        // Give an invalid-key error a direct Settings recovery message.
        if (error["code"] as? String) == "invalid_api_key" {
            return "Incorrect API key provided. Add a valid key in Settings."
        }
        // Prefer the provider's nonempty error message when available.
        if let message = error["message"] as? String, !message.isEmpty {
            return message
        }
    }

    // xAI / others sometimes return { "error": "message" } or a top-level message.
    if let error = object["error"] as? String, !error.isEmpty {
        return error
    }
    // Accept the compatible provider's top-level error message as a fallback.
    if let message = object["message"] as? String, !message.isEmpty {
        return message
    }

    return nil
}

// anthropicErrorMessage(data): Extract Anthropic's error message for display.
func anthropicErrorMessage(from data: Data) -> String? {
    // Require Anthropic's structured error object before reading its message.
    guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let error = object["error"] as? [String: Any]
    // Return no provider detail when the error payload cannot be decoded.
    else {
        return nil
    }

    // Use Anthropic's message only when it is nonempty.
    if let message = error["message"] as? String, !message.isEmpty {
        return message
    }

    return nil
}

// anthropicOutputText(data): Extract text blocks from an Anthropic Messages API
// success payload.
func anthropicOutputText(from data: Data) -> String {
    // Require a structured Anthropic content response before extracting text blocks.
    guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let content = object["content"] as? [[String: Any]]
    // Return no output when the expected response structure is absent.
    else {
        return ""
    }

    return content.compactMap { item in
        // Exclude thinking and other nontext blocks from the displayed answer.
        guard item["type"] as? String == "text" else {
            return nil
        }

        return item["text"] as? String
    }
    .joined()
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

// geminiErrorMessage(data): Extract Gemini's error message for display.
func geminiErrorMessage(from data: Data) -> String? {
    // Require Gemini's structured error object before reading its message.
    guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let error = object["error"] as? [String: Any]
    // Return no Gemini error detail when its payload is malformed.
    else {
        return nil
    }

    // Use Gemini's nonempty error message when present.
    if let message = error["message"] as? String, !message.isEmpty {
        return message
    }

    return nil
}

// geminiOutputText(data): Extract text parts from a Gemini generateContent
// success payload.
func geminiOutputText(from data: Data) -> String {
    // Require a candidate with content parts before extracting a Gemini answer.
    guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let candidates = object["candidates"] as? [[String: Any]],
        let first = candidates.first,
        let content = first["content"] as? [String: Any],
        let parts = content["parts"] as? [[String: Any]]
    // Return no output when the candidate structure is missing.
    else {
        return ""
    }

    return parts.compactMap { $0["text"] as? String }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// collectOutputText(value): Recursively collect output_text nodes from the
// Responses API payload.
func collectOutputText(from value: Any) -> [String] {
    // Collect output text recursively from array-valued response content.
    if let array = value as? [Any] {
        return array.flatMap { collectOutputText(from: $0) }
    }

    // Ignore scalar metadata while searching for output-text objects.
    guard let object = value as? [String: Any] else {
        return []
    }

    var parts: [String] = []
    // Extract text only from response blocks explicitly marked as output text.
    if object["type"] as? String == "output_text" {
        // Use the standard text field when the block provides it.
        if let text = object["text"] as? String {
            parts.append(text)
        } else if let value = object["value"] as? String {
            // Accept the alternate value field when the standard text field is absent.
            parts.append(value)
        }
    }

    // Search nested response objects for additional output-text blocks.
    for nested in object.values {
        parts.append(contentsOf: collectOutputText(from: nested))
    }

    return parts
}

// openAIOutputText(data): Extract the assistant text from a Responses API
// success payload.
func openAIOutputText(from data: Data) -> String {
    // Return no text when the provider body is not valid JSON.
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
        return ""
    }

    return collectOutputText(from: object)
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// markingTruncation(output, truncated): Append a visible warning when the
// provider reports truncated output.
func markingTruncation(_ output: String, truncated: Bool) -> String {
    truncated ? output + truncatedResponseNotice : output
}

// openAIResponseWasTruncated(data): Recognize incomplete output reported by the
// OpenAI Responses API.
func openAIResponseWasTruncated(_ data: Data) -> Bool {
    // An undecodable payload cannot establish a truncation reason.
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
    }
    // Inspect incomplete details only when the Responses API marks output incomplete.
    guard object["status"] as? String == "incomplete" else { return false }
    let reason = (object["incomplete_details"] as? [String: Any])?["reason"] as? String
    return reason == nil || reason == "max_output_tokens"
}

// openAICompatibleResponseWasTruncated(data): Recognize the token-limit finish
// reason in a chat-completions response.
func openAICompatibleResponseWasTruncated(_ data: Data) -> Bool {
    // Require the first chat-completions choice before checking its finish reason.
    guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let first = (object["choices"] as? [[String: Any]])?.first
    // Do not claim token truncation from a missing or malformed choice.
    else {
        return false
    }
    return first["finish_reason"] as? String == "length"
}

// anthropicResponseWasTruncated(data): Recognize Anthropic's output-token-limit
// stop reason.
func anthropicResponseWasTruncated(_ data: Data) -> Bool {
    // Require a structured Anthropic response before checking its stop reason.
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
    }
    return object["stop_reason"] as? String == "max_tokens"
}

// geminiResponseWasTruncated(data): Recognize Gemini's token-limit finish
// reason for the first candidate.
func geminiResponseWasTruncated(_ data: Data) -> Bool {
    // Require the first Gemini candidate before checking its finish reason.
    guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let first = (object["candidates"] as? [[String: Any]])?.first
    // Do not claim token truncation from a missing Gemini candidate.
    else {
        return false
    }
    return first["finishReason"] as? String == "MAX_TOKENS"
}

// collectWebCitations(data): Collect source titles and URLs from Responses
// citations in first-seen order.
func collectWebCitations(from data: Data) -> [(title: String, url: String)] {
    // An undecodable response supplies no usable citation metadata.
    guard let root = try? JSONSerialization.jsonObject(with: data) else {
        return []
    }

    var ordered: [(title: String, url: String)] = []
    var seen = Set<String>()

    // walk(value): Walk nested response values to collect provider citation
    // metadata.
    func walk(_ value: Any) {
        // Visit each nested array element for citation objects.
        if let array = value as? [Any] {
            array.forEach(walk)
            return
        }
        // Ignore nonobject scalar values while collecting citations.
        guard let object = value as? [String: Any] else {
            return
        }
        // Add only distinct, nonempty URLs explicitly marked as citations.
        if
            (object["type"] as? String) == "url_citation",
            let url = (object["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !url.isEmpty,
            !seen.contains(url)
        {
            seen.insert(url)
            let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ordered.append((title: title, url: url))
        }
        // Search nested objects for citation records in their provider envelope.
        for nested in object.values {
            walk(nested)
        }
    }

    walk(root)
    return ordered
}

// webCitationLabel(title, url): Pick a readable link label, preferring the page
// title over the bare host.
func webCitationLabel(title: String, url: String) -> String {
    let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
    // Some providers use textual null placeholders when the page has no title.
    if !cleaned.isEmpty, !["none", "null"].contains(cleaned.lowercased()) {
        return cleaned
    }
    // Use a readable hostname when no title is available.
    if let host = URL(string: url)?.host {
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    return url
}

// escapedMarkdownLinkLabel(value): Escape link-label punctuation before
// appending provider sources as Markdown.
func escapedMarkdownLinkLabel(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "[", with: "\\[")
        .replacingOccurrences(of: "]", with: "\\]")
}

// collectAnthropicCitations(data): Collect Anthropic web_search citations
// (title + url) in first-seen order. Claude attaches web_search_result_location
// blocks to the text it cites.
func collectAnthropicCitations(from data: Data) -> [(title: String, url: String)] {
    // An undecodable Anthropic payload supplies no source citations.
    guard let root = try? JSONSerialization.jsonObject(with: data) else {
        return []
    }

    var ordered: [(title: String, url: String)] = []
    var seen = Set<String>()

    // walk(value): Walk nested citation metadata while collecting usable
    // web-source references.
    func walk(_ value: Any) {
        // Visit nested arrays while collecting Anthropic web sources.
        if let array = value as? [Any] {
            array.forEach(walk)
            return
        }
        // Ignore scalar metadata that cannot describe a web source.
        guard let object = value as? [String: Any] else {
            return
        }
        let type = object["type"] as? String
        // Accept distinct usable URLs only from recognized Anthropic web-source block types.
        if
            (type == "web_search_result_location" || type == "web_search_result"),
            let url = (object["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !url.isEmpty,
            !seen.contains(url)
        {
            seen.insert(url)
            let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ordered.append((title: title, url: url))
        }
        // Search nested values for additional web-source records.
        for nested in object.values {
            walk(nested)
        }
    }

    walk(root)
    return ordered
}

// collectGeminiCitations(data): Collect Gemini grounding citations (title +
// url) in chunk order.
func collectGeminiCitations(from data: Data) -> [(title: String, url: String)] {
    // Require Gemini grounding metadata before reading its web chunks.
    guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let candidates = object["candidates"] as? [[String: Any]],
        let first = candidates.first,
        let grounding = first["groundingMetadata"] as? [String: Any],
        let chunks = grounding["groundingChunks"] as? [[String: Any]]
    // Return no citations when the expected grounding structure is absent.
    else {
        return []
    }

    var ordered: [(title: String, url: String)] = []
    var seen = Set<String>()
    // Preserve the provider's grounding-chunk order for numbered references.
    for chunk in chunks {
        // Require usable distinct web-source data in each grounding chunk.
        guard
            let web = chunk["web"] as? [String: Any],
            let url = (web["uri"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !url.isEmpty,
            !seen.contains(url)
        // Skip malformed, empty, or duplicate grounding references.
        else {
            continue
        }
        seen.insert(url)
        let title = (web["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ordered.append((title: title, url: url))
    }
    return ordered
}

// appendingWebSources(output, citations, [requireMarkers = true]): Append
// numbered source links. Require in-text markers only for providers that need
// them; Anthropic and Gemini supply citation metadata directly.
func appendingWebSources(
    to output: String,
    citations: [(title: String, url: String)],
    requireMarkers: Bool = true
) -> String {
    // Leave the answer unchanged when the provider supplied no citations.
    guard !citations.isEmpty else {
        return output
    }

    // Keep malformed structured output intact for the Explain delivery path
    // to reject; wrapping it in a new object would hide the decoding failure.
    guard let parsed = try? parseExplanationResponse(output), !parsed.explanation.isEmpty else {
        return output
    }
    // Honor callers that require visible citation markers before adding a source footer.
    if requireMarkers {
        // Leave unreferenced output unchanged when numbered markers are required but absent.
        guard parsed.explanation.range(of: "\\[[0-9]{1,3}\\]", options: .regularExpression) != nil else {
            return output
        }
    }

    var lines = ["", "### Sources", ""]
    // Build numbered source links with escaped readable labels.
    for (index, citation) in citations.enumerated() {
        let label = escapedMarkdownLinkLabel(webCitationLabel(title: citation.title, url: citation.url))
        lines.append("[\(index + 1)] [\(label)](\(citation.url))")
    }
    let explanation = removingTrailingSourcesSection(from: parsed.explanation) + "\n" + lines.joined(separator: "\n")

    let object: [String: Any] = ["title": parsed.topicTitle, "explanation": explanation]
    // Require successful JSON serialization before replacing a structured explanation response.
    guard
        let encoded = try? JSONSerialization.data(withJSONObject: object),
        let json = String(data: encoded, encoding: .utf8)
    // Preserve the original output if the source-enriched object cannot be encoded.
    else {
        return output
    }
    return json
}

// appendingWebSources(output, data): Collect citations from the provider
// payload and append them to the result text.
func appendingWebSources(to output: String, from data: Data) -> String {
    appendingWebSources(to: output, citations: collectWebCitations(from: data))
}

let truncatedResponseNotice =
    "\n\n> ⚠️ The response hit the model's length limit and may be incomplete."

// openAICompatibleChatURL(baseURL): Build the chat-completions URL from a base
// like "http://localhost:1234/v1".
func openAICompatibleChatURL(from baseURL: String) -> URL? {
    var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    // Remove trailing slashes before appending the chat-completions endpoint path.
    while trimmed.hasSuffix("/") {
        trimmed.removeLast()
    }
    // Do not append the endpoint path twice when the configured URL already includes it.
    if !trimmed.hasSuffix("/chat/completions") {
        trimmed += "/chat/completions"
    }
    return URL(string: trimmed)
}

// openAICompatibleOutputText(data): Extract the assistant text from an
// OpenAI-compatible chat-completions payload.
func openAICompatibleOutputText(from data: Data) -> String {
    // Require a first completion choice before extracting compatible-provider output.
    guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let choices = object["choices"] as? [[String: Any]],
        let first = choices.first
    // Return no output when the completion-choice structure is absent.
    else {
        return ""
    }

    // Prefer chat-style message content when the response supplies it.
    if let message = first["message"] as? [String: Any], let content = message["content"] as? String {
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // Accept legacy text-completion output as a fallback.
    if let text = first["text"] as? String {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return ""
}

// startOpenAICompatibleTextRequest(baseURL, apiKey, model, prompt,
// emptyMessage, [providerLabel = "Custom endpoint"], completion): Start one
// request against an OpenAI-compatible endpoint (LM Studio, Ollama, Groq, …).
func startOpenAICompatibleTextRequest(
    baseURL: String,
    apiKey: String,
    model: String,
    prompt: ExplanationPrompt,
    emptyMessage: String,
    providerLabel: String = "Custom endpoint",
    completion: @escaping (Result<String, Error>) -> Void
) throws -> RetryingDataTask {
    // Reject an invalid custom or compatible-provider endpoint before creating a request.
    guard let url = openAICompatibleChatURL(from: baseURL) else {
        throw HelperFailure(message: "The \(providerLabel) URL is not valid.")
    }

    let prompt = promptApplyingCustomInstructions(prompt)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    // Bound simple lookups more tightly than long-form generation.
    request.timeoutInterval = prompt.appleFormat == .dictionary ? 60 : speechRequestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    // Allow compatible endpoints without authentication when no key was configured.
    if !key.isEmpty {
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    var body: [String: Any] = [
        "model": model,
        "messages": [
            ["role": "system", "content": prompt.instructions]
        ] + prompt.chatMessages
    ]
    // Dictionary lookups do not need the high reasoning defaults of these
    // providers. Restrict their options to known models and their own adapters.
    if prompt.appleFormat == .dictionary {
        if providerLabel == "DeepSeek", ["deepseek-v4-pro", "deepseek-flash"].contains(model) {
            body["thinking"] = ["type": "disabled"]
        } else if providerLabel == "Grok", ["grok-4.5", "grok-4.6", "grok-4.7"].contains(model) {
            body["reasoning_effort"] = "low"
        }
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    return RetryingDataTask(request: request, totalTimeout: request.timeoutInterval) { data, response, error in
        // Propagate network failures before trying to parse response data.
        if let error {
            completion(.failure(error))
            return
        }

        // Report an absent response body with a provider-specific recovery message.
        guard let data else {
            completion(.failure(HelperFailure(message: "The \(providerLabel) returned no response. Is the server running?")))
            return
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Read successful output only from a successful HTTP response.
        guard (200..<300).contains(status) else {
            let detail = openAIErrorMessage(from: data).map { ": \($0)" } ?? "."
            let message = "\(providerLabel) request failed (HTTP \(status))\(detail)"
            completion(.failure(HelperFailure(message: message)))
            return
        }

        let output = openAICompatibleOutputText(from: data)
        // Report empty generated output using provider details when available.
        guard !output.isEmpty else {
            let message = openAIErrorMessage(from: data) ?? emptyMessage
            completion(.failure(HelperFailure(message: message)))
            return
        }

        completion(.success(markingTruncation(
            output,
            truncated: openAICompatibleResponseWasTruncated(data)
        )))
    }
}

// startOpenAITextRequest(apiKey, model, prompt, emptyMessage, research,
// completion): Start one OpenAI Responses request.
func startOpenAITextRequest(
    apiKey: String,
    model: String,
    prompt: ExplanationPrompt,
    emptyMessage: String,
    research: Bool,
    completion: @escaping (Result<String, Error>) -> Void
) throws -> RetryingDataTask {
    let preferences = loadAppPreferences()
    let prompt = promptApplyingCustomInstructions(prompt, preferences: preferences)
    let endpoint = resolvedOverrideURL(preferences.openAIEndpointOverride, default: openAIResponsesEndpoint)
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    // Bound simple lookups more tightly than long-form generation.
    request.timeoutInterval = prompt.appleFormat == .dictionary ? 60 : speechRequestTimeout
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    var body: [String: Any] = [
        "model": model,
        "instructions": prompt.instructions,
        "input": prompt.conversationMessages.isEmpty ? prompt.input as Any : prompt.chatMessages,
        "store": false
    ]

    // Add the web-search tool only when research was requested.
    if research {
        body["tools"] = [
            [
                "type": openAIWebSearchToolType
            ]
        ]
        body["tool_choice"] = "required"
    }

    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    return RetryingDataTask(request: request, totalTimeout: request.timeoutInterval) { data, response, error in
        // Deliver OpenAI transport errors without attempting response parsing.
        if let error {
            completion(.failure(error))
            return
        }

        // Report a missing OpenAI response body.
        guard let data else {
            completion(.failure(HelperFailure(message: "OpenAI returned no response.")))
            return
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Handle OpenAI HTTP errors before extracting answer text.
        guard (200..<300).contains(status) else {
            let message = openAIErrorMessage(from: data)
                ?? "OpenAI request failed with HTTP status \(status)."
            completion(.failure(HelperFailure(message: message)))
            return
        }

        let rawOutput = openAIOutputText(from: data)
        let output = research
            ? appendingWebSources(to: rawOutput, from: data)
            : rawOutput
        // Reject empty OpenAI output rather than presenting an empty result.
        guard !output.isEmpty else {
            let message = openAIErrorMessage(from: data) ?? emptyMessage
            completion(.failure(HelperFailure(message: message)))
            return
        }

        completion(.success(markingTruncation(output, truncated: openAIResponseWasTruncated(data))))
    }
}

// startAnthropicTextRequest(apiKey, model, prompt, emptyMessage, [research =
// false], completion): Start one Anthropic Messages request.
func startAnthropicTextRequest(
    apiKey: String,
    model: String,
    prompt: ExplanationPrompt,
    emptyMessage: String,
    research: Bool = false,
    completion: @escaping (Result<String, Error>) -> Void
) throws -> RetryingDataTask {
    let preferences = loadAppPreferences()
    let prompt = promptApplyingCustomInstructions(prompt, preferences: preferences)
    let endpoint = resolvedOverrideURL(preferences.anthropicEndpointOverride, default: anthropicMessagesEndpoint)
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    // Bound simple lookups more tightly than long-form generation.
    request.timeoutInterval = prompt.appleFormat == .dictionary ? 60 : speechRequestTimeout
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue(resolvedOverride(preferences.anthropicVersionOverride, default: anthropicAPIVersion), forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    var body: [String: Any] = [
        "model": model,
        "max_tokens": 8192,
        "system": prompt.instructions,
        "messages": prompt.chatMessages
    ]
    // Add Anthropic's configured search tool only for research requests.
    if research {
        let searchToolType = resolvedOverride(
            preferences.anthropicWebSearchToolTypeOverride,
            default: anthropicWebSearchToolType
        )
        body["tools"] = [
            [
                "type": searchToolType,
                "name": "web_search",
                "max_uses": 5
            ]
        ]
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    return RetryingDataTask(request: request, totalTimeout: request.timeoutInterval) { data, response, error in
        // Deliver Anthropic transport failures before parsing content.
        if let error {
            completion(.failure(error))
            return
        }

        // Report a missing Anthropic response body.
        guard let data else {
            completion(.failure(HelperFailure(message: "Anthropic returned no response.")))
            return
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Handle Anthropic HTTP errors before extracting content blocks.
        guard (200..<300).contains(status) else {
            let message = anthropicErrorMessage(from: data)
                ?? "Anthropic request failed with HTTP status \(status)."
            completion(.failure(HelperFailure(message: message)))
            return
        }

        let rawOutput = anthropicOutputText(from: data)
        let output = research
            ? appendingWebSources(to: rawOutput, citations: collectAnthropicCitations(from: data), requireMarkers: false)
            : rawOutput
        // Reject empty Anthropic output with any available provider explanation.
        guard !output.isEmpty else {
            let message = anthropicErrorMessage(from: data) ?? emptyMessage
            completion(.failure(HelperFailure(message: message)))
            return
        }

        completion(.success(markingTruncation(output, truncated: anthropicResponseWasTruncated(data))))
    }
}

// startGeminiTextRequest(apiKey, model, prompt, emptyMessage, [research =
// false], completion): Start one Google Gemini generateContent request.
func startGeminiTextRequest(
    apiKey: String,
    model: String,
    prompt: ExplanationPrompt,
    emptyMessage: String,
    research: Bool = false,
    completion: @escaping (Result<String, Error>) -> Void
) throws -> RetryingDataTask {
    let preferences = loadAppPreferences()
    let prompt = promptApplyingCustomInstructions(prompt, preferences: preferences)
    let base = resolvedOverride(preferences.geminiEndpointOverride, default: geminiAPIBaseURL)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    // Encode the model name before placing it in the Gemini request URL.
    guard
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
        let url = URL(string: "\(base)/\(encodedModel):generateContent")
    // Reject a model name that cannot form a valid Gemini endpoint.
    else {
        throw HelperFailure(message: "The Gemini model name is not valid.")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    // Bound simple lookups more tightly than long-form generation.
    request.timeoutInterval = prompt.appleFormat == .dictionary ? 60 : speechRequestTimeout
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    var body: [String: Any] = [
        "systemInstruction": [
            "parts": [["text": prompt.instructions]]
        ],
        "contents": prompt.messages.map { message -> [String: Any] in
            ["role": message.role == .assistant ? "model" : "user",
             "parts": [["text": message.content]]]
        },
        "generationConfig": [
            "maxOutputTokens": 8192
        ]
    ]
    // Enable Google Search only for requests that opted into research.
    if research {
        body["tools"] = [["google_search": [String: Any]()]]
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    return RetryingDataTask(request: request, totalTimeout: request.timeoutInterval) { data, response, error in
        // Deliver Gemini transport failures before parsing candidates.
        if let error {
            completion(.failure(error))
            return
        }

        // Report a missing Gemini response body.
        guard let data else {
            completion(.failure(HelperFailure(message: "Gemini returned no response.")))
            return
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Handle Gemini HTTP errors before extracting the first answer.
        guard (200..<300).contains(status) else {
            let message = geminiErrorMessage(from: data)
                ?? "Gemini request failed with HTTP status \(status)."
            completion(.failure(HelperFailure(message: message)))
            return
        }

        let rawOutput = geminiOutputText(from: data)
        let output = research
            ? appendingWebSources(to: rawOutput, citations: collectGeminiCitations(from: data), requireMarkers: false)
            : rawOutput
        // Reject empty Gemini output with any available provider explanation.
        guard !output.isEmpty else {
            let message = geminiErrorMessage(from: data) ?? emptyMessage
            completion(.failure(HelperFailure(message: message)))
            return
        }

        completion(.success(markingTruncation(output, truncated: geminiResponseWasTruncated(data))))
    }
}

// startCloudTextRequest(model, prompt, emptyMessage, [research = false],
// completion): Route a cloud text request to its provider and return a
// cancellable task.
func startCloudTextRequest(
    model: String,
    prompt: ExplanationPrompt,
    emptyMessage: String,
    research: Bool = false,
    completion: @escaping (Result<String, Error>) -> Void
) throws -> TextRequestHandle {
    let resolved = textProvider(for: model)

    // Route the resolved model to its provider-specific request builder.
    switch resolved.provider {
    // Reject Apple models here because they belong to the on-device request path.
    case .apple:
        throw HelperFailure(message: "Use the on-device text provider for Apple Intelligence.")

    // Use OpenAI's dedicated response API and credential.
    case .openAI:
        let apiKey = loadOpenAIAPIKey()
        // Require an OpenAI key before starting a paid remote request.
        guard !apiKey.isEmpty else {
            throw HelperFailure(
                message: "OpenAI API key is not available to Langmin. Add it in Settings, choose Apple Intelligence, or choose an Anthropic model."
            )
        }

        let task = try startOpenAITextRequest(
            apiKey: apiKey,
            model: resolved.model,
            prompt: prompt,
            emptyMessage: emptyMessage,
            research: research,
            completion: completion
        )

        return TextRequestHandle(resume: { task.resume() }, cancel: { task.cancel() })

    // Use Anthropic's dedicated message API and credential.
    case .anthropic:
        let apiKey = loadAnthropicAPIKey()
        // Require an Anthropic key before starting a remote request.
        guard !apiKey.isEmpty else {
            throw HelperFailure(
                message: "Anthropic API key is not available to Langmin. Add it in Settings, choose Apple Intelligence, or choose an OpenAI model."
            )
        }

        let task = try startAnthropicTextRequest(
            apiKey: apiKey,
            model: resolved.model,
            prompt: prompt,
            emptyMessage: emptyMessage,
            research: research,
            completion: completion
        )

        return TextRequestHandle(resume: { task.resume() }, cancel: { task.cancel() })

    // Use Gemini's dedicated generation API and credential.
    case .gemini:
        let apiKey = loadGeminiAPIKey()
        // Require a Gemini key before starting a remote request.
        guard !apiKey.isEmpty else {
            throw HelperFailure(
                message: "Google Gemini API key is not available to Langmin. Add it in Settings, choose Apple Intelligence, or choose another model."
            )
        }

        let task = try startGeminiTextRequest(
            apiKey: apiKey,
            model: resolved.model,
            prompt: prompt,
            emptyMessage: emptyMessage,
            research: research,
            completion: completion
        )

        return TextRequestHandle(resume: { task.resume() }, cancel: { task.cancel() })

    // Use xAI's compatible chat endpoint with its own credential.
    case .grok:
        let apiKey = loadGrokAPIKey()
        // Require an xAI key before starting a Grok request.
        guard !apiKey.isEmpty else {
            throw HelperFailure(
                message: "xAI (Grok) API key is not available to Langmin. Add it in Settings, choose Apple Intelligence, or choose another model."
            )
        }

        let task = try startOpenAICompatibleTextRequest(
            baseURL: grokAPIBaseURL,
            apiKey: apiKey,
            model: resolved.model,
            prompt: prompt,
            emptyMessage: emptyMessage,
            providerLabel: "Grok",
            completion: completion
        )

        return TextRequestHandle(resume: { task.resume() }, cancel: { task.cancel() })

    // Use DeepSeek's compatible chat endpoint with its own credential.
    case .deepSeek:
        let apiKey = loadDeepSeekAPIKey()
        // Require a DeepSeek key before starting its request.
        guard !apiKey.isEmpty else {
            throw HelperFailure(
                message: "DeepSeek API key is not available to Langmin. Add it in Settings, choose Apple Intelligence, or choose another model."
            )
        }

        let task = try startOpenAICompatibleTextRequest(
            baseURL: deepSeekAPIBaseURL,
            apiKey: apiKey,
            model: resolved.model,
            prompt: prompt,
            emptyMessage: emptyMessage,
            providerLabel: "DeepSeek",
            completion: completion
        )

        return TextRequestHandle(resume: { task.resume() }, cancel: { task.cancel() })

    // Read the user-configured compatible endpoint and model from Settings.
    case .openAICompatible:
        let preferences = loadAppPreferences()
        let baseURL = preferences.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Require a custom endpoint URL before creating the request.
        guard !baseURL.isEmpty else {
            throw HelperFailure(message: "Set a Custom endpoint URL in Settings, or choose another model.")
        }
        let modelName = preferences.customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Require a custom API model name before creating the request.
        guard !modelName.isEmpty else {
            throw HelperFailure(message: "Set a Custom model name in Settings, or choose another model.")
        }

        let task = try startOpenAICompatibleTextRequest(
            baseURL: baseURL,
            apiKey: loadCustomAPIKey(),
            model: modelName,
            prompt: prompt,
            emptyMessage: emptyMessage,
            completion: completion
        )

        return TextRequestHandle(resume: { task.resume() }, cancel: { task.cancel() })
    }
}
