import Cocoa
import CloudKit

// langminApplicationSupportDirectory(): No app launch, preferences, account
// lookup, or live CloudKit calls. Each simulated Mac has private files under
// the supplied test directory and shares only the in-memory transport below.
func langminApplicationSupportDirectory() -> URL { fatalError("Unexpected user storage access") }
// langminPreferencesStore(): Fail if a sync test reaches the user’s real
// preferences.
func langminPreferencesStore() -> UserDefaults { fatalError("Unexpected user preferences access") }
// Require sync coordinators to use injected Pro access.
final class ProStore {
    static let shared = ProStore()
    static let entitlementDidChange = Notification.Name("FixtureProEntitlementDidChange")
    var hasFullAccess: Bool { fatalError("Tests must inject Pro access") }
}
// Let tests change Pro access and opt-in independently.
final class SyncAccess {
    var pro = false
    var enabled = false
}
var checks = 0
// check(condition, message): Report failed fixture expectations with their case
// names.
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    // Stop this fixture when its named expectation does not hold.
    guard try condition() else { throw NSError(domain: "Fixture: " + message, code: 1) }
    checks += 1
}
// rejects(message, work): Require invalid archive input to throw an error.
func rejects(_ message: String, _ work: () throws -> Void) throws {
    // Count a thrown validation error and reject unexpected success.
    do { try work() } catch { checks += 1; return }
    throw NSError(domain: "Expected rejection: " + message, code: 1)
}

