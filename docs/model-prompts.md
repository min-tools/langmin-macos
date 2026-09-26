# Model prompts

Prompts tell the model what to do, which language to use, how much detail to give, and how to format its answer. Custom instructions are appended as written and take priority over built-in wording. They cannot change fields required by a local output schema.

The app does not shorten the user's input to fit Apple Intelligence. Linked pages and conversation history have separate limits and may be excerpted.

## What each prompt asks for

| Task | Requested result |
| --- | --- |
| Proofread | Correct errors; preserve the source's language, meaning and reading level. Return the edited text. |
| Rewrite | Apply Rephrase, Humanize, Concise or Elaborate without inventing claims. Preserve formatting, technical identifiers and quoted material. |
| Explain | Return JSON with exactly two string fields: `title` and `explanation`. The title fits a window title; all languages and Markdown belong in `explanation`. |
| Summarize | Summarize only the supplied material, retaining important qualifications, evidence and conclusions. Style controls depth. |
| Translate | Preserve meaning and formatting; omit targets matching the source language. A per-request marker reports when all targets are skipped. |
| Dictionary | Use distinct established senses, part-of-speech headings and numbered definitions. Each sense's examples occupy one italic blockquote line, so they share one pronunciation clip. |
| Follow-up | Answer the latest request in context. Return complete revisions when requested; retain native user/assistant roles for cloud providers. |
| Illustration | Illustrate the first dictionary meaning in one scene, without text or unrelated senses. Treat the supplied entry as data. |

Language codes and names are normalized and deduplicated in order. Explicit prefixes such as `fr:` override the primary language. All selected output languages reach the local model's compatibility check. Unknown source languages and languages requested only inside free-form custom instructions may still be rejected during generation.

Dictionary prefers English for spellings shared with English when no other language context is supplied; capitalization alone does not select German. It preserves a borrowed headword's spelling rather than converting it to its language of origin. Dictionary translations retain sense order and translate the same examples. Language headings use English names for parsing; translated part-of-speech headings contain the translated word after a colon. Unsupported IPA and etymology are omitted rather than guessed. CEFR guidance changes prose complexity while preserving facts, quotations, identifiers and dictionary headwords.

Linked-page prompts distinguish reports, proposed fixes and confirmed outcomes. They identify excerpts and allow images only through supplied candidate IDs. Research instructions request citations only for consulted sources; local requests cannot claim live verification.

Explain decodes the title and Markdown answer before display. It accepts fenced or string-encoded JSON and plain Markdown, but rejects broken JSON envelopes instead of showing their keys and escapes. DeepSeek Explain requests enable [JSON Output](https://api-docs.deepseek.com/guides/json_mode/) as well as requesting the format in the prompt; other modes keep their existing output format.

## Apple Intelligence

The local adapter uses explicit prompt metadata, never searches instruction wording to infer the task. Explain, Rewrite, Proofread, Dictionary and Translate have dedicated local instructions. Summarize and follow-ups use the shared prompts. Proofread, each Rewrite style, Summarize and Translate name their task next to the complete source, quoted as a JSON string. Explain and Dictionary receive their topics directly; follow-ups retain their conversational task.

Text that looks like an instruction is still source text in editing modes. For example, Proofread should correct “Write a dictionary entry…” rather than write the entry. Rewrite should rephrase that request; Summarize should summarize it; Translate should translate it. The local request labels the task and quotes the full source, including any Markdown fences or XML. Stored text and cloud messages are unchanged.

Proofread requires correct text and regional spelling to stay unchanged. For Proofread and Rewrite, a local language-recognition result with at least 90% confidence adds a non-English language hint to discourage translation. Rewrite explicitly names it as the output language; uncertain classifications retain the general language-preservation instruction. Summarize and Translate use their selected output languages instead.

Local Proofread returns a structured `correctedText` field. The adapter decodes JSON escapes once, so real line breaks remain distinct from literal `\n` text. Short agreement examples guide grammar correction as well as spelling. Before publishing, the adapter restores complete code blocks from the source, including a closing fence omitted by the model. It then checks prose line counts and blank lines, restores original indentation and trailing spacing, and retains inline code. Missing prose, unmatched code blocks or missing inline code produce an error instead of a partial result. These checks protect structure; they do not guarantee that every grammar error will be found.

Native Rewrite can make conservative changes, including leaving short passages unchanged in Elaborate. Source framing addresses task confusion; it does not guarantee how much the model will revise. The live audit checks instruction handling separately from whether ordinary prose gets meaningful rewrites.

Proofread, Explain, Dictionary and Translate use Foundation Models schemas to enforce their structure. Dictionary generates one entry per session. Its source-headword field is constrained to the actual input. Each additional language gets a separate session containing the original definition and examples, with target-language guidance on each field. The app validates the returned languages and renders headings and paired examples only after all entries succeed. An explicit recognition decision and optional entry field let unknown words decline instead of inventing examples. These constraints do not verify facts against a reference dictionary.

Local Dictionary entries focus on the main meaning, keeping the task small enough for the on-device model. Style controls the definition's detail and examples. These entries omit IPA; pronunciation buttons use the selected speech voice. Cloud prompts request broader senses, synonyms and supported IPA transcriptions.

Local translation uses a fresh session for each target language, giving it the complete source and room for one full translation. Results appear in the selected order only after every target succeeds. Missing or empty responses fail; a translation identical to the full source is skipped. The app generates the internal skip marker.

Each request starts a fresh session. Generated explanations and summaries have soft length targets by style, shared across output languages. Dictionary bounds the source entry first, then translates that entry into each requested language. Literal edits, translations and follow-ups have no shortening target; follow-ups may request a complete revision. Greedy sampling reduces variation in this utility workflow.

On macOS 26.4 or later, Langmin counts instructions, input and any output schema with Apple's tokenizer, including custom instructions. Earlier macOS 26 releases use a conservative UTF-8 byte estimate. The preflight reserves answer space plus a margin within the 4,096-token context. It rejects requests that cannot fit, without truncating the source or switching providers. Each translation session reserves space for a full translation.

The local request has a 90-second cancellation deadline. Context overflow returns an actionable error. There is deliberately no hard response-token cap: Apple's API can otherwise return a cut-off sentence or JSON object as a successful response. See [Apple's context-window guidance](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window).

