import Foundation
import CloudKit

// The sync coordinator uses this boundary for offline tests; only this implementation contacts Apple.
struct LibraryCloudRecord: Codable {
    let id: String
    var digest: String?
    var folderName: String?
    var systemFields: Data
    var chunks: [URL]
}
// Return a page of changes with the durable continuation token and pagination state.
struct LibraryCloudPage {
    let records: [LibraryCloudRecord]
    let token: Data
    let moreComing: Bool
}
// Separate account, change-fetching, and record-saving operations from sync merge logic.
protocol LibraryCloudTransport {
    // accountID(): Return the current available cloud account's stable
    // identity.
    func accountID() async throws -> String
    // prepare(createZone): Ensure the Library zone exists, creating it only
    // when the caller permits that recovery.
    func prepare(createZone: Bool) async throws -> Bool
    // fetch(token, directory): Fetch one change page and copy temporary assets
    // into the caller's staging directory.
    func fetch(since token: Data?, into directory: URL) async throws -> LibraryCloudPage
    // save(record): Save a record while preserving the provider's version
    // information for conflict detection.
    func save(_ record: LibraryCloudRecord) async throws -> LibraryCloudRecord
}

// Store Library records in Langmin's private CloudKit zone for the current Apple Account.
final class CloudKitLibraryTransport: LibraryCloudTransport {
    static let containerID = "iCloud.tools.min.langmin"
    private let container = CKContainer(identifier: containerID)
    private let zoneID = CKRecordZone.ID(zoneName: "LangminLibrary", ownerName: CKCurrentUserDefaultName)
    private var database: CKDatabase { container.privateCloudDatabase }
    // Distinguish account unavailability, a reset zone, and unsupported record data.
    enum Failure: LocalizedError {
        // Separate account problems, removed zones, and newer unsupported record formats.
        case account, reset, unsupported
        var errorDescription: String? {
            // Choose recovery guidance for the specific CloudKit state.
            switch self {
            // Direct account-unavailable failures to Apple Account and iCloud settings.
            case .account: return "iCloud is unavailable. Check your Apple Account and iCloud settings in System Settings."
            // Require explicit re-enabling after a removed or reset Library zone.
            case .reset: return "The iCloud Library was reset. Turn sync off and on to merge your local Library again."
            // Ask for an app update when the cloud record format is unsupported.
            case .unsupported: return "Update Langmin to read this iCloud Library item."
            }
        }
    }

    // accountID(): Require an available iCloud account before returning its
    // user record identity.
    func accountID() async throws -> String {
        // Require available iCloud service before looking up the account identity.
        guard try await container.accountStatus() == .available else { throw Failure.account }
        return try await container.userRecordID().recordName
    }

