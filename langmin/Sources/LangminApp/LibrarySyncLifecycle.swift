import Cocoa

// Connect the sync coordinator to application and Library lifecycle events.
extension AppDelegate {
    // startLibrarySync(): Provide open-entry and pending-deletion state before
    // starting the Library sync coordinator.
    func startLibrarySync() {
        let sync = LibraryCloudSync.shared
        sync.openEntryIDs = { [weak self] in
            // Return no open entries after the application delegate is released.
            guard let self else { return [] }
            return Set((self.sessions + [self.launcherController.inlineResultSession].compactMap { $0 })
                .compactMap(\.savedLibraryID))
        }
        sync.pendingDeletionIDs = { [weak self] in Set(self?.launcherController.pendingLibraryDeletions.keys.map { $0 } ?? []) }
        sync.validateEntry = { directory in
            _ = try JSONDecoder().decode(LibraryEntry.self, from: Data(contentsOf: directory.appendingPathComponent("entry.json")))
        }
        sync.onLibraryChanged = { [weak self] in
            LibraryStore.invalidateEntryCache()
            self?.launcherController.libraryContentCacheGeneration += 1
            self?.launcherController.libraryContentSearchCache.removeAll()
            self?.launcherController.pendingContentSearchLoads.removeAll()
            self?.launcherController.libraryDidChange()
        }
        LibraryStore.onChange = { sync.libraryChanged() }
        sync.start()
    }
}
