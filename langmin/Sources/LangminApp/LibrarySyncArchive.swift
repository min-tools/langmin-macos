import Foundation
import CryptoKit

// A small, versioned archive format avoids shell tools and preserves binary assets verbatim.
// All paths and lengths are checked before any downloaded file reaches the Library.
enum LibrarySyncArchive {
    static let maximumBytes: UInt64 = 2 * 1024 * 1024 * 1024
    static let chunkBytes = 32 * 1024 * 1024
    static let maximumManifestBytes = 1024 * 1024
    // Record each archived file's relative path, byte count, and content digest.
    struct File: Codable { let path: String; let size: UInt64; let digest: String }
    // Describe the archive format version and the files expected during unpacking.
    struct Manifest: Codable { let version: Int; let files: [File] }
    // Return a completed archive together with its content digest.
    struct Package { let url: URL; let digest: String }
    // Distinguish invalid, oversized, incomplete, and metadata-heavy sync packages.
    enum Failure: LocalizedError {
        // Separate malformed data, package limits, metadata limits, and missing file content.
        case invalid, tooLarge, metadataTooLarge, incomplete
        var errorDescription: String? {
            // Describe the actual archive validation failure to the sync status UI.
            switch self {
            // Report a format or integrity problem in the item.
            case .invalid: return "A Library item contains invalid or unsupported data."
            // Report the whole-item size limit separately from its metadata limit.
            case .tooLarge: return "This Library item exceeds the 2 GB iCloud sync limit."
            // Explain when saved entry details alone exceed their smaller limit.
            case .metadataTooLarge: return "This Library item's saved details exceed the 8 MB iCloud sync limit."
            // Report an archive whose referenced file data is incomplete.
            case .incomplete: return "A Library item is missing one of its files."
            }
        }
    }