// Simulate paged cloud records, account changes, and conflicts using temporary files.
final class Server: LibraryCloudTransport {
    let root: URL
    var account = "fixture-account"
    var rows: [String: LibraryCloudRecord] = [:]
    var history: [String] = []
    var offline = false
    var pageSize = 100
    var beforeSave: (() async throws -> Void)?
    var beforeFetch: (() async throws -> Void)?
    var beforePrepare: (() async throws -> Void)?
    var afterSave: (() -> Void)?
    var requests = 0
    // init(root): Create the temporary server-side attachment directory.
    init(root: URL) throws { self.root = root; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    // accountID(): Count account lookups and simulate loss of connectivity when
    // requested.
    func accountID() async throws -> String { requests += 1; /* Simulate an unavailable account without contacting CloudKit. */ if offline { throw CKError(.networkUnavailable) }; return account }
    // prepare(createZone): Expose a one-shot hook for account changes during
    // zone preparation.
    func prepare(createZone: Bool) async throws -> Bool {
        requests += 1
        // Run the preparation hook once so retries see the changed state.
        if let action = beforePrepare { beforePrepare = nil; try await action() }
        return false
    }
    // fetch(token, directory): Return a page of changed records with fresh
    // local copies of their attachments.
    func fetch(since token: Data?, into directory: URL) async throws -> LibraryCloudPage {
        requests += 1
        // Run the fetch hook once to simulate cancellation or a concurrent operation.
        if let action = beforeFetch { beforeFetch = nil; try await action() }
        let cursor = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let end = min(history.count, cursor + pageSize)
        var values: [LibraryCloudRecord] = []
        // Return each changed ID once per page, using its latest server value.
        for id in Set(history[cursor..<end]) {
            var value = rows[id]!
            value.chunks = try value.chunks.map { source in
                let target = directory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.copyItem(at: source, to: target)
                return target
            }
            values.append(value)
        }
        return LibraryCloudPage(records: values, token: Data(String(end).utf8), moreComing: end < history.count)
    }
    // save(record): Save attachment copies only if the caller still has the
    // current server tag.
    func save(_ record: LibraryCloudRecord) async throws -> LibraryCloudRecord {
        requests += 1
        // Run a competing operation immediately before the tag comparison.
        if let action = beforeSave { beforeSave = nil; try await action() }
        // Reject a stale upload rather than overwriting a newer server record.
        guard rows[record.id]?.systemFields ?? Data() == record.systemFields else { throw CKError(.serverRecordChanged) }
        var saved = record
        saved.chunks = try record.chunks.map { source in
            let target = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }
        saved.systemFields = Data(UUID().uuidString.utf8)
        rows[saved.id] = saved
        history.append(saved.id)
        // Allow one post-save action to test changes after the server accepts a record.
        if let action = afterSave { afterSave = nil; action() }
        return saved
    }
}

// Run sync and archive regressions against temporary simulated Macs.
@main struct Tests {
    // main(): Exercise synchronization between isolated Library directories and
    // simulated accounts.
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        let server = try Server(root: root.appendingPathComponent("Server"))
        // mac(name): Create a simulated Mac with its own Library and sync
        // state.
        func mac(_ name: String) -> LibraryCloudSync {
            LibraryCloudSync(library: root.appendingPathComponent(name + "/Library"), storage: root.appendingPathComponent(name + "/Sync"), transport: { server }, proAccess: { true })
        }
        let a = mac("A"), b = mac("B")
        // make(sync, text, [id = UUID().uuidString]): Create a saved entry
        // containing text, conversation metadata, and referenced assets.
        func make(_ sync: LibraryCloudSync, text: String, id: String = UUID().uuidString) throws -> String {
            let dir = sync.library.appendingPathComponent(id)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let metadata: [String: Any] = ["id": id, "textFile": "text.md", "title": "Fixture", "mode": "explain", "fontSize": 16, "createdAt": 1,
                "audioFile": "audio.caf", "illustrationFile": "illustration.png", "diffOriginalFile": "original.md", "diffRevisedFile": "revised.md",
                "pronunciations": [["key": "word", "file": "pronounce/p.caf"]],
                "sourceImages": [["id": "image", "file": "source.png", "sourceURL": "https://example.com/image", "pageURL": "https://example.com"]],
                "conversation": ["originalRequest": "Question", "turns": [["answer": "Reply"]]]]
            try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: dir.appendingPathComponent("entry.json"))
            try text.write(to: dir.appendingPathComponent("text.md"), atomically: true, encoding: .utf8)
            try fm.createDirectory(at: dir.appendingPathComponent("pronounce"), withIntermediateDirectories: true)
            // Populate each referenced asset with known bytes for round-trip comparisons.
            for path in ["audio.caf", "illustration.png", "original.md", "revised.md", "pronounce/p.caf", "source.png"] {
                try Data([0, 1, 128, 255, 10]).write(to: dir.appendingPathComponent(path))
            }
            return id
        }
        // edit(sync, id, text): Change an entry’s text without replacing its
        // other metadata.
        func edit(_ sync: LibraryCloudSync, _ id: String, _ text: String) throws {
            try text.write(to: sync.library.appendingPathComponent(id + "/text.md"), atomically: true, encoding: .utf8)
        }
        // text(sync, id): Read a simulated Mac’s local version of an entry.
        func text(_ sync: LibraryCloudSync, _ id: String) throws -> String {
            try String(contentsOf: sync.library.appendingPathComponent(id + "/text.md"), encoding: .utf8)
        }
        // ids(sync): List only valid Library entry IDs in the fixture
        // directory.
        func ids(_ sync: LibraryCloudSync) throws -> [String] {
            try fm.contentsOfDirectory(atPath: sync.library.path).filter(LibrarySyncArchive.validID)
        }
        // files(sync, id): Read every referenced file so comparisons detect
        // lost or changed attachments.
        func files(_ sync: LibraryCloudSync, _ id: String) throws -> [String: Data] {
            let dir = sync.library.appendingPathComponent(id)
            return try Dictionary(uniqueKeysWithValues: LibrarySyncArchive.paths(in: Data(contentsOf: dir.appendingPathComponent("entry.json")), id: id).map { ($0, try Data(contentsOf: dir.appendingPathComponent($0))) })
        }

        let id = try make(a, text: "Hello **world** — Привет 👋")
        try Data("Do not sync".utf8).write(to: a.library.appendingPathComponent(id + "/leftover.tmp"))
        try await a.synchronize()
        try await b.synchronize()
        try check(try files(a, id) == files(b, id), "Initial restore preserves all text, conversations and binary assets")
        try check(!fm.fileExists(atPath: b.library.appendingPathComponent(id + "/leftover.tmp").path), "Unreferenced files do not upload")
        let uploads = server.history.count
        try await a.synchronize(); try await b.synchronize()
        try check(server.history.count == uploads, "No echo uploads after a download or cache reload")
        let restarted = mac("B")
        try await restarted.synchronize()
        try check(server.history.count == uploads, "Restart uses the persisted acknowledgement and token")

        server.offline = true
        try edit(a, id, "Offline edit")
        // Attempt sync while the fixture transport is offline.
        do { try await a.synchronize(); throw NSError(domain: "Expected offline", code: 0) }
        // Confirm that an offline error is reported while local changes remain intact.
        catch let error as CKError { try check(error.code == .networkUnavailable, "Offline failure is surfaced") }
        try check(try text(a, id) == "Offline edit", "Offline changes remain local")
        server.offline = false
        try await a.synchronize(); try await b.synchronize()
        try check(try text(b, id) == "Offline edit", "Reconnect sends offline changes")

