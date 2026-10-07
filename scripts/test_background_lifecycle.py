#!/usr/bin/env python3
"""Exercise production background lifecycle methods without changing the host UI."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MAIN = (ROOT / 'langmin/Sources/LangminApp/main.swift').read_text()


# block(marker): Extract one production method with its nested branches.
def block(marker):
    start = MAIN.index(marker)
    end = MAIN.index('{', start) + 1
    depth = 1
    while depth:
        depth += (MAIN[end] == '{') - (MAIN[end] == '}')
        end += 1
    return MAIN[start:end].replace('@objc ', '') + '\n'


source = r'''
import Foundation

// Model only the window properties used by lifecycle decisions; create no UI.
final class NSWindow {
    struct StyleMask: OptionSet {
        let rawValue: Int
        static let titled = Self(rawValue: 1)
        static let nonactivatingPanel = Self(rawValue: 2)
    }
    var styleMask: StyleMask = [.titled]
    var isVisible = false, isMiniaturized = false
}
final class NSApplication {
    enum ActivationPolicy { case regular, accessory }
    var windows: [NSWindow] = [], modalWindow: NSWindow?
    var policy: ActivationPolicy = .regular
    var isHidden = false
    var terminations = 0, policyChanges = 0
    func activationPolicy() -> ActivationPolicy { policy }
    func setActivationPolicy(_ value: ActivationPolicy) { policy = value; policyChanges += 1 }
    func terminate(_ sender: Any?) { terminations += 1 }
}
let NSApp = NSApplication()
struct Preferences { var runInBackground = true, menuBarEnabled = true }
var preferences = Preferences()
func loadAppPreferences() -> Preferences { preferences }
final class Work { var isGenerating = false, isActive = false }

// Model AppKit close-notification ordering without opening native windows.
final class FixtureQueue {
    var work: [() -> Void] = []
    func async(execute: @escaping () -> Void) { work.append(execute) }
    func drain() { while !work.isEmpty { work.removeFirst()() } }
}
enum DispatchQueue { static let main = FixtureQueue() }
final class AppDelegate {
    var backgroundPresenceUpdateScheduled = false
    var serviceTransformInFlight = false
    let launcherController = Work(), clipboardController = Work(), clipboardHUDController = Work()
    var sessions: [Int] = []
'''
for marker in (
    'func isApplicationWindow(', 'func hasOpenApplicationWindows(',
    'func updateApplicationPresence(', '@objc func applicationWindowBecameKey(',
    '@objc func applicationWindowWillClose(', 'func scheduleBackgroundPresenceUpdate(',
    'func terminateIfIdle()', 'func applicationShouldTerminateAfterLastWindowClosed(',
    '@objc func quitFromMenu(',
):
    source += block(marker)
source += r'''
}
var checks = 0
// check(condition, message): Stop on a named lifecycle regression.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checks += 1
}
// notification(window): Deliver a fake window notification to the real handler.
func notification(_ window: NSWindow) -> Notification {
    Notification(name: Notification.Name("fixture"), object: window)
}
// Exercise both independent menu-icon choices with each background setting.
for menuIcon in [false, true] {
    for background in [false, true] {
        preferences = Preferences(runInBackground: background, menuBarEnabled: menuIcon)
        let delegate = AppDelegate(), main = NSWindow(), settings = NSWindow()
        let hud = NSWindow()
        hud.styleMask = [.nonactivatingPanel]
        hud.isVisible = true
        main.isVisible = true
        NSApp.windows = [main, settings, hud]
        NSApp.terminations = 0; NSApp.policy = .regular; NSApp.modalWindow = nil
        delegate.terminateIfIdle()
        check(NSApp.terminations == 0 && NSApp.policy == .regular, "Visible main window stays reachable")

        // Cmd-H hides open windows without closing them. Finishing a request
        // must preserve both the process and its route back through the Dock.
        NSApp.isHidden = true; main.isVisible = false
        delegate.terminateIfIdle()
        check(NSApp.terminations == 0 && NSApp.policy == .regular, "Hiding an open app is not closing its last window")
        NSApp.isHidden = false; main.isVisible = true

        // Closing Settings must neither hide nor terminate the still-visible main window.
        settings.isVisible = true
        delegate.applicationWindowWillClose(notification(settings))
        settings.isVisible = false
        DispatchQueue.main.drain()
        check(NSApp.terminations == 0 && NSApp.policy == .regular, "Closing one of two windows preserves the other")

        // Minimized windows still need their Dock entry even if another window closes.
        main.isVisible = false; main.isMiniaturized = true
        delegate.terminateIfIdle()
        check(NSApp.terminations == 0 && NSApp.policy == .regular, "Minimized windows stay in Dock")
        main.isMiniaturized = false; main.isVisible = true
        delegate.applicationWindowWillClose(notification(main))
        check(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp), "AppKit automatic quit waits for lifecycle handling")
        check(DispatchQueue.main.work.count == 1 && NSApp.terminations == 0, "Duplicate close events coalesce without early quit")
        main.isVisible = false
        DispatchQueue.main.drain()
        check(NSApp.terminations == (background ? 0 : 1), "Last-window close obeys background setting independently of menu icon")
        check(NSApp.policy == (background ? .accessory : .regular), "Windowless background app leaves Dock and app switcher")

        // A HUD must not restore the Dock; a new normal window must, before isVisible changes.
        let before = NSApp.policyChanges
        delegate.applicationWindowBecameKey(notification(hud))
        check(NSApp.policyChanges == before, "Shortcut HUD does not change presence")
        delegate.applicationWindowBecameKey(notification(settings))
        check(NSApp.policy == .regular, "Opening Settings restores regular activation")
        settings.isVisible = true
        delegate.terminateIfIdle()
        check(NSApp.policy == .regular, "Open Settings keeps normal app menus")

        // A new window arriving during the close callback keeps the app accessible.
        NSApp.terminations = 0
        delegate.applicationWindowWillClose(notification(settings))
        settings.isVisible = false; main.isVisible = true
        DispatchQueue.main.drain()
        check(NSApp.terminations == 0 && NSApp.policy == .regular, "Opening a window before deferred close handling keeps app alive")
        main.isVisible = false

        // Every existing work guard must delay automatic quitting when background mode is disabled.
        for active in 0..<6 {
            NSApp.terminations = 0
            delegate.serviceTransformInFlight = active == 0
            delegate.launcherController.isGenerating = active == 1
            delegate.clipboardController.isGenerating = active == 2
            delegate.clipboardHUDController.isActive = active == 3
            delegate.sessions = active == 4 ? [1] : []
            NSApp.modalWindow = active == 5 ? NSWindow() : nil
            delegate.terminateIfIdle()
            check(NSApp.terminations == 0, "Outstanding work or modal interaction prevents automatic quit")
            // Explicit Quit always exits, even with background work in progress.
            delegate.quitFromMenu(nil)
            check(NSApp.terminations == 1, "Explicit Quit ignores the keep-running setting")
        }
        delegate.serviceTransformInFlight = false
        delegate.launcherController.isGenerating = false
        delegate.clipboardController.isGenerating = false
        delegate.clipboardHUDController.isActive = false
        delegate.sessions = []; NSApp.modalWindow = nil; NSApp.terminations = 0
        delegate.terminateIfIdle()
        check(NSApp.terminations == (background ? 0 : 1), "Finishing the last job honors the keep-running choice")
    }
}
print("PASS: \(checks) background lifecycle checks")
'''
with tempfile.TemporaryDirectory(prefix='langmin-background-fixture-', dir='/private/tmp') as directory:
    path = Path(directory)
    swift = path / 'fixture.swift'
    swift.write_text(source)
    env = os.environ.copy()
    env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    cache = env.get('LANGMIN_TEST_MODULE_CACHE', str(path / 'modules'))
    subprocess.run(['swiftc', '-module-cache-path', cache, str(swift), '-o', str(path / 'fixture')], env=env, check=True)
    subprocess.run([str(path / 'fixture')], env=env, check=True)
