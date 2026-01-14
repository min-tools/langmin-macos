import Cocoa
import CloudKit
import Security

// Local files remain authoritative while offline. Persist server acknowledgements separately so
// disappearance of an unacknowledged item is never mistaken for a deletion on another Mac.
final class LibraryCloudSync {
    static let statusDidChange = Notification.Name("LangminLibrarySyncStatusDidChange")
    static let enabledKey = "libraryICloudSyncEnabled"
    static let proRequiredMessage = "iCloud Library sync requires Langmin Pro. Your local Library stays available."
    static let proPausedMessage = "iCloud sync is paused. Renew Pro to resume. Local and iCloud copies are kept."
    static let shared = LibraryCloudSync(
        library: langminApplicationSupportDirectory().appendingPathComponent("Library"),
        storage: langminApplicationSupportDirectory().appendingPathComponent("iCloudSync"),
        transport: { CloudKitLibraryTransport() }
    )
    // Persist the account, change token, known records, and incoming work needed to resume sync.
    struct State: Codable {
        var version = 1
        var account: String?
        var token: Data?
        var known: [String: LibraryCloudRecord] = [:]
        var inbox: [String: LibraryCloudRecord] = [:]
    }
    // Describe a local item's content stamp, optional folder identity, and staged archive.
    struct Local {
        let digest: String
        let folder: String?
        let archive: URL?
        let stamp: String
    }
    let library: URL
    let storage: URL
    private let makeTransport: () -> LibraryCloudTransport
    private let proAccess: () -> Bool
    private let buildSupported: () -> Bool
    private let loadEnabled: () -> Bool
    private let saveEnabled: (Bool) -> Void
    private var previousProAccess: Bool
    private var transport: LibraryCloudTransport?
    private var state = State()
    private var cache: [String: Local] = [:]
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var epoch = 0
    private var retryAt = Date.distantPast
    private var failures = 0
    private var stateLoaded = false
    private var allowAccountChange = false
    private var anotherPass = false
    private var accountObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var proObserver: NSObjectProtocol?
    private var scheduledSync: DispatchWorkItem?
    private(set) var enabled = false
    private(set) var isSyncing = false
    private(set) var status = "iCloud sync is off. Your Library is stored on this Mac."
    private(set) var lastSync: Date?
    var hasProAccess: Bool { proAccess() }
    // Open documents keep their backing files until closed; staged deletions retain their Undo window.
    var openEntryIDs: () -> Set<String> = { [] }
    var pendingDeletionIDs: () -> Set<String> = { [] }
    var onLibraryChanged: () -> Void = {}
    var validateEntry: (URL) throws -> Void = { _ in }

    // init(library, storage, transport, [proAccess], [buildSupported],
    // [loadEnabled], [saveEnabled]): Inject storage, transport, access checks,
    // and preference handling for the sync coordinator.
    init(library: URL, storage: URL, transport: @escaping () -> LibraryCloudTransport,
         proAccess: @escaping () -> Bool = { ProStore.shared.hasFullAccess },
         buildSupported: @escaping () -> Bool = { LibraryCloudSync.supportedBuild },
         loadEnabled: @escaping () -> Bool = { langminPreferencesStore().bool(forKey: LibraryCloudSync.enabledKey) },
         saveEnabled: @escaping (Bool) -> Void = { langminPreferencesStore().set($0, forKey: LibraryCloudSync.enabledKey) }) {
        self.library = library
        self.storage = storage
        self.makeTransport = transport
        self.proAccess = proAccess
        self.buildSupported = buildSupported
        self.loadEnabled = loadEnabled
        self.saveEnabled = saveEnabled
        self.previousProAccess = proAccess()
    }

    // deinit(): Stop scheduled and in-flight sync work when the coordinator is
    // released.
    deinit {
        timer?.invalidate()
        scheduledSync?.cancel()
        task?.cancel()
        // Remove each installed account, activation, and entitlement observer.
        for observer in [accountObserver, activationObserver, proObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    static var supportedBuild: Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        // Require a signed running executable whose code and entitlements can be inspected.
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let services = entitlements["com.apple.developer.icloud-services"] as? [String],
              let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String],
              containers.contains(CloudKitLibraryTransport.containerID) else { return false }
        return services.contains("CloudKit")
    }

