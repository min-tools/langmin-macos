#!/usr/bin/env python3
"""Inspect real provider request bodies offline; transport never opens a socket."""
from pathlib import Path
import os
import platform
import subprocess
import tempfile

from source_files import ROOT, app_path, app_source, swift_fixture_args
MAIN = app_source('main.swift')


# block(marker): Extract one brace-balanced production declaration for this
# isolated Swift fixture.
def block(marker):
    start = MAIN.index(marker)
    end = MAIN.index('{', start) + 1
    depth = 1
    # Include nested blocks when finding the end of the extracted declaration.
    while depth:
        depth += (MAIN[end] == '{') - (MAIN[end] == '}')
        end += 1
    return MAIN[start:end]


source = r'''
import Foundation
// Represent fixture failures using the app’s localized-error contract.
struct HelperFailure: LocalizedError { let message: String }
// Supply custom instructions and endpoint overrides for request-payload tests.
struct AppPreferences {
 var customInstructions = "Use a friendly tone."
 var openAIEndpointOverride = ""
 var anthropicEndpointOverride = ""
 var anthropicVersionOverride = ""
 var anthropicWebSearchToolTypeOverride = ""
 var geminiEndpointOverride = ""
}
// loadAppPreferences(): Provide the preferences configured by this fixture.
func loadAppPreferences() -> AppPreferences { AppPreferences() }
// resolvedOverride(value, fallback): Use the configured string override or its
// built-in fallback.
func resolvedOverride(_ value: String, default fallback: String) -> String { value.isEmpty ? fallback : value }
// resolvedOverrideURL(value, fallback): Resolve fixture endpoint overrides
// without network access.
func resolvedOverrideURL(_ value: String, default fallback: URL) -> URL { value.isEmpty ? fallback : URL(string: value)! }
let speechRequestTimeout: TimeInterval = 30
let openAIResponsesEndpoint = URL(string: "https://example.test/responses")!
let anthropicMessagesEndpoint = URL(string: "https://example.test/messages")!
let anthropicAPIVersion = "fixture"
let openAIWebSearchToolType = "web_search"
let anthropicWebSearchToolType = "web_search_fixture"
let geminiAPIBaseURL = "https://example.test/models"
let defaultExplanationModel = "gpt-6-sol"
let appleIntelligenceModelID = "apple-intelligence"
let customModelID = "custom"
// openAICompatibleChatURL(base): Construct the chat endpoint used by the
// compatible-provider adapter.
func openAICompatibleChatURL(from base: String) -> URL? { URL(string: base + "/chat/completions") }

// Capture the final URLRequest from the actual adapters. No URLSession,
// credential loaders or response callbacks are used by these payload tests.
final class RetryingDataTask {
 let request: URLRequest
 // init(request, completion): Capture the request without starting transport or
 // calling its completion.
 init(request: URLRequest, completion: @escaping (Data?, URLResponse?, Error?) -> Void) { self.request = request }
}
// openAIErrorMessage(data): Leave OpenAI error parsing outside this
// request-payload fixture.
func openAIErrorMessage(from data: Data) -> String? { nil }
// anthropicErrorMessage(data): Leave Anthropic error parsing outside this
// request-payload fixture.
func anthropicErrorMessage(from data: Data) -> String? { nil }
// geminiErrorMessage(data): Leave Gemini error parsing outside this
// request-payload fixture.
func geminiErrorMessage(from data: Data) -> String? { nil }
// openAIOutputText(data): Leave OpenAI response decoding outside this
// request-payload fixture.
func openAIOutputText(from data: Data) -> String { "" }
// openAICompatibleOutputText(data): Leave compatible-provider response decoding
// outside this fixture.
func openAICompatibleOutputText(from data: Data) -> String { "" }
// geminiOutputText(data): Leave Gemini response decoding outside this
// request-payload fixture.
func geminiOutputText(from data: Data) -> String { "" }
// openAIResponseWasTruncated(data): Disable response truncation checks because
// no response is delivered.
func openAIResponseWasTruncated(_ data: Data) -> Bool { false }
// openAICompatibleResponseWasTruncated(data): Disable response truncation
// checks because no response is delivered.
func openAICompatibleResponseWasTruncated(_ data: Data) -> Bool { false }
// anthropicResponseWasTruncated(data): Disable response truncation checks
// because no response is delivered.
func anthropicResponseWasTruncated(_ data: Data) -> Bool { false }
// geminiResponseWasTruncated(data): Disable response truncation checks because
// no response is delivered.
func geminiResponseWasTruncated(_ data: Data) -> Bool { false }
// markingTruncation(output, truncated): Leave response text unchanged; this
// fixture inspects outgoing requests.
func markingTruncation(_ output: String, truncated: Bool) -> String { output }
// collectAnthropicCitations(data): Leave Anthropic citation decoding outside
// this request-payload fixture.
func collectAnthropicCitations(from data: Data) -> [String] { [] }
// collectGeminiCitations(data): Leave Gemini citation decoding outside this
// request-payload fixture.
func collectGeminiCitations(from data: Data) -> [String] { [] }
// appendingWebSources(output, citations, requireMarkers): Keep source rendering
// inactive while inspecting outgoing requests.
func appendingWebSources(to output: String, citations: [String], requireMarkers: Bool) -> String { output }
// appendingWebSources(output, data): Keep source rendering inactive while
// inspecting outgoing requests.
func appendingWebSources(to output: String, from data: Data) -> String { output }
// Supply the model-option fields referenced by prompt code.
struct PreferenceOption { let id: String; let title: String; let note: String }
// localized(key, english): Resolve labels through the fixture’s controlled
// localization.
func localized(_ key: String, _ english: String) -> String { english }
// applyLanguageLevel(input, level): Expose the selected reading level in the
// prompt for assertions.
func applyLanguageLevel(to input: String, level: String) -> String { input + "\nLanguage level: " + level }
// watermarkCleanedGeneratedText(input): Leave text unchanged so this fixture
// isolates behavior outside Unicode cleanup.
func watermarkCleanedGeneratedText(_ input: String) -> String { input }
'''
source += MAIN[MAIN.index('let languageOptions:'):MAIN.index('// Override the UI language')]
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['enum TextModelProvider {', 'func textProvider(', 'func modelSupportsWebResearch(',
               'func webCitationLabel(', 'func collectWebCitations(',
               'func anthropicOutputText(', 'struct ExplanationPrompt {', 'func promptApplyingCustomInstructions(',
               'func languageName(', 'func detectLanguagePrefix(', 'func preferredOutputLanguage(',
               'func translationLanguageCode(', 'func promptLanguageNames(', 'func translationSourceLanguageInstructions(',
               'struct TranslationSkipped:', 'func cleanedLiteralTransformOutput(',
               'func cleanedTextTransformOutput(', 'func translationPrompt(',
               'func appleIntelligencePrompt(', 'func startOpenAICompatibleTextRequest(',
               'func startOpenAITextRequest(', 'func startAnthropicTextRequest(', 'func startGeminiTextRequest(']:
    source += block(marker) + '\n'

