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
var fixturePreferences = AppPreferences()
func loadAppPreferences() -> AppPreferences { fixturePreferences }
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
 let totalTimeout: TimeInterval?
 // init(request, [totalTimeout], completion): Capture the request without starting transport or
 // calling its completion.
 init(request: URLRequest, totalTimeout: TimeInterval? = nil, completion: @escaping (Data?, URLResponse?, Error?) -> Void) { self.request = request; self.totalTimeout = totalTimeout }
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
               'func appleIntelligencePrompt(', 'func cloudThinkingOptions(', 'func cloudThinkingSelection(', 'func cloudThinkingForRequest(', 'func startOpenAICompatibleTextRequest(',
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
// Every cloud adapter must connect its request to a total deadline.
for dictionary in [false, true] {
 var prompt = ExplanationPrompt(instructions: "Define the word.", input: "Karate")
 prompt.appleFormat = dictionary ? .dictionary : .text
 let tasks = [
  try startOpenAICompatibleTextRequest(baseURL: "https://example.test", apiKey: "fixture", model: "fixture", prompt: prompt, emptyMessage: "empty", completion: complete),
  try startOpenAITextRequest(apiKey: "fixture", model: "fixture", prompt: prompt, emptyMessage: "empty", research: false, completion: complete),
  try startAnthropicTextRequest(apiKey: "fixture", model: "fixture", prompt: prompt, emptyMessage: "empty", completion: complete),
  try startGeminiTextRequest(apiKey: "fixture", model: "fixture", prompt: prompt, emptyMessage: "empty", completion: complete)
 ]
 for task in tasks {
  let limit: TimeInterval = dictionary ? 60 : speechRequestTimeout
  check(task.totalTimeout == limit && task.request.timeoutInterval == limit, "Cloud adapters enforce the complete request deadline")
 }
}