    // start(): Restore the local opt-in at launch without opening an account
    // dialog or contacting AI providers.
    func start() {
        // Install the recurring sync schedule only once.
        guard timer == nil else { return }
        enabled = loadEnabled()
        previousProAccess = hasProAccess
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.syncNow() }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            // Ignore account-change notifications after the coordinator is released.
            guard let self else { return }
            self.epoch += 1
            self.task?.cancel()
            // An opt-in made before this notification cannot authorize a different account.
            self.allowAccountChange = false
            self.anotherPass = true
            self.retryAt = .distantPast
            self.syncNow()
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.syncNow() }
        proObserver = NotificationCenter.default.addObserver(forName: ProStore.entitlementDidChange, object: nil, queue: .main) { [weak self] _ in self?.proAccessChanged() }
        // Start the initial pass only when this device previously opted into sync.
        if enabled { syncNow() }
    }

    // proAccessChanged(): Keep the opt-in and merge history through expiry. A
    // renewal resumes only an existing opt-in.
    private func proAccessChanged() {
        let access = hasProAccess
        // Avoid cancelling or restarting work when Pro access has not actually changed.
        guard access != previousProAccess else { return }
        previousProAccess = access
        epoch += 1
        task?.cancel()
        scheduledSync?.cancel()
        anotherPass = enabled && access && isSyncing
        retryAt = .distantPast
        // Refresh or pause only an explicitly enabled sync configuration.
        if enabled {
            // Resume opted-in sync when Pro access returns.
            if access { syncNow() }
            // Explain that enabled sync is paused when Pro access is lost.
            else { publish(Self.proPausedMessage) }
        // Keep the off-state explanation when the user has not opted in.
        } else { /* Explain that disabling sync preserves both sets of saved items. */ publish("iCloud sync is off. Local and iCloud copies are kept.") }
    }

    // setEnabled(enabled): Apply device-local sync opt-in, enforcing Pro access
    // while always permitting opt-out.
    func setEnabled(_ enabled: Bool) {
        // Callers cannot enable background sync by bypassing the purchase UI. Opt-out is always allowed.
        if enabled {
            // Do not enable sync without Pro access, even if a caller bypasses the purchase UI.
            guard hasProAccess else { publish(self.enabled ? Self.proPausedMessage : Self.proRequiredMessage); return }
            // Do not enable sync when this executable lacks the required signed iCloud capability.
            guard buildSupported() else { publish("iCloud requires an Apple-signed build with iCloud enabled."); return }
        }
        self.enabled = enabled
        saveEnabled(enabled)
        epoch += 1
        task?.cancel()
        scheduledSync?.cancel()
        allowAccountChange = enabled
        anotherPass = enabled && isSyncing
        retryAt = .distantPast
        // Begin merging immediately after a successful opt-in.
        if enabled { syncNow() }
        // Keep both local and cloud copies when sync is turned off.
        else { publish("iCloud sync is off. Local and iCloud copies are kept.") }
    }

    // libraryChanged(): Debounce completed store writes. Timed scans also
    // recover changes made just before a crash.
    func libraryChanged() {
        // Ignore automatic scheduling while sync is off or Pro access is unavailable.
        guard enabled, hasProAccess else { return }
        // Remember a requested extra pass instead of starting overlapping sync work.
        if isSyncing { anotherPass = true; return }
        scheduledSync?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        scheduledSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // syncNow(): Start an explicit sync only when opt-in, entitlement, and
    // current coordinator state allow it.
    func syncNow() {
        // An explicit Sync Now action still requires device-local opt-in.
        guard enabled else { return }
        // Pause opted-in sync while Pro access is unavailable.
        guard hasProAccess else {
            publish(Self.proPausedMessage)
            return
        }
        // Explain unsupported signing before attempting any CloudKit operation.
        guard buildSupported() else {
            publish("iCloud requires an Apple-signed build with iCloud enabled.")
            return
        }
        // Avoid overlapping passes and respect the current failure backoff deadline.
        guard !isSyncing, Date() >= retryAt else { return }
        isSyncing = true
        publish("Syncing Library…")
        let generation = epoch
        task = Task { @MainActor [weak self] in
            // Stop the asynchronous pass if the coordinator was released before it began.
            guard let self else { return }
            // Run one sync generation and report only failures that still belong to it.
            do {
                try await self.synchronize(generation: generation)
                try self.check(generation)
                self.failures = 0
                self.lastSync = Date()
                self.publish(self.state.inbox.isEmpty ? "Library is up to date." : "Close open Library results to receive their iCloud updates.")
            } catch is CancellationError {
                // Disabling sync, losing Pro, or switching accounts must not apply an old result.
                if self.enabled && !self.hasProAccess { self.publish(Self.proPausedMessage) }
            } catch {
                // Apply backoff and status only for a failure belonging to the current sync generation.
                // Ignore failures from work invalidated by opt-out, account changes, or access changes.
                if generation == self.epoch {
                    self.failures += 1
                    let delay = (error as? CKError)?.retryAfterSeconds ?? min(300, pow(2, Double(min(self.failures, 8))))
                    self.retryAt = Date().addingTimeInterval(max(2, delay))
                    // Do not replace the off-state message with a delayed sync error.
                    if self.enabled { self.publish(self.message(for: error)) }
                }
            }
            self.isSyncing = false
            self.task = nil
            NotificationCenter.default.post(name: Self.statusDidChange, object: self)
            // Schedule changes that arrived while the completed pass was running.
            if self.anotherPass {
                self.anotherPass = false
                self.syncNow()
            }
        }
    }

    // publish(text): Publish a new sync status for observing Settings controls.
    private func publish(_ text: String) {
        status = text
        NotificationCenter.default.post(name: Self.statusDidChange, object: self)
    }

    // message(error): Translate cloud failures into actionable status text
    // while retaining other error descriptions.
    private func message(for error: Error) -> String {
        // Provide specific recovery text for known CloudKit errors.
        if let cloud = error as? CKError {
            // Separate connectivity, quota, account, conflict, and build-configuration failures.
            switch cloud.code {
            // Keep local work available while waiting for connectivity to return.
            case .networkFailure, .networkUnavailable: return "Offline. Your Library changes will sync when the connection returns."
            // Explain that the account needs available iCloud storage.
            case .quotaExceeded: return "Your iCloud storage is full. Free up space to resume Library sync."
            // Explain when iCloud authentication is missing.
            case .notAuthenticated: return "Sign in to iCloud in System Settings to resume sync."
            // Retry after concurrent cloud updates invalidate the submitted record version.
            case .serverRecordChanged, .batchRequestFailed: return "Another Mac updated the Library. Retrying with its latest changes."
            // Distinguish build and container configuration failures from user data problems.
            case .permissionFailure, .missingEntitlement, .badContainer: return "iCloud is not configured for this build. Check its signing and iCloud container."
            // Use the error's ordinary description for other CloudKit failures.
            default: break
            }
        }
        return "Sync paused: \(error.localizedDescription) Your local Library is kept."
    }

    // check(generation): Stop work whose generation was superseded, whose Pro
    // access ended, or whose task was cancelled.
    private func check(_ generation: Int) throws {
        // Abort when this generation is stale or Pro access has ended.
        guard generation == epoch, hasProAccess else { throw CancellationError() }
        try Task.checkCancellation()
    }

    // persist(): Atomically persist sync state with stable key ordering.
    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: storage.appendingPathComponent("state.json"), options: .atomic)
    }

    // synchronize([generation = nil]): The account binding prevents a newly
    // signed-in Apple Account from receiving the previous account's data.
    @MainActor func synchronize(generation: Int? = nil) async throws {
        let generation = generation ?? epoch
        try check(generation)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Load and validate durable sync state once per coordinator lifecycle.
        if !stateLoaded {
            let url = storage.appendingPathComponent("state.json")
            // Restore state only when a previous state file exists.
            if FileManager.default.fileExists(atPath: url.path) {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
                // Refuse a persisted sync format this client does not understand.
                guard state.version == 1 else { throw CloudKitLibraryTransport.Failure.unsupported }
                var missingDownloads = Set<String>()
                // Validate both acknowledged records and pending incoming records.
                for (records, pending) in [(state.known, false), (state.inbox, true)] {
                    // Check each saved record against the dictionary key that identifies it.
                    for (id, record) in records {
                        // Reject mismatched record identities or invalid persisted metadata.
                        // Reject malformed records before accepting their archive chunks.
                        guard id == record.id,
                              record.folderName.map({ Self.folderID($0) == id }) ?? LibrarySyncArchive.validID(id),
                              record.digest.map(LibrarySyncArchive.validDigest) ?? true,
                              pending || record.chunks.isEmpty else { throw LibrarySyncArchive.Failure.invalid }
                        // Validate every persisted incoming chunk reference before reusing it.
                        for chunk in record.chunks {
                            // Require task-owned incoming files with valid filenames under the expected staging directory.
                            guard chunk.isFileURL, LibrarySyncArchive.validID(chunk.lastPathComponent),
                                  chunk.deletingLastPathComponent().standardizedFileURL == storage.appendingPathComponent("Incoming").standardizedFileURL else { throw LibrarySyncArchive.Failure.invalid }
                            // Verify each staged chunk still exists as a permitted regular file.
                            do { _ = try LibrarySyncArchive.checkedFile(chunk.lastPathComponent, in: chunk.deletingLastPathComponent()) }
                            // Mark missing staged downloads for refetching rather than trusting the saved token alone.
                            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                                missingDownloads.insert(id)
                            }
                        }
                    }
                }
                // Lost staging files are recoverable from CloudKit. Keep acknowledgements and the
                // account binding, and refetch the affected records before advancing their history.
                if !missingDownloads.isEmpty {
                    state.token = nil
                    // Remove records whose staged assets are missing so the next fetch can recover them.
                    for id in missingDownloads { state.inbox.removeValue(forKey: id) }
                }
            }
            // These are disposable working copies, never acknowledged downloads or local Library data.
            for url in try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil) {
                // Clean only recognized abandoned preparation directories with valid generated IDs.
                for prefix in ["Prepared-", "Download-", "Conflict-"]
                where url.lastPathComponent.hasPrefix(prefix) && LibrarySyncArchive.validID(String(url.lastPathComponent.dropFirst(prefix.count))) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            stateLoaded = true
        }
        let cloud = transport ?? makeTransport()
        transport = cloud
        let account = try await cloud.accountID()
        try check(generation)
        let isNew = state.account == nil
        let switchingAccount = state.account.map { account != $0 } ?? false
        // Handle an account change separately from normal sync continuation.
        if switchingAccount {
            // Require explicit off-and-on opt-in before merging with a different Apple Account.
            guard allowAccountChange else {
                publish("Your iCloud account changed. Turn sync off and on to merge this Library with the new account.")
                throw CancellationError()
            }
        }
        // Bind the first resolved identity before another suspension. Later account changes must
        // retain the previous binding until setup succeeds in the same, still-authorized generation.
        if isNew {
            state.account = account
            try persist()
        }
        let createdZone = try await cloud.prepare(createZone: isNew || allowAccountChange)
        try check(generation)
        // Discard old account or zone baselines when starting a newly authorized merge.
        if createdZone || switchingAccount {
            state = State()
            cache.removeAll()
        }
        state.account = account
        allowAccountChange = false
        try persist()
        let incoming = storage.appendingPathComponent("Incoming")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        // A cancelled or partially fetched page may leave files without a committed token.
        try cleanIncoming(incoming)
        var more = true
        // Fetch change pages until CloudKit reports the end of the current change stream.
        while more {
            try check(generation)
            // Fetch one change page before persisting its records and continuation token.
            do {
                let page = try await cloud.fetch(since: state.token, into: incoming)
                try check(generation)
                // Persist each fetched record in the inbox before advancing its continuation token.
                for record in page.records { state.inbox[record.id] = record }
                state.token = page.token
                // Assets are already local before this token is saved; a crash cannot skip a download.
                try persist()
                more = page.moreComing
            } catch let error as CKError where error.code == .changeTokenExpired {
                // Recover from an expired change token by fetching the zone again.
                try check(generation)
                // Do not loop indefinitely if a full fetch without a token also reports expiry.
                guard state.token != nil else { throw error }
                state.token = nil
                try persist()
            }
        }

        var local = try await localItems(generation: generation)
        try check(generation)
        let pendingDeletes = pendingDeletionIDs()
        let ids = Set(local.keys).union(state.known.keys).union(state.inbox.keys).subtracting(pendingDeletes)
        var changed = false
        // Notify the Library once after this merge if any local entry changed.
        defer { /* Notify the Library once after any successful local changes. */ if changed { onLibraryChanged() } }
        // Merge records in stable ID order with cancellation checks between items.
        for id in ids.sorted() {
            try check(generation)
            let base = state.known[id]
            let remote = state.inbox[id] ?? base
            let value = local[id]
            // A new installation restoring an old local copy must also respect existing tombstones.
            let decision: LibrarySyncDecision = base == nil && remote != nil && remote?.digest == nil && value != nil
                ? .conflict : LibrarySyncDecision.resolve(base: base?.digest, local: value?.digest, remote: remote?.digest)
            // A saved window may still be editing or generating audio against this entry's files.
            if state.inbox[id] != nil, openEntryIDs().contains(id), decision == .download || decision == .conflict { continue }
            // Recheck after each await so typing, renaming or Undo cannot be overwritten by a stale capture.
            guard try currentStamp(id: id, folder: value?.folder ?? remote?.folderName) == value?.stamp else {
                anotherPass = true
                continue
            }
            // Choose the operation from the local, remote, and last shared content stamps.
            switch decision {
            // Acknowledge matching content without transferring an asset.
            case .unchanged:
                // Retain the matching remote record's version fields without its temporary assets.
                if let remote { state.known[id] = withoutAssets(remote) }
                state.inbox.removeValue(forKey: id)
            // Upload a local change or tombstone using the current shared record version.
            case .upload:
                let archive = value?.archive
                // Require an archive for live entries; folders and deletions need no file payload.
                guard value == nil || value?.folder != nil || archive != nil else { throw LibrarySyncArchive.Failure.incomplete }
                let chunks = try await Task.detached(priority: .utility) { try archive.map { try Self.split($0) } ?? [] }.value
                try check(generation)
                // Splitting large audio yields to edits and Undo, just like preparing a download.
                guard !pendingDeletionIDs().contains(id),
                      try currentStamp(id: id, folder: value?.folder ?? remote?.folderName) == value?.stamp else { anotherPass = true; continue }
                let upload = LibraryCloudRecord(id: id, digest: value?.digest, folderName: value?.folder ?? base?.folderName,
                                                systemFields: remote?.systemFields ?? Data(), chunks: chunks)
                let saved = try await cloud.save(upload)
                try check(generation)
                state.known[id] = withoutAssets(saved)
                state.inbox.removeValue(forKey: id)
            // Prepare remote content before applying downloads or preserving conflicts.
            case .download, .conflict:
                // A remote-apply decision requires an actual remote record.
                guard let remote else { throw LibrarySyncArchive.Failure.invalid }
                let prepared: URL?
                // Prepare and validate the incoming payload before deciding how to merge it.
                do { prepared = try await prepareIncoming(remote) }
                // Recheck cancellation before deciding how to recover from failed incoming preparation.
                catch {
                    try check(generation)
                    // Refetch damaged or missing staging assets instead of trapping the item behind
                    // an acknowledged token. The existing local entry remains untouched.
                    state.token = nil
                    state.inbox.removeValue(forKey: id)
                    try persist()
                    throw error
                }
                // Remove prepared incoming files after this record is merged or rejected.
                defer { /* Remove the temporary archive even when applying it fails. */ if let prepared { try? FileManager.default.removeItem(at: prepared) } }
                try check(generation)
                // Defer applying content that was opened, deleted for undo, or edited while preparation awaited.
                guard !openEntryIDs().contains(id), !pendingDeletionIDs().contains(id),
                      try currentStamp(id: id, folder: value?.folder ?? remote.folderName) == value?.stamp else { anotherPass = true; continue }
                // Validate prepared entry metadata before it can replace Library content.
                if let prepared { try validateEntry(prepared) }
                if decision == .conflict, remote.folderName == nil {
                    // Preserve both edits. When deletion races an edit, the edited version becomes a separate item.
                    if value != nil {
                        try preserveConflict(from: library.appendingPathComponent(id), id: id, digest: value!.digest)
                    } else if let prepared, let digest = remote.digest {
                        // Preserve a competing remote edit when the conflict requires keeping that version separately.
                        try preserveConflict(from: prepared, id: id, digest: digest)
                        state.known[id] = withoutAssets(remote)
                        state.inbox.removeValue(forKey: id)
                        try persist()
                        anotherPass = true
                        changed = true
                        continue
                    }
                }
                try install(remote, prepared: prepared)
                cache.removeValue(forKey: id)
                state.known[id] = withoutAssets(remote)
                state.inbox.removeValue(forKey: id)
                local.removeValue(forKey: id)
                changed = true
            }
            try persist()
        }
        // Only assets still referenced by a durable pending record survive between passes.
        try cleanIncoming(incoming)
        // Uploaded copies are reproducible from the Library. Do not retain deleted audio or duplicate
        // an entire synced Library in the staging cache after its server acknowledgement is durable.
        let outbox = storage.appendingPathComponent("Outgoing")
        // Remove outgoing snapshots no longer needed for this local or acknowledged state.
        for url in try FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil) {
            let id = url.lastPathComponent
            // Delete snapshots for removed items or content already acknowledged by the cloud.
            if local[id] == nil || state.known[id]?.digest == cache[id]?.digest {
                try? FileManager.default.removeItem(at: url)
                // Keep reusable digest and stamp metadata after dropping the cached archive path.
                if let value = cache[id] {
                    cache[id] = Local(digest: value.digest, folder: value.folder, archive: nil, stamp: value.stamp)
                }
            }
        }
    }

    // withoutAssets(value): Retain record metadata without temporary asset
    // references once those assets are no longer needed.
    private func withoutAssets(_ value: LibraryCloudRecord) -> LibraryCloudRecord {
        var copy = value
        copy.chunks = []
        return copy
    }

    // cleanIncoming(directory): Delete incoming files only when no persisted
    // inbox record still references them.
    private func cleanIncoming(_ directory: URL) throws {
        let retained = Set(state.inbox.values.flatMap(\.chunks).map(\.lastPathComponent))
        // Delete incoming files only when no durable inbox record still references them.
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where !retained.contains(url.lastPathComponent) { try FileManager.default.removeItem(at: url) }
    }
    // folderID(name): Derive a stable cloud record ID from a folder's exact
    // name.
    static func folderID(_ name: String) -> String { "folder-" + LibrarySyncArchive.hash(Data(name.utf8)) }

    // folders(): Read and validate the explicit local folder list used by sync.
    private func folders() throws -> [String] {
        let url = library.appendingPathComponent("folders.json")
        // An absent explicit folder file means there are no empty folders to sync.
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        // Reject invalid folder names before deriving their cloud identities.
        // Reject empty, oversized, or padded folder names before merging them.
        guard names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }) else { throw LibrarySyncArchive.Failure.invalid }
        return names
    }

    // currentStamp(id, folder): Recheck an entry or folder's current content
    // stamp before applying an asynchronous result.
    private func currentStamp(id: String, folder: String?) throws -> String? {
        // Use a name digest for an existing folder and no stamp for a removed folder.
        if let folder { return try folders().contains(folder) ? LibrarySyncArchive.hash(Data(folder.utf8)) : nil }
        // Require a valid entry ID before resolving its Library directory.
        guard LibrarySyncArchive.validID(id) else { throw LibrarySyncArchive.Failure.invalid }
        let directory = library.appendingPathComponent(id)
        // A missing local entry directory represents a deletion.
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let metadata = try LibrarySyncArchive.metadata(in: directory)
        var stamp = Data(metadata)
        // Include every referenced asset's filesystem state when checking for local edits.
        for path in try LibrarySyncArchive.paths(in: metadata, id: id) {
            let url = try LibrarySyncArchive.checkedFile(path, in: directory)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let date = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            stamp.append(Data("\(path):\(attrs[.size] ?? 0):\(date):\(attrs[.systemFileNumber] ?? 0)".utf8))
        }
        return LibrarySyncArchive.hash(stamp)
    }

    // localItems(generation): Capture local entries and folders into the
    // outgoing snapshot for this sync generation.
    @MainActor private func localItems(generation: Int) async throws -> [String: Local] {
        let outbox = storage.appendingPathComponent("Outgoing")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        var result: [String: Local] = [:]
        let children = try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
        // Snapshot only valid entry directories, checking this sync generation between entries.
        for source in children where LibrarySyncArchive.validID(source.lastPathComponent) {
            try check(generation)
            let id = source.lastPathComponent
            // Skip records whose local entry no longer has an uploadable stamp.
            guard let stamp = try currentStamp(id: id, folder: nil) else { continue }
            // An acknowledged archive is disposable, but a later restore needs new upload bytes.
            if let cached = cache[id], cached.stamp == stamp,
               cached.archive != nil || state.known[id]?.digest == cached.digest { result[id] = cached; continue }
            let work = outbox.appendingPathComponent(id)
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let copy = work.appendingPathComponent("Files")
            try LibrarySyncArchive.capture(source, id: id, to: copy)
            let destination = work.appendingPathComponent("item.archive")
            let package = try await Task.detached(priority: .utility) { try LibrarySyncArchive.pack(copy, id: id, to: destination) }.value
            try check(generation)
            try? FileManager.default.removeItem(at: copy)
            let value = Local(digest: package.digest, folder: nil, archive: package.url, stamp: stamp)
            cache[id] = value
            result[id] = value
        }
        // Include explicitly saved folders even when they currently contain no entries.
        for name in try folders() {
            let digest = LibrarySyncArchive.hash(Data(name.utf8))
            result[Self.folderID(name)] = Local(digest: digest, folder: name, archive: nil, stamp: digest)
        }
        cache = cache.filter { result[$0.key] != nil }
        return result
    }

    // split(archive): Split an archive into bounded cloud-asset chunks without
    // loading the entire package at once.
    private static func split(_ archive: URL) throws -> [URL] {
        let input = try FileHandle(forReadingFrom: archive)
        // Close the source archive after splitting it into upload chunks.
        defer { try? input.close() }
        var chunks: [URL] = []
        // Write archive chunks no larger than the CloudKit asset limit used by this format.
        while let data = try input.read(upToCount: LibrarySyncArchive.chunkBytes), !data.isEmpty {
            let url = archive.deletingLastPathComponent().appendingPathComponent("chunk-\(chunks.count)")
            try data.write(to: url, options: .atomic)
            chunks.append(url)
        }
        return chunks
    }

    // prepareIncoming(value): Validate incoming folder or entry content and
    // prepare it for installation.
    private func prepareIncoming(_ value: LibraryCloudRecord) async throws -> URL? {
        // A tombstone has no content to unpack.
        guard let digest = value.digest else { return nil }
        // Validate folder records by name without expecting an entry archive.
        if let name = value.folderName {
            // Require the folder name, digest, and deterministic cloud ID to agree.
            guard digest == LibrarySyncArchive.hash(Data(name.utf8)), Self.folderID(name) == value.id else { throw LibrarySyncArchive.Failure.invalid }
            return nil
        }
        let directory = storage.appendingPathComponent("Prepared-" + UUID().uuidString)
        let archive = storage.appendingPathComponent("Download-" + UUID().uuidString)
        return try await Task.detached(priority: .utility) {
            // Remove the temporary joined archive after incoming preparation finishes.
            defer { try? FileManager.default.removeItem(at: archive) }
            FileManager.default.createFile(atPath: archive.path, contents: nil)
            let output = try FileHandle(forWritingTo: archive)
            // Close the joined archive's output handle even when a chunk fails validation.
            defer { try? output.close() }
            var total: UInt64 = 0
            // Combine incoming chunks in the order stored by the cloud record.
            for chunk in value.chunks {
                let input = try FileHandle(forReadingFrom: chunk)
                // Close each chunk before advancing to the next one.
                defer { try? input.close() }
                // Read each chunk incrementally while enforcing the whole-item limit.
                while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                    total += UInt64(data.count)
                    // Stop an oversized incoming item before writing more data.
                    guard total <= LibrarySyncArchive.maximumBytes else { throw LibrarySyncArchive.Failure.tooLarge }
                    try output.write(contentsOf: data)
                }
            }
            try LibrarySyncArchive.unpack(archive, digest: digest, id: value.id, to: directory)
            return directory
        }.value
    }

    // preserveConflict(source, id, digest): Preserve competing entry content
    // under a deterministic conflict-copy ID so retries do not duplicate it.
    private func preserveConflict(from source: URL, id: String, digest: String) throws {
        // A stable ID makes retries after a crash idempotent on every Mac.
        let hash = LibrarySyncArchive.hash(Data((id + digest).utf8))
        let raw = String(hash.prefix(32))
        let uuid = "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-\(raw.dropFirst(16).prefix(4))-\(raw.suffix(12))".uppercased()
        let target = library.appendingPathComponent(uuid)
        // Reuse an existing deterministic conflict copy instead of duplicating it on retry.
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        let staged = storage.appendingPathComponent("Conflict-" + UUID().uuidString)
        // Remove the temporary captured archive after computing its digest.
        defer { try? FileManager.default.removeItem(at: staged) }
        try LibrarySyncArchive.capture(source, id: id, to: staged)
        let metadataURL = staged.appendingPathComponent("entry.json")
        // Require a valid metadata object before assigning the conflict copy its new entry ID.
        guard var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any] else { throw LibrarySyncArchive.Failure.invalid }
        metadata["id"] = uuid
        metadata["title"] = (metadata["title"] as? String ?? "Result") + " (Conflict copy)"
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted]).write(to: metadataURL, options: .atomic)
        try FileManager.default.moveItem(at: staged, to: target)
        anotherPass = true
    }

    // install(value, prepared): Apply a validated incoming folder, entry, or
    // tombstone to the local Library.
    private func install(_ value: LibraryCloudRecord, prepared: URL?) throws {
        // Apply folder membership directly to the explicit folder-name list.
        if let name = value.folderName {
            var names = try folders().filter { $0 != name }
            // Reinsert the folder only for a live record; a tombstone leaves it removed.
            if value.digest != nil { names.append(name) }
            try JSONEncoder().encode(names.sorted()).write(to: library.appendingPathComponent("folders.json"), options: .atomic)
            return
        }
        let target = library.appendingPathComponent(value.id)
        // Install a prepared live entry after validating it again.
        if let prepared {
            try validateEntry(prepared)
            // Atomically replace an existing entry directory with its prepared version.
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: prepared)
            // Move a new entry into place when no prior local entry exists.
            } else { /* Install the prepared item when no local copy exists. */ try FileManager.default.moveItem(at: prepared, to: target) }
        } else if FileManager.default.fileExists(atPath: target.path) {
            // Remove an existing local entry when the remote record is a tombstone.
            try FileManager.default.removeItem(at: target)
        }
    }
}
