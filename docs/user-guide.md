# Langmin user guide

This guide describes the App Store app and public source builds. Both start with 30 days of full access. Afterward, Apple Intelligence, Apple voices, Apple transcription, text editing, and the local Library stay free. Other Pro features require a verified yearly or lifetime purchase. Provider charges and Apple signing requirements still apply.

The parts of Langmin that are not obvious from the window: how modes and models behave, what happens from other apps, and what the Library keeps. The [README](../README.md) covers the basics.

## Models, style, and language

Add API keys or a custom endpoint in **Settings → Models**. Keys are stored in the macOS Keychain.

Text providers: Apple Intelligence, OpenAI, Anthropic, Google Gemini, xAI Grok, DeepSeek, and custom endpoints. Narration: Apple voices, OpenAI, or Grok. Audio transcription: Apple or OpenAI.

A custom endpoint is a server that supports OpenAI chat completions. You can run [LM Studio](https://lmstudio.ai/docs/developer/openai-compat) or [Ollama](https://docs.ollama.com/api/openai-compatibility) on your Mac, or use a hosted service such as [Groq](https://console.groq.com/docs/openai).

To connect one:

1. Start your local server and make sure the model is available, or choose a model from your hosted service.
2. In **Settings → Models**, enter its address in **Custom URL** and its model ID in **Custom Model**. Use the address shown by your server, such as `http://localhost:1234/v1` for LM Studio or `http://localhost:11434/v1` for Ollama.
3. Fill in **Custom API Key** only if the server requires a key.

Apple Intelligence supports fewer languages and shorter requests. Langmin checks the selected output languages and the available context before generating, keeps local answers compact, and tells you when a request needs another model. Local Dictionary entries focus on the main meaning and examples; choose a cloud model for fuller entries and IPA transcriptions.

**Language level** controls vocabulary and grammar: A is basic, B intermediate, C advanced. It starts off and applies to every mode except Proofread. Style controls depth separately.

Translate skips a target language when the whole input is already in that language, and says so instead of touching the clipboard.

**Rewrite → Humanize** reduces formulaic wording while keeping the meaning. It does not guarantee human authorship or a particular result from an AI detector.

## Transcribing a recording

Drop an **M4A, MP3, or WAV** file into the input. You can also copy a file in Finder and paste it; if macOS denies access, drag it instead. A progress sheet shows the current file and lets you cancel. Text from completed files is still inserted if a later file fails or you cancel the import.

Choose the speech provider in **Settings → Transcription**:

- **Apple · On-device** is free and requires macOS 26 or later. Choose the recording's language, or leave **Mac's language** selected. The menu lists supported languages and marks a saved choice if it is unavailable. Langmin asks before macOS downloads a missing speech model; the recording stays on your Mac. Transcription does not use an Apple Intelligence text model.
- **OpenAI · Pro** uses GPT-Transcribe and the API key saved in **Settings → Models**. It detects the language and bills transcription to your OpenAI account. Langmin asks for permission to upload audio separately from permission to send text. Files must be no larger than **25 MB**. For a larger recording, export a smaller M4A or MP3, split it, or use Apple.

The transcript is inserted as editable text. Review it, then choose a mode such as Proofread, Summarize, or Translate. The writing model is independent of the speech provider. Long transcripts may exceed a writing model's input limit; shorten the text or choose a model with more capacity.

Apple speech models are reused across imports and app launches. macOS limits how many languages an app can keep. Adding a new language at that limit can mean downloading a previous one again later. Langmin asks again only when a model needs to be installed; macOS may also remove models that have not been used for a while.

Importing a recording does not attach it to the Library or start narration. Saving a result also saves the input text used to create it. To revoke permission to upload audio, use **Settings → Models → Reset AI Permissions**.

## From another app

Copy the text, then use a Langmin menu-bar action or its shortcut. Langmin reads the clipboard only when you ask it to.

| Mode | When it finishes |
| --- | --- |
| Proofread or Rewrite | The result replaces your clipboard and **Copied** appears briefly |
| Explain, Summarize, Translate or Dictionary | The result appears in a floating panel; your clipboard is unchanged |

If you copy something else while a proofread or rewrite is running, Langmin asks before replacing it.

The default shortcuts are **⌃⇧1** to **⌃⇧6** in mode order and **⌃⇧L** for the Library; change them in **Settings → Shortcuts**. Inside Langmin's own window the same shortcuts select a mode, and **⌘Return** runs it.

To use selected text without copying it, open the source app's **Services** menu:

| Service | What happens |
| --- | --- |
| Compose or Translate with Langmin | Opens Langmin with your selection, ready to run |
| Proofread or Rewrite with Langmin | Replaces the selection with the result |
| Explain, Summarize or Look Up in Langmin Dictionary | Opens the result in its own window |

Services leave your clipboard alone and need no Accessibility or Automation permission. Assign their shortcuts in **System Settings → Keyboard → Keyboard Shortcuts → Services**, avoiding the ones Langmin already uses. If the Services are missing after the first launch, log out and back in.

With the menu-bar icon enabled, closing windows leaves Langmin running. **⌘Q** quits it.

## Follow-ups

From the floating panel, choose **Open** first. **Return** sends, **Shift-Return** adds a line, and Escape cancels a pending reply while keeping your draft.

Each follow-up receives the original request, the result, and the recent conversation, so "shorter" or "now in Serbian" just work. A reopened saved result keeps its original language level. The picker under the field can use any enabled model.

Deleted questions and replies are left out of later requests. Deleting earlier context cancels a reply that is still using it. The hover controls on a reply stay visible with VoiceOver.

## Editing a result

**Edit Text** opens the result as a small editor. **Done** applies the change everywhere: copies, exports, later follow-ups, and the saved Library item. Editing an unsaved result does not save it. Diff compares the original input with the edited result; follow-up replies are not part of the diff.

Saving manual edits removes attached narration and pronunciation audio, after a warning. Cancelling the warning keeps both your draft and the audio. Playback controls come back when you generate new narration.

## Library and iCloud sync

Saving a result keeps its whole conversation, and new replies update the saved item. Copying and text export include the conversation.

With **Langmin Pro**, turn on **Settings → General → Library → iCloud Sync** on each Mac that uses the same Apple Account. It syncs saved results, folders, conversations, images, and audio. API keys, settings, and unsaved results stay on each Mac.

The Library works offline; changes sync while Langmin is open and connected, and the iCloud panel has a **Sync Now** button. An incoming update to a result you have open waits until you close it.

**Deletions sync too.** This keeps every Mac in step but keeps no history, so sync is not a backup. Conflicting edits are kept as separate copies. Turning sync off, or losing Pro, keeps both the local and the iCloud copies; renewing Pro resumes sync if it is still enabled.

iCloud needs an Apple-signed build configured for CloudKit, so it is unavailable in a locally signed development build.

The Library opens inside the main window. The control at the right of the title bar detaches it into its own window or brings it back, and Langmin remembers the choice.

## Narration and printing

Narration reads the result and its follow-ups. New follow-ups leave existing audio unchanged until you regenerate it.

**Share → Print…** or **⌘P** prints the result, its images, and the finished follow-ups on white pages with page numbers. Save as PDF from the same dialog.

## Reading a webpage

Paste a URL by itself into **Explain** or **Summarize** and Langmin reads the page on your Mac before asking the model. A Detailed summary may keep up to two relevant page images, with captions and source links, and a saved result keeps local copies of them.

Long pages are excerpted. Pages that need a sign-in or JavaScript may require pasting their text instead.

Local URLs work with any port, including localhost previews, but their redirects and images must stay on the same scheme, host, and port; public pages cannot use redirects or images to reach private services. Page text still goes to the model you selected.

For questions that need current information, turn on web research in Settings. OpenAI, Anthropic, and Gemini support it.

## Dictionary pictures

Lookups do not generate pictures unless you ask, with the picture button on a result, or turn on **Automatically illustrate new lookups** under **Settings → Illustrations**.

- **Image Playground** uses Apple's on-device styles on Macs running macOS 15.4 or later.
- **OpenAI** uses your OpenAI API key. It requires Pro, and the provider bills the usage.

The caption names the image model separately from the text model, also in print and PDF copies. A saved result keeps its picture, including one that finishes after you save.

## Privacy and storage

Apple text models, Apple voices, Apple transcription, document and image text extraction, and text cleanup run on your Mac. Remote requests go directly to the provider you chose, on your own account. Langmin asks before first sharing text with each provider and separately before uploading recordings to OpenAI.

Text cleanup strips invisible characters that generated text often carries, while preserving code, emoji, and writing-system controls. Turn it off in **Settings → General → Text Cleanup**.

Preferences, Library entries, and generated files live in Langmin's app container; API keys live in the Keychain. The [privacy policy](../PRIVACY.md) covers sharing, retention, and deletion.

## Automation

The `langmin://` URL scheme can run a request, open Compose with text, or show the Library. Langmin asks before running a request that came from outside.

```text
langmin://run?mode=summarize&text=Paste%20text%20here
langmin://run?mode=translate&text=Good%20morning&language=Spanish
langmin://run?mode=explain&text=What%20is%20love%3F&level=a
langmin://compose?mode=rewrite&text=Draft%20to%20polish
langmin://library
```
