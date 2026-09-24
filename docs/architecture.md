# Source architecture

Langmin is one app, built from this repository. All app code compiles into the `LangminApp` Swift module.

| Files | Responsibility |
| --- | --- |
| `main.swift`, `SetupWizard.swift`, result and HUD views | AppKit interface, writing modes, editing, clipboard actions, and printing |
| `CloudText.swift`, `CloudTransport.swift`, `ProviderCredentials.swift` | Cloud models, custom endpoints, web research, and Keychain access |
| `AudioTranscription.swift`, `CloudTranscription.swift`, `AudioFileImport.swift` | Apple speech recognition, OpenAI transcription, and cancellable file imports |
| `CloudVoices.swift`, `DictionaryIllustration.swift`, `CloudIllustrations.swift` | Narration and optional illustrations |
| `LibraryFolders.swift`, `LibraryFolderViews.swift`, `LibraryFolderActions.swift` | Library folders and their controls |
| `LibraryCloudSync.swift`, `LibraryCloudTransport.swift`, `LibrarySyncArchive.swift` | CloudKit transport, conflict handling, and attachment validation |
| `ProStore.swift`, `ProEntitlementLogic.swift` | App Store purchases, trials, renewal, and restore |
| `BuildEdition.swift`, `SourcePurchaseFooter.swift` | Shared app identity and source-build access |

## Source and App Store builds

Both use the bundle ID `tools.min.langmin` and the `langmin://` URL scheme. They contain the same feature implementations and data formats.

Every public build provides the same 30-day full-access period and uses StoreKit to verify purchases. App Store production builds use the verified app transaction's original acquisition date. Source builds and verified StoreKit sandboxes use the disclosed local start date. After the trial, Apple Intelligence, Apple voices, Apple transcription, text editing, and the local Library remain free. A dismissible amber footer offers purchase and restore for Pro features. Provider accounts, API charges, OS requirements, and Apple's signing requirements still apply.

The `AppStore` Xcode configuration defines `LANGMIN_APP_STORE`. It requires Apple's signed acquisition date in production and permits the local trial clock only after StoreKit verifies a nonproduction environment. It uses the same footer and purchase verification as Debug and Release. The shared scheme uses AppStore for archives.

`ProStore` is the single access check used by models, voices, transcription, folders, and sync. It combines the distribution-appropriate trial clock with verified StoreKit transactions. Private maintainer builds may supply an ignored compile-time override. API credentials and sharing permissions are required independently of access status.

## Data and permissions

Audio imports have their own cancellation and upload permission. Permission to send text does not authorize uploading recordings. The bundled privacy manifest covers both user text and OpenAI audio uploads.

Library data stays local unless the user enables iCloud sync in a provisioned build. Ad-hoc builds omit CloudKit entitlements and explain that limit in Settings. See [iCloud sync](icloud-sync.md) and [build instructions](development.md).
