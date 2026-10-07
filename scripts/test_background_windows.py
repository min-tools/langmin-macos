#!/usr/bin/env python3
"""Test background lifecycle with real AppKit windows in a disposable macOS desktop.

This opens test windows and changes the fixture app's Dock presence. Run it only
inside the macOS test VM. No provider calls or real Langmin preferences are used.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MAIN = (ROOT / 'langmin/Sources/LangminApp/main.swift').read_text()


# block(marker): Extract a production lifecycle method, preserving its selectors.
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

// Isolate preferences and work state while using real AppKit lifecycle events.
struct Preferences { var runInBackground = true }
var preferences = Preferences()
func loadAppPreferences() -> Preferences { preferences }
final class Work {
    var isGenerating = false, isActive = false
    var window: NSWindow?, libraryWindow: NSWindow?
}
final class Session { var window: NSWindow! }
final class AppDelegate: NSObject, NSApplicationDelegate {
    var backgroundPresenceUpdateScheduled = false
    var serviceTransformInFlight = false
    let launcherController = Work(), clipboardController = Work()
    let clipboardHUDController = Work(), preferencesController = Work()
    var sessions: [Session] = []
    var activeSession: Session?
    var quits = 0
    // Record genuine NSApplication termination requests without ending the fixture.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quits += 1
        return .terminateCancel
    }
    // Menu presentation is outside these window-lifecycle assertions.
    func updateMenuForActiveWindow() {}
}
// Attach the unchanged production handlers to the native delegate.
extension AppDelegate {
'''
for marker in (
    'func isApplicationWindow(', 'func hasOpenApplicationWindows(',
    'func updateApplicationPresence(', '@objc func applicationWindowBecameKey(',
    '@objc func applicationWindowWillClose(', 'func scheduleBackgroundPresenceUpdate(',
    'func terminateIfIdle()', 'func applicationShouldTerminateAfterLastWindowClosed(',
    '@objc func quitFromMenu(', '@objc func closeWindow(',
):
    source += block(marker)
source += r'''
}
var checks = 0
// check(condition, message): Report the specific native behavior that regressed.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
}
// pump(seconds): Allow AppKit notifications, animations, and queued callbacks to finish.
func pump(_ seconds: TimeInterval = 0.3) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        // Deliver queued window activation events as NSApplication.run would.
        if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                       inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }
}
// show(window): Bring a test window forward using Langmin's presentation order.
func show(_ window: NSWindow) {
    NSApp.unhide(nil)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    pump()
}
// press(key): Send an actual menu key equivalent without Accessibility permissions.
func press(_ key: String) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
        timestamp: 0, windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
        characters: key, charactersIgnoringModifiers: key, isARepeat: false,
        keyCode: key == "w" ? 13 : 12)!
    check(NSApp.mainMenu!.performKeyEquivalent(with: event), "Command-\(key) reaches its menu action")
    pump()
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
// Install the same window notification subscriptions used by Langmin.
NotificationCenter.default.addObserver(delegate, selector: #selector(AppDelegate.applicationWindowBecameKey(_:)),
    name: NSWindow.didBecomeKeyNotification, object: nil)
NotificationCenter.default.addObserver(delegate, selector: #selector(AppDelegate.applicationWindowWillClose(_:)),
    name: NSWindow.willCloseNotification, object: nil)
let menu = NSMenu(), root = NSMenuItem(), submenu = NSMenu()
root.submenu = submenu; menu.addItem(root)
for (title, key, action) in [("Close", "w", #selector(AppDelegate.closeWindow(_:))),
                             ("Quit", "q", #selector(AppDelegate.quitFromMenu(_:)))] {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = delegate; submenu.addItem(item)
}
app.mainMenu = menu
app.finishLaunching()
let main = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 220),
    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
main.title = "Langmin lifecycle fixture"; main.isReleasedWhenClosed = false
let settings = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 300, height: 200),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
settings.title = "Fixture settings"; settings.isReleasedWhenClosed = false
delegate.launcherController.window = main
delegate.preferencesController.window = settings
let hud = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 200, height: 60),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
hud.isReleasedWhenClosed = false
// Exercise both real status-item states and both background preferences.
for iconEnabled in [false, true] {
    let item: NSStatusItem? = iconEnabled ? NSStatusBar.system.statusItem(withLength: 22) : nil
    item?.button?.title = "T"
    for background in [true, false] {
        preferences.runInBackground = background
        show(main)
        check(main.isVisible && app.activationPolicy() == .regular, "Opening a normal window restores Dock presence")
        show(settings)
        let before = delegate.quits
        print("CASE icon=\(iconEnabled) background=\(background) active=\(app.isActive) key=\(app.keyWindow?.title ?? "none")")
        press("w")
        print("CLOSE settings=\(settings.isVisible) main=\(main.isVisible) quits=\(delegate.quits) before=\(before)")
        check(!settings.isVisible && main.isVisible && delegate.quits == before, "Command-W closes Settings without closing the main window")

        // Hiding is distinct from closing, including after a request completes.
        app.hide(nil); pump()
        check(app.isHidden, "Command-H behavior hides the fixture app")
        delegate.terminateIfIdle(); pump()
        check(delegate.quits == before && app.activationPolicy() == .regular, "Hidden open windows keep their Dock entry and process")
        show(main)
        main.miniaturize(nil); pump(0.8)
        delegate.terminateIfIdle()
        check(main.isMiniaturized && delegate.quits == before && app.activationPolicy() == .regular,
              "Minimized windows remain reachable")
        main.deminiaturize(nil); show(main)

        // The real nonactivating HUD must not count as a normal window.
        hud.orderFrontRegardless(); pump()
        press("w")
        check(!main.isVisible, "Command-W closes the last normal window")
        check(app.activationPolicy() == (background ? .accessory : .regular), "Last-window closure applies the background preference")
        check((delegate.quits > before) == !background, "Automatic quit is independent of the status icon")
        hud.orderOut(nil)

        // Restoring a window must restore the menu's Quit action as well.
        show(main)
        let beforeQuit = delegate.quits
        delegate.clipboardController.isGenerating = true
        press("q")
        check(delegate.quits == beforeQuit + 1, "Explicit Command-Q requests termination during clipboard work")
        delegate.clipboardController.isGenerating = false
        main.close(); pump()
    }
    if let item { NSStatusBar.system.removeStatusItem(item) }
}
print("PASS: \(checks) native background window checks")
'''
with tempfile.TemporaryDirectory(prefix='langmin-native-background-', dir='/private/tmp') as directory:
    folder = Path(directory)
    swift = folder / 'main.swift'
    swift.write_text(source)
    env = os.environ.copy()
    env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    cache = env.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    executable = folder / 'fixture'
    subprocess.run(['swiftc', '-module-cache-path', cache, str(swift), '-o', str(executable)], env=env, check=True, timeout=120)
    subprocess.run([str(executable)], env=env, check=True, timeout=60)
