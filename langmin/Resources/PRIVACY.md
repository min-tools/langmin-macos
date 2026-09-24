# Langmin Privacy Policy

Effective and last updated: September 24, 2026

This policy explains what data Langmin handles, where it goes, and how you can control it.

## Data on your Mac

Langmin stores preferences, saved Library items, generated files, and other app data in its macOS app container. The Mac App Store build reads Apple's signed original acquisition date to determine the 30-day Pro period. Source and test builds store a local trial start date instead. Trial information is not sent to the developer. Provider API keys are stored separately in macOS Keychain. Langmin has no advertising, analytics, or tracking SDKs and does not monitor the clipboard.

A macOS Service receives selected text from the source app on a private pasteboard. Menu-bar and global shortcut actions read the general clipboard only when you invoke them.

Optional text cleanup also runs on your Mac. It does not contact a watermark-detection service or send text to another party.

Apple processes Langmin Pro purchases and does not share payment details with Langmin's developer. The app reads your Apple purchase status to unlock Pro, including purchases shared through Family Sharing.

## Documents, images, and audio

You can drop or paste documents, images, and M4A, MP3, or WAV recordings into the launcher.

Langmin extracts text from documents and images on your Mac, using OCR for images and scanned PDFs. These source files are not uploaded.

For audio, choose a provider in **Settings → Transcription**. Apple transcription runs on your Mac. macOS may download a speech model after you agree; Apple does not receive the recording.

OpenAI transcription requires Pro and separate permission to send audio. Langmin sends the recording directly to OpenAI using your API key. It gives the upload a generic filename rather than your file's name or path. OpenAI may process or retain recordings under its policy and terms.

Extracted text and audio transcripts become editable input. When you run a writing mode, this text follows the same sharing permissions as text you type. Saving a result also saves the input text used to create it.

Imported recordings are not attached to the Library or included in iCloud sync. Langmin does not move, change, or delete the source recording.

## Optional iCloud Library sync

If you enable **Settings → General → Library → iCloud Sync**, Langmin sends saved Library items, folders, conversations, images, narration, and pronunciation audio to your private iCloud database through Apple's CloudKit service. They are available to Langmin on Macs signed in to the same Apple Account. Langmin's developer does not receive this content or operate a sync server.

API keys, app settings, AI sharing permissions, and unsaved results are not synced. Your Library remains available locally when offline. Apple processes and stores iCloud data under its iCloud terms and privacy policy.

Disabling sync keeps existing local and iCloud copies. While sync is enabled, deletions propagate to other Macs when they reconnect. Small deletion records remain in iCloud to prevent an offline Mac from restoring a deleted item. Concurrent edits can produce a separate conflict copy so neither edit is lost; you can delete copies you no longer need.

## AI providers and websites

Apple Intelligence text generation and Apple voices run on your Mac. When you choose OpenAI, Anthropic, Google Gemini, xAI, DeepSeek, or a custom endpoint, Langmin sends the text needed for your request directly to that provider. OpenAI and xAI speech receive the text to narrate. Optional web research lets the selected provider and its search tools process your query and related search terms.

Follow-ups include your new question, the original request and result, and recent questions and replies. Long conversations are excerpted to limit the amount sent. The same sharing permissions and Secret Protection checks apply.

### Webpages

When you submit a page URL in Explain or Summarize, Langmin contacts the website to extract readable text. It does not run page scripts or use browser cookies or sign-in credentials. The extracted text and relevant image descriptions go to your selected text model.

In Detailed mode, Langmin may download up to two relevant images from the page or its image hosts. Those hosts receive ordinary web requests, including your IP address. They do not receive your model API keys. Source images are stored on your Mac and copied into the Library when you save the result. Saved images also sync if you enable iCloud Library sync.

Direct localhost and local-server URLs support any valid port. Their text goes to your selected model under the same sharing and Secret Protection checks. Local redirects and images must keep the scheme, host, and port you entered. Public pages cannot use redirects or images to access private services.

### Dictionary illustrations

OpenAI illustrations send the word, up to 4,000 characters of its generated definition, and illustration instructions directly to OpenAI using your API key.

Image Playground uses Apple's system interface and on-device illustration styles. Langmin does not enable its external-provider styles. Generated pictures stay with the local result and are copied into the Library when saved.

### Permission and provider policies

Before first sending text to a remote destination, Langmin asks you to allow one request, remember permission, or cancel. Uploading recordings to OpenAI needs separate audio permission. Revoke saved text and audio permissions in **Settings → Models → Reset AI Permissions**. Secret Protection can also warn when text appears to contain credentials or other secrets; it does not scan recordings before upload.

Remote requests use your provider account and API key. The provider may associate, process, or retain your text, recordings, and results under its policy, account settings, and terms. Review that policy before sending personal or confidential information.

You choose who operates a custom endpoint; Langmin cannot verify its protections. Review its operator and policy before using it.

Requests go directly to your provider. Langmin's developer does not receive your text, recordings, results, API keys, provider account identifiers, or usage data.

## Retention and deletion

Unsaved working files are removed when their result closes. If a crash or force-quit prevents cleanup, Langmin removes abandoned files at its next launch. Unsaved conversations stay in memory until the result closes.

Library items stay on your Mac until you delete them. With iCloud sync enabled, saved items also have an iCloud copy and deletions sync across your Macs. Saving a result includes its original request and completed follow-ups; new replies update the saved item.

API keys stay in Keychain until you remove them in Settings or Keychain Access. Removing the app and its container deletes app-managed data, but Keychain items may need to be removed separately.

Providers control retention of the data they receive. Use their account and privacy controls to request access or deletion.

## Your choices

You can use on-device Apple models, voices, and transcription, decline remote sharing, revoke saved permissions, disable web research or iCloud sync, remove API keys, delete Library items, or remove Langmin.

To revoke permission to share text and audio, use **Settings → Models → Reset AI Permissions**.

## Changes and contact

This policy and its date will be updated when material changes occur. For privacy questions or requests, visit the [Langmin GitHub repository](https://github.com/min-tools/langmin-macos).
