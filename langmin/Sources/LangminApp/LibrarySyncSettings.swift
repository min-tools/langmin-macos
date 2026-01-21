import Cocoa

// Expose the Library sync panel from the shared Settings controller.
extension PreferencesController {
    // showLibrarySync(sender): Open the dedicated iCloud sync panel.
    @objc func showLibrarySync(_ sender: Any?) { LibrarySyncSettingsController.shared.show() }
}

// Sync is an explicit, device-local opt-in. Its controls apply immediately and are separate from
// the general Settings draft, so Cancel there cannot suggest that an upload has been undone.
final class LibrarySyncSettingsController: NSObject {
    static let shared = LibrarySyncSettingsController()
    private var window: NSWindow?
    private var toggle: NSButton!
    private var syncButton: NSButton!
    private var statusLabel: NSTextField!
    private var lastSyncLabel: NSTextField!

    // show(): Refresh and show the reusable sync panel with the current
    // coordinator state.
    func show() {
        // Build the reusable sync panel only on its first presentation.
        if window == nil { build() }
        refresh()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // build(): Build sync opt-in, explanation, status, and manual-sync controls
    // in a compact panel.
    private func build() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Library · iCloud Sync"
        panel.isReleasedWhenClosed = false
        toggle = NSButton(checkboxWithTitle: "Sync Library with iCloud", target: self, action: #selector(toggleSync(_:)))
        toggle.font = .systemFont(ofSize: 14, weight: .medium)
        let detail = NSTextField(wrappingLabelWithString: "Keep saved results, folders, conversations, images, and audio available across Macs using the same Apple Account.\n\nDeletions sync too. Turning sync off keeps your local and iCloud copies. API keys, settings, and unsaved results stay on this Mac.")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        // Keep current status and the last completed sync time separate.
        statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        lastSyncLabel = NSTextField(labelWithString: "")
        lastSyncLabel.font = .systemFont(ofSize: 11)
        lastSyncLabel.textColor = .secondaryLabelColor
        syncButton = NSButton(title: "Sync Now", target: self, action: #selector(syncNow(_:)))
        // Let the explanatory text wrap to the shared panel width.
        let stack = NSStackView(views: [toggle, detail, statusLabel, lastSyncLabel, syncButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -20),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        // Refresh the visible status when the sync coordinator publishes a
        // change.
        window = panel
        NotificationCenter.default.addObserver(self, selector: #selector(statusChanged(_:)), name: LibraryCloudSync.statusDidChange, object: nil)
    }

    // toggleSync(sender): Capture the requested opt-in before any purchase UI
    // can refresh the checkbox.
    @objc private func toggleSync(_ sender: NSButton) {
        // Entitlement notifications can refresh this checkbox while the purchase panel is open.
        let requested = sender.state == .on
        // Declining Pro access leaves opt-in unchanged and restores the displayed checkbox state.
        if requested && !ensureProAccess(.librarySync) { refresh(); return }
        LibraryCloudSync.shared.setEnabled(requested)
        refresh()
    }
    // syncNow(sender): Verify Pro access before starting a user-requested sync.
    @objc private func syncNow(_ sender: Any?) {
        // Do not run a manual sync when Pro access is unavailable.
        guard ensureProAccess(.librarySync) else { refresh(); return }
        LibraryCloudSync.shared.syncNow()
        refresh()
    }
    // statusChanged(notification): Refresh the panel when sync status or
    // entitlement notifications arrive.
    @objc private func statusChanged(_ notification: Notification) { refresh() }

    // refresh(): Reflect build support, Pro access, opt-in, progress, and the
    // latest sync status in the controls.
    private func refresh() {
        // Skip control updates before the panel exists.
        guard window != nil else { return }
        let sync = LibraryCloudSync.shared
        let supported = LibraryCloudSync.supportedBuild
        let pro = sync.hasProAccess
        toggle.state = sync.enabled ? .on : .off
        // A paused opt-in can always be turned off, even in an unsupported build or after expiry.
        toggle.isEnabled = supported || sync.enabled
        syncButton.title = pro ? "Sync Now" : localized("pro_upgrade_button", "Upgrade…")
        syncButton.isEnabled = supported && (!pro || (sync.enabled && !sync.isSyncing))
        // Explain missing build capabilities before account or sync status.
        if !supported {
            statusLabel.stringValue = "iCloud requires an Apple-signed build with iCloud enabled."
        } else if !pro {
            // Explain whether lack of Pro access blocks new opt-in or pauses existing sync.
            statusLabel.stringValue = sync.enabled ? LibraryCloudSync.proPausedMessage : LibraryCloudSync.proRequiredMessage
        // Show the coordinator's actual status when build support and entitlement are available.
        } else { /* Show the current sync status when no access warning is needed. */ statusLabel.stringValue = sync.status }
        // Announce status changes only while the panel is visible.
        if window?.isVisible == true, let statusLabel { NSAccessibility.post(element: statusLabel, notification: .valueChanged) }
        // Show the most recent successful check time when one exists.
        if let date = sync.lastSync {
            lastSyncLabel.stringValue = "Last checked: " + DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
        // Clear the timestamp text when no previous sync time is available.
        } else { /* Hide the timestamp text until a sync check has completed. */ lastSyncLabel.stringValue = "" }
        // Omit the empty timestamp row until the first check, including its stack spacing.
        lastSyncLabel.isHidden = sync.lastSync == nil
        // Fit the current content with consistent padding, including wrapped account or network errors.
        if let view = window?.contentView, let stack = view.subviews.first as? NSStackView {
            view.layoutSubtreeIfNeeded()
            let height = ceil(stack.fittingSize.height) + 44
            // Resize only when changed status text materially changes the panel's required height.
            if abs(view.bounds.height - height) > 1 { window?.setContentSize(NSSize(width: 460, height: height)) }
        }
    }
}