        b.openEntryIDs = { [id] }
        try edit(a, id, "Remote edit while open")
        try await a.synchronize(); try await b.synchronize()
        try check(try text(b, id) == "Offline edit", "Open result backing files are not replaced")
        let pendingRestart = mac("B")
        pendingRestart.openEntryIDs = { [id] }
        try await pendingRestart.synchronize()
        try check(try text(b, id) == "Offline edit", "Pending downloads survive restart")
        pendingRestart.openEntryIDs = { [] }
        try await pendingRestart.synchronize()
        try check(try text(b, id) == "Remote edit while open", "Closing applies the durable pending download")
        // Continue with a fresh coordinator after another process has advanced the same simulated Mac.
        let c = mac("B")
        try await c.synchronize()
        try edit(a, id, "Edit from A")
        try edit(c, id, "Edit from B")
        try await a.synchronize(); try await c.synchronize(); try await c.synchronize(); try await a.synchronize()
        let variants = try ids(a).map { try text(a, $0) }
        try check(Set(variants) == Set(["Edit from A", "Edit from B"]), "Concurrent edits preserve both versions")
        let count = try ids(c).count
        try await mac("B").synchronize()
        try check(try ids(c).count == count, "Conflict retries do not create duplicate copies")

        // Server-tag comparison catches an edit that arrives between fetch and save.
        let racer = try make(a, text: "Race base")
        try await a.synchronize(); try await c.synchronize()
        try edit(a, racer, "Race A"); try edit(c, racer, "Race B")
        server.beforeSave = { try await c.synchronize() }
        // Attempt an upload after a competing server update.
        do { try await a.synchronize(); throw NSError(domain: "Expected server conflict", code: 0) }
        // Confirm that a concurrent server edit rejects the stale upload.
        catch let error as CKError { try check(error.code == .serverRecordChanged, "Concurrent server update rejects stale upload") }
        try await a.synchronize(); try await a.synchronize(); try await c.synchronize()
        try check(try Set(ids(a).map { try text(a, $0) }).isSuperset(of: ["Race A", "Race B"]), "Server conflict keeps both edits")

        let deleted = try make(a, text: "Delete base")
        try await a.synchronize(); try await c.synchronize()
        try fm.removeItem(at: a.library.appendingPathComponent(deleted))
        try edit(c, deleted, "Edit during deletion")
        try await a.synchronize(); try await c.synchronize(); try await c.synchronize(); try await a.synchronize()
        try check(!fm.fileExists(atPath: c.library.appendingPathComponent(deleted).path), "Tombstone removes the original deleted entry")
        try check(try ids(c).contains { try text(c, $0) == "Edit during deletion" }, "Delete/edit conflict preserves edited content separately")
        let late = mac("Late")
        try await late.synchronize()
        try check(!fm.fileExists(atPath: late.library.appendingPathComponent(deleted).path), "New Mac does not resurrect tombstones")

        let inverse = try make(a, text: "Inverse base")
        try await a.synchronize(); try await c.synchronize()
        try fm.removeItem(at: c.library.appendingPathComponent(inverse))
        try edit(a, inverse, "Remote edit versus local delete")
        try await a.synchronize(); try await c.synchronize(); try await c.synchronize(); try await a.synchronize()
        try check(!fm.fileExists(atPath: a.library.appendingPathComponent(inverse).path), "Local delete remains deleted after conflict resolution")
        try check(try ids(c).contains { try text(c, $0) == "Remote edit versus local delete" }, "Remote edit survives the inverse deletion conflict")

        let undo = try make(a, text: "Undo me")
        try await a.synchronize(); try await c.synchronize()
        let staged = root.appendingPathComponent("Undo")
        try fm.moveItem(at: a.library.appendingPathComponent(undo), to: staged)
        a.pendingDeletionIDs = { [undo] }
        try await a.synchronize(); try await c.synchronize()
        try check(try text(c, undo) == "Undo me", "Pending Undo does not send deletion")
        try fm.moveItem(at: staged, to: a.library.appendingPathComponent(undo))
        a.pendingDeletionIDs = { [] }
        try await a.synchronize()
        try check(server.rows[undo]?.digest != nil, "Undo leaves the cloud item intact")

