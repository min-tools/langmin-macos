# iCloud Library sync

With **Langmin Pro**, turn on **Settings → General → Library → iCloud Sync** on each Mac using the same Apple Account. Sync is off by default.

| Synced | Kept on each Mac |
| --- | --- |
| Saved results, original input and conversations | Unsaved results |
| Folders and the items filed in them | Folder navigation order |
| Source images, illustrations, narration and pronunciation clips | API keys, settings and sharing permissions |

Saving a result made from an audio transcript includes the input text. Imported recordings are not attached to the Library or synced.

## When changes sync

The Library works offline. With sync enabled, Langmin checks at launch, when you return to the app, after Library changes, and every 30 seconds while running. **Sync Now** requests a check, though connection errors and server limits can delay retries.

Keep Langmin open until its panel says the Library is up to date. The other Mac also needs to finish its check before it has those changes. Incoming updates to an open result wait until you close it, so they cannot interrupt editing or playback.

**Sync is not a backup history.** It shares deletions as well as additions and edits. Turning it off keeps the copies already stored. Offline changes are sent when sync resumes.

If two Macs edit the same item, Langmin preserves the different versions as separate items, marked **(Conflict copy)**. If an edit conflicts with a deletion, it keeps the edited content in a separate item and leaves the original deleted.

## If Pro expires

In public builds, each Mac needs Pro access through the local 30-day trial, a subscription, a lifetime purchase, or Family Sharing. Losing access pauses sync and prevents pending downloads from being applied. An upload already accepted by iCloud may still finish.

Local files, iCloud copies and sync records are kept. Renewing or restoring Pro resumes sync only if it is still enabled. Upgrading alone does not turn it on. You can always turn sync off, even without Pro.

## Record schema

CloudKit requires a provisioned, Apple-signed build with access to the configured iCloud container. Ad-hoc builds do not support sync; Settings explains that limitation.

CloudKit creates these fields in the Development environment as the app saves records:

| Field | CloudKit type |
| --- | --- |
| `formatVersion` | Int64 |
| `digest` | String |
| `deleted` | Int64 |
| `folderName` | String |
| `chunks` | Asset List |

No query indexes are required: sync fetches record-zone changes in the private `LangminLibrary` zone. No public database or developer-operated server is used. Sync does not request notification permission; foreground and timed checks handle delivery.

Apple references: [CloudKit setup and sample](https://github.com/apple/sample-cloudkit-sync-engine), [iCloud services entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-services), [CloudKit assets](https://developer.apple.com/documentation/cloudkit/ckasset).

## Storage and recovery

Library files remain under app-owned Application Support. The separate `iCloudSync` folder holds the account binding, server token, record acknowledgements, and downloaded changes awaiting application. Server tags reject stale writes. The merge compares content against the last acknowledged version, independent of device clocks.

Each result is packed into an archive with a file list and SHA-256 checksums. The archive is split into 32 MB CloudKit assets. Downloads are checked before they replace local files, including paths, links, duplicate names, format versions and lengths.

A result's complete archive is limited to 2 GB; its saved metadata is limited to 8 MB. Invalid or missing data pauses sync without replacing the affected local item. Temporary upload copies are removed once iCloud acknowledges them.

Deletion records remain in iCloud so an offline Mac cannot recreate the original deleted item. A fresh installation with an old local copy preserves that content as a conflict copy. Signing into a different Apple Account pauses sync until the user explicitly turns it off and on; local data is not silently uploaded to the new account. Resetting the CloudKit zone also requires an explicit off/on before uploading the local Library again.

Do not remove the local sync state as routine troubleshooting: it records acknowledged deletions and pending downloads. An unreadable state file pauses sync rather than discarding that history.

If a pending download loses its staging files, Langmin refetches it while retaining the account binding and acknowledged changes. Account changes during setup cancel that attempt and require a fresh off/on before merging into the new account.

## Verification

Run the isolated tests, which use fake CloudKit transport and temporary Library directories:

```bash
python3 scripts/test_library_cloud_sync.py
python3 scripts/test_library_sync_settings.py
python3 scripts/test_pro_store.py
```

The tests do not read the user's Library, preferences, Keychain or iCloud account. They cover:

- Pro access, expiry, renewal, opt-in, opt-out and unsupported builds.
- Attachment restoration, offline changes, interrupted downloads and restart recovery.
- Conflicting edits, deletions, Undo, folders and account changes.
- Archive validation and size limits.

Offline tests cannot verify signing, the deployed schema, real iCloud delivery or account storage limits.
