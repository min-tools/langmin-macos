import Cocoa

// Connect folder browsing, editing, and entry filing to the shared Library controller.
extension LauncherController {
    // libraryFolderNames(entries): Combine explicitly saved folders with folder
    // names still referenced by entries.
    func libraryFolderNames(entries: [LibraryEntry]) -> [String] {
        var folders = Set(LibraryStore.listFolders())
        // Include folder names still referenced by saved entries.
        for entry in entries {
            // Unfiled entries contribute no folder name.
            if let name = entry.folder {
                folders.insert(name)
            }
        }
        return folders.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // allLibraryFolderNames(): Resolve folder names against the current
    // complete Library listing.
    func allLibraryFolderNames() -> [String] {
        libraryFolderNames(entries: LibraryStore.list())
    }

    // libraryFoldersInMRUOrder(names): Order folders by recent use, then
    // alphabetically. Keep a folder being renamed first so its editor cannot
    // fall into overflow.
    func libraryFoldersInMRUOrder(names: [String]) -> [String] {
        let recent = LibraryStore.listFolderMRU().filter { names.contains($0) }
        var ordered = recent + names.filter { !recent.contains($0) }
        // Keep the folder being renamed visible before applying recent-folder ordering.
        if let renaming = renamingLibraryFolder, ordered.contains(renaming) {
            ordered = [renaming] + ordered.filter { $0 != renaming }
        }
        return ordered
    }

    // rebuildLibraryFolderChips(entries): Fit All and recent folders into one
    // row. Use + for creation when space allows, or include creation in
    // overflow. While creating, show only All and the editor.
    func rebuildLibraryFolderChips(entries: [LibraryEntry]) {
        // Wait until the Library's chip stack exists before rebuilding folder controls.
        guard let chipStack = libraryChipStack else { return }
        libraryFolderChipEntries = entries
        // Clear editor references before removing views, since removal can synchronously
        // end editing and trigger an unwanted second rebuild.
        libraryFolderEditor = nil
        libraryFolderEditorContainer = nil
        libraryFolderEditorHint = nil
        chipStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let folders = libraryFoldersInMRUOrder(names: libraryFolderNames(entries: entries))
        // A vanished selection (deleted or renamed elsewhere) falls back to All.
        if let selected = selectedLibraryFolder, !folders.contains(selected) {
            selectedLibraryFolder = nil
        }

        // folderChip(name): Create a folder chip with its nondeleted entry
        // count and selection action.
        func folderChip(_ name: String) -> LibraryFolderChipButton {
            // Omit zero counts from folder chips.
            let count = entries.filter { $0.folder == name && pendingLibraryDeletions[$0.id] == nil }.count
            let chip = LibraryFolderChipButton(
                kind: .folder(name),
                title: name,
                count: count > 0 ? count : nil,
                target: self,
                action: #selector(libraryFolderChipClicked(_:))
            )
            chip.isSelectedChip = selectedLibraryFolder == name
            chip.menu = libraryFolderChipMenu(for: name, entryCount: count)
            chip.onDropEntry = { [weak self] id in
                self?.fileDroppedEntry(id: id, into: name)
            }
            return chip
        }

        let spacing: CGFloat = 8
        let availableWidth = (libraryHostWindow?.contentLayoutRect.width ?? libraryContentSize.width) - 64
        libraryFolderChipsWidth = availableWidth

        // Include the keyboard hint in the editor's width calculation.
        let hintFont = NSFont.systemFont(ofSize: 11)
        // hintLabel(text): Create subdued keyboard guidance beside the inline
        // folder editor.
        func hintLabel(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = hintFont
            label.textColor = .tertiaryLabelColor
            return label
        }
        // hintWidth(text): Measure a folder-editor hint using the same font
        // that draws it.
        func hintWidth(_ text: String) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: hintFont]).width)
        }
        let createHintText = localized("folder_create_hint", "\u{21b5} create \u{b7} esc cancel")
        let renameHintText = localized("folder_rename_hint", "\u{21b5} rename \u{b7} esc cancel")

        let allChip = LibraryFolderChipButton(
            kind: .all,
            title: localized("all_chip", "All"),
            count: nil,
            target: self,
            action: #selector(libraryFolderChipClicked(_:))
        )
        allChip.isSelectedChip = selectedLibraryFolder == nil
        // Dropping on All unfiles the entry.
        allChip.onDropEntry = { [weak self] id in
            self?.fileDroppedEntry(id: id, into: nil)
        }
        chipStack.addArrangedSubview(allChip)
        libraryTabStops.append(allChip)

        // Show All, the editor and its hint during creation; restore the folder chips afterward.
        if isCreatingLibraryFolder {
            chipStack.addArrangedSubview(makeLibraryFolderEditor(text: ""))
            let hint = hintLabel(createHintText)
            libraryFolderEditorHint = hint
            libraryFolderEditorBaseHint = createHintText
            chipStack.addArrangedSubview(hint)
            libraryOverflowFolders = []
            return
        }

        // Measure chips and keep the longest recent-folder prefix that fits beside the trailing control.
        let chips = folders.map { name -> (name: String, view: NSView, width: CGFloat) in
            // Replace the renamed folder's chip with its editor in the same row.
            if renamingLibraryFolder == name {
                let editor = makeLibraryFolderEditor(text: name)
                return (
                    name,
                    editor,
                    editor.intrinsicContentSize.width + spacing + hintWidth(renameHintText)
                )
            }
            let chip = folderChip(name)
            return (name, chip, chip.intrinsicContentSize.width)
        }
        var usedWidth = allChip.intrinsicContentSize.width
        let trailingWidth = LibraryFolderChipButton(kind: .add, title: "", count: nil, target: nil, action: nil)
            .intrinsicContentSize.width
        let overflowReserve: CGFloat = 64

        var visible: [(name: String, view: NSView, width: CGFloat)] = []
        var hidden: [String] = []
        // Fit folder chips in order while reserving room for remaining controls.
        for (index, chip) in chips.enumerated() {
            let remaining = chips.count - index - 1
            // Reserve overflow width as soon as any folder must be hidden.
            let reserve = remaining == 0 ? trailingWidth : max(trailingWidth, overflowReserve)
            // Keep a chip visible when it fits with the required overflow space.
            if usedWidth + spacing + chip.width + spacing + reserve <= availableWidth {
                visible.append(chip)
                usedWidth += spacing + chip.width
            } else {
                // Move a folder into overflow when its chip would exceed the row width.
                hidden.append(chip.name)
                // Everything after the first miss hides too, keeping MRU order.
                hidden.append(contentsOf: chips[(index + 1)...].map { $0.name })
                break
            }
        }

        // Attach the chips chosen to fit in the visible row.
        for chip in visible {
            chipStack.addArrangedSubview(chip.view)
            // Include ordinary folder buttons in keyboard navigation.
            if let button = chip.view as? LibraryFolderChipButton {
                libraryTabStops.append(button)
            } else if chip.view === libraryFolderEditorContainer {
                // Show rename guidance beside the inline editor instead of treating it as a folder button.
                let hint = hintLabel(renameHintText)
                libraryFolderEditorHint = hint
                libraryFolderEditorBaseHint = renameHintText
                chipStack.addArrangedSubview(hint)
            }
        }

        // Show the Add chip directly when no folders need an overflow menu.
        if hidden.isEmpty {
            let addChip = LibraryFolderChipButton(
                kind: .add,
                title: "",
                count: nil,
                target: self,
                action: #selector(libraryNewFolderChipClicked(_:))
            )
            chipStack.addArrangedSubview(addChip)
            libraryTabStops.append(addChip)
            libraryOverflowFolders = []
        } else {
            // Show an overflow chip when some folders cannot fit in the row.
            let overflowChip = LibraryFolderChipButton(
                kind: .overflow,
                title: "\u{22ef}",
                count: hidden.count,
                target: self,
                action: #selector(libraryOverflowChipClicked(_:))
            )
            chipStack.addArrangedSubview(overflowChip)
            libraryTabStops.append(overflowChip)
            libraryOverflowFolders = hidden
        }
    }

    // libraryOverflowChipClicked(sender): Offer hidden folders, search and New
    // Folder in the overflow menu.
    @objc func libraryOverflowChipClicked(_ sender: Any?) {
        // Require the invoking folder chip before anchoring its overflow palette.
        guard let chip = sender as? LibraryFolderChipButton else { return }
        let hidden = libraryOverflowFolders
        let entries = LibraryStore.list()
        let page = PalettePage(
            searchPlaceholder: localized("filter_folders", "Filter folders"),
            // Keep New Folder above the scrolling list.
            topAction: PaletteItem(
                id: "new-folder",
                icon: "plus",
                title: localized("new_folder_menu", "New Folder\u{2026}"),
                action: { [weak self] in
                    self?.beginLibraryFolderCreation()
                    return .close
                }
            ),
            rows: { [weak self] filter in
                // Return no overflow rows after the launcher controller is released.
                guard let self else { return [] }
                var rows: [PaletteRow] = []
                rows.append(contentsOf: hidden
                    .filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }
                    .map { name in
                        let count = entries.filter { $0.folder == name }.count
                        return .item(PaletteItem(
                            id: name,
                            icon: "folder",
                            title: name,
                            detail: "\(count)",
                            checked: self.selectedLibraryFolder == name,
                            action: { [weak self] in
                                // Promote the chosen folder to the visible row.
                                LibraryStore.touchFolderMRU(name)
                                self?.selectedLibraryFolder = name
                                self?.refreshLibrary()
                                return .close
                            }
                        ))
                    })
                return rows
            }
        )
        presentPalette(page, anchorRect: screenRect(of: chip), width: 280)
    }

    // makeLibraryFolderEditor(text): The inline chip-shaped editor used for
    // both creation and rename. Return commits; Esc or clicking away cancels.
    private func makeLibraryFolderEditor(text: String) -> LibraryFolderChipEditorView {
        let container = LibraryFolderChipEditorView(
            text: text,
            placeholder: localized("folder_name_placeholder", "Folder name")
        )
        container.textField.delegate = self
        libraryFolderEditor = container.textField
        libraryFolderEditorContainer = container
        DispatchQueue.main.async { [weak self, weak container] in
            // Focus the inline editor only if its container still owns a text field.
            guard let field = container?.textField else { return }
            self?.libraryHostWindow?.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NSRange(
                location: 0,
                length: field.stringValue.utf16.count
            )
        }
        return container
    }

    // controlTextDidChange(notification): Resize the folder editor and flag
    // duplicate names. Return opens an existing folder during creation;
    // renaming reports the conflict.
    func controlTextDidChange(_ notification: Notification) {
        // Ignore text-change notifications from fields other than the active folder editor.
        guard (notification.object as? NSTextField) === libraryFolderEditor else { return }
        libraryFolderEditorContainer?.refreshWidth()
        let name = LibraryStore.normalizedFolderName(libraryFolderEditor?.stringValue ?? "")
        let existing = allLibraryFolderNames().first {
            $0.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        let duplicate = !name.isEmpty && existing != nil && existing != renamingLibraryFolder
        libraryFolderEditorContainer?.isDuplicate = duplicate
        // Update the visible editor hint when one is installed.
        if let hint = libraryFolderEditorHint {
            // Explain duplicate-name behavior while a matching folder already exists.
            if duplicate {
                hint.stringValue = isCreatingLibraryFolder
                    ? localized("folder_exists_opens_hint", "already exists \u{b7} \u{21b5} opens it")
                    : localized("folder_exists_hint", "already exists")
                hint.textColor = .systemOrange
            } else {
                // Restore normal keyboard guidance when the name is not a duplicate.
                hint.stringValue = libraryFolderEditorBaseHint
                hint.textColor = .tertiaryLabelColor
            }
        }
    }

    // fileDroppedEntry(id, folder): File the dropped entry and update folder
    // recency. Dropping on All removes its folder assignment.
    func fileDroppedEntry(id: String, into folder: String?) {
        // Filing into a folder is Pro; dropping on All (unfiling) stays free.
        if folder != nil, !ensureProAccess(.libraryFolders) {
            return
        }
        try? LibraryStore.setFolder(id: id, folder: folder)
        // Remember recent usage only for a named folder, not the All view.
        if let folder {
            LibraryStore.touchFolderMRU(folder)
        }
        refreshLibrary()
    }

    // libraryFolderChipClicked(sender): Resolve any folder edit before
    // switching the active Library folder chip.
    @objc func libraryFolderChipClicked(_ sender: Any?) {
        // Ignore chip actions from unrelated controls.
        guard let chip = sender as? LibraryFolderChipButton else { return }
        commitOrCancelLibraryFolderEditing()
        // Choose the browsing action from the clicked chip's kind.
        switch chip.kind {
        // The All chip clears folder filtering.
        case .all:
            selectedLibraryFolder = nil
        case .folder(let name):
            // Do not reorder visible chips on selection; update recency on filing or overflow selection
            // instead.
            selectedLibraryFolder = name
        // Creation and overflow chips use their own dedicated action handlers.
        case .add, .overflow:
            return
        }
        refreshLibrary()
    }

    // libraryNewFolderChipClicked(sender): Start folder creation from the
    // dedicated add chip.
    @objc func libraryNewFolderChipClicked(_ sender: Any?) {
        beginLibraryFolderCreation()
    }

    // beginLibraryFolderCreation([thenMoveEntryID = nil]): Start folder
    // creation, optionally filing an entry when the folder is created.
    func beginLibraryFolderCreation(thenMoveEntryID: String? = nil) {
        // Require Pro before opening folder creation.
        guard ensureProAccess(.libraryFolders) else {
            return
        }
        renamingLibraryFolder = nil
        isCreatingLibraryFolder = true
        pendingFolderMoveEntryID = thenMoveEntryID
        refreshLibrary()
    }

    // beginLibraryFolderRename(name): Replace the selected folder chip with an
    // inline rename editor.
    func beginLibraryFolderRename(_ name: String) {
        isCreatingLibraryFolder = false
        pendingFolderMoveEntryID = nil
        renamingLibraryFolder = name
        refreshLibrary()
    }

    // cancelLibraryFolderEditing(): Discard an active folder edit and restore
    // ordinary folder chips.
    func cancelLibraryFolderEditing() {
        // Skip cancellation when no folder creation or rename is active.
        guard isCreatingLibraryFolder || renamingLibraryFolder != nil else { return }
        isCreatingLibraryFolder = false
        renamingLibraryFolder = nil
        pendingFolderMoveEntryID = nil
        // Rebuild the listing only if the Library is currently being shown.
        if isShowingLibrary {
            refreshLibrary()
        }
    }

    // commitOrCancelLibraryFolderEditing(): Commit nonempty creation text when
    // another chip is clicked; cancel an empty editor.
    private func commitOrCancelLibraryFolderEditing() {
        // Resolve pending edits only when an editor field still exists.
        guard let editor = libraryFolderEditor else { return }
        let name = LibraryStore.normalizedFolderName(editor.stringValue)
        // Commit a nonempty new-folder draft before switching elsewhere.
        if isCreatingLibraryFolder, !name.isEmpty {
            commitLibraryFolderEditor(named: name)
        } else {
            // Cancel empty drafts or unfinished renames on this click-away path.
            cancelLibraryFolderEditing()
        }
    }

    // commitLibraryFolderEditor(name): Commit a folder edit while reusing a
    // case-insensitive match instead of creating a duplicate.
    private func commitLibraryFolderEditor(named name: String) {
        // Reuse case-insensitive name matches to avoid duplicate folders.
        let existing = allLibraryFolderNames().first {
            $0.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        // An active rename updates the existing folder identity by display name.
        if let renamed = renamingLibraryFolder {
            // Allow a rename only when it does not collide with another folder.
            if existing == nil || existing == renamed {
                LibraryStore.renameFolder(from: renamed, to: name)
                // Keep the renamed folder selected if it was the active filter.
                if selectedLibraryFolder == renamed {
                    selectedLibraryFolder = name
                }
            }
        } else {
            // Creation can reuse a case-insensitive existing folder name.
            let target = existing ?? name
            // Persist a new explicit folder only when there is no existing match.
            if existing == nil {
                LibraryStore.addFolder(target)
            }
            // Keep the created or reused folder visible.
            LibraryStore.touchFolderMRU(target)
            // Complete a pending entry move after its destination folder is created or resolved.
            if let id = pendingFolderMoveEntryID {
                try? LibraryStore.setFolder(id: id, folder: target)
            } else {
                // Select the new folder when creation was not part of an entry move.
                selectedLibraryFolder = target
            }
        }
        isCreatingLibraryFolder = false
        renamingLibraryFolder = nil
        pendingFolderMoveEntryID = nil
        refreshLibrary()
    }

    // control(control, textView, commandSelector): Handle Return and Escape in
    // the folder editor, then return focus to search.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Leave commands from other text controls to their own delegates.
        guard control === libraryFolderEditor else { return false }
        // Return commits the inline folder editor.
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let name = LibraryStore.normalizedFolderName(control.stringValue)
            // Treat an empty submitted name as cancellation.
            if name.isEmpty {
                cancelLibraryFolderEditing()
            } else {
                // Commit a nonempty normalized folder name.
                commitLibraryFolderEditor(named: name)
            }
            focusLibrarySearch()
            return true
        }
        // Escape discards the inline folder draft.
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelLibraryFolderEditing()
            focusLibrarySearch()
            return true
        }
        return false
    }

    // controlTextDidEndEditing(notification): Clicking away from the editor
    // cancels, matching the hint's promise.
    func controlTextDidEndEditing(_ notification: Notification) {
        // Handle focus loss only for the active folder editor.
        guard (notification.object as? NSTextField) === libraryFolderEditor else { return }
        DispatchQueue.main.async { [weak self] in
            self?.cancelLibraryFolderEditing()
        }
    }

    // libraryFolderChipMenu(name, entryCount): Offer folder actions. Deleting a
    // folder leaves its entries unfiled under All.
    func libraryFolderChipMenu(for name: String, entryCount: Int) -> NSMenu {
        let menu = NSMenu()
        let renameItem = NSMenuItem(
            title: localized("rename_folder_menu", "Rename Folder"),
            action: #selector(libraryFolderRenamePicked(_:)),
            keyEquivalent: ""
        )
        renameItem.target = self
        renameItem.representedObject = name
        menu.addItem(renameItem)
        menu.addItem(.separator())
        let deleteItem = NSMenuItem(
            title: localized("delete_folder_menu", "Delete Folder"),
            action: #selector(libraryFolderDeletePicked(_:)),
            keyEquivalent: ""
        )
        // For nonempty folders, explain that entries are kept. Use a subtitle, or a tooltip before macOS
        // 14.4.
        if entryCount > 0 {
            let subtitle = localized("delete_folder_subtitle", "All entries stay in the Library")
            // Show the deletion explanation as a menu subtitle on supported macOS versions.
            if #available(macOS 14.4, *) {
                deleteItem.subtitle = subtitle
            } else {
                // Use a tooltip for the same explanation on older versions.
                deleteItem.toolTip = subtitle
            }
        }
        deleteItem.target = self
        deleteItem.representedObject = name
        menu.addItem(deleteItem)
        return menu
    }

    // libraryFolderRenamePicked(sender): Start renaming the folder identified
    // by the context-menu item.
    @objc func libraryFolderRenamePicked(_ sender: NSMenuItem) {
        // Require the stored folder name before starting a context-menu rename.
        guard let name = sender.representedObject as? String else { return }
        beginLibraryFolderRename(name)
    }

    // libraryFolderDeletePicked(sender): Unfile the folder's entries and remove
    // the folder through its delete action.
    @objc func libraryFolderDeletePicked(_ sender: NSMenuItem) {
        // Require the stored folder name before deleting a folder.
        guard let name = sender.representedObject as? String else { return }
        // Unfile entries belonging to the removed folder while retaining the entries themselves.
        for entry in LibraryStore.list() where entry.folder == name {
            try? LibraryStore.setFolder(id: entry.id, folder: nil)
        }
        LibraryStore.removeFolder(name)
        LibraryStore.removeFolderMRU(name)
        // Return to All when the folder being deleted was the active filter.
        if selectedLibraryFolder == name {
            selectedLibraryFolder = nil
        }
        refreshLibrary()
    }

    // libraryMoveMenu(entry, folders): Build the File In submenu from the
    // supplied folder list: No Folder, existing folders and New Folder. Filing
    // changes metadata without moving saved files.
    func libraryMoveMenu(for entry: LibraryEntry, folders: [String]) -> NSMenu {
        let menu = NSMenu()
        let rootItem = NSMenuItem(
            title: localized("no_folder", "No Folder"),
            action: #selector(libraryMovePicked(_:)),
            keyEquivalent: ""
        )
        rootItem.target = self
        rootItem.representedObject = ["id": entry.id]
        rootItem.state = entry.folder == nil ? .on : .off
        menu.addItem(rootItem)
        // Separate available destination folders from the menu's fixed actions.
        if !folders.isEmpty {
            menu.addItem(.separator())
            // Offer each existing folder as a filing destination.
            for name in folders {
                let item = NSMenuItem(title: name, action: #selector(libraryMovePicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["id": entry.id, "folder": name]
                item.state = entry.folder == name ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let newFolderItem = NSMenuItem(
            title: localized("new_folder_menu", "New Folder\u{2026}"),
            action: #selector(libraryMoveToNewFolderPicked(_:)),
            keyEquivalent: ""
        )
        newFolderItem.target = self
        newFolderItem.representedObject = ["id": entry.id]
        menu.addItem(newFolderItem)
        return menu
    }

    // libraryMovePicked(sender): Move a selected entry to a folder, keeping the
    // no-folder action available without Pro.
    @objc func libraryMovePicked(_ sender: NSMenuItem) {
        // Require the entry identifier carried by the folder move action.
        guard let info = sender.representedObject as? [String: String], let id = info["id"] else { return }
        // "No Folder" (unfiling) stays free; filing into a folder is Pro.
        if info["folder"] != nil, !ensureProAccess(.libraryFolders) {
            return
        }
        try? LibraryStore.setFolder(id: id, folder: info["folder"])
        // Update folder recency after filing.
        if let folder = info["folder"] {
            LibraryStore.touchFolderMRU(folder)
        }
        refreshLibrary()
    }

    // libraryMoveToNewFolderPicked(sender): Create a folder first, then file
    // the selected entry into it.
    @objc func libraryMoveToNewFolderPicked(_ sender: NSMenuItem) {
        // Require the target entry ID before creating a folder for its pending move.
        guard let info = sender.representedObject as? [String: String], let id = info["id"] else { return }
        beginLibraryFolderCreation(thenMoveEntryID: id)
    }

    // reflowLibraryFolderChips(): Keep search, row selection and unfinished
    // folder edits intact when the width changes.
    func reflowLibraryFolderChips() {
        // Reflow chips only with a usable idle host and no active folder editor.
        guard let window = libraryHostWindow, let chipStack = libraryChipStack,
              !window.inLiveResize, !isCreatingLibraryFolder, renamingLibraryFolder == nil,
              abs(window.contentLayoutRect.width - 64 - libraryFolderChipsWidth) > 0.5 else { return }
        let focusedKind = (window.firstResponder as? LibraryFolderChipButton)?.kind
        let rowStops = libraryTabStops.filter { !$0.isDescendant(of: chipStack) }
        libraryTabStops.removeAll()
        rebuildLibraryFolderChips(entries: libraryFolderChipEntries)
        libraryTabStops.append(contentsOf: rowStops)
        // Restore keyboard focus when the rebuilt row replaced a previously focused chip.
        if let focusedKind {
            let chips = chipStack.arrangedSubviews.compactMap { $0 as? LibraryFolderChipButton }
            // Prefer the same chip, then overflow, then the first remaining chip as focus fallback.
            if let replacement = chips.first(where: { $0.kind == focusedKind })
                ?? chips.first(where: { $0.kind == .overflow }) ?? chips.first {
                window.makeFirstResponder(replacement)
            }
        }
    }

}