        try JSONEncoder().encode(["English", "Српски"]).write(to: a.library.appendingPathComponent("folders.json"))
        server.pageSize = 1
        try await a.synchronize(); try await c.synchronize()
        try check(try Set(JSONDecoder().decode([String].self, from: Data(contentsOf: c.library.appendingPathComponent("folders.json")))) == Set(["English", "Српски"]), "Empty folders and paginated downloads sync")
        try JSONEncoder().encode(["English"]).write(to: a.library.appendingPathComponent("folders.json"))
        try await a.synchronize(); try await c.synchronize()
        try check(server.rows[LibraryCloudSync.folderID("Српски")]?.digest == nil, "Folder deletion uses a tombstone")

        let savedAccountCount = server.history.count
        server.account = "different-account"
        // Attempt sync across a changed account boundary.
        do { try await a.synchronize(); throw NSError(domain: "Expected account boundary", code: 0) }
        // Account changes must cancel the old account’s pending synchronization.
        catch is CancellationError { checks += 1 }
        try check(server.history.count == savedAccountCount, "Account change cannot export the previous account's Library")
        server.account = "fixture-account"

        let restoredOld = mac("RestoredOld")
        _ = try make(restoredOld, text: "Old backup content", id: deleted)
        try await restoredOld.synchronize(); try await restoredOld.synchronize()
        try check(!fm.fileExists(atPath: restoredOld.library.appendingPathComponent(deleted).path), "Old backups respect an existing tombstone")
        try check(server.rows[deleted]?.digest == nil, "Fresh installation does not resurrect the deleted server record")
        try check(try ids(restoredOld).contains { try text(restoredOld, $0) == "Old backup content" }, "Restored content remains available as a conflict copy")

        let large = try make(a, text: "Large attachment")
        let audio = Data(repeating: 0xA5, count: LibrarySyncArchive.chunkBytes + 4096)
        try audio.write(to: a.library.appendingPathComponent(large + "/audio.caf"))
        try await a.synchronize(); try await c.synchronize()
        try check(server.rows[large]!.chunks.count == 2, "Large audio is split into bounded CloudKit assets")
        try check(try Data(contentsOf: c.library.appendingPathComponent(large + "/audio.caf")) == audio, "Chunked audio restores byte for byte")
        try check(try fm.contentsOfDirectory(atPath: a.storage.appendingPathComponent("Outgoing").path).isEmpty, "Acknowledged upload staging is removed")

        let damagedID = try make(a, text: "Intact local version")
        try await a.synchronize(); try await c.synchronize()
        try edit(a, damagedID, "Complete newer version")
        try await a.synchronize()
        let cloudChunk = server.rows[damagedID]!.chunks[0]
        let originalChunk = try Data(contentsOf: cloudChunk)
        try Data(originalChunk.dropLast()).write(to: cloudChunk)
        // Attempt to download an archive with damaged contents.
        do { try await c.synchronize(); throw NSError(domain: "Expected corrupt download rejection", code: 0) }
        // A damaged archive must fail validation before replacing local content.
        catch is LibrarySyncArchive.Failure { checks += 1 }
        try check(try text(c, damagedID) == "Intact local version", "Damaged download cannot replace local files")
        try originalChunk.write(to: cloudChunk)
        try await c.synchronize()
        try check(try text(c, damagedID) == "Complete newer version", "A fresh download recovers from damaged staging")

        let cancelled = mac("Cancelled")
        let cancelledID = try make(cancelled, text: "Do not upload after cancellation")
        server.beforeFetch = { try await Task.sleep(nanoseconds: 5_000_000_000) }
        let cancelledTask = Task { @MainActor in try await cancelled.synchronize() }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelledTask.cancel()
        // Require the cancelled cycle to end without uploading local changes.
        do { try await cancelledTask.value; throw NSError(domain: "Expected cancellation", code: 0) }
        // A cancelled fetch must stop the pending upload.
        catch is CancellationError { checks += 1 }
        try check(server.rows[cancelledID] == nil, "Cancelled fetch cannot upload local content")
        try check(try text(cancelled, cancelledID) == "Do not upload after cancellation", "Cancellation keeps local content")