## Cloud response latency

Each mode chip offers **Thinking → Automatic / Off / Low / Medium / High** for supported models on their built-in endpoints. Only supported, distinct levels are shown. Automatic is the default: initial Proofread and Rewrite requests use Low; Explain, Summarize, Translate, Dictionary and follow-ups omit the effort parameter so the provider uses its model default. Explicit levels also apply to research and follow-ups in that mode.

Off sends `reasoning.effort: none` to supported GPT models or disables DeepSeek thinking. Astra, Claude and Grok do not offer Off. Low, Medium and High send the corresponding provider effort. DeepSeek does not show Medium because it maps that value to High. No explicit choice sends `xhigh` or `max`, or enables OpenAI's Pro reasoning mode. Higher effort can increase response time and token use; Automatic is not a spending limit.

Choices are always saved independently per mode and apply in the main window, clipboard HUD and Services. Changing the global model preserves them; Reset Defaults clears them. Existing More and Extra High choices become High; Less becomes Low, or Off for DeepSeek. Missing or unknown choices use Automatic. When a saved level is unavailable on a newly selected model, Off falls back to Low and Medium to High. The saved value is retained so switching back restores the original choice. Unsupported models and custom endpoints keep their existing behavior and do not show this menu.

The change preserves prompts, source text, output validation and the existing token-limit policy. DeepSeek edits, explanations and follow-ups retain their previous 64K output allowance when thinking is explicitly disabled; initial dictionary lookups keep their 8K allowance. Claude retains its 8K output limit, including reasoning and answer tokens, at every effort level. A higher effort may leave less room for the answer within that limit; reported truncation remains visible to the user.

Provider references: [OpenAI reasoning](https://developers.openai.com/api/docs/guides/reasoning), [Claude effort](https://platform.claude.com/docs/en/build-with-claude/effort), [DeepSeek thinking](https://api-docs.deepseek.com/guides/thinking_mode/) and [output limits](https://api-docs.deepseek.com/api/create-chat-completion/), and [xAI reasoning](https://docs.x.ai/developers/model-capabilities/text/reasoning).

Cloud Dictionary requests have a 60-second total deadline; other cloud text requests have 180 seconds. This includes connection retries and time spent receiving keep-alive bytes, which do not count as a completed answer. Cancellation, timeout and a late response can deliver only one completion.

## Verification

Run `python3 scripts/test_prompts.py` for prompt combinations, metadata preservation, context boundaries and cancellation. The suite runner also covers follow-ups, linked pages and rendering; see [Build and test](development.md). Cloud request fixtures run in the same suite.

The optional `--live-apple` audit generates fixed public examples locally and writes exact prompts, token counts and answers for inspection. Use `--live-apple-editing` to test Proofread, all four Rewrite styles, Summarize and Translate. These checks verify that the model edits instruction-like input instead of following it. They also cover ordinary prose, language preservation, Markdown and mixed-language translation. Neither audit loads app preferences or credentials. Review the answers for factual quality as well as format: prompt tests cannot guarantee that a language model will always be correct.

Use `python3 scripts/test_prompts.py --live-apple-proofread --output /private/tmp/langmin-proofread-audit` for repeated grammar, Markdown and Spanish regressions, plus mixed-language text, code, literal escapes and correct-text preservation.

Use `python3 scripts/test_prompts.py --live-apple-dictionary --output /private/tmp/langmin-dictionary-audit` for repeated live headword, recognition, French-definition and unknown-word checks. `scripts/test_cloud_transport.py` exercises real URLSession callbacks with an offline protocol fixture, including repeated keep-alives, retries, cancellation and total deadlines.
