#!/usr/bin/env python3
"""Exercise the locked-access footer without making purchases or reading receipts."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
from source_files import ROOT, app_path

FIXTURE = r'''
import Cocoa
var translations: [String: String] = [:]
var emptyRestores = 0, errors = 0
// localized(key, fallback): Resolve fixture translations without user preferences.
func localized(_ key: String, _ fallback: String) -> String { translations[key] ?? fallback }
// presentNothingToRestoreAlert(): Record feedback without opening a modal alert.
func presentNothingToRestoreAlert() { emptyRestores += 1 }
// presentProAlert(title, body, [style]): Record a failed restore without a modal alert.
func presentProAlert(title: String, body: String, style: NSAlert.Style = .informational) { errors += 1 }
// Supply access updates and a controllable restore operation without StoreKit.
class ProStore {
    static let shared = ProStore()
    static let entitlementDidChange = Notification.Name("FixtureAccessChanged")
    var hasPreparedAppTrial = true
    var hasResolvedEntitlement = true
    var hasFullAccess = false
    var restores = 0
    var pending: CheckedContinuation<Bool, Error>?
    // restore(): Suspend until the fixture supplies success, failure, or no purchase.
    func restore() async throws -> Bool {
        restores += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    // grantAccess(value): Simulate an entitlement update as the real store does.
    func grantAccess(_ value: Bool) {
        hasFullAccess = value
        NotificationCenter.default.post(name: Self.entitlementDidChange, object: nil)
    }
}
// Record entry to the existing paywall without displaying it.
enum ProPaywallController {
    static var purchases = 0
    // presentModal(feature): Simulate completing a purchase in the paywall.
    static func presentModal(feature: String?) -> Bool {
        purchases += 1
        ProStore.shared.grantAccess(true)
        return true
    }
}
// check(value, message): Fail with a named expectation.
func check(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
@main struct Tests {
    // main(): Check localized layout, entitlement changes, and purchase actions.
    @MainActor static func main() async throws {
        check(LangminEdition.localProAccess == nil, "Public builds have no override")
        UserDefaults.standard.removeObject(forKey: "LangminDidDismissExpiredTrialBanner")
        _ = NSApplication.shared
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let artifacts = URL(fileURLWithPath: CommandLine.arguments[2])
        let locales = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
        ProStore.shared.hasResolvedEntitlement = false
        let unresolved = SourcePurchaseFooter(frame: .zero)
        check(unresolved.isHidden, "Entitlement lookup keeps the expired banner hidden")
        ProStore.shared.hasResolvedEntitlement = true
        NotificationCenter.default.post(name: ProStore.entitlementDidChange, object: nil)
        check(!unresolved.isHidden, "Resolved free access reveals the expired banner")
        // Fit all translated actions in light and dark mode at the minimum launcher width.
        for locale in locales where locale.pathExtension == "lproj" {
            let data = try Data(contentsOf: locale.appendingPathComponent("Localizable.strings"))
            translations = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
            for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 58),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                let host = window.contentView!
                host.wantsLayer = true
                window.appearance?.performAsCurrentDrawingAppearance {
                    host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
                let banner = SourcePurchaseFooter(frame: .zero)
                banner.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(banner)
                NSLayoutConstraint.activate([
                    banner.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    banner.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    banner.bottomAnchor.constraint(equalTo: host.bottomAnchor)
                ])
                window.layoutIfNeeded()
                let stacks = banner.subviews.compactMap { $0 as? NSStackView }
                let text = stacks.first { $0.orientation == .vertical }!
                let actions = stacks.first { $0.orientation == .horizontal }!
                check(text.frame.minX >= 13 && actions.frame.maxX <= banner.bounds.maxX - 13, "Horizontal padding")
                check(text.frame.width >= 250 && text.frame.maxX <= actions.frame.minX - 13, "Readable text beside actions: \(locale.lastPathComponent), text \(text.frame), actions \(actions.frame)")
                check(text.frame.minY >= 4 && text.frame.maxY <= banner.bounds.maxY - 4, "Text fits vertically")
                check(banner.bounds.height == 58 && !banner.isHidden, "Locked banner is visible")
                check(!banner.hasAmbiguousLayout && !text.hasAmbiguousLayout && !actions.hasAmbiguousLayout, "Layout is determined")
                // Save a visual sample without displaying a real window.
                if locale.lastPathComponent == "en.lproj" {
                    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: artifacts.appendingPathComponent("banner-\(appearance.rawValue).png"))
                }
                var visible = true
                banner.onVisibilityChange = { visible = $0 }
                ProStore.shared.grantAccess(true)
                window.layoutIfNeeded()
                check(!visible && banner.isHidden && banner.frame.height == 0, "Pro removes banner and its space")
                ProStore.shared.grantAccess(false)
                window.layoutIfNeeded()
                check(visible && !banner.isHidden && banner.frame.height == 58, "Revocation restores the banner")
            }
        }
        // Run action tests against controlled asynchronous restoration.
        let banner = SourcePurchaseFooter(frame: .zero)
        let actions = banner.subviews.compactMap { $0 as? NSStackView }.first { $0.orientation == .horizontal }!
        let buttons = actions.arrangedSubviews.compactMap { $0 as? NSButton }
        let dismiss = buttons[0], restore = buttons[1], purchase = buttons[2]
        // click(button): Send the real button action without generating a system event.
        func click(_ button: NSButton) { NSApp.sendAction(button.action!, to: button.target, from: button) }
        // until(condition): Bound asynchronous waits to avoid hanging the suite.
        func until(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            check(condition(), "Asynchronous action settled")
        }
        click(dismiss)
        check(banner.isHidden, "Dismiss hides the optional reminder")
        UserDefaults.standard.removeObject(forKey: "LangminDidDismissExpiredTrialBanner")
        ProStore.shared.grantAccess(false)
        check(!banner.isHidden, "Clearing dismissal restores the reminder for this fixture")

        click(restore)
        click(restore)
        click(purchase)
        try await until { ProStore.shared.pending != nil }
        check(ProStore.shared.restores == 1 && ProPaywallController.purchases == 0, "Competing requests are blocked")
        check(!restore.isEnabled && !purchase.isEnabled, "Busy actions are disabled")
        ProStore.shared.pending?.resume(returning: false)
        ProStore.shared.pending = nil
        try await until { restore.isEnabled }
        check(emptyRestores == 1 && !banner.isHidden, "Missing purchase keeps access locked and explains why")
        click(restore)
        try await until { ProStore.shared.pending != nil }
        ProStore.shared.pending?.resume(throwing: NSError(domain: "Fixture", code: 1))
        ProStore.shared.pending = nil
        try await until { restore.isEnabled }
        check(errors == 1 && !banner.isHidden, "Failure keeps actions available and access locked")
        click(restore)
        try await until { ProStore.shared.pending != nil }
        ProStore.shared.grantAccess(true)
        ProStore.shared.pending?.resume(returning: true)
        ProStore.shared.pending = nil
        try await until { restore.isEnabled }
        check(banner.isHidden, "Verified restore hides the banner")
        ProStore.shared.grantAccess(false)
        click(purchase)
        check(ProPaywallController.purchases == 1 && banner.isHidden, "Purchase uses the paywall and refreshes access")
        let unlockedBanner = SourcePurchaseFooter(frame: .zero)
        check(unlockedBanner.isHidden, "Existing Pro starts without a locked banner")
        print("Distribution banner checks passed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='langmin-banner-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'Fixture.swift').write_text(FIXTURE)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    # Compile public and Store variants against the same access and banner sources.
    for name, flags in [('source', []), ('store', ['-D', 'LANGMIN_APP_STORE'])]:
        executable = folder / name
        subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', cache, *flags,
                        str(app_path('BuildEdition.swift')), str(app_path('SourcePurchaseFooter.swift')),
                        str(folder / 'Fixture.swift'), '-o', str(executable)], check=True)
        subprocess.run([str(executable), str(ROOT / 'langmin/Resources'), directory], check=True, timeout=30)
    # A compile flag alone cannot provide the missing private implementation.
    for flags, diagnostic in [(['-D', 'LANGMIN_LOCAL_BUILD'], 'LangminLocalAccess'),
                               (['-D', 'LANGMIN_LOCAL_BUILD', '-D', 'LANGMIN_APP_STORE'],
                                'Local access must not be included in an App Store build.')]:
        result = subprocess.run(['swiftc', '-typecheck', '-module-cache-path', cache, *flags,
                                 str(app_path('BuildEdition.swift'))], capture_output=True, text=True)
        assert result.returncode != 0 and diagnostic in result.stderr, result.stderr
    # Retain preview images only in an explicitly requested task directory.
    if target := os.environ.get('LANGMIN_TEST_ARTIFACTS'):
        output = Path(target)
        output.mkdir(parents=True, exist_ok=True)
        for image in folder.glob('*.png'):
            shutil.copyfile(image, output / image.name)