    // hash(data): Produce the lowercase SHA-256 digest format used by sync
    // records and manifests.
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    // validID(id): Accept only UUID-shaped Library entry identifiers.
    static func validID(_ id: String) -> Bool { UUID(uuidString: id) != nil }
    // validDigest(value): Require the exact lowercase hexadecimal format of a
    // SHA-256 digest.
    static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    // validPath(path): Restrict archive members to supported relative paths
    // without hidden or ambiguous components.
    static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.count <= 2 && parts.allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") && !$0.contains(":")
                && $0.rangeOfCharacter(from: .controlCharacters) == nil
        }
    }

    // metadata(directory): Read checked entry metadata only when its size fits
    // the sync metadata limit.
    static func metadata(in directory: URL) throws -> Data {
        let url = try checkedFile("entry.json", in: directory)
        // Do not read metadata whose file size cannot be established.
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw Failure.invalid }
        // Enforce the metadata limit before loading the JSON into memory.
        guard size <= 8 * 1024 * 1024 else { throw Failure.metadataTooLarge }
        return try Data(contentsOf: url)
    }

    // paths(metadata, id): Only referenced assets travel to iCloud; temporary
    // and abandoned files stay local.
    static func paths(in metadata: Data, id: String) throws -> [String] {
        // Require metadata to identify the requested entry and its primary text file.
        guard validID(id), let object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              object["id"] as? String == id, let text = object["textFile"] as? String else { throw Failure.invalid }
        var paths = ["entry.json", text]
        // Collect the optional single-file assets referenced by entry metadata.
        for key in ["audioFile", "diffOriginalFile", "diffRevisedFile", "illustrationFile"] {
            // Treat null asset fields as absent, not as file references.
            if let value = object[key], !(value is NSNull) {
                // Reject asset references that are not path strings.
                guard let path = value as? String else { throw Failure.invalid }
                paths.append(path)
            }
        }
        // Collect file references from pronunciation and source-image arrays.
        for key in ["pronunciations", "sourceImages"] {
            // Ignore absent or null reference arrays.
            if let value = object[key], !(value is NSNull) {
                // Reject an asset collection with an unsupported structure.
                guard let refs = value as? [[String: Any]] else { throw Failure.invalid }
                // Validate every member of the referenced asset collection.
                for ref in refs {
                    // Require each asset reference to contain its file path.
                    guard let path = ref["file"] as? String else { throw Failure.invalid }
                    paths.append(path)
                }
            }
        }
        // Reject unsupported member paths before building the archive list.
        guard paths.allSatisfy(validPath) else { throw Failure.invalid }
        return Array(Set(paths)).sorted()
    }

    // checkedFile(path, directory): Reject links in both file and parent
    // components before reading or copying an asset.
    static func checkedFile(_ path: String, in directory: URL) throws -> URL {
        // Validate a relative path before resolving it beneath the entry directory.
        guard validPath(path) else { throw Failure.invalid }
        var url = directory
        let root = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        // Require a real directory rather than a symlink as the archive root.
        guard root.isDirectory == true, root.isSymbolicLink != true else { throw Failure.invalid }
        // Check each path component so intermediate directories cannot redirect traversal.
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part))
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            // Reject symbolic links at every level of an archived path.
            guard values.isSymbolicLink != true else { throw Failure.invalid }
        }
        // Archive only regular files, not directories or special filesystem objects.
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure.invalid }
        return url
    }

    // capture(source, id, destination): Capture on the app thread, between
    // Library mutations. Hashing and packing use this private copy.
    static func capture(_ source: URL, id: String, to destination: URL) throws {
        let metadata = try metadata(in: source)
        let paths = try paths(in: metadata, id: id)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // Copy only files explicitly referenced by validated entry metadata.
        for path in paths {
            let url = try checkedFile(path, in: source)
            let target = destination.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
        }
    }

    // fileDigest(url): Hash a file incrementally and count its bytes without
    // loading the whole file into memory.
    static func fileDigest(_ url: URL) throws -> (UInt64, String) {
        let input = try FileHandle(forReadingFrom: url)
        // Close the validated file after hashing its streamed contents.
        defer { try? input.close() }
        var digest = SHA256(), size: UInt64 = 0
        // Read file content in bounded chunks while hashing it.
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            size += UInt64(data.count)
            // Stop once the file exceeds the supported item-size budget.
            guard size <= maximumBytes else { throw Failure.tooLarge }
            digest.update(data: data)
        }
        return (size, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    // pack(directory, id, destination): Package the entry's referenced files
    // with a manifest and whole-package digest.
    static func pack(_ directory: URL, id: String, to destination: URL) throws -> Package {
        let metadata = try metadata(in: directory)
        let files = try paths(in: metadata, id: id).map { path -> File in
            let (size, digest) = try fileDigest(checkedFile(path, in: directory))
            return File(path: path, size: size, digest: digest)
        }
        // Bound both file count and combined payload size before writing an archive.
        // Bound archive metadata and total extracted data before encoding.
        guard files.count <= 4096, files.reduce(UInt64(0), { $0 + $1.size }) <= maximumBytes else { throw Failure.tooLarge }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifest = try encoder.encode(Manifest(version: 1, files: files))
        // Never upload a table that the receiver's bounded decoder would reject.
        guard manifest.count <= maximumManifestBytes else { throw Failure.invalid }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        // Close archive output after manifest and asset writing finishes.
        defer { try? output.close() }
        var size = UInt64(manifest.count).bigEndian
        try withUnsafeBytes(of: &size) { try output.write(contentsOf: Data($0)) }
        try output.write(contentsOf: manifest)
        // Write payloads in the same order recorded by the manifest.
        for file in files {
            let input = try FileHandle(forReadingFrom: directory.appendingPathComponent(file.path))
            // Close each source asset after its bytes are copied into the archive.
            defer { try? input.close() }
            // Stream each payload to avoid holding large assets in memory.
            while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { try output.write(contentsOf: data) }
        }
        try output.synchronize()
        return Package(url: destination, digest: try fileDigest(destination).1)
    }

    // unpack(archive, digest, id, directory): Verify the package and each
    // member before unpacking it into the destination directory.
    static func unpack(_ archive: URL, digest: String, id: String, to directory: URL) throws {
        // Verify the declared whole-package digest before parsing its members.
        guard validDigest(digest), try fileDigest(archive).1 == digest else { throw Failure.invalid }
        let input = try FileHandle(forReadingFrom: archive)
        // Close archive input on either successful extraction or validation failure.
        defer { try? input.close() }
        // Require the complete fixed-width manifest-length header.
        guard let header = try input.read(upToCount: 8), header.count == 8 else { throw Failure.invalid }
        let length = header.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        // Require a nonempty bounded manifest and all its declared bytes.
        guard length > 0, length <= maximumManifestBytes,
              let data = try input.read(upToCount: Int(length)), data.count == Int(length) else { throw Failure.invalid }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        // Accept only the supported manifest version with distinct member paths and bounded count.
        guard manifest.version == 1, manifest.files.count <= 4096,
              Set(manifest.files.map(\.path)).count == manifest.files.count else { throw Failure.invalid }
        var total: UInt64 = 0
        // Validate the entire table before creating any paths, including overlapping file/directory names.
        let paths = Set(manifest.files.map(\.path))
        let canonicalPaths = Set(paths.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        // Reject paths that collide after filesystem-style case and Unicode normalization.
        guard canonicalPaths.count == paths.count else { throw Failure.invalid }
        // Validate every member before creating its output file.
        for file in manifest.files {
            // Reject invalid paths, digests, sizes, or file-versus-directory collisions.
            guard validPath(file.path), validDigest(file.digest), file.size <= maximumBytes - total,
                  !canonicalPaths.contains(file.path.split(separator: "/").dropLast().joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()),
                  file.path != "entry.json" || file.size <= 8 * 1024 * 1024 else { throw Failure.invalid }
            total += file.size
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            // Create and fill only the already validated archive members.
            for file in manifest.files {
                let target = directory.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: target.path, contents: nil)
                let output = try FileHandle(forWritingTo: target)
                // Close each extracted asset before processing the next archive entry.
                defer { try? output.close() }
                var remaining = file.size
                // Read exactly the payload length declared for this member.
                while remaining > 0 {
                    // Treat premature end of input as a missing-file-content failure.
                    guard let chunk = try input.read(upToCount: Int(min(remaining, 1024 * 1024))), !chunk.isEmpty else { throw Failure.incomplete }
                    try output.write(contentsOf: chunk)
                    remaining -= UInt64(chunk.count)
                }
                // Verify each unpacked file against its own manifest digest.
                guard try fileDigest(target).1 == file.digest else { throw Failure.invalid }
            }
            // Reject trailing bytes or a mismatch between unpacked metadata references and archive members.
            guard (try input.read(upToCount: 1))?.isEmpty != false,
                  Set(try self.paths(in: metadata(in: directory), id: id)) == paths else { throw Failure.invalid }
        } catch {
            // Remove partial output when any archive validation or unpacking step fails.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

// A three-way comparison uses the last acknowledged content, never device clocks.
// A tombstone is represented by nil content after an item has been acknowledged once.
enum LibrarySyncDecision: Equatable {
    // Merge decisions distinguish unchanged content, one-sided changes, and competing edits.
    case unchanged, upload, download, conflict
    // resolve(base, local, remote): Choose upload, download, no change, or
    // conflict from the last shared and current digests.
    static func resolve(base: String?, local: String?, remote: String?) -> Self {
        // Matching local and remote content requires no transfer.
        if local == remote { return .unchanged }
        // If the remote still matches the shared base, only the local side changed.
        if remote == base { return .upload }
        // If the local still matches the shared base, only the remote side changed.
        if local == base { return .download }
        return .conflict
    }
}
