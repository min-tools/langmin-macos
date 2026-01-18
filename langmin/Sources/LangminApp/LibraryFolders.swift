import Cocoa

// Persist flat folder names and local recent-folder ordering alongside the Library.
extension LibraryStore {
    // foldersFile(): Folders are flat display names, never paths. Combine names
    // from folders.json with names used by entries so empty folders remain
    // visible.
    private static func foldersFile() -> URL {
        libraryDirectory().appendingPathComponent("folders.json")
    }

    // normalizedFolderName(raw): Trim incidental whitespace without treating a
    // folder's display name as a filesystem path.
    static func normalizedFolderName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // listFolders(): Read the explicit folder list, using an empty list when no
    // valid saved list exists.
    static func listFolders() -> [String] {
        // Read an explicit folder list only when its file exists and decodes correctly.
        guard
            let data = try? Data(contentsOf: foldersFile()),
            let stored = try? JSONDecoder().decode([String].self, from: data)
        // Use an empty list when explicit folder metadata is absent or invalid.
        else { return [] }
        return stored.map(normalizedFolderName).filter { !$0.isEmpty }
    }

    // saveFolders(folders): Normalize and deduplicate folder names before
    // attempting an atomic list write.
    static func saveFolders(_ folders: [String]) {
        // Invalidate cached entry listings after attempting a folder-list change.
        defer { invalidateEntryCache() }
        let cleaned = Array(Set(folders.map(normalizedFolderName).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        try? FileManager.default.createDirectory(
            at: libraryDirectory(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Write only successfully encoded folder metadata.
        if let data = try? encoder.encode(cleaned) {
            try? data.write(to: foldersFile(), options: .atomic)
        }
    }

    // addFolder(name): Add a nonempty normalized folder through the shared list
    // writer.
    static func addFolder(_ name: String) {
        let normalized = normalizedFolderName(name)
        // Do not create a folder from an empty normalized name.
        guard !normalized.isEmpty else { return }
        saveFolders(listFolders() + [normalized])
    }

    // removeFolder(name): Drop a folder from the explicit list; the caller
    // unfiles or moves its entries first.
    static func removeFolder(_ name: String) {
        let normalized = normalizedFolderName(name)
        // Ignore removal requests with an empty folder name.
        guard !normalized.isEmpty else { return }
        saveFolders(listFolders().filter { $0 != normalized })
    }

    // setFolder(id, folder): Change folder metadata without moving the entry's
    // files. Nil means unfiled.
    static func setFolder(id: String, folder: String?) throws {
        invalidateEntryCache()
        let dir = entryDirectory(id: id)
        let metadataURL = dir.appendingPathComponent("entry.json")
        let data = try Data(contentsOf: metadataURL)
        var entry = try JSONDecoder().decode(LibraryEntry.self, from: data)
        let normalized = folder.map(normalizedFolderName) ?? ""
        entry.folder = normalized.isEmpty ? nil : normalized
        // Ensure a newly assigned folder also exists in the explicit folder list.
        if let name = entry.folder {
            addFolder(name)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entry).write(to: metadataURL, options: .atomic)
    }

    // renameFolder(from, to): Rename a folder across folders.json, the MRU
    // order, and every entry filed in it.
    static func renameFolder(from: String, to: String) {
        let source = normalizedFolderName(from)
        let target = normalizedFolderName(to)
        // Skip blank or unchanged folder renames.
        guard !source.isEmpty, !target.isEmpty, source != target else { return }
        saveFolders(listFolders().map { $0 == source ? target : $0 } + [target])
        saveFolderMRU(listFolderMRU().map { $0 == source ? target : $0 })
        // Update entries filed under the old name while preserving their saved content.
        for entry in list() where entry.folder == source {
            try? setFolder(id: entry.id, folder: target)
        }
    }

    // folderMRUFile(): Use recent folder order to choose visible chips; place
    // the rest in overflow.
    private static func folderMRUFile() -> URL {
        libraryDirectory().appendingPathComponent("folderMRU.json")
    }

    // listFolderMRU(): Load the locally remembered recent-folder order.
    static func listFolderMRU() -> [String] {
        // Read recent-folder ordering only from a valid local list file.
        guard
            let data = try? Data(contentsOf: folderMRUFile()),
            let stored = try? JSONDecoder().decode([String].self, from: data)
        // Start with no recent-folder ordering when the local file is absent or invalid.
        else { return [] }
        return stored
    }

    // saveFolderMRU(names): Attempt to persist the recent-folder order without
    // changing Library entry metadata.
    static func saveFolderMRU(_ names: [String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        // Write recent-folder state only when it encodes successfully.
        if let data = try? encoder.encode(names) {
            try? data.write(to: folderMRUFile(), options: .atomic)
        }
    }

    // touchFolderMRU(name): Move a used, created or selected folder to the
    // front.
    static func touchFolderMRU(_ name: String) {
        let normalized = normalizedFolderName(name)
        // Do not add an empty name to recent-folder ordering.
        guard !normalized.isEmpty else { return }
        saveFolderMRU([normalized] + listFolderMRU().filter { $0 != normalized })
    }

    // removeFolderMRU(name): Remove a deleted folder from the local
    // recent-folder list.
    static func removeFolderMRU(_ name: String) {
        saveFolderMRU(listFolderMRU().filter { $0 != name })
    }

}