        // Exercise the public lifecycle with injected entitlements, opt-in storage and signing.
        // No real preferences, StoreKit transactions, or CloudKit account are consulted.
        let gatedServer = try Server(root: root.appendingPathComponent("GatedServer"))
        let access = SyncAccess()
        // gatedMac(name, [supported = true]): Create a coordinator whose Pro
        // access, build support, and opt-in are controlled.
        func gatedMac(_ name: String, supported: Bool = true) -> LibraryCloudSync {
            LibraryCloudSync(library: root.appendingPathComponent(name + "/Library"),
                             storage: root.appendingPathComponent(name + "/Sync"), transport: { gatedServer },
                             proAccess: { access.pro }, buildSupported: { supported },
                             loadEnabled: { access.enabled }, saveEnabled: { access.enabled = $0 })
        }
        // updatePro(value): Change simulated Pro access and notify the
        // coordinator’s observers.
        func updatePro(_ value: Bool) {
            access.pro = value
            NotificationCenter.default.post(name: ProStore.entitlementDidChange, object: nil)
        }
        // waitForSync(sync): Wait for a sync cycle with a bounded fixture
        // deadline.
        func waitForSync(_ sync: LibraryCloudSync) async throws {
            let limit = Date().addingTimeInterval(5)
            // Yield while the coordinator is busy, stopping at the deadline.
            while sync.isSyncing, Date() < limit { try await Task.sleep(nanoseconds: 5_000_000) }
            try check(!sync.isSyncing, "Sync settles within its fixture deadline")
        }
        let gated = gatedMac("Gated")
        let gatedID = try make(gated, text: "Free local content")
        gated.start()
        gated.setEnabled(true)
        gated.syncNow()
        gated.libraryChanged()
        try check(!gated.enabled && !access.enabled, "Free callers cannot persist a new sync opt-in")
        try check(gatedServer.requests == 0, "Free controls do not contact CloudKit")
        // Attempt sync with Pro access disabled.
        do { try await gated.synchronize(); throw NSError(domain: "Expected Pro gate", code: 0) }
        // Reject synchronization before staging files when Pro access is missing.
        catch is CancellationError { checks += 1 }
        try check(!fm.fileExists(atPath: gated.storage.path), "Core Pro gate runs before staging or account access")
        try check(try text(gated, gatedID) == "Free local content", "Free local Library remains readable")
        updatePro(true)
        try check(!gated.enabled && gatedServer.requests == 0, "Upgrade alone does not opt in")
        try check(!gated.status.contains("requires Langmin Pro"), "Upgrade clears the stale Pro requirement")
        gated.setEnabled(true)
        try await waitForSync(gated)
        try check(gated.enabled && access.enabled && gatedServer.rows[gatedID]?.digest != nil, "Pro opt-in uploads the Library")
        let firstSync = gated.lastSync
        let retainedFiles = try files(gated, gatedID)
        let retainedState = try Data(contentsOf: gated.storage.appendingPathComponent("state.json"))

        // Revoke during a fetch, even if that transport ignores Task cancellation.
        try edit(gated, gatedID, "Edited just before expiry")
        let historyBeforeExpiry = gatedServer.history.count
        gatedServer.beforeFetch = { updatePro(false) }
        gated.syncNow()
        try await waitForSync(gated)
        try check(gatedServer.history.count == historyBeforeExpiry, "Expiry during fetch prevents the next upload")
        try check(gated.lastSync == firstSync && gated.status == LibraryCloudSync.proPausedMessage, "Cancelled work cannot report a successful sync")
        try check(gated.enabled && access.enabled, "Expiry preserves the opt-in for renewal")
        try check(try Data(contentsOf: gated.storage.appendingPathComponent("state.json")) == retainedState, "Expiry does not erase acknowledged merge history")
        let requestsWhilePaused = gatedServer.requests
        gated.syncNow()
        gated.libraryChanged()
        try check(gatedServer.requests == requestsWhilePaused, "Manual and background checks remain blocked after expiry")
        try edit(gated, gatedID, "Local edit while Pro is paused")
        try check(try files(gated, gatedID)["audio.caf"] == retainedFiles["audio.caf"], "Expiry keeps attachments")
        updatePro(true)
        try await waitForSync(gated)
        try check(gatedServer.history.count == historyBeforeExpiry + 1, "Renewal automatically sends paused local changes once")
        let peer = LibraryCloudSync(library: root.appendingPathComponent("GatedPeer/Library"),
                                   storage: root.appendingPathComponent("GatedPeer/Sync"), transport: { gatedServer }, proAccess: { true })
        try await peer.synchronize()
        try check(try text(peer, gatedID) == "Local edit while Pro is paused", "Renewed changes restore on the second Mac")

        // A remote edit downloaded after revocation cannot replace local files. Renewal refetches it.
        try edit(peer, gatedID, "Remote edit while paused")
        try await peer.synchronize()
        gatedServer.beforeFetch = { updatePro(false) }
        gated.syncNow()
        try await waitForSync(gated)
        try check(try text(gated, gatedID) == "Local edit while Pro is paused", "Expiry during download leaves the local version intact")
        updatePro(true)
        try await waitForSync(gated)
        try check(try text(gated, gatedID) == "Remote edit while paused", "Renewal receives the deferred remote version")