source += r'''
var checks = 0
// check(condition, message): Report failed fixture expectations with their case
// names.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
 // Stop this fixture when its named expectation does not hold.
 guard condition() else { fputs("FAILED: " + message + "\n", stderr); exit(1) }
 checks += 1
}
// body(task): Decode the captured request body for provider-specific
// assertions.
func body(_ task: RetryingDataTask) throws -> [String: Any] {
 try JSONSerialization.jsonObject(with: task.request.httpBody!) as! [String: Any]
}
let complete: (Result<String, Error>) -> Void = { _ in fatalError("Transport must not run") }
// Missing citation titles must use a readable domain instead of a provider's null placeholder.
let citationURL = "https://www.unicode.org/charts/nameslist/n_2F00.html?utm_source=openai"
for title in ["", "   ", "none", " None ", "NULL"] {
 check(webCitationLabel(title: title, url: citationURL) == "unicode.org", "Missing citation titles fall back to the source host")
}
check(webCitationLabel(title: "  Kangxi radicals  ", url: citationURL) == "Kangxi radicals", "Real source titles are retained and trimmed")
check(webCitationLabel(title: "None of the above", url: citationURL) == "None of the above", "Real titles containing a placeholder word are preserved")
let citationData = try JSONSerialization.data(withJSONObject: ["output": [["annotations": [
 ["type": "url_citation", "url": citationURL, "title": "none"]
]]]])
let citations = collectWebCitations(from: citationData)
check(citations.count == 1 && webCitationLabel(title: citations[0].title, url: citations[0].url) == "unicode.org",
      "Provider citation metadata produces a readable source label")
let serbianLatin = "Privredna komora Srbije organizuje dvodnevni vebinar. Polaznici dobijaju materijale i sertifikat."
let serbianCyrillic = "Привредна комора Србије организује дводневни вебинар. Полазници добијају материјале и сертификат."
let skipRule = "Skip any target language the source text is already entirely written in"
let translationCases = [
 translationPrompt(input: serbianLatin, targetLanguage: "ru", extraTargets: ["Serbian"], languageLevel: "a"),
 translationPrompt(input: serbianCyrillic, targetLanguage: "sr", extraTargets: ["Russian"]),
 translationPrompt(input: "Спасибо за помощь.", targetLanguage: "ru"),
 translationPrompt(input: "Good night.\n\nЛаку ноћ.", targetLanguage: "en", extraTargets: ["Serbian"]),
 translationPrompt(input: "Gift", targetLanguage: "en", extraTargets: ["German"])
]
// Check target handling for single-language, mixed, and ambiguous sources.
for prompt in translationCases {
 let marker = prompt.translationSkipMarker!
 // Check that provider adaptation and custom instructions retain translation metadata.
 for (adapted, isLocal) in [(prompt, false), (appleIntelligencePrompt(prompt), true), (promptApplyingCustomInstructions(prompt), false),
                          (promptApplyingCustomInstructions(appleIntelligencePrompt(prompt)), true)] {
  check(adapted.input == prompt.input, "Translation preserves the literal source, including Serbian script")
  check(adapted.translationSkipMarker == marker, "Adapters retain the same per-request skip marker")
  check(adapted.requestedOutputLanguageCodes == prompt.requestedOutputLanguageCodes, "Adapters retain target order and locale checks")
  // Local models use the explicit translation format without internal skip markers.
  if isLocal {
   check(adapted.appleFormat == .translation && adapted.instructions.contains("Return the full translation"), "Local translations use the explicit format and complete-source instruction")
   check(!adapted.instructions.contains(marker), "Local models do not generate internal skip markers")
  } else {
      // Remote models receive the skip rules and the request’s marker.
   check(adapted.instructions.contains(skipRule) && adapted.instructions.contains(marker), "Cloud prompts receive the skip rule and marker")
   check(adapted.instructions.contains("Different scripts of one language do not require translation"), "Script changes do not force Serbian translation")
   check(adapted.instructions.contains("meaningful passages in different languages") && adapted.instructions.contains("If the source language is uncertain"), "Mixed and ambiguous source text retains requested translations")
   // Multiple targets must keep a heading even when some targets are skipped.
   if prompt.requestedOutputLanguageCodes.count > 1 {
    check(adapted.instructions.contains("Keep the heading even if only one target remains"), "Multi-target requests label the remaining translation")
   }
  }
 }
 // All-skipped output is consumed before it can enter a result or clipboard.
 for output in [marker, "\n" + marker + "\n", "```\n" + marker + "\n```", "\"" + marker + "\""] {
  // Require internal skip output to leave the normal result path.
  do { _ = try cleanedTextTransformOutput(output, prompt: prompt); check(false, "Skip marker must not become result text") }
  // Consume the internal skip result before it reaches visible output.
  catch is TranslationSkipped { checks += 1 }
 }
 let translated = "## Русский\n\nТорговая палата Сербии организует двухдневный вебинар."
 let clean = try cleanedTextTransformOutput(translated, prompt: prompt)
 check(clean == translated, "The remaining translation retains its heading and paragraph breaks")
}
let deduplicated = translationPrompt(input: serbianLatin, targetLanguage: "ru", extraTargets: [" Russian ", "ru", "sr", "Serbian", "serbian", "", "auto"])
check(deduplicated.requestedOutputLanguageCodes == ["ru", "sr"], "Target names and codes are deduplicated without reordering")
let prefixed = translationPrompt(input: "fr: " + serbianLatin, targetLanguage: "ru", extraTargets: ["Serbian"])
check(prefixed.input == serbianLatin && prefixed.requestedOutputLanguageCodes == ["fr", "sr"], "An explicit language prefix remains a target override, not the detected source")
check(prefixed.translationSkipMarker != deduplicated.translationSkipMarker, "Skip markers are scoped to each request")
let otherMarker = try cleanedTextTransformOutput(prefixed.translationSkipMarker!, prompt: deduplicated)
check(otherMarker == prefixed.translationSkipMarker, "A marker from another request is ordinary text")
let literalMarker = try cleanedTextTransformOutput(prefixed.translationSkipMarker!, prompt: ExplanationPrompt(instructions: "Rewrite", input: "Text"))
check(literalMarker == prefixed.translationSkipMarker, "Other modes never interpret a translation marker")

// Inspect each remote adapter's real wire payload; no request is resumed.
for prompt in translationCases.prefix(2) {
 let compatible = try body(startOpenAICompatibleTextRequest(baseURL: "https://example.test", apiKey: "fixture", model: "fixture", prompt: prompt, emptyMessage: "empty", completion: complete))
 let openAI = try body(startOpenAITextRequest(apiKey: "fixture", model: "fixture", prompt: prompt, emptyMessage: "empty", research: false, completion: complete))
 let anthropic = try body(startAnthropicTextRequest(apiKey: "fixture", model: "fixture", prompt: prompt, emptyMessage: "empty", research: false, completion: complete))
 let gemini = try body(startGeminiTextRequest(apiKey: "fixture", model: "fixture", prompt: prompt, emptyMessage: "empty", research: false, completion: complete))
 // Verify the same source and skip rule in every remote provider’s payload.
 for payload in [compatible, openAI, anthropic, gemini] {
  let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
  check(json.contains(skipRule) && json.contains(prompt.translationSkipMarker!), "Every remote provider receives the skip rule and marker")
  check(json.contains(prompt.input), "Every remote provider receives the full source text")
 }
}
let astra = textProvider(for: "gpt-6-astra")
let fable = textProvider(for: "anthropic:claude-fable-5-1")
check(astra.provider == .openAI && astra.model == "gpt-6-astra", "Astra routes to OpenAI with its API ID intact")
check(fable.provider == .anthropic && fable.model == "claude-fable-5-1", "Fable 5.1 routes to Anthropic without the stored provider prefix")
check(modelSupportsWebResearch("gpt-6-astra") && modelSupportsWebResearch("anthropic:claude-fable-5-1"), "Both new models can use their provider's web research")
// Fable returns thinking blocks as well as answer text. Keep only the answer.
let fableResponse = Data(#"{"content":[{"type":"thinking","thinking":"","signature":"fixture"},{"type":"text","text":"The answer."}]}"#.utf8)
check(anthropicOutputText(from: fableResponse) == "The answer.", "Fable thinking blocks do not enter the visible answer or saved history")
let original = "Explain love."
let result = "Love is a feeling of care and closeness."
let turns = [
 ResultFollowUpTurn(question: "In context of sex?", answer: "Love can mean care, trust and closeness between partners.", modelID: "gpt", modelName: "GPT"),
 ResultFollowUpTurn(question: "And what is play?", answer: "Play means doing something for fun.", modelID: "deepseek", modelName: "DeepSeek")
]
let conversation = ResultConversation(originalRequest: original, modelID: "gpt", turns: turns)
let prepared = try resultFollowUpPrompt(question: "And what is play?", originalResult: result, conversation: conversation, mode: "explain", research: true, contextLimit: 32_000)
let expectedText = [original, result, turns[0].question, turns[0].answer, turns[1].question, turns[1].answer, "And what is play?"]
let expectedRoles = ["user", "assistant", "user", "assistant", "user", "assistant", "user"]
check(prepared.messages.map(\.content) == expectedText, "Model switching preserves the user's contextual turn and both providers' answers")
check(prepared.messages.allSatisfy { prepared.secretScanText.contains($0.content) }, "Every transmitted context message passes through the literal secret scan")
check(prepared.instructions.contains("user's most recent topic") && prepared.instructions.contains("explicit change of topic"), "Continuation guidance retains context and permits deliberate topic changes")

let history = ExplanationPrompt(instructions: prepared.instructions, input: prepared.input,
 requestedOutputLanguageCodes: ["en"], conversationMessages: prepared.messages)
let decorated = promptApplyingCustomInstructions(history)
check(decorated.conversationMessages == history.conversationMessages && decorated.requestedOutputLanguageCodes == ["en"], "Advanced custom instructions preserve conversation and locale metadata")
let local = appleIntelligencePrompt(history)
check(local.input == history.input && local.instructions == history.instructions, "Apple retains its bounded JSON fallback and follow-up instructions")

// Check both a single request and a chronological follow-up conversation.
for prompt in [ExplanationPrompt(instructions: "Explain this.", input: "A single request."), history] {
 let multi = !prompt.conversationMessages.isEmpty
 let texts = multi ? expectedText : [prompt.input]
 let roles = multi ? expectedRoles : ["user"]
 let compatible = try body(startOpenAICompatibleTextRequest(baseURL: "https://example.test", apiKey: "fixture", model: "deepseek-flash", prompt: prompt, emptyMessage: "empty", providerLabel: "DeepSeek", completion: complete))
 let compatibleMessages = compatible["messages"] as! [[String: String]]
 check(compatibleMessages.map { $0["role"]! } == ["system"] + roles, "DeepSeek receives native chronological roles; multi=\(multi)")
 check(Array(compatibleMessages.dropFirst()).map { $0["content"]! } == texts, "DeepSeek receives each complete exchange and latest user question last; multi=\(multi)")
 check(compatibleMessages.first!["content"]!.contains("Use a friendly tone."), "Custom instructions stay in the system message")

 let openAI = try body(startOpenAITextRequest(apiKey: "fixture", model: astra.model, prompt: prompt, emptyMessage: "empty", research: true, completion: complete))
 check(openAI["model"] as? String == "gpt-6-astra" && openAI["temperature"] == nil, "Astra receives its API ID without unsupported sampling options")
 // Multi-turn requests must retain every message and its role.
 if multi {
  let messages = openAI["input"] as! [[String: String]]
  check(messages.map { $0["role"]! } == roles && messages.map { $0["content"]! } == texts, "Responses receives the same chronological conversation")
 } else {
     // Single-turn requests keep the simpler string input format.
  check(openAI["input"] as? String == prompt.input, "Single-turn Responses input stays a string")
 }
 check(openAI["store"] as? Bool == false && openAI["tool_choice"] as? String == "required", "Responses retains storage and research settings")

 let anthropic = try body(startAnthropicTextRequest(apiKey: "fixture", model: fable.model, prompt: prompt, emptyMessage: "empty", research: true, completion: complete))
 // Leave thinking and tool choice to the model's defaults.
 check(anthropic["model"] as? String == "claude-fable-5-1" && anthropic["thinking"] == nil && anthropic["tool_choice"] == nil, "Fable keeps its thinking and tool defaults")
 let anthropicMessages = anthropic["messages"] as! [[String: String]]
 check(anthropicMessages.map { $0["role"]! } == roles && anthropicMessages.map { $0["content"]! } == texts, "Anthropic receives user/assistant messages, ending with user; multi=\(multi)")
 check(anthropic["system"] as? String == promptApplyingCustomInstructions(prompt).instructions && anthropic["tools"] != nil, "Anthropic retains system instructions and research")

 let gemini = try body(startGeminiTextRequest(apiKey: "fixture", model: "fixture", prompt: prompt, emptyMessage: "empty", research: true, completion: complete))
 let contents = gemini["contents"] as! [[String: Any]]
 check(contents.map { $0["role"] as! String } == roles.map { $0 == "assistant" ? "model" : $0 }, "Gemini translates assistant roles to model; multi=\(multi)")
 check(contents.map { ($0["parts"] as! [[String: String]])[0]["text"]! } == texts, "Gemini preserves all message text; multi=\(multi)")
 check(gemini["systemInstruction"] != nil && gemini["tools"] != nil, "Gemini retains system instructions and research")
}
let legacy = try resultFollowUpPrompt(question: "Shorten it.", originalResult: result, conversation: ResultConversation(originalRequest: "", modelID: "deepseek"), mode: "explain", research: false, contextLimit: 6_000)
check(legacy.messages.first?.role == .user && legacy.messages.allSatisfy { !$0.content.isEmpty }, "Legacy results begin with a nonempty user turn")
print("\(checks) provider conversation and translation checks passed; no network or credentials used")
'''

with tempfile.TemporaryDirectory(prefix='langmin-conversation-payloads-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', *swift_fixture_args(), '-O', '-module-cache-path', cache, '-target', f'{platform.machine()}-apple-macos14.0',
                    str(folder / 'main.swift'), str(app_path('ResultConversation.swift')),
                    '-o', str(folder / 'tests')], check=True)
    subprocess.run([str(folder / 'tests')], check=True, timeout=30)
