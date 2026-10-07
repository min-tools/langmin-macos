#!/usr/bin/env python3
"""Exercise real startup methods with Apple events and isolated UI/integrations.

Never opens app windows, reads user preferences, or registers a login item.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MAIN = (ROOT / 'langmin/Sources/LangminApp/main.swift').read_text()


# block(marker): Extract one production declaration, including nested branches.
def block(marker):
    start = MAIN.index(marker)
    end = MAIN.index('{', start) + 1
    depth = 1
    while depth:
        depth += (MAIN[end] == '{') - (MAIN[end] == '}')
        end += 1
    return MAIN[start:end] + '\n'


source = r'''
import Cocoa
import Carbon

// Keep application startup effects inside the fixture instead of the workstation.
var startupCalls: [String] = []
let appIconName = "FixtureIcon", appName = "Langmin"
func migrateCommandOpenClipboardShortcut() { startupCalls.append("migrateClipboard") }
func migrateLibraryShortcutToGlobalDefault() { startupCalls.append("migrateLibrary") }
func removeAbandonedLangminTemporaryItems() { startupCalls.append("cleanup") }
func NSUpdateDynamicServices() { startupCalls.append("services") }
final class ProStore {
    static let shared = ProStore()
    func start() { startupCalls.append("store") }
}
enum LangminEdition { static let isExpiredTrialPreview = false }

// Capture deferred callbacks so tests can clear the current event before delivery.
struct FixtureDeadline {
    static func now() -> Self { Self() }
    static func + (lhs: Self, rhs: Double) -> Self { lhs }
}
final class FixtureQueue {
    var work: [() -> Void] = []
    func async(execute: @escaping () -> Void) { work.append(execute) }
    func asyncAfter(deadline: FixtureDeadline, execute: @escaping () -> Void) { work.append(execute) }
    func drain() {
        while !work.isEmpty { work.removeFirst()() }
    }
}
enum DispatchQueue { static let main = FixtureQueue() }

// Use real Apple-event descriptors without touching the process event manager.
final class NSAppleEventManager {
    static let instance = NSAppleEventManager()
    var currentAppleEvent: NSAppleEventDescriptor?
    static func shared() -> NSAppleEventManager { instance }
}
final class NSImage {
    typealias Name = String
    init?(named: Name) { return nil }
    init?(systemSymbolName: String, accessibilityDescription: String) {}
}
final class NSApplication {
    static let shared = NSApplication()
    var applicationIconImage: NSImage?
    var servicesProvider: Any?
}
let NSApp = NSApplication.shared

// Record presentation without creating any AppKit windows or changing focus.
final class FixtureWindow { var isVisible = false }
final class Launcher {
    weak var appDelegate: AppDelegate?
    var window: FixtureWindow? = FixtureWindow()
    var isGenerating = false
    var shows = 0
    func prepareForLaunch() { startupCalls.append("prepareLauncher") }
    func show() { shows += 1; window?.isVisible = true }
}
final class Wizard {
    var isCompleted = true
    var shows = 0
    func present() { shows += 1 }
}
struct Preferences {
    var globalShortcuts = ["compose": "shortcut"]
    var menuBarEnabled = true
}
var preferences = Preferences()
func loadAppPreferences() -> Preferences { preferences }
'''
source += block('struct GlobalHotKeyRegistrationOutcome {')
source += block('func isLoginItemLaunch(')
source += r'''
final class AppDelegate: NSObject {
    let launcherController = Launcher(), clipboardController = Launcher(), setupWizard = Wizard()
    var pendingPublicURLs: [URL] = [], handledURLs: [URL] = []
    var sessions: [Int] = []
    var suppressInitialLauncherReveal = false
    var deferredLoginLaunchUI = false
    var deferredShortcutRegistrationWarning: GlobalHotKeyRegistrationOutcome?
    var registration = GlobalHotKeyRegistrationOutcome(rejectedActions: [], infrastructureUnavailable: false)
    var warnings = 0, integrations = 0
    func startLibrarySync() { startupCalls.append("librarySync") }
    func installKeyboardControls() { startupCalls.append("keyboard") }
    func updateMenuForActiveWindow() { startupCalls.append("menu") }
    func openPublicURL(_ url: URL) {
        handledURLs.append(url)
        suppressInitialLauncherReveal = true
    }
    func registerGlobalHotKeys(_ shortcuts: [String: String]) -> GlobalHotKeyRegistrationOutcome {
        integrations += 1
        return registration
    }
    func configureLibraryMenuShortcut(_ shortcut: String?) {}
    func configureStatusItem(enabled: Bool, shortcuts: [String: String]) {}
    func presentGlobalShortcutRegistrationWarning(_ result: GlobalHotKeyRegistrationOutcome) { warnings += 1 }
'''
for marker in (
    'func applicationDidFinishLaunching(',
    'private func presentSetupWizardIfNeeded(',
    'func configureSystemIntegration(',
    '@objc func showLauncher(',
    'func applicationShouldHandleReopen(',
):
    source += block(marker)
source += r'''
}

var checks = 0
// check(condition, message): Stop on a named regression rather than continuing silently.
func check(_ condition: Bool, _ message: String) {
    guard condition else { fputs("FAILED: \(message)\n", stderr); exit(1) }
    checks += 1
}
// event([id], [reason], [eventClass]): Construct the same descriptor shape macOS sends.
func event(_ id: AEEventID = AEEventID(kAEOpenApplication),
           reason: AEKeyword? = nil, eventClass: AEEventClass = AEEventClass(kCoreEventClass)) -> NSAppleEventDescriptor {
    let value = NSAppleEventDescriptor(eventClass: eventClass, eventID: id,
        targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
        transactionID: AETransactionID(kAnyTransactionID))
    if let reason { value.setParam(NSAppleEventDescriptor(enumCode: reason), forKeyword: keyAEPropData) }
    return value
}
// launch(delegate, event): Let real startup enqueue work, then discard the transient event.
func launch(_ delegate: AppDelegate, _ event: NSAppleEventDescriptor?) {
    check(DispatchQueue.main.work.isEmpty, "previous launch callbacks completed")
    startupCalls = []
    NSAppleEventManager.shared().currentAppleEvent = event
    delegate.applicationDidFinishLaunching(Notification(name: Notification.Name("launch")))
    NSAppleEventManager.shared().currentAppleEvent = nil
    DispatchQueue.main.drain()
}

let login = event(reason: keyAELaunchedAsLogInItem)
check(isLoginItemLaunch(login), "macOS login marker is recognized")
check(!isLoginItemLaunch(nil), "missing event is an ordinary launch")
check(!isLoginItemLaunch(event()), "manual open is an ordinary launch")
check(!isLoginItemLaunch(event(reason: keyAELaunchedAsServiceItem)), "Service launch is not a login item")
check(!isLoginItemLaunch(event(AEEventID(kAEReopenApplication))), "Dock reopen is not a login launch")
check(!isLoginItemLaunch(event(AEEventID(kAEGetURL), reason: keyAELaunchedAsLogInItem,
                             eventClass: AEEventClass(kInternetEventClass))), "URL event cannot be mistaken for login")
check(!isLoginItemLaunch(event(reason: keyAELaunchedAsLogInItem,
                             eventClass: AEEventClass(kInternetEventClass))), "event class must match")

let warnings = [
    GlobalHotKeyRegistrationOutcome(rejectedActions: [], infrastructureUnavailable: false),
    GlobalHotKeyRegistrationOutcome(rejectedActions: ["compose"], infrastructureUnavailable: false),
    GlobalHotKeyRegistrationOutcome(rejectedActions: [], infrastructureUnavailable: true)
]
// Login startup stays quiet with or without setup, a menu icon, or a shortcut conflict.
for completed in [false, true] {
    for menuBar in [false, true] {
        for registration in warnings {
            preferences.menuBarEnabled = menuBar
            let app = AppDelegate()
            app.setupWizard.isCompleted = completed
            app.registration = registration
            let warningCount = registration.infrastructureUnavailable || !registration.rejectedActions.isEmpty ? 1 : 0
            launch(app, login)
            check(app.launcherController.shows == 0, "login does not present the launcher")
            check(app.setupWizard.shows == 0, "login defers incomplete setup")
            check(app.warnings == 0, "login does not activate a shortcut alert")
            check(app.integrations == 1, "login still registers menu and global shortcuts")
            check(startupCalls.contains("services") && startupCalls.contains("store") && startupCalls.contains("librarySync"),
                  "login initializes Services, purchase status, and Library sync")
            check(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false), "manual reopen remains handled")
            check(app.launcherController.shows == 1, "manual reopen after login presents the launcher")
            check(app.setupWizard.shows == (completed ? 0 : 1), "manual reopen presents deferred setup")
            check(app.warnings == warningCount, "manual reopen reports deferred shortcut failures")
            _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            check(app.warnings == warningCount, "deferred warnings are shown only once")
            check(app.setupWizard.shows == (completed ? 0 : 1), "deferred setup is handled only once")
        }
    }
}
// A normal launch keeps existing presentation, including first-run setup and warnings.
for completed in [false, true] {
    for registration in warnings {
        let app = AppDelegate()
        app.setupWizard.isCompleted = completed
        app.registration = registration
        launch(app, event())
        check(app.launcherController.shows == 1, "manual launch presents its window")
        check(app.setupWizard.shows == (completed ? 0 : 1), "manual launch preserves setup")
        let expected = registration.infrastructureUnavailable || !registration.rejectedActions.isEmpty ? 1 : 0
        check(app.warnings == expected, "manual launch preserves shortcut warnings")
    }
}
// Preserve the existing URL, Service, visible-window, result, and active-request guards.
for state in 0..<6 {
    let app = AppDelegate()
    switch state {
    case 0: app.pendingPublicURLs = [URL(string: "langmin://library")!]
    case 1: app.suppressInitialLauncherReveal = true
    case 2: app.launcherController.window?.isVisible = true
    case 3: app.sessions = [1]
    case 4: app.launcherController.isGenerating = true
    default: app.clipboardController.isGenerating = true
    }
    launch(app, event())
    check(app.launcherController.shows == 0, "existing startup guard \(state) remains effective")
    if state == 0 { check(app.handledURLs.count == 1 && app.pendingPublicURLs.isEmpty, "queued URL is still handled") }
}
// Menu actions still open the app, and changed shortcut settings invalidate stale alerts.
let menuOpen = AppDelegate()
menuOpen.registration = warnings[1]
launch(menuOpen, login)
menuOpen.registration = warnings[0]
_ = menuOpen.configureSystemIntegration()
menuOpen.showLauncher(nil)
check(menuOpen.launcherController.shows == 1, "explicit menu open presents the launcher")
check(menuOpen.warnings == 0, "fixed shortcut settings discard the old login warning")
print("\(checks) login startup checks passed; no real windows, preferences, or login registrations used")
'''

with tempfile.TemporaryDirectory(prefix='langmin-login-launch-', dir='/private/tmp') as directory:
    folder = Path(directory)
    fixture = folder / 'main.swift'
    fixture.write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', '-module-cache-path', cache, str(fixture), '-o', str(folder / 'tests')],
                   cwd=ROOT, check=True, timeout=120)
    subprocess.run([str(folder / 'tests')], cwd=ROOT, check=True, timeout=30)