        // An upload already accepted by the server can finish; ignore its stale acknowledgement,
        // then reconcile it on renewal without duplicating content or losing the next local edit.
        try edit(gated, gatedID, "Upload accepted before expiry")
        let secondGatedID = try make(gated, text: "Another queued upload")
        let savedBeforeFlight = gated.lastSync
        let flightHistory = gatedServer.history.count
        gatedServer.afterSave = { updatePro(false) }
        gated.syncNow()
        try await waitForSync(gated)
        try check(gatedServer.history.count == flightHistory + 1, "No further uploads start after the in-flight save loses Pro")
        try check(gated.lastSync == savedBeforeFlight, "Late upload acknowledgement cannot mark paused sync successful")
        try edit(gated, gatedID, "Edit after in-flight expiry")
        updatePro(true)
        try await waitForSync(gated)
        try await peer.synchronize()
        try check(try ids(peer).contains { try text(peer, $0) == "Edit after in-flight expiry" }, "Reconciliation keeps the local edit after an accepted late upload")
        try check(gatedServer.rows[secondGatedID]?.digest != nil, "Renewal sends remaining queued uploads")

        // A pending debounce cannot restart sync after expiry or opt-out.
        gated.libraryChanged()
        updatePro(false)
        let debounceRequests = gatedServer.requests
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try check(gatedServer.requests == debounceRequests, "Expiry cancels a scheduled Library change check")
        gated.setEnabled(false)
        try check(!access.enabled && !gated.enabled, "Expired users can opt out without upgrading")
        updatePro(true)
        try check(gatedServer.requests == debounceRequests && !gated.enabled, "Renewal respects a later opt-out")

        // A saved opt-in must not leak any requests at a free launch, or in an unsigned build.
        access.enabled = true
        updatePro(false)
        let freeLaunch = gatedMac("FreeLaunch")
        freeLaunch.start()
        try check(freeLaunch.enabled && freeLaunch.status == LibraryCloudSync.proPausedMessage, "A restored free opt-in starts paused")
        try check(gatedServer.requests == debounceRequests, "Free launch makes no account request")
        freeLaunch.setEnabled(false)
        updatePro(true)
        access.enabled = true
        let unsupported = gatedMac("Unsupported", supported: false)
        unsupported.start()
        try check(gatedServer.requests == debounceRequests, "Pro cannot bypass missing CloudKit signing")
        unsupported.setEnabled(false)
        unsupported.setEnabled(true)
        try check(!access.enabled && !unsupported.enabled, "Unsupported builds permit opt-out but reject opt-in")

        // Oversized entry details have a separate limit from the complete attachment archive.
        let oversized = root.appendingPathComponent("OversizedMetadata")
        try fm.createDirectory(at: oversized, withIntermediateDirectories: true)
        try Data(repeating: 32, count: 8 * 1024 * 1024 + 1).write(to: oversized.appendingPathComponent("entry.json"))
        // Require metadata beyond its size limit to fail validation.
        do {
            _ = try LibrarySyncArchive.metadata(in: oversized)
            throw NSError(domain: "Expected metadata size rejection", code: 0)
        } catch LibrarySyncArchive.Failure.metadataTooLarge {
            // Confirm that oversized metadata hits its specific validation limit.
            checks += 1
        }

