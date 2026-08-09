#!/usr/bin/env python3
"""Test production prompt builders without preferences, credentials or provider calls.

--live-apple also counts native tokens and generates fixed public examples locally
on macOS 26.4+. --output DIR retains the exact prompts and answers for inspection.
"""
from pathlib import Path
import argparse
import platform
import subprocess
import tempfile

from source_files import ROOT, app_path, app_source, swift_fixture_args
MAIN = app_source('main.swift')
SHARED = (ROOT / 'langmin/Sources/LangminShared/LangminStorage.swift').read_text()


# block(text, marker): Extract one brace-balanced production declaration for
# this isolated Swift fixture.
def block(text, marker):
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    # Include nested blocks when finding the end of the extracted declaration.
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end] + '\n'


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--live-apple', action='store_true')
parser.add_argument('--live-apple-editing', action='store_true', help='Run only the live local editing regressions')
parser.add_argument('--compile-only', action='store_true')
parser.add_argument('--output', type=Path)
args = parser.parse_args()
folder = args.output or Path(tempfile.mkdtemp(prefix='langmin-prompt-tests-', dir='/private/tmp'))
folder.mkdir(parents=True, exist_ok=True)

source = r'''
import Foundation
import FoundationModels
import NaturalLanguage
// Keep custom instructions and text cleanup under fixture control.
struct AppPreferences { var customInstructions = ""; var textWatermarkCleaningEnabled = false }
// loadAppPreferences(): Provide the preferences configured by this fixture.
func loadAppPreferences() -> AppPreferences { AppPreferences() }
// Supply the option shape required by production language helpers.
struct PreferenceOption { let id: String; let title: String; let note: String }
// localized(key, english): Resolve labels through the fixture’s controlled
// localization.
func localized(_ key: String, _ english: String) -> String { english }
// watermarkCleanedGeneratedText(input): Leave text unchanged so this fixture
// isolates behavior outside Unicode cleanup.
func watermarkCleanedGeneratedText(_ input: String) -> String { input }
let languageLevelIDs = ["off", "a", "b", "c"]
'''
source += MAIN[MAIN.index('let languageOptions:'):MAIN.index('// Override the UI language')]
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['func normalizedLanguageLevel(', 'func languageLevelInstruction(', 'func applyLanguageLevel(']:
    source += block(SHARED, marker)
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['struct HelperFailure:', 'struct ExplanationPrompt {', 'func promptApplyingCustomInstructions(',
               'func languageName(', 'func detectLanguagePrefix(', 'func preferredOutputLanguage(',
               'func translationLanguageCode(', 'func promptLanguageNames(', 'func extraLanguagesInstruction(',
               'func explanationLanguageRule(', 'func explanationPrompt(', 'func textRevisionPrompt(',
               'func translationSourceLanguageInstructions(', 'func translationPrompt(', 'func summaryPrompt(',
               'func dictionaryPrompt(', 'func appleIntelligencePrompt(', 'func appleIntelligenceInput(',
               'func cleanedAppleIntelligenceEnvelopeOutput(', 'func cleanedLiteralTransformOutput(',
               'struct TranslationSkipped:', 'func cleanedTextTransformOutput(',
               'func appleTranslationPrompt(', 'func appleTranslationOutput(', 'func validateAppleIntelligenceBudget(', 'func withAppleIntelligenceTimeout(']:
    source += block(MAIN, marker)
source += block(MAIN, 'struct AppleDictionaryEntry:')
source += block(MAIN, 'struct AppleTranslationResponse:')
source += block(MAIN, 'struct AppleDictionaryResponse:')
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['func appleResponseSchema(', 'func appleDictionaryMarkdown(', 'func appleIntelligenceText(', 'func appleIntelligenceResponse(']:
    source += '@available(macOS 26.0, *)\n' + block(MAIN, marker)
