import Cocoa

// Supply a dependency’s type identity without adding behavior to this fixture.
final class PreferencesController: NSObject {}
// localized(key, fallback): Resolve labels through the fixture’s controlled
// localization.
func localized(_ key: String, _ fallback: String) -> String { fallback }
// Supply the paid-feature identifier used by the sync settings panel.
enum ProFeature { case librarySync }
var purchase: () -> Bool = { false }
// ensureProAccess(feature): Let tests simulate either existing access or a
// successful upgrade.
func ensureProAccess(_ feature: ProFeature) -> Bool { LibraryCloudSync.shared.hasProAccess || purchase() }
// Expose controlled sync state and count user actions without CloudKit.
final class LibraryCloudSync {
    static let shared = LibraryCloudSync()
    static let statusDidChange = Notification.Name("FixtureSyncStatus")
    static var supportedBuild = true
    static let proRequiredMessage = "iCloud Library sync requires Langmin Pro. Your local Library stays available."
    static let proPausedMessage = "iCloud sync is paused. Renew Pro to resume. Local and iCloud copies are kept."
    var enabled = false, hasProAccess = false, isSyncing = false
    var status = "iCloud sync is off. Local and iCloud copies are kept."
    var lastSync: Date?
    var enableCalls = 0, syncCalls = 0
    // setEnabled(value): Record opt-in changes requested by the settings panel.
    func setEnabled(_ value: Bool) { enabled = value; enableCalls += 1 }
    // syncNow(): Count synchronization only when both opt-in and Pro access
    // allow it.
    func syncNow() { /* Count sync requests only while sync and purchase access are enabled. */ if enabled && hasProAccess { syncCalls += 1 } }
}

// Run the sync settings interactions and native layout checks.
@main struct Tests {
    // main(): Exercise upgrade, opt-out, unsupported-build, and settings-layout
    // behavior.
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let panel = LibrarySyncSettingsController()
        panel.build()
        panel.refresh()
        let sync = LibraryCloudSync.shared
        var count = 0
        // check(valid, message): Report failed fixture expectations with their
        // case names.
        func check(_ valid: Bool, _ message: String) throws {
            // Stop this fixture when its named expectation does not hold.
            guard valid else { throw NSError(domain: message, code: 1) }
            count += 1
        }
        try check(panel.syncButton.title == "Upgrade…" && panel.syncButton.isEnabled, "Free users see an enabled upgrade action")
        try check(panel.statusLabel.stringValue == LibraryCloudSync.proRequiredMessage, "Free state explains the Pro requirement")
        panel.toggle.state = .on
        panel.toggleSync(panel.toggle)
        try check(sync.enableCalls == 0 && panel.toggle.state == .off, "Cancelling purchase restores the checkbox without enabling sync")

        // A successful purchase may refresh the checkbox before the modal call returns.
        purchase = { sync.hasProAccess = true; panel.refresh(); return true }
        panel.toggle.state = .on
        panel.toggleSync(panel.toggle)
        try check(sync.enabled && panel.toggle.state == .on, "Purchase preserves the user's original enable action through a refresh")
        try check(panel.syncButton.title == "Sync Now", "Purchase replaces the upgrade action")
        sync.hasProAccess = false
        panel.refresh()
        try check(panel.toggle.isEnabled && panel.toggle.state == .on, "Expired users can still disable their opt-in")
        try check(panel.statusLabel.stringValue == LibraryCloudSync.proPausedMessage, "Expired state explains preservation of local and cloud copies")
        purchase = { throwPurchase() }
        panel.toggle.state = .off
        panel.toggleSync(panel.toggle)
        try check(!sync.enabled, "Disabling after expiry never opens a purchase panel")
        purchase = { sync.hasProAccess = true; panel.refresh(); return true }
        panel.syncNow(nil)
        try check(!sync.enabled && sync.syncCalls == 0, "Upgrade button does not implicitly enable sync")
        LibraryCloudSync.supportedBuild = false
        sync.enabled = true
        panel.refresh()
        try check(panel.toggle.isEnabled && !panel.syncButton.isEnabled, "Unsupported builds permit opt-out but cannot sync")
        panel.toggle.state = .off
        panel.toggleSync(panel.toggle)
        try check(!sync.enabled && !panel.toggle.isEnabled, "Unsupported opt-in becomes disabled after opting out")

        // Fit both appearances, including the longer paused status and timestamp row.
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Cover free, expired, and active Pro states, including saved timestamps.
        for (name, pro, enabled, date) in [
            ("free", false, false, nil as Date?),
            ("expired", false, true, Date(timeIntervalSince1970: 1_789_100_000)),
            ("pro", true, true, Date(timeIntervalSince1970: 1_789_100_000))
        ] {
            LibraryCloudSync.supportedBuild = true
            sync.hasProAccess = pro; sync.enabled = enabled; sync.lastSync = date
            // Show a completed-sync status for the active Pro layout case.
            if pro { sync.status = "Library is up to date." }
            panel.refresh()
            let window = panel.window!
            // Check spacing and wrapping in both native appearances.
            for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                window.orderBack(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let view = window.contentView!
                view.wantsLayer = true
                view.layer!.backgroundColor = NSColor(calibratedWhite: appearance == .aqua ? 0.96 : 0.12, alpha: 1).cgColor
                window.layoutIfNeeded()
                let stack = view.subviews.first as! NSStackView
                try check(abs(stack.frame.minY - 20) <= 1, "Content has consistent bottom spacing")
                try check(abs(view.bounds.maxY - stack.frame.maxY - 24) <= 1, "Content has consistent top spacing")
                try check(panel.lastSyncLabel.isHidden == (date == nil), "Only existing timestamps occupy a row")
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                bitmap.size = view.bounds.size
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + "-" + appearance.rawValue + ".png"))
            }
        }
        print("\(count) native iCloud settings checks passed")
    }
    // throwPurchase(): Fail if disabling sync unexpectedly opens a purchase
    // flow.
    static func throwPurchase() -> Bool { fatalError("Opt-out must not require a purchase") }
}