        // Recovery fixtures use independent servers so a broken case cannot contaminate the others.
        var recoveryFailures: [String] = []
        // recoveryMac(name, server): Create an isolated recovery coordinator
        // with explicit opt-in controls.
        func recoveryMac(_ name: String, server: Server) -> LibraryCloudSync {
            LibraryCloudSync(library: root.appendingPathComponent(name + "/Library"),
                             storage: root.appendingPathComponent(name + "/Sync"), transport: { server },
                             proAccess: { true }, buildSupported: { true }, loadEnabled: { false }, saveEnabled: { _ in })
        }
        // Check recovery when a deferred download is unsafe or disappears after restart.
        do {
            let cloud = try Server(root: root.appendingPathComponent("MissingAssetServer"))
            let sender = recoveryMac("MissingSender", server: cloud)
            let receiver = recoveryMac("MissingReceiver", server: cloud)
            let item = try make(sender, text: "Recover a deferred download after restart")
            try await sender.synchronize()
            receiver.openEntryIDs = { [item] }
            try await receiver.synchronize()
            let incoming = receiver.storage.appendingPathComponent("Incoming")
            let pendingAsset = try fm.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil).first!
            try fm.removeItem(at: pendingAsset)
            try fm.createSymbolicLink(at: pendingAsset, withDestinationURL: sender.library.appendingPathComponent(item + "/text.md"))
            let unsafe = recoveryMac("MissingReceiver", server: cloud)
            // Require the coordinator to reject an unsafe staged asset.
            do { try await unsafe.synchronize(); throw NSError(domain: "Expected unsafe staging rejection", code: 0) }
            // Reject a staged asset replaced with a symbolic link.
            catch LibrarySyncArchive.Failure.invalid { checks += 1 }
            // Remove staged fixture assets to simulate a lost download after restart.
            for file in try fm.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil) { try fm.removeItem(at: file) }
            let relaunched = recoveryMac("MissingReceiver", server: cloud)
            try await relaunched.synchronize()
            try check(try files(sender, item) == files(relaunched, item), "Restart refetches a lost deferred asset without losing its merge history")
        // Record this recovery failure while allowing the independent cases to run.
        } catch { recoveryFailures.append("Missing download after restart: \(error)") }
        // Check that restoring an unchanged entry rebuilds its upload archive.
        do {
            let cloud = try Server(root: root.appendingPathComponent("RestoreCacheServer"))
            let sender = recoveryMac("RestoreSender", server: cloud)
            let item = try make(sender, text: "Restore the same files")
            try await sender.synchronize()
            let directory = sender.library.appendingPathComponent(item)
            let backup = root.appendingPathComponent("MovedEntry")
            try fm.moveItem(at: directory, to: backup)
            try await sender.synchronize()
            try fm.moveItem(at: backup, to: directory)
            try await sender.synchronize()
            try check(cloud.rows[item]?.digest != nil && cloud.rows[item]?.chunks.isEmpty == false, "Restoring unchanged files rebuilds an acknowledged upload archive")
            let receiver = recoveryMac("RestoreReceiver", server: cloud)
            try await receiver.synchronize()
            try check(try files(sender, item) == files(receiver, item), "A restored cached entry is readable on another Mac")
        // Record any failure to rebuild an upload after restoring unchanged files.
        } catch { recoveryFailures.append("Restored upload cache: \(error)") }
        // Check that an account change during zone setup invalidates prior approval.
        do {
            let cloud = try Server(root: root.appendingPathComponent("AccountRaceServer"))
            let sync = recoveryMac("AccountRace", server: cloud)
            let item = try make(sync, text: "Bound to the first account")
            sync.start()
            // Stop this coordinator’s scheduled work when the case finishes.
            defer { sync.setEnabled(false) }
            sync.setEnabled(true)
            try await waitForSync(sync)
            let history = cloud.history.count
            sync.setEnabled(false)
            cloud.account = "approved-second-account"
            NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
            cloud.beforePrepare = {
                cloud.account = "unapproved-third-account"
                NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
            }
            sync.setEnabled(true)
            try await waitForSync(sync)
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: sync.storage.appendingPathComponent("state.json"))) as! [String: Any]
            try check(state["account"] as? String == "fixture-account", "Cancelled zone preparation retains the previous account binding")
            try check(cloud.history.count == history && sync.status.contains("account changed"), "A third account requires a fresh explicit opt-in")
            try check(try text(sync, item) == "Bound to the first account", "Account cancellation preserves local content")
            // A fresh off/on may intentionally merge into the now-selected account.
            cloud.rows.removeAll()
            cloud.history.removeAll()
            sync.setEnabled(false)
            sync.setEnabled(true)
            try await waitForSync(sync)
            try check(cloud.rows[item]?.digest != nil && !sync.status.contains("account changed"), "Fresh approval resumes into the selected account")
        // Record account-approval regressions without hiding the remaining cases.
        } catch { recoveryFailures.append("Account switch during zone preparation: \(error)") }
        // Check account binding when the first opt-in is interrupted by an account change.
        do {
            let cloud = try Server(root: root.appendingPathComponent("FirstAccountRaceServer"))
            let sync = recoveryMac("FirstAccountRace", server: cloud)
            _ = try make(sync, text: "Never send to a newly switched account")
            sync.start()
            // Stop this coordinator’s scheduled work when the case finishes.
            defer { sync.setEnabled(false) }
            cloud.beforePrepare = {
                cloud.account = "unapproved-account"
                NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
            }
            sync.setEnabled(true)
            try await waitForSync(sync)
            try check(cloud.history.isEmpty && sync.status.contains("account changed"), "First opt-in binds the resolved account before awaiting zone setup")
        // Record failures to bind the first approved account before awaiting setup.
        } catch { recoveryFailures.append("First account binding race: \(error)") }
        // Check that offline opt-in cannot approve an account selected later.
        do {
            let cloud = try Server(root: root.appendingPathComponent("OfflineAccountServer"))
            let sync = recoveryMac("OfflineAccount", server: cloud)
            _ = try make(sync, text: "Keep offline account approval scoped")
            sync.start()
            // Stop this coordinator’s scheduled work when the case finishes.
            defer { sync.setEnabled(false) }
            sync.setEnabled(true)
            try await waitForSync(sync)
            sync.setEnabled(false)
            cloud.offline = true
            sync.setEnabled(true)
            try await waitForSync(sync)
            cloud.offline = false
            cloud.account = "account-after-offline-opt-in"
            NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
            try await waitForSync(sync)
            try check(sync.status.contains("account changed"), "An account notification invalidates an unused offline merge approval")
        // Record failures to invalidate account approval made while offline.
        } catch { recoveryFailures.append("Offline account approval: \(error)") }
        // Print each recovery failure before the combined assertion.
        for failure in recoveryFailures { print("REGRESSION: " + failure) }
        try check(recoveryFailures.isEmpty, "Recovery regressions: " + recoveryFailures.joined(separator: "; "))

        // Corrupted/truncated data and unsafe paths never replace a complete local item.
        let source = a.library.appendingPathComponent(id)
        let archiveURL = root.appendingPathComponent("archive")
        let package = try LibrarySyncArchive.pack(source, id: id, to: archiveURL)
        let restored = root.appendingPathComponent("restored")
        try LibrarySyncArchive.unpack(package.url, digest: package.digest, id: id, to: restored)
        try check(try Data(contentsOf: restored.appendingPathComponent("text.md")) == Data(contentsOf: source.appendingPathComponent("text.md")), "Archive restores exact bytes")
        let damaged = root.appendingPathComponent("damaged")
        var bytes = try Data(contentsOf: archiveURL)
        bytes.removeLast()
        try bytes.write(to: damaged)
        try rejects("Truncated archive") { try LibrarySyncArchive.unpack(damaged, digest: package.digest, id: id, to: root.appendingPathComponent("bad")) }
        try rejects("Unknown format") {
            let manifest = try JSONEncoder().encode(LibrarySyncArchive.Manifest(version: 99, files: []))
            var length = UInt64(manifest.count).bigEndian
            var body = withUnsafeBytes(of: &length) { Data($0) }; body.append(manifest)
            try body.write(to: damaged)
            try LibrarySyncArchive.unpack(damaged, digest: LibrarySyncArchive.hash(body), id: id, to: root.appendingPathComponent("bad-version"))
        }
        // A legal file count can still overflow the receiver's manifest budget with long names.
        let manyFiles = root.appendingPathComponent("LongManifest")
        try fm.createDirectory(at: manyFiles, withIntermediateDirectories: true)
        let names = (0..<4000).map { "asset-\($0)-" + String(repeating: "x", count: 230) }
        // Create enough referenced files to exercise the archive file-count limit.
        for name in names { try Data().write(to: manyFiles.appendingPathComponent(name)) }
        try Data("Text".utf8).write(to: manyFiles.appendingPathComponent("text.md"))
        let largeMetadata: [String: Any] = ["id": id, "textFile": "text.md", "sourceImages": names.map { ["file": $0] }]
        try JSONSerialization.data(withJSONObject: largeMetadata).write(to: manyFiles.appendingPathComponent("entry.json"))
        try rejects("Oversized upload manifest") { _ = try LibrarySyncArchive.pack(manyFiles, id: id, to: root.appendingPathComponent("large-manifest.archive")) }
        for path in ["../escape", "/absolute", "pronounce/../../escape", "a//b", "a\\b", "a/.", "", ".secret"] {
            try check(!LibrarySyncArchive.validPath(path), "Reject unsafe path: " + path)
        }
        let linkRoot = root.appendingPathComponent("Symlink")
        try fm.createDirectory(at: linkRoot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkRoot.appendingPathComponent("text.md"), withDestinationURL: source.appendingPathComponent("text.md"))
        try rejects("Symlink asset") { _ = try LibrarySyncArchive.checkedFile("text.md", in: linkRoot) }
        try check(LibrarySyncDecision.resolve(base: "a", local: "b", remote: "c") == .conflict, "Three-way conflict is clock independent")
        try check(LibrarySyncDecision.resolve(base: "a", local: nil, remote: nil) == .unchanged, "Matching deletions converge")
        print("\(checks) iCloud Library sync checks passed")
    }
}