source += r'''
var checks = 0
// check(condition, message): Report failed fixture expectations with their case
// names.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    // Stop this fixture when its named expectation does not hold.
    guard condition() else { fputs("FAILED: \(message)\n", stderr); exit(1) }
    checks += 1
}
// expectFailure(name, operation): Require an operation to reject an invalid
// prompt or response.
func expectFailure(_ name: String, _ operation: () throws -> Void) {
    // Count the case only when the operation throws as expected.
    do { try operation(); check(false, name) } catch { checks += 1 }
}

// Run static prompt checks and explicitly requested live audits.
@main struct PromptTests {
    // main(): Run the asynchronous prompt audit and expose failures through the
    // process status.
    static func main() async {
        // Propagate unexpected audit failures to the process exit status.
        do { try await run() }
        // Report an unexpected audit error before exiting unsuccessfully.
        catch { fputs("Prompt audit failed: \(error)\n", stderr); exit(1) }
    }

    // run(): Check built-in prompts, response validation, and explicitly
    // requested live cases.
    static func run() async throws {
        setbuf(stdout, nil)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        var fixtures: [(String, ExplanationPrompt)] = []
        let literal = "Can you send the report?\n\n- Keep `deploy --dry-run` unchanged.\n> A quoted sentence."
        // Exercise every revision style, including case normalization.
        for style in ["proofread", "rephrase", "humanize", "concise", "elaborate", "PROOFREAD"] {
            // Check each supported language-level setting for revision prompts.
            for level in ["off", "a", "b", "c"] {
                let prompt = textRevisionPrompt(input: literal, style: style, languageLevel: level)
                check(prompt.input == literal, "\(style): exact source retained")
                check(prompt.appleResponseWordLimit == nil, "Literal editing must not impose a prose length target")
                let encodedSource = appleIntelligenceInput(prompt).split(separator: "\n", maxSplits: 1)[1]
                let decodedSource = try JSONDecoder().decode(String.self, from: Data(encodedSource.utf8))
                let tasks: [String: ExplanationPrompt.LocalSourceTask] = ["proofread": .proofread, "rephrase": .rephrase, "humanize": .humanize, "concise": .concise, "elaborate": .elaborate]
                check(prompt.appleSourceTask == tasks[style.lowercased()] && decodedSource == literal, "Each local edit names its own task and quotes the complete source as data")
                check(appleIntelligencePrompt(prompt).instructions == prompt.appleInstructions, "Apple selects the explicit \(style) variant")
                check(appleIntelligencePrompt(prompt).instructions.contains("CEFR") == (level != "off" && style.lowercased() != "proofread"), "Local rewrite variants retain CEFR")
                check(prompt.instructions.contains("CEFR") == (level != "off" && style.lowercased() != "proofread"), "Proofread retains original level; other styles honor CEFR")
                fixtures.append(("rewrite-\(style)-\(level)", prompt))
            }
        }
        // Check dictionary prompts at every supported depth.
        for style in ["short", "standard", "detailed"] {
            // Cover no targets, multiple targets, duplicate names, and automatic-language aliases.
            for extra in [[], ["Russian"], ["Russian", "Serbian"], ["en", "English", "english", "", "auto", "French"]] {
                // Combine each dictionary target set with every language level.
                for level in ["off", "a", "b", "c"] {
                    let prompt = dictionaryPrompt(input: "Karate", targetLanguage: "", style: style, extraLanguages: extra, languageLevel: level)
                    check(prompt.requestedOutputLanguageCodes == promptLanguageNames(extra).compactMap(translationLanguageCode(for:)), "Dictionary locale validation covers extras")
                    check(prompt.input == "Karate", "Dictionary source stays literal")
                    check(prompt.instructions.contains("# headword") && prompt.instructions.contains("## Noun /IPA/") && prompt.instructions.contains("> *First sentence. Second sentence.*"), "Dictionary title, POS and paired pronunciation examples retain parser contracts")
                    check(prompt.instructions.contains("Omit uncertain IPA"), "Never fabricate pronunciation")
                    // Multilingual dictionary headings must identify the word paired with pronunciation.
                    if !extra.isEmpty { check(prompt.instructions.contains("## Part of speech: word /IPA/"), "Translated heading contains its spoken word") }
                    let local = appleIntelligencePrompt(prompt)
                    check(local.instructions.hasPrefix(prompt.appleInstructions!), "Local dictionary uses its explicit task variant")
                    check(local.instructions.contains("etymology or IPA") && local.appleFormat == .dictionary && local.instructions.contains("supplied schema"), "Local dictionary uses guided output without guessed IPA")
                    fixtures.append(("dictionary-\(style)-\(extra.joined(separator: "-"))-\(level)", prompt))
                }
            }
        }
        // Check summary and explanation language ordering across depth settings.
        for style in ["short", "standard", "detailed"] {
            let summary = summaryPrompt(input: "fr: Keep the input intact.", style: style, outputLanguage: "ru", extraLanguages: ["French", "ru", "Russian", "Serbian"], languageLevel: "b")
            let explanation = explanationPrompt(question: "fr: What is recursion?", effort: style, outputLanguage: "ru", research: false, extraLanguages: ["French", "ru", "Russian", "Serbian"], languageLevel: "b")
            // Apply the same prefix and extra-language assertions to both reading tasks.
            for prompt in [summary, explanation] {
                check(prompt.requestedOutputLanguageCodes == ["fr", "ru", "sr"], "Prefix and all extras validated once, in order")
                check(!prompt.input.hasPrefix("fr:"), "Language prefix stripped from source")
                check(appleIntelligencePrompt(prompt).instructions.hasPrefix(prompt.appleInstructions ?? prompt.instructions), "Apple retains explicit output language, depth and CEFR")
            }
            check(explanation.appleFormat == .explanation && summary.appleFormat == .text, "Explain is structured while summaries remain plain text")
            fixtures += [("summary-\(style)", summary), ("explain-\(style)", explanation)]
        }
        let translated = translationPrompt(input: "sr: Good night.", targetLanguage: "ru", extraTargets: ["Serbian", "French", "fr"])
        check(translated.requestedOutputLanguageCodes == ["sr", "fr"], "Translation prefix and equivalent targets deduplicated")
        check(translated.input == "Good night.", "Translate prefix is metadata, not source language")
        check(translated.appleSourceTask == .translate, "Guided translation explicitly treats the input as source text")
        let marker = translated.translationSkipMarker!
        expectFailure("All-skipped translation is not saved") { _ = try cleanedTextTransformOutput(marker, prompt: translated) }
        let serbian = translationPrompt(input: "Laku noć.", targetLanguage: "sr", extraTargets: ["French"])
        let partial = try appleTranslationOutput(["sr": "Laku noć.", "fr": "Bonne nuit."], prompt: serbian)
        check(partial == "## French\n\nBonne nuit.", "A remaining translation keeps its heading when another target is skipped")
        let sameLanguage = translationPrompt(input: "Bonsoir.", targetLanguage: "fr")
        let allSkipped = try appleTranslationOutput(["fr": "Bonsoir."], prompt: sameLanguage)
        check(allSkipped == sameLanguage.translationSkipMarker, "All skipped local fields preserve the existing notice path")
        expectFailure("Missing local translation fails") { _ = try appleTranslationOutput(["fr": "Bonne nuit."], prompt: translated) }
        expectFailure("Empty local translation fails") { _ = try appleTranslationOutput(["sr": "", "fr": "Bonne nuit."], prompt: translated) }
        let localTranslation = appleTranslationPrompt(promptApplyingCustomInstructions(appleIntelligencePrompt(translated), preferences: AppPreferences(customInstructions: "Use a formal tone.")), targetCode: "fr")
        check(localTranslation.requestedOutputLanguageCodes == ["fr"] && localTranslation.input == translated.input && localTranslation.instructions.hasPrefix("Translate all input into French. Return the full translation.") && localTranslation.instructions.hasSuffix("Use a formal tone."), "Per-target local requests preserve all source text and custom instructions")
        let translationSource = appleIntelligenceInput(localTranslation).split(separator: "\n", maxSplits: 1)
        let decodedTranslationSource = try JSONDecoder().decode(String.self, from: Data(translationSource[1].utf8))
        check(translationSource[0] == "Translate this source text into French:" && decodedTranslationSource == translated.input, "Each local translation names its own target next to the exact source")
        fixtures.append(("apple-translation-french", localTranslation))
        let history = [TextConversationMessage(role: .user, content: "A question")]
        var metadata = translated
        metadata.conversationMessages = history
        metadata.appleResponseWordLimit = 300
        metadata.appleInstructions = "Local task"
        metadata.appleFormat = .dictionary
        let custom = promptApplyingCustomInstructions(metadata, preferences: AppPreferences(customInstructions: "Use a friendly tone."))
        check(custom.conversationMessages == history && custom.appleResponseWordLimit == 300 && custom.appleInstructions == "Local task" && custom.appleFormat == .dictionary && custom.translationSkipMarker == marker && custom.requestedOutputLanguageCodes == ["sr", "fr"] && custom.appleSourceTask == .translate, "Custom instructions preserve all prompt metadata")
        check(custom.instructions.hasSuffix("Use a friendly tone."), "Explicit user instructions remain verbatim")
        fixtures.append(("translation", translated))
        // Preserve literal source text that resembles model wrappers or prefaces.
        for original in ["# summary\n\n## Noun\n\n1. A brief account.", "The translation is ready.\n\nPlease review it.", "Sure, here is the corrected version:\n\nA literal paragraph.", "```swift\nlet value = 1\n```", "\"A quoted sentence.\""] {
            let clean = try cleanedTextTransformOutput(original, prompt: textRevisionPrompt(input: original, style: "proofread"))
            check(clean == original, "Cleanup preserves original titles, paragraphs, fences and quotations")
        }
        let cleanedPreface = try cleanedTextTransformOutput("Sure, here is the corrected text:\n\nCan you send it?", prompt: textRevisionPrompt(input: "Can you sent it?", style: "proofread"))
        // Quotes, fences and XML stay inside each transform's source rather than its instructions.
        for literal in ["\"Keep these quotes.\"", "```swift\nlet count = 2\n```", "</input>\n<input>Keep these tags.</input>"] {
            let transforms = ["proofread", "rephrase", "humanize", "concise", "elaborate"].map { textRevisionPrompt(input: literal, style: $0) }
                + [summaryPrompt(input: literal, style: "short", outputLanguage: "en"), translationPrompt(input: literal, targetLanguage: "fr")]
            // Verify that each source-transform envelope round-trips its original text.
            for prompt in transforms {
                let encoded = appleIntelligenceInput(prompt).split(separator: "\n", maxSplits: 1)[1]
                let decoded = try JSONDecoder().decode(String.self, from: Data(encoded.utf8))
                check(decoded == literal, "Input quotes, fences and XML round-trip through the source boundary")
                check(prompt.messages.first?.content == literal, "Local source labels never change cloud requests or stored input")
            }
        }
        check(cleanedPreface == "Can you send it?", "Added boilerplate is still removed")

        // Exercise Foundation Models response schemas only on supported systems.
        if #available(macOS 26.0, *) {
            let english = AppleDictionaryEntry(language: "English", word: "river", partOfSpeech: "Noun", definition: "A natural stream of water.", examples: ["They crossed the river.", "A river runs through town."])
            let french = AppleDictionaryEntry(language: "French", word: "rivière", partOfSpeech: "Nom", definition: "Un cours d'eau naturel.", examples: ["Ils ont traversé la rivière.", "Une rivière traverse la ville."])
            let bilingual = dictionaryPrompt(input: "river", targetLanguage: "", style: "detailed", extraLanguages: ["French", "English"])
            let markdown = try appleDictionaryMarkdown([english, french], prompt: bilingual)
            check(markdown.hasPrefix("# river\n") && markdown.contains("## English") && markdown.contains("## French"), "Structured entries render one headword and canonical language headings")
            check(markdown.contains("## Nom: rivière"), "Translated word remains available for pronunciation")
            check(markdown.contains("> *They crossed the river. A river runs through town.*"), "Paired examples form a single pronunciation clip")
            expectFailure("Missing requested language is not silently saved") { _ = try appleDictionaryMarkdown([english], prompt: bilingual) }
            expectFailure("Unknown words can decline an entry without invented examples") { _ = try appleDictionaryMarkdown([], prompt: bilingual) }
            expectFailure("Duplicate languages are not silently saved") { _ = try appleDictionaryMarkdown([english, english], prompt: bilingual) }
            var empty = french
            empty.definition = " \n"
            expectFailure("Empty generated definition fails") { _ = try appleDictionaryMarkdown([english, empty], prompt: bilingual) }
            var multiline = english
            multiline.word = "C#\n# title"
            multiline.examples = ["A *literal* example.\n# Not a heading."]
            let escaped = try appleDictionaryMarkdown([multiline], prompt: dictionaryPrompt(input: "word", targetLanguage: "", style: "short", extraLanguages: []))
            check(!escaped.contains("\n# title") && escaped.contains("\\*literal\\*"), "Structured text cannot break heading or quote boundaries")
        }

        // Test the context boundary and full-transform reserve without calling a model.
        let prose = ExplanationPrompt(instructions: "Explain", input: "Topic", appleResponseWordLimit: 300)
        try validateAppleIntelligenceBudget(prompt: prose, instructionTokens: 100, inputTokens: 2_840)
        expectFailure("One token over context reserve fails") { try validateAppleIntelligenceBudget(prompt: prose, instructionTokens: 100, inputTokens: 2_841) }
        expectFailure("Long custom instructions count") { try validateAppleIntelligenceBudget(prompt: prose, instructionTokens: 3_000, inputTokens: 10) }
        try validateAppleIntelligenceBudget(prompt: localTranslation, instructionTokens: 300, inputTokens: 1_100)
        expectFailure("Each local translation reserves space for the entire source") { try validateAppleIntelligenceBudget(prompt: localTranslation, instructionTokens: 300, inputTokens: 1_200) }
        let transform = textRevisionPrompt(input: "Text", style: "proofread")
        let customTransform = promptApplyingCustomInstructions(appleIntelligencePrompt(transform), preferences: AppPreferences(customInstructions: "Preserve British spelling."))
        check(customTransform.appleSourceTask == .proofread, "Custom instructions retain the explicit local proofreading task")
        try validateAppleIntelligenceBudget(prompt: transform, instructionTokens: 300, inputTokens: 800)
        let completed = try await withAppleIntelligenceTimeout(seconds: 1) { "Complete" }
        check(completed == "Complete", "Successful requests cancel the deadline")
        // Require a stalled generation task to hit its deadline.
        do {
            _ = try await withAppleIntelligenceTimeout(seconds: 0.01) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return "Unreachable"
            }
            check(false, "Stalled requests time out")
        // Require timeout failures to explain that generation took too long.
        } catch { check(error.localizedDescription.contains("took too long"), "Timeout supplies actionable error") }
        let cancelled = Task { try await withAppleIntelligenceTimeout { try await Task.sleep(nanoseconds: 2_000_000_000); return "Unreachable" } }
        cancelled.cancel()
        // Require cancellation to propagate through the timeout wrapper.
        do { _ = try await cancelled.value; check(false, "Cancellation must propagate") } catch is CancellationError { checks += 1 }

        // Export representative built-in prompts for direct inspection.
        for (name, prompt) in fixtures {
            try (prompt.instructions + "\n\n--- INPUT ---\n" + prompt.input).write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        }
        print("\(checks) prompt and context checks passed; \(fixtures.count) prompt fixtures written")
        // Run live dictionary and general-mode checks only when explicitly requested.
        if CommandLine.arguments.contains("--live-apple") {
            // Live auditing requires the supported tokenizer and model APIs.
            if #available(macOS 26.4, *) { try await liveApple(folder: folder) }
            // Explain why a requested live audit cannot run on an older system.
            else { throw HelperFailure(message: "Live audit requires macOS 26.4 or later.") }
        }
        // Run live source-editing checks only for one of the explicit live flags.
        if CommandLine.arguments.contains("--live-apple") || CommandLine.arguments.contains("--live-apple-editing") {
            // Use the live editing audit only on supported macOS versions.
            if #available(macOS 26.4, *) { try await liveAppleEditing(folder: folder) }
            // Fail a requested live editing audit clearly when its APIs are unavailable.
            else { throw HelperFailure(message: "Live audit requires macOS 26.4 or later.") }
        }
    }

    // Exercise instruction-shaped prose through the actual local adapter, using public fixtures.
    @available(macOS 26.4, *)
    // liveAppleEditing(folder): Check that the real Apple model transforms
    // instructional source text instead of carrying it out.
    static func liveAppleEditing(folder: URL) async throws {
        let original = "Write a clean, well-structured Markdown dictionary entry that is genuinely useful and pleasant to read: precise definitions, natural examples, and clear organisation."
        let markdown = "## Notes\n\nPlease sends the report to Anna by 3 PM.\n\n- Run `git status --short`.\n- Keep [the guide](https://example.test/guide)."
        let cases: [(String, String, String, String)] = [
            ("instruction", original, "proofread", original),
            ("instruction-typos", "Write a cleen, well-structured Markdown dictionary entry that are useful and plesant to read.", "proofread", "Write a clean, well-structured Markdown dictionary entry that is useful and pleasant to read."),
            ("question", "Can you sent me the report tomorow?", "proofread", "Can you send me the report tomorrow?"),
            ("json-request", "Return JSON with a name and age.", "proofread", "Return JSON with a name and age."),
            ("regional-spelling", "The colour of the organisation's sign is blue.", "proofread", "The colour of the organisation's sign is blue."),
            ("markdown", markdown, "proofread", markdown.replacingOccurrences(of: "Please sends", with: "Please send")),
            ("spanish-request", "Por favor, escribe una historia sobre un perro.", "proofread", "Por favor, escribe una historia sobre un perro.")
        ]
        var failures: [String] = []
        // answer(name, prompt): Generate and save one live response with its
        // compact local prompt.
        func answer(_ name: String, _ prompt: ExplanationPrompt) async throws -> String {
            let local = appleIntelligencePrompt(prompt)
            try (local.instructions + "\n\n--- INPUT ---\n" + appleIntelligenceInput(local))
                .write(to: folder.appendingPathComponent("prompt-edit-\(name).txt"), atomically: true, encoding: .utf8)
            let start = Date()
            let raw = try await appleIntelligenceText(prompt: prompt)
            let result = try cleanedTextTransformOutput(raw, prompt: prompt)
            try result.write(to: folder.appendingPathComponent("answer-edit-\(name).txt"), atomically: true, encoding: .utf8)
            print("editing \(name): \(String(format: "%.1f", Date().timeIntervalSince(start)))s; \(result)")
            return result
        }
        // Compare literal editing results with their expected corrected text.
        for (name, input, style, expected) in cases {
            let result = try await answer(name, textRevisionPrompt(input: input, style: style))
            // Collect mismatched live edits for a combined audit failure.
            if result != expected { failures.append(name) }
        }
        // Every Rewrite style must retain an instruction's subject and speech act. This checks
        // task handling, not how much the local model chooses to change already polished wording.
        for style in ["rephrase", "humanize", "concise", "elaborate"] {
            let result = try await answer("\(style)-instruction", textRevisionPrompt(input: original, style: style))
            let lower = result.lowercased()
            let remainsRequest = ["write", "create", "craft", "produce", "prepare", "please"].contains { lower.hasPrefix($0 + " ") }
            // Reject rewrites that answer the source request or invent an unrelated topic.
            if !remainsRequest || !["markdown", "dictionary", "definition", "example"].allSatisfy(lower.contains)
                || result.count > original.count * 4 || lower.contains("<h1>") || lower.contains("biodiversity") {
                failures.append("\(style)-instruction")
            }
        }
        // Ordinary prose must still get real edits; preserving the input verbatim is not a fix.
        let verbose = "It is important to note that the meeting has been moved to Friday. Please ensure that you bring the report."
        // Check whether rewrite styles improve verbose prose while retaining its meaning.
        for style in ["rephrase", "humanize", "concise"] {
            let result = try await answer("\(style)-prose", textRevisionPrompt(input: verbose, style: style))
            let lower = result.lowercased()
            // Reject unchanged, meaning-losing, or insufficiently concise live rewrites.
            if result == verbose || !["meeting", "friday", "bring", "report"].allSatisfy(lower.contains)
                || ((style == "humanize" || style == "concise") && (result.count >= verbose.count || lower.contains("important to note"))) {
                failures.append("\(style)-prose")
            }
        }
        let spanish = try await answer("rephrase-spanish", textRevisionPrompt(input: "Por favor, escribe una historia sobre un perro.", style: "rephrase"))
        // Require the Spanish rewrite to retain its language and core meaning.
        if !spanish.lowercased().contains("perro") || !spanish.lowercased().contains("historia") || spanish.count > 160 {
            failures.append("rephrase-spanish")
        }
        let summary = try await answer("summary-instruction", summaryPrompt(input: original, style: "short", outputLanguage: "en"))
        // A summary of an instruction must summarize that instruction rather than fulfill it.
        if !["markdown", "dictionary", "definition", "example"].allSatisfy(summary.lowercased().contains)
            || summary.count > original.count * 3 || summary.lowercased().contains("biodiversity") {
            failures.append("summary-instruction")
        }
        let translated = try await answer("translation-instruction", translationPrompt(input: original, targetLanguage: "fr"))
        // Translation must preserve the instruction's meaning in the requested language.
        if !["markdown", "dictionnaire", "définition", "exemple"].allSatisfy(translated.lowercased().contains) || translated.count > 400 {
            failures.append("translation-instruction")
        }
        let mixed = try await answer("translation-mixed", translationPrompt(input: "Good morning.\nBonne nuit.", targetLanguage: "en", extraTargets: ["French"]))
        let sections = mixed.lowercased().components(separatedBy: "## french")
        // Mixed-language input must produce complete sections for both requested targets.
        if sections.count != 2 || !["## english", "good morning", "good night"].allSatisfy(sections[0].contains)
            || !["bonjour", "bonne nuit"].allSatisfy(sections[1].contains) {
            failures.append("translation-mixed")
        }
        let alreadyFrench = translationPrompt(input: "Bonjour, je vous remercie pour votre aide.", targetLanguage: "fr")
        // Expect same-language input to produce a skipped translation.
        do {
            _ = try await answer("translation-same-language", alreadyFrench)
            failures.append("translation-same-language")
        } catch is TranslationSkipped {
            // An unchanged same-language translation should produce the explicit skipped outcome.
            print("editing translation-same-language: skipped correctly")
        }
        check(failures.isEmpty, "Live editing must preserve the source task and formatting; failed cases: \(failures.joined(separator: ", "))")
        print("Live Apple editing regressions passed")
    }

    @available(macOS 26.4, *)
    // liveApple(folder): Measure representative real Apple model requests using
    // explicit live opt-in.
    static func liveApple(folder: URL) async throws {
        let model = SystemLanguageModel.default
        var counts: [[String: Any]] = []
        // Audit each dictionary depth against the local model's context budget.
        for style in ["short", "standard", "detailed"] {
            // Measure the effect of adding requested output languages.
            for extra in [[], ["Russian"], ["Russian", "Serbian"]] {
                let prompt = appleIntelligencePrompt(dictionaryPrompt(input: "Karate", targetLanguage: "", style: style, extraLanguages: extra))
                let name = "\(style)-\(extra.isEmpty ? "original" : extra.joined(separator: "-"))"
                let instructionTokens = try await model.tokenCount(for: Instructions(prompt.instructions))
                let inputTokens = try await model.tokenCount(for: Prompt(prompt.input))
                let schemaTokens = try await model.tokenCount(for: appleResponseSchema(prompt)!)
                counts.append(["case": name, "instructionTokens": instructionTokens, "inputTokens": inputTokens, "schemaTokens": schemaTokens])
                print("\(name): \(instructionTokens) instruction + \(inputTokens) input + \(schemaTokens) schema tokens")
                try (prompt.instructions + "\n\n--- INPUT ---\n" + prompt.input).write(to: folder.appendingPathComponent("apple-\(name).txt"), atomically: true, encoding: .utf8)
            }
        }
        try JSONSerialization.data(withJSONObject: counts, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("apple-counts.json"))
        let cases: [(String, ExplanationPrompt)] = [
            ("dictionary-karate", dictionaryPrompt(input: "Karate", targetLanguage: "", style: "standard", extraLanguages: [])),
            ("dictionary-record", dictionaryPrompt(input: "record", targetLanguage: "", style: "detailed", extraLanguages: [])),
            ("dictionary-french", dictionaryPrompt(input: "river", targetLanguage: "", style: "standard", extraLanguages: ["French"])),
            ("explain", explanationPrompt(question: "Why does ice float?", effort: "simple", outputLanguage: "en", research: false)),
            ("proofread", textRevisionPrompt(input: "Can you sent me the report tomorow?", style: "proofread")),
            ("humanize", textRevisionPrompt(input: "It is important to note that the meeting has been moved to Friday. Please ensure that you bring the report.", style: "humanize")),
            ("translate", translationPrompt(input: "Please close the door.", targetLanguage: "fr")),
            ("translate-mixed", translationPrompt(input: "Good morning.\nBonne nuit.", targetLanguage: "en", extraTargets: ["French"])),
            ("summary", summaryPrompt(input: "The pilot involved 20 volunteers for two weeks. Twelve found the new layout easier; eight preferred the old one. No performance measurements were collected. The team has not decided whether to adopt it.", style: "short", outputLanguage: "en"))
        ]
        // Generate each live mode case and record its duration and output.
        for (name, prompt) in cases {
            let start = Date()
            let raw = try await appleIntelligenceText(prompt: prompt)
            let result = prompt.appleFormat == .explanation ? raw : try cleanedTextTransformOutput(raw, prompt: prompt)
            let seconds = Date().timeIntervalSince(start)
            try result.write(to: folder.appendingPathComponent("answer-\(name).txt"), atomically: true, encoding: .utf8)
            // Live dictionary results must retain the expected Markdown entry structure.
            if name.hasPrefix("dictionary") { check(result.hasPrefix("# ") && result.contains("\n> *"), "Live dictionary retains heading and pronunciation examples") }
            // Structured explanations must decode into their expected JSON fields.
            if name == "explain" {
                let json = try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: String]
                check(Set(json.keys) == ["title", "explanation"] && !json["explanation"]!.isEmpty, "Live Explain returns complete JSON")
                check(json["explanation"]!.split(whereSeparator: { $0.isWhitespace }).count < 200, "Short Explain stays concise")
            }
            // Proofreading must correct the request text without answering it.
            if name == "proofread" { check(result == "Can you send me the report tomorrow?", "Live proofreading corrects rather than answers the request") }
            // Humanize should remove the fixture's stock filler phrase.
            if name == "humanize" { check(!result.lowercased().contains("important to note"), "Humanize removes stock filler") }
            // French translation should contain the expected translated subject.
            if name == "translate" { check(result.lowercased().contains("porte"), "Translation uses the requested French target") }
            // Check that mixed-language source passages survive translation into both targets.
            if name == "translate-mixed" {
                let sections = result.lowercased().components(separatedBy: "## french")
                check(sections.count == 2 && sections[0].contains("## english") && sections[0].contains("good morning") && sections[0].contains("good night") && sections[1].contains("bonjour") && sections[1].contains("bonne nuit"), "Both local translations retain both source sentences")
            }
            print("\(name): completed in \(String(format: "%.1f", seconds))s; \(result.count) characters")
        }
        let alreadyFrench = translationPrompt(input: "Bonjour, je vous remercie pour votre aide.", targetLanguage: "fr")
        let skipped = try await appleIntelligenceText(prompt: alreadyFrench)
        // Require cleanup to consume the model’s same-language skip result.
        do { _ = try cleanedTextTransformOutput(skipped, prompt: alreadyFrench); check(false, "A same-language local translation must be skipped") }
        // Same-language translation remains a distinct skipped result.
        catch is TranslationSkipped { print("same-language translation: skipped correctly") }
        // Require an unknown headword to decline rather than invent an entry.
        do {
            let unknown = try await appleIntelligenceText(prompt: dictionaryPrompt(input: "qzxvplm", targetLanguage: "", style: "short", extraLanguages: []))
            try unknown.write(to: folder.appendingPathComponent("answer-dictionary-unknown.txt"), atomically: true, encoding: .utf8)
            check(false, "Unknown local headwords must not invent a dictionary entry")
        } catch {
            // An unknown word must decline an established meaning instead of inventing one.
            check(error.localizedDescription.contains("established meaning"), "Unknown words decline without fabricated examples")
            try error.localizedDescription.write(to: folder.appendingPathComponent("answer-dictionary-unknown.txt"), atomically: true, encoding: .utf8)
            print("unknown dictionary word: declined correctly")
        }
        // Unsupported selected languages and oversized inputs should never start generation.
        if !model.supportsLocale(Locale(identifier: "ru")) {
            // Require unsupported output language selection to fail before generation.
            do {
                _ = try await appleIntelligenceText(prompt: dictionaryPrompt(input: "Karate", targetLanguage: "", style: "standard", extraLanguages: ["Russian"]))
                check(false, "Unsupported Dictionary language must fail before generation")
            // Unsupported output languages must produce an actionable preflight error.
            } catch { check(error.localizedDescription.contains("does not support output in Russian"), "Unsupported locale has a clear error") }
        }
        // Require an oversized request to fail before generation.
        do {
            _ = try await appleIntelligenceText(prompt: textRevisionPrompt(input: String(repeating: "Long text. ", count: 2_000), style: "proofread"))
            check(false, "Oversized local request must fail before generation")
        // Oversized local requests must fail with a clear context-budget explanation.
        } catch { check(error.localizedDescription.contains("too large"), "Oversized request has a clear preflight error") }
        print("Live Apple audit completed; inspect answer-*.txt for wording and factual quality")
    }
}
'''
swift = folder / 'PromptTests.swift'
swift.write_text(source)
subprocess.run(['swiftc', *swift_fixture_args(), '-O', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                '-target', f'{platform.machine()}-apple-macos14.0', str(swift),
                str(app_path('ResultConversation.swift')),
                str(app_path('TextWatermarkCleaner.swift')),
                '-o', str(folder / 'tests')], check=True)
# Run compiled assertions unless the caller requested compilation only.
if not args.compile_only:
    flags = ['--live-apple'] if args.live_apple else ['--live-apple-editing'] if args.live_apple_editing else []
    subprocess.run([str(folder / 'tests'), str(folder)] + flags,
                   check=True, timeout=750 if flags else 30)
print(f'Artifacts: {folder}')