    // prepare(createZone): Find the existing zone, or create a missing zone
    // only during an authorized initialization.
    func prepare(createZone: Bool) async throws -> Bool {
        // An existing CloudKit zone needs no initialization.
        do { _ = try await database.recordZone(for: zoneID); return false }
        // Handle a missing or user-deleted zone through the explicit initialization policy.
        catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // Do not silently recreate a deleted cloud Library during an ordinary sync.
            guard createZone else { throw Failure.reset }
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
            return true
        }
    }

    // fetch(token, directory): Persist downloaded assets before acknowledging
    // the page's server token.
    func fetch(since token: Data?, into directory: URL) async throws -> LibraryCloudPage {
        let previous = try token.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: previous, resultsLimit: 100)
        // Treat physical CloudKit deletions as a reset because normal sync deletions use tombstones.
        guard page.deletions.isEmpty else { throw Failure.reset }
        var records: [LibraryCloudRecord] = []
        // Decode each changed record and propagate individual fetch failures.
        for (_, result) in page.modificationResultsByID {
            let record = try result.get().record
            records.append(try decode(record, copyingAssetsTo: directory))
        }
        let next = try NSKeyedArchiver.archivedData(withRootObject: page.changeToken, requiringSecureCoding: true)
        return LibraryCloudPage(records: records, token: next, moreComing: page.moreComing)
    }

    // save(value): Save a new or versioned Library record and return its
    // updated CloudKit system fields.
    func save(_ value: LibraryCloudRecord) async throws -> LibraryCloudRecord {
        let record: CKRecord
        // Create a fresh CloudKit record when there are no saved version fields.
        if value.systemFields.isEmpty {
            record = CKRecord(recordType: "LibraryItem", recordID: CKRecord.ID(recordName: value.id, zoneID: zoneID))
        } else {
            // Restore saved system fields so updates retain conflict-detection metadata.
            let decoder = try NSKeyedUnarchiver(forReadingFrom: value.systemFields)
            decoder.requiresSecureCoding = true
            // Reject archived system fields for a different entry or record zone.
            guard let decoded = CKRecord(coder: decoder), decoded.recordID.recordName == value.id, decoded.recordID.zoneID == zoneID else { throw LibrarySyncArchive.Failure.invalid }
            decoder.finishDecoding()
            record = decoded
        }
        record["formatVersion"] = 1 as CKRecordValue
        record["digest"] = value.digest as CKRecordValue?
        record["folderName"] = value.folderName as CKRecordValue?
        record["deleted"] = (value.digest == nil ? 1 : 0) as CKRecordValue
        record["chunks"] = value.chunks.isEmpty ? nil : value.chunks.map { CKAsset(fileURL: $0) } as CKRecordValue
        // Compare server tags so an offline device cannot overwrite newer content without reconciliation.
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        // Require an acknowledgement for the record that was submitted.
        guard let saved = result.saveResults[record.recordID] else { throw LibrarySyncArchive.Failure.incomplete }
        var acknowledged = value
        acknowledged.systemFields = try Self.encode(try saved.get())
        acknowledged.chunks = []
        return acknowledged
    }

    // encode(record): Archive CloudKit system fields for later version-aware
    // saves.
    private static func encode(_ record: CKRecord) throws -> Data {
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: encoder)
        encoder.finishEncoding()
        return encoder.encodedData
    }

    // decode(record, directory): Validate a fetched record and copy its
    // temporary assets into durable incoming storage.
    private func decode(_ record: CKRecord, copyingAssetsTo directory: URL) throws -> LibraryCloudRecord {
        // Reject record types or format versions this client cannot read.
        guard record.recordType == "LibraryItem", record["formatVersion"] as? Int == 1 else { throw Failure.unsupported }
        let id = record.recordID.recordName
        let folder = record["folderName"] as? String
        // Validate the display name carried by folder records.
        if let folder {
            // Reject empty, oversized, or untrimmed folder names.
            guard !folder.isEmpty, folder.utf8.count <= 1024,
                  folder == folder.trimmingCharacters(in: .whitespacesAndNewlines) else { throw LibrarySyncArchive.Failure.invalid }
        }
        let digest = record["digest"] as? String
        let deleted = record["deleted"] as? Int == 1
        // Require a valid record identity and content digest, unless the record is a tombstone.
        // Require a valid digest for live records before reading their assets.
        guard folder.map({ LibraryCloudSync.folderID($0) == id }) ?? LibrarySyncArchive.validID(id),
              deleted || (digest.map(LibrarySyncArchive.validDigest) ?? false) else { throw LibrarySyncArchive.Failure.invalid }
        let assets = record["chunks"] as? [CKAsset] ?? []
        // Enforce chunk counts and prohibit file assets on folders or deleted entries.
        guard assets.count <= 65, (deleted || folder != nil) ? assets.isEmpty : !assets.isEmpty else { throw LibrarySyncArchive.Failure.invalid }
        var chunks: [URL] = []
        // Copy every supplied cloud asset before its temporary URL expires.
        for asset in assets {
            // Report an asset whose temporary file is missing.
            guard let source = asset.fileURL else { throw LibrarySyncArchive.Failure.incomplete }
            // Reject empty or oversized chunks before copying them into incoming storage.
            guard let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= LibrarySyncArchive.chunkBytes else { throw LibrarySyncArchive.Failure.invalid }
            let target = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: target)
            chunks.append(target)
        }
        return LibraryCloudRecord(id: id, digest: deleted ? nil : digest, folderName: folder,
                                  systemFields: try Self.encode(record), chunks: chunks)
    }
}
