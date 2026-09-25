# Build and test

## Build Langmin

Use an Apple-silicon Mac and full Xcode with the macOS 26.4 SDK or later. The app runs on macOS 14 or later; Apple Intelligence and Apple audio transcription need macOS 26 or later and a supported device and language.

Open `langmin/Langmin.xcodeproj` and select the `Langmin` scheme. Debug and Release builds start the 30-day full-access trial locally after its disclosure. App Store production builds use Apple's signed original acquisition date; verified sandbox builds use the local clock for testing. No subscription starts automatically. After the trial, Apple Intelligence, Apple voices, Apple transcription, text editing, and the local Library remain free; an optional amber banner offers Purchase, Restore Purchases, and Dismiss.

StoreKit purchase testing requires an Xcode StoreKit test configuration or a suitably signed Sandbox build. An ad-hoc signature alone does not make App Store purchases available. Cloud providers require your own keys and bill you separately.

There is one bundle ID, `tools.min.langmin`, and one automation scheme, `langmin://`. Source and App Store builds share that identity. Do not run both at once. An installation under an older bundle ID has a different sandbox and Keychain service; changing the identifier does not migrate its data or keys automatically. Keep the old installation and its data until you have saved anything you need.

## Build configurations

Open `langmin/Langmin.xcodeproj`. The target and shared scheme are named `Langmin`.

| Configuration | Access | Entitlements |
| --- | --- | --- |
| Debug / Release | 30-day full-access trial, then included free features or verified Pro access | `LangminApp.entitlements`, without CloudKit |
| AppStore | 30 days from signed acquisition in production; local clock in verified sandboxes | `LangminCloud.entitlements` |

The shared scheme archives with **AppStore**. Debug and Release builds are not App Store submission artifacts.

For command-line distribution, `scripts/package_app_store.py` signs an existing AppStore archive with explicit signing inputs. It resolves entitlement placeholders from the target's effective Xcode settings and requires the iCloud environment to be the string `Production`. It verifies both the signed app and the app extracted from the finished installer before replacing the previous package. Run the script with `--help` for its arguments.

Ad-hoc signing cannot enable iCloud. A provisioned build needs a developer team and matching CloudKit entitlements. See [iCloud sync](icloud-sync.md).

## Files and repositories

The app has no sibling source dependency. App code is in `langmin/Sources/LangminApp`, shared storage helpers in `langmin/Sources/LangminShared`, resources in `langmin/Resources`, and test tools in `scripts`.

Keep local build output in `build/` or `dist/`. Do not commit app bundles, archives, installers, compiler output, or signing files.

## Run offline checks

```bash
python3 scripts/test_all.py --logs /private/tmp/langmin-checks
python3 scripts/check_localizations.py
```

The runner covers local and cloud features, payloads, purchases, sync, UI fixtures, and distribution settings. It writes one log per suite and a `results.json`, and fails if any suite fails. `--jobs 2` is the default; keyboard-focus tests run sequentially.

Fixtures use temporary files, in-memory preferences, and simulated providers. They do not call AI services, use real credentials, read purchases, or launch the installed app. Native window tests need WindowServer access; audio export needs macOS codec services. Do not run two suite runners at once when testing keyboard focus.

Purchase fixtures compile the actual access logic in both source and Store configurations. Both configurations must handle verified purchases, expiry, restore, and renewal without granting Pro by default.

For an optional live Apple model check:

```bash
python3 scripts/test_prompts.py --live-apple --output /private/tmp/langmin-prompt-audit
```

This needs macOS 26.4 or later and uses fixture preferences without API keys. Inspect answers for factual quality as well as formatting. See [prompt design](model-prompts.md).

## Resources

Edit translations in `langmin/Resources`. Keep `PRIVACY.md` and `langmin/Resources/PRIVACY.md` identical.

Automatic Dictionary illustrations default to off. Settings → Illustrations controls the provider and opt-in. Choosing a provider alone does not start generation.

## Audio transcription

`AudioTranscription.swift` transcribes recordings locally with SpeechAnalyzer on macOS 26 or later. `AudioFileImport.swift` handles the progress sheet and cancellation. `TranscriptionSettings.swift` holds changes until Settings are saved. OpenAI uploads and response handling live in `CloudTranscription.swift`.

Supported formats are M4A, MP3, and WAV. OpenAI uploads have a 25 MB file limit, use an ephemeral URLSession, and are not retried by the app. Apple transcription uses the selected language and asks before downloading a missing speech model. File imports need no microphone access.

Keep successful Apple speech-model reservations across imports and app launches. Releasing a reservation unsubscribes the app from those assets and lets macOS remove them. At Apple's reservation limit, replace one unused reservation to allow a new language. If installation fails or is declined, release the new reservation and try to restore the displaced one. Use the installation request to check whether anything needs downloading; an existing download needs no second approval.

Apple imports run in order, including cancellation cleanup. This keeps an old request from releasing a model while a new request is using it.

The transcription tests use temporary files and simulated responses. They cover provider choice, separate audio permission, file and response validation, Settings drafts, progress, and cancellation. They do not download models or contact OpenAI. To test actual transcription, Apple needs a supported Mac and a speech model; OpenAI needs an API key and charges for use.