// DeepSeek Explain requests enforce JSON; prose modes and custom endpoints do not.
for label in ["DeepSeek", "Grok", "Custom endpoint"] {
 for model in ["deepseek-flash", "deepseek-v4-pro"] {
  for format: ExplanationPrompt.LocalFormat in [.explanation, .dictionary, .text, .translation, .proofread] {
   var prompt = ExplanationPrompt(instructions: "Return JSON with title and explanation string fields.", input: "What is love?")
   prompt.appleFormat = format
   let payload = try body(startOpenAICompatibleTextRequest(baseURL: "https://example.test", apiKey: "fixture", model: model,
                     prompt: prompt, emptyMessage: "empty", providerLabel: label, completion: complete))
   if label == "DeepSeek" && format == .explanation {
    check((payload["response_format"] as? [String: String]) == ["type": "json_object"], "DeepSeek Explain enables JSON Output")
   } else {
    check(payload["response_format"] == nil, "Other tasks and endpoints retain their existing output format")
   }
  }
 }
}
// Automatic uses Low only for initial proofreading and rewriting. Other
// tasks and follow-ups omit effort; explicit choices override that policy.
let transforms: [(String, ExplanationPrompt.LocalSourceTask)] = [
 ("Proofread", .proofread), ("Rephrase", .rephrase), ("Humanize", .humanize),
 ("Concise", .concise), ("Elaborate", .elaborate), ("Summarize", .summarize),
 ("Translate", .translate)
]
var latencyCases: [(String, ExplanationPrompt, Bool)] = []
for (name, task) in transforms {
 var prompt = ExplanationPrompt(instructions: "Transform the source without adding facts.", input: "Please sent the report tomorow.")
 prompt.appleSourceTask = task
 latencyCases.append((name, prompt, ["Proofread", "Rephrase", "Humanize", "Concise", "Elaborate"].contains(name)))
 // A follow-up can change tasks even if source-transform metadata was retained.
 prompt.conversationMessages = [TextConversationMessage(role: .user, content: "Why is this correct?")]
 latencyCases.append((name + " follow-up", prompt, false))
}
// Real translation prompts must reach the same policy without changing target metadata.
latencyCases.append(("Translation with two targets", translationCases[0], false))
for format: ExplanationPrompt.LocalFormat in [.dictionary, .explanation, .text] {
 var prompt = ExplanationPrompt(instructions: "Answer the question.", input: "What is love?")
 prompt.appleFormat = format
 latencyCases.append(("\(format)", prompt, false))
 // A dictionary result can also lead to an open-ended follow-up question.
 prompt.conversationMessages = [TextConversationMessage(role: .user, content: "Explain the history.")]
 latencyCases.append(("\(format) follow-up", prompt, false))
}
// Explicit choices apply to all tasks, including research and follow-ups.
for (name, original, automaticLow) in latencyCases {
 for choice in ExplanationPrompt.Thinking.allCases {
  var prompt = original
  prompt.thinking = choice
  latencyCases.append((name + " " + choice.rawValue, prompt, automaticLow))
 }
}
for label in ["DeepSeek", "Grok", "Custom endpoint"] {
 for model in ["deepseek-v4-pro", "deepseek-flash", "grok-4.5", "grok-4.6", "grok-4.7", "grok-4", "custom-model"] {
  for (name, prompt, automaticLow) in latencyCases {
   let payload = try body(startOpenAICompatibleTextRequest(baseURL: "https://example.test", apiKey: "fixture", model: model, prompt: prompt, emptyMessage: "empty", providerLabel: label, completion: complete))
   let supportsThinkingToggle = label == "DeepSeek" && ["deepseek-v4-pro", "deepseek-flash"].contains(model)
   let supportsLowEffort = label == "Grok" && ["grok-4.5", "grok-4.6", "grok-4.7"].contains(model)
   let automatic = prompt.thinking == nil || prompt.thinking == .automatic
   let sendsEffort = !automatic || automaticLow
   let deepSeekOff = prompt.thinking == .off
   let thinkingType: String? = supportsThinkingToggle && sendsEffort ? (deepSeekOff ? "disabled" : "enabled") : nil
   check((payload["thinking"] as? [String: String])?["type"] == thinkingType, "\(name): DeepSeek Off is distinct from Low thinking")
   var compatibleEffort: String?
   if supportsThinkingToggle && sendsEffort && !deepSeekOff {
    compatibleEffort = automatic || prompt.thinking == .low ? "low" : "high"
   } else if supportsLowEffort && sendsEffort {
    compatibleEffort = prompt.thinking == .medium ? "medium" : prompt.thinking == .high ? "high" : "low"
   }
   check(payload["reasoning_effort"] as? String == compatibleEffort, "\(name): Compatible adapters send only distinct supported levels")
   check(!["xhigh", "max"].contains(payload["reasoning_effort"] as? String ?? ""), "Effort above High is never requested")
   let previouslyUsedLargerBudget = prompt.appleSourceTask != nil || prompt.appleFormat != .dictionary || !prompt.conversationMessages.isEmpty
   let preservesOutputBudget = deepSeekOff && supportsThinkingToggle && previouslyUsedLargerBudget
   check((payload["max_tokens"] as? Int) == (preservesOutputBudget ? 65_536 : nil), "\(name): Disabling DeepSeek thinking must not lower the existing output budget")
   let messages = payload["messages"] as! [[String: String]]
   check(Array(messages.dropFirst()) == prompt.chatMessages, "\(name): Fast settings preserve every input and conversation message")
  }
 }
}
// Exercise actual Responses and Messages bodies for each task, endpoint and
// research setting. Models without the supported effort control remain unchanged.
let openAILatencyModels: [(String, Bool)] = [
 ("gpt-6-astra", true), ("gpt-6-sol", true), ("gpt-6-luna", true),
 ("gpt-5.6-sol", true), ("gpt-5.6-terra", true), ("gpt-5.6-luna", true), ("gpt-5.5", true),
 ("gpt-5.4", false), ("gpt-5.4-mini", false), ("gpt-5.4-nano", false),
 ("gpt-4.1", false), ("gpt-4.1-mini", false), ("custom-model", false)
]
let claudeLatencyModels: [(String, Bool)] = [
 ("claude-fable-5-1", true), ("claude-fable-5", true),
 ("claude-opus-5-5", true), ("claude-sonnet-5", true),
 ("claude-haiku-4-5", false), ("custom-model", false)
]
for customEndpoint in [false, true] {
 fixturePreferences.openAIEndpointOverride = customEndpoint ? "https://custom.test/responses" : ""
 fixturePreferences.anthropicEndpointOverride = customEndpoint ? "https://custom.test/messages" : ""
 for research in [false, true] {
  for (name, prompt, automaticLow) in latencyCases {
   for (model, supportsEffort) in openAILatencyModels {
    let payload = try body(startOpenAITextRequest(apiKey: "fixture", model: model, prompt: prompt, emptyMessage: "empty", research: research, completion: complete))
    let automatic = prompt.thinking == nil || prompt.thinking == .automatic
    let requested: String? = automatic ? (automaticLow ? "low" : nil)
        : prompt.thinking == .off && model == "gpt-6-astra" ? "low" : prompt.thinking?.apiEffort
    let expected: [String: String]? = supportsEffort && !customEndpoint ? requested.map { ["effort": $0] } : nil
    check((payload["reasoning"] as? [String: String]) == expected, "\(name): Responses effort is scoped to supported models, tasks and endpoints")
    check(payload["instructions"] as? String == promptApplyingCustomInstructions(prompt).instructions, "\(name): Responses effort preserves task and custom instructions")
    // Inspect both Responses input shapes so no source text is lost.
    if prompt.conversationMessages.isEmpty {
     check(payload["input"] as? String == prompt.input, "\(name): Responses effort preserves the full source")
    } else {
     // Follow-ups keep every role and message in their original order.
     check(payload["input"] as? [[String: String]] == prompt.chatMessages, "\(name): Responses effort preserves the conversation")
    }
    check(payload["store"] as? Bool == false && (payload["tools"] != nil) == research && payload["service_tier"] == nil, "\(name): Responses preserves storage, research and service tier")
   }
   for (model, supportsEffort) in claudeLatencyModels {
    let payload = try body(startAnthropicTextRequest(apiKey: "fixture", model: model, prompt: prompt, emptyMessage: "empty", research: research, completion: complete))
    let automatic = prompt.thinking == nil || prompt.thinking == .automatic
    let requested: String? = automatic ? (automaticLow ? "low" : nil)
        : prompt.thinking == .off ? "low" : prompt.thinking?.apiEffort
    let expected: [String: String]? = supportsEffort && !customEndpoint ? requested.map { ["effort": $0] } : nil
    check((payload["output_config"] as? [String: String]) == expected, "\(name): Claude effort is scoped to supported models, tasks and endpoints")
    check(payload["system"] as? String == promptApplyingCustomInstructions(prompt).instructions && payload["messages"] as? [[String: String]] == prompt.chatMessages, "\(name): Claude effort preserves instructions and all source messages")
    check(payload["max_tokens"] as? Int == 8192 && payload["thinking"] == nil && (payload["tools"] != nil) == research && payload["service_tier"] == nil, "\(name): Claude retains its output budget, thinking compatibility, research and service tier")
   }
  }
 }
}
fixturePreferences = AppPreferences()
let capabilities: [(TextModelProvider, String, [String])] = [
 (.openAI, "gpt-6-astra", ["automatic", "low", "medium", "high"]),
 (.openAI, "gpt-6-sol", ["automatic", "off", "low", "medium", "high"]),
 (.openAI, "gpt-6-luna", ["automatic", "off", "low", "medium", "high"]),
 (.openAI, "gpt-5.6-sol", ["automatic", "off", "low", "medium", "high"]),
 (.openAI, "gpt-5.6-terra", ["automatic", "off", "low", "medium", "high"]),
 (.openAI, "gpt-5.6-luna", ["automatic", "off", "low", "medium", "high"]),
 (.openAI, "gpt-5.5", ["automatic", "off", "low", "medium", "high"]),
 (.anthropic, "claude-fable-5-1", ["automatic", "low", "medium", "high"]),
 (.anthropic, "claude-fable-5", ["automatic", "low", "medium", "high"]),
 (.anthropic, "claude-opus-5-5", ["automatic", "low", "medium", "high"]),
 (.anthropic, "claude-sonnet-5", ["automatic", "low", "medium", "high"]),
 (.deepSeek, "deepseek-flash", ["automatic", "off", "low", "high"]),
 (.deepSeek, "deepseek-v4-pro", ["automatic", "off", "low", "high"]),
 (.grok, "grok-4.5", ["automatic", "low", "medium", "high"]),
 (.grok, "grok-4.6", ["automatic", "low", "medium", "high"]),
 (.grok, "grok-4.7", ["automatic", "low", "medium", "high"])
]
for (provider, model, options) in capabilities {
 check(cloudThinkingOptions(provider: provider, model: model, preferences: fixturePreferences).map(\.rawValue) == options,
       "\(model): Menu exposes only documented distinct levels, without Extra High or Maximum")
 for saved in [nil, "", "automatic", "less", "more", "off", "low", "medium", "high", "xhigh", "max", "future-value"] as [String?] {
  let expected: String
  switch saved {
  case "more", "high": expected = "high"
  case "xhigh": expected = "high"
  case "medium": expected = options.contains("medium") ? "medium" : "high"
  case "off": expected = options.contains("off") ? "off" : "low"
  case "low": expected = "low"
  case "less": expected = provider == .deepSeek ? "off" : "low"
  default: expected = "automatic"
  }
  check(cloudThinkingSelection(saved, provider: provider, model: model, preferences: fixturePreferences)?.rawValue == expected,
        "\(model): Saved choices migrate and remain compatible after a model switch")
 }
}
fixturePreferences = AppPreferences()
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
 // Effort uses the app default; no unsupported thinking toggle or tool choice is added.
 check(anthropic["model"] as? String == "claude-fable-5-1" && anthropic["thinking"] == nil && anthropic["tool_choice"] == nil, "Fable uses supported effort controls without a thinking toggle or forced tools")
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
