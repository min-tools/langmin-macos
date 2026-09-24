#!/usr/bin/env python3
"""Check setup instructions in every language using isolated AppKit views.

Uses the app's workflow layout and sizing methods without opening Setup,
reading preferences, accessing credentials, or registering a login item.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
wizard = (ROOT / 'langmin/Sources/LangminApp/SetupWizard.swift').read_text()
assert '30 days of full access' in wizard
assert 'No subscription starts, and you will not be charged.' in wizard
assert 'Apple Intelligence, Apple voices, Apple transcription, text editing, and the Library stay free.' in wizard
assert 'Proofread and Rewrite copy the result.' not in wizard
assert 'wizard_clipboard_note' not in wizard

localized_sources = [
    path.read_text()
    for path in (ROOT / 'langmin/Resources').glob('*.lproj/Localizable.strings')
]
assert all('"wizard_clipboard_note"' not in source for source in localized_sources)
assert all('macOS may ask for clipboard access' not in source for source in localized_sources)
assert all('Proofread and Rewrite copy the result.' not in source for source in localized_sources)
shortcut_lines = [
    line
    for source in localized_sources
    for line in source.splitlines()
    if line.startswith('"wizard_shortcuts_body"')
]
assert len(shortcut_lines) == 30
assert all('HUD' not in line for line in shortcut_lines)
assert 'case 0: step = welcomeStep()' in wizard
assert 'case 1: step = providerStep()' in wizard
assert 'case 2: step = languageStep()' in wizard
assert 'case 3: step = audioStep()' in wizard
assert 'case 4: step = workflowStep()' in wizard
assert 'default: step = readyStep()' in wizard
assert 'if stepIndex == stepCount - 1 {' in wizard
assert 'ProStore.shared.beginAppTrial()' in wizard
assert 'func windowWillClose(_ notification: Notification) {' in wizard


# method(name): Extract one setup method and expose it to the standalone
# fixture.
def method(name):
    start = wizard.index('    private func ' + name)
    end = wizard.index('\n    private func ', start + 1)
    block = wizard[start:end]
    return block[:block.rindex('\n    }') + 6].replace('private func', 'func') + '\n'


fixture = r'''
import Cocoa
var strings: [String: String] = [:]
// localized(key, fallback): Resolve labels from the translation currently
// loaded by the fixture.
func localized(_ key: String, _ fallback: String) -> String { strings[key] ?? fallback }
// Represent only the shortcut label needed by setup instructions.
struct Shortcut { let displayText: String }
var bindings: [String: Shortcut] = [:]
// loadGlobalShortcuts(): Return fixture-owned shortcuts instead of global user
// settings.
func loadGlobalShortcuts() -> [String: Shortcut] { bindings }
// nativeContentSize(size, window): The shared title-bar embedding is covered by
// the native window suite.
func nativeContentSize(_ size: NSSize, in window: NSWindow) -> NSSize { size }
// installNativeContent(window): Use the fixture window's content view without
// installing real app accessories.
func installNativeContent(in window: NSWindow) -> NSView { window.contentView! }
// Host the production workflow layout with isolated setup dependencies.
final class Workflow: NSObject, NSWindowDelegate {
    var loginItemCheckbox: NSButton!
    var window: NSWindow?
    var contentContainer: NSView!
    var progressLabel: NSTextField!
    var backButton: NSButton!
    var laterButton: NSButton!
    var continueButton: NSButton!
    var stepIndex = 4
    let stepCount = 6
    var stepViews: [Int: NSView] = [:]
    // buildProviders(): Keep provider discovery out of the workflow-layout
    // fixture.
    func buildProviders() {}
    // setUpLater(sender): Suppress setup dismissal actions while measuring
    // layout.
    @objc func setUpLater(_ sender: Any?) {}
    // goBack(sender): Suppress backward navigation in the isolated workflow
    // view.
    @objc func goBack(_ sender: Any?) {}
    // goForward(sender): Suppress forward navigation while the fixture drives
    // the selected step.
    @objc func goForward(_ sender: Any?) {}
    // welcomeStep(): Use workflow content when the window requests the welcome
    // step.
    func welcomeStep() -> NSView { workflowStep() }
    // providerStep(): Keep provider-step rendering focused on the workflow
    // layout under test.
    func providerStep() -> NSView { workflowStep() }
    // languageStep(): Use the same measured content for the language-step
    // dependency.
    func languageStep() -> NSView { workflowStep() }
    // audioStep(): Use workflow content for the unused audio-step dependency.
    func audioStep() -> NSView { workflowStep() }
    // readyStep(): Use workflow content for the unused completion-step
    // dependency.
    func readyStep() -> NSView { workflowStep() }
'''
fixture += ''.join(method(name) for name in ['buildWindow(', 'showStep(', 'stepStack(', 'workflowStep(', 'fitWindow('])
fixture += r'''
}
let _ = NSApplication.shared
let resources = URL(fileURLWithPath: CommandLine.arguments[1])
let locales = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "lproj" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
var checks = 0
// check(condition, message): Count layout expectations and report the first
// failure by name.
func check(_ condition: Bool, _ message: String) {
    // Stop if a translated workflow fails its asserted layout or wording contract.
    guard condition else { fputs("FAILED: \(message)\n", stderr); exit(1) }
    checks += 1
}
// Measure setup instructions for every bundled translation.
for locale in locales {
    let data = try Data(contentsOf: locale.appendingPathComponent("Localizable.strings"))
    strings = (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]) ?? [:]
    bindings = ["proofread": Shortcut(displayText: "⌥⌘P"), "dictionary": Shortcut(displayText: "⌃⇧6")]
    let controller = Workflow()
    controller.buildWindow()
    let window = controller.window!
    let container = window.contentView!
    let top = window.frame.maxY
    controller.showStep()
    container.layoutSubtreeIfNeeded()
    let view = controller.stepViews[4]!
    // labels(view): Collect all descendant text labels to check the visible
    // workflow wording.
    func labels(in view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { labels(in: $0) }
    }
    let text = labels(in: view)
    check(text.contains("⌥⌘P   " + localized("proofread", "Proofread")), "\(locale.lastPathComponent): custom shortcuts appear in setup")
    check(text.contains("—   " + localized("rewrite", "Rewrite")), "\(locale.lastPathComponent): cleared shortcuts are not shown as defaults")
    let contentHeight = window.contentRect(forFrameRect: window.frame).height
    let available = contentHeight - 24 - 20 - controller.continueButton.fittingSize.height - 20
    check(view.fittingSize.height <= available + 0.5, "\(locale.lastPathComponent): instructions fit above the footer")
    check(abs(window.frame.maxY - top) < 0.5, "\(locale.lastPathComponent): resizing keeps the top edge in place")
    check(contentHeight >= 480, "\(locale.lastPathComponent): short steps retain the minimum height")
    let frame = view.convert(view.bounds, to: container)
    check(frame.maxX <= container.bounds.maxX - 31.5, "\(locale.lastPathComponent): text stays inside the side margins")
    window.close()
}
print("\(checks) setup layout checks passed across \(locales.count) languages")
'''

with tempfile.TemporaryDirectory(prefix='langmin-setup-layout-', dir='/private/tmp') as directory:
    folder = Path(directory)
    source = folder / 'main.swift'
    source.write_text(fixture)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', '-module-cache-path', cache, str(source), '-o', str(folder / 'tests')], check=True)
    subprocess.run([str(folder / 'tests'), str(ROOT / 'langmin/Resources')], check=True, timeout=30)
