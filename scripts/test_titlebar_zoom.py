#!/usr/bin/env python3
"""Check title-bar hit testing and native maximize/restore with isolated windows.

Requires macOS WindowServer access.
"""
from pathlib import Path
import os
import platform
import subprocess
import tempfile

from source_files import ROOT, app_path, app_source, swift_fixture_args
MAIN = app_source('main.swift')


# block(marker, [start = 0]): Extract one brace-balanced production declaration
# for this isolated Swift fixture.
def block(marker, start=0):
    start = MAIN.index(marker, start)
    end = MAIN.index('{', start) + 1
    depth = 1
    # Include nested blocks when finding the end of the extracted declaration.
    while depth:
        depth += (MAIN[end] == '{') - (MAIN[end] == '}')
        end += 1
    return MAIN[start:end]


source = 'import Cocoa\n' + block('class NativeWindow:').replace('private ', '') + '\n'
# Compile the same production window callbacks for both viewer and launcher delegates.
for name, marker in [('ResultDelegate', 'final class ViewerSession:'), ('LauncherDelegate', 'final class LauncherController:')]:
    source += f'final class {name}: NSObject, NSWindowDelegate {{\n'
    source += block('    func windowWillUseStandardFrame(', MAIN.index(marker)) + '\n}\n'

source += r'''
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
NSApp.finishLaunching()
var checks = 0
// check(value, message): Report failed fixture expectations with their case
// names.
func check(_ value: @autoclosure () -> Bool, _ message: String) {
 // Stop this fixture when its named expectation does not hold.
 guard value() else { fputs("FAILED: \(message)\n", stderr); exit(1) }
 checks += 1
}
// near(a, b): Compare window geometry while allowing subpixel rounding.
func near(_ a: NSRect, _ b: NSRect) -> Bool {
 abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
}
// mouse(window, point, [clicks = 2], [type = .leftMouseDown], [windowNumber =
// nil]): Create a window-local mouse event without sending a desktop-wide
// click.
func mouse(_ window: NSWindow, _ point: NSPoint, clicks: Int = 2, type: NSEvent.EventType = .leftMouseDown,
           windowNumber: Int? = nil) -> NSEvent {
 NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: windowNumber ?? window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: clicks, pressure: 1)!
}
// titleCenter(window): Choose an empty point in the title bar for double-click
// tests.
func titleCenter(_ window: NSWindow) -> NSPoint {
 NSPoint(x: window.frame.width / 2, y: (window.contentLayoutRect.maxY + window.frame.height) / 2)
}
// center(view): Convert a control’s center into its host window’s coordinates.
func center(_ view: NSView) -> NSPoint {
 view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
}
// waitForFrame(window, expected, message): Let native window layout settle,
// with a bounded deadline.
func waitForFrame(_ window: NSWindow, _ expected: NSRect, message: String) {
 let deadline = Date().addingTimeInterval(2)
 // Pump window callbacks until the expected frame appears or time runs out.
 while !near(window.frame, expected) && Date() < deadline {
  RunLoop.main.run(until: Date().addingTimeInterval(0.01))
 }
 check(near(window.frame, expected), "\(message): \(window.frame) != \(expected)")
}
// doubleClick(window): Exercise the paired mouse-down and mouse-up handling for
// title-bar zoom.
func doubleClick(_ window: NativeWindow) {
 window.sendEvent(mouse(window, titleCenter(window)))
 check(window.consumesTitlebarMouseUp, "Double-click consumes the native title-bar mouse-up")
 window.sendEvent(mouse(window, titleCenter(window), type: .leftMouseUp))
 check(!window.consumesTitlebarMouseUp, "Mouse-up suppression resets after the click")
}
// Report missing native display access before attempting window geometry checks.
guard let display = NSScreen.main else {
 fputs("This native window fixture needs WindowServer access.\n", stderr)
 exit(1)
}
let screen = display.visibleFrame
let delegates: [NSWindowDelegate] = [LauncherDelegate(), ResultDelegate()]
// Check the same zoom behavior for launcher and result-window delegates.
for delegate in delegates {
 let window = NativeWindow(contentRect: NSRect(x: screen.minX + 100, y: screen.minY + 100, width: 600, height: 440),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                           backing: .buffered, defer: false, screen: display)
 window.isReleasedWhenClosed = false
 window.animationBehavior = .none
 window.delegate = delegate
 window.contentView = NSView(frame: window.contentView!.bounds)
 window.contentView?.layoutSubtreeIfNeeded()
 let original = window.frame
 check(window.isTitlebarDoubleClick(mouse(window, titleCenter(window))), "Empty title-bar center accepts a double-click")
 check(!window.isTitlebarDoubleClick(mouse(window, titleCenter(window), clicks: 1)), "Single-click remains available for dragging")
 check(!window.isTitlebarDoubleClick(mouse(window, titleCenter(window), clicks: 3)), "Triple-click does not toggle again")
 check(!window.isTitlebarDoubleClick(mouse(window, titleCenter(window), type: .rightMouseDown)), "Right-click remains a context-menu action")
 check(!window.isTitlebarDoubleClick(mouse(window, titleCenter(window), windowNumber: -1)), "Foreign window events are ignored")
 check(!window.isTitlebarDoubleClick(mouse(window, NSPoint(x: 300, y: window.contentLayoutRect.maxY - 2))), "Body double-clicks remain text-selection actions")
 // Keep native traffic-light buttons outside the custom zoom gesture.
 for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
  let button = window.standardWindowButton(type)!
  check(!window.isTitlebarDoubleClick(mouse(window, center(button))), "Traffic-light buttons retain their normal actions")
 }

 doubleClick(window)
 waitForFrame(window, window.screen!.visibleFrame, message: "First double-click fills the visible screen")
 check(!window.styleMask.contains(.fullScreen), "Maximize does not enter fullscreen")
 doubleClick(window)
 waitForFrame(window, original, message: "Second double-click restores size and position")
 let resized = NSRect(x: original.minX + 32, y: original.minY + 25, width: 650, height: 470)
 window.setFrame(resized, display: false)
 doubleClick(window)
 waitForFrame(window, window.screen!.visibleFrame, message: "A resized window maximizes")
 doubleClick(window)
 waitForFrame(window, resized, message: "Restore uses the latest user size and position")

 let accessory = NSTitlebarAccessoryViewController()
 accessory.layoutAttribute = .right
 accessory.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
 let button = NSButton(frame: NSRect(x: 90, y: 3, width: 100, height: 22))
 button.title = "Library"
 accessory.view.addSubview(button)
 let label = NSTextField(labelWithString: "Langmin")
 label.frame = NSRect(x: 0, y: 3, width: 80, height: 22)
 accessory.view.addSubview(label)
 window.addTitlebarAccessoryViewController(accessory)
 window.contentView?.superview?.layoutSubtreeIfNeeded()
 check(!window.isTitlebarDoubleClick(mouse(window, center(button))), "Library and star buttons do not maximize the window")
 button.isEnabled = false
 check(!window.isTitlebarDoubleClick(mouse(window, center(button))), "Disabled buttons do not become zoom targets")
 check(window.isTitlebarDoubleClick(mouse(window, center(label))), "Static title text accepts double-clicks")
 label.isSelectable = true
 check(!window.isTitlebarDoubleClick(mouse(window, center(label))), "Selectable accessory text keeps text selection")
 window.styleMask.remove(.resizable)
 check(!window.isTitlebarDoubleClick(mouse(window, titleCenter(window))), "Fixed-size windows cannot maximize")
 window.close()
}
print("\(checks) title-bar zoom checks passed")
'''

# Use the Library's actual window construction, constraints and chip layout. Keep saved data
# and unrelated controller actions in memory so this fixture never opens the user's Library.
source += r'''
let appName = "Langmin Fixture"
let plainTitleGap: CGFloat = 10
let nativeTrafficLightInsetAdjustment: CGFloat = 2
var nativeTrafficLightOriginalCloseX: [ObjectIdentifier: CGFloat] = [:]
// localized(key, fallback): Resolve labels through the fixture’s controlled
// localization.
func localized(_ key: String, _ fallback: String) -> String { fallback }
// tintedSymbol(name, color, pointSize): Supply the symbol image needed for
// layout without testing its tint.
func tintedSymbol(_ name: String, color: NSColor, pointSize: CGFloat) -> NSImage? {
 NSImage(systemSymbolName: name, accessibilityDescription: nil)
}
typealias OpticallyAlignedSearchField = NSSearchField
// Supply a dependency’s type identity without adding behavior to this fixture.
final class ResultEditorTextView: NSTextView {}
// Represent saved items by the fields used by folder chips.
struct LibraryEntry { let id: String; let folder: String? }
// Keep folder names in memory so layout never reads the user’s Library.
enum LibraryStore {
 static var folders = ["English", "Russian", "Serbian", "German", "French", "Spanish", "Italian", "Japanese"]
 // listFolders(): Return the folder list selected by the fixture.
 static func listFolders() -> [String] { folders }
 // listFolderMRU(): Use the same fixed order for recent-folder layout.
 static func listFolderMRU() -> [String] { folders }
}
// Track the active result session during window handoffs.
final class FixtureAppDelegate {
 var activeSession: FixtureSession?
 // setActiveSession(session): Record which session becomes active after a
 // window action.
 func setActiveSession(_ session: FixtureSession?) { activeSession = session }
 // updateMenuForActiveWindow(): Keep this production dependency inactive in the
 // isolated fixture.
 func updateMenuForActiveWindow() {}
}
// Record audio pauses without starting playback.
final class FixtureSession {
 var pauseCount = 0
 // pauseAudio(): Count requests to pause audio during navigation.
 func pauseAudio() { pauseCount += 1 }
 // updateCopyButtonMode(): Keep this production dependency inactive in the
 // isolated fixture.
 func updateCopyButtonMode() {}
}
// Expose the loading state used when restoring the launcher.
final class FixturePlaceholder: NSView {
 var isLoading = false
 // setLoading(loading, status): Record placeholder changes without drawing a
 // real loading animation.
 func setLoading(_ loading: Bool, status: String) { isLoading = loading }
}
// Supply the request state used by launcher presentation decisions.
struct FixtureRun { var returnsTransformedText = false }
// Keep detached-Library preferences inside the fixture.
final class MemoryPreferences {
 var values: [String: Bool] = [:]
 // bool(key): Treat absent fixture flags as disabled.
 func bool(forKey key: String) -> Bool { values[key] ?? false }
 // set(value, key): Record preference changes without touching user defaults.
 func set(_ value: Bool, forKey key: String) { values[key] = value }
}
let preferencesStore = MemoryPreferences()
// Name the only persisted flag used by this fixture.
enum PreferenceKey { static let libraryDetached = "libraryDetached" }
// Draw the real grouped outlines without showing tooltip panels in this fixture.
final class TooltipButton: NSButton {
 var drawsOutline = false
 var tooltipMessage = ""
 var interactionFillColor: NSColor? { nil }
 override var acceptsFirstResponder: Bool { true }
}
// Supply focusable title-bar buttons without showing tooltips.
final class TitlebarTooltipButton: NSButton {
 var tooltipMessage = ""
 override var acceptsFirstResponder: Bool { true }
}
'''
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in [
    'func tabDirection(', 'func configureNativeWindow(', 'func insetNativeTrafficLights(',
    'let langminControlBorderColor =', 'final class NativeBackgroundView:', 'func nativeTitlebarHeight(', 'func nativeContentSize(',
    'func installNativeContent(', 'final class LauncherWindow:', 'final class LibraryWindow:', 'final class LibraryWindowDelegate:',
    'final class LibraryDocumentView:', 'final class LibraryEmptyStateView:', 'final class LibraryFolderChipEditorView:',
    'final class LibraryFolderChipButton:', 'extension NSPasteboard.PasteboardType {',
    'final class ResultToolbarButtonGroup:',
    'final class LibraryTitlebarButton:',
]:
    source += block(marker).replace('final class LauncherWindow:', 'class LauncherWindow:') + '\n'

source += r'''
// The fixture stays in the background. Supply key state for menu checks without taking desktop focus.
final class FixtureLauncherWindow: LauncherWindow {
 var fixtureIsKey = false
 override var isKeyWindow: Bool { fixtureIsKey || super.isKeyWindow }
}
// Host production Library window behavior with in-memory data and observable actions.
final class LauncherController: NSObject, NSWindowDelegate {
 var appDelegate: FixtureAppDelegate?
 var window: NSWindow?
 var launcherContentView: NSView?
 var composeStack: NSStackView?
 var libraryButton: NSButton?
 var launcherTitleLabel: NSTextField?
 var runHintLabel: NSTextField?
 var selectedMode = "translate"
 var inputView = NSTextView()
 var inlineResultSession: FixtureSession?
 var resultPlaceholderView: FixturePlaceholder? = FixturePlaceholder()
 var resultHostView: NSView? = NSView()
 var statusLabel: NSTextField?
 var isGenerating = false
 var activeRun: FixtureRun?
 var activeTextTask: String?
 var activeDataTask: String?
 var activeDataTasks: [String] = []
 var palettePanel: NSWindow?
 var searchEscapeHandled = true
 var finalizeCalls = 0
 var closeComposerCalls = 0
 var refreshCalls = 0
 // closePalette(): Record command-palette dismissal without managing a real
 // palette.
 func closePalette() { palettePanel = nil }
 // centerLauncherIfNeeded(window): Keep this production dependency inactive in
 // the isolated fixture.
 func centerLauncherIfNeeded(_ window: NSWindow) {}
 // launcherWindowTitle(mode): Use a stable launcher title for title-bar layout
 // assertions.
 func launcherWindowTitle(for mode: String) -> String { "Langmin • Translate" }
 // runHintText(mode): Use a stable run hint for layout assertions.
 func runHintText(for mode: String) -> String { "Translate" }
 // shouldShowInlineResult(run): Keep fixture results inline until a tested
 // window action changes presentation.
 func shouldShowInlineResult(for run: FixtureRun) -> Bool { true }
 // refreshLibrary(): Count Library refresh requests without loading saved
 // entries.
 func refreshLibrary() { refreshCalls += 1 }
 // prewarmLibraryContentSearchCache(): Keep this production dependency inactive
 // in the isolated fixture.
 func prewarmLibraryContentSearchCache() {}
 // updateLibraryButtonCount(): Keep this production dependency inactive in the
 // isolated fixture.
 func updateLibraryButtonCount() {}
 // updateChipRowsIfNeeded(): Keep this production dependency inactive in the
 // isolated fixture.
 func updateChipRowsIfNeeded() {}
 // cancelLibraryFolderEditing(): Clear simulated folder editing when navigation
 // requires it.
 func cancelLibraryFolderEditing() { isCreatingLibraryFolder = false; renamingLibraryFolder = nil }
 // finalizeAllPendingLibraryDeletions(): Count deletion finalization without
 // removing files.
 func finalizeAllPendingLibraryDeletions() { finalizeCalls += 1 }
 // handleCommandK(): Leave unrelated command-palette handling inactive.
 func handleCommandK() -> Bool { false }
 // handleEscapeKey(): Leave unrelated launcher Escape handling inactive.
 func handleEscapeKey() -> Bool { false }
 // activateFocusedLibraryNavigationControl(): Leave focused-control activation
 // outside these window tests.
 func activateFocusedLibraryNavigationControl() -> Bool { false }
 // moveFocus(forward): Leave general launcher focus navigation outside this
 // fixture.
 func moveFocus(forward: Bool) -> Bool { false }
 // cancelGeneration(): Record cancellation without starting a generation task.
 func cancelGeneration() { isGenerating = false }
 // discardInlineResult(): Record composer closure and release its simulated
 // result.
 func discardInlineResult() { closeComposerCalls += 1; inlineResultSession = nil }
 // prepareForLaunch(): Build the launcher lazily when the production handoff
 // requests it.
 func prepareForLaunch() { buildWindow() }
 // buildWindow(): Create the native launcher shell used by Library hosting
 // tests.
 func buildWindow() {
  let main = FixtureLauncherWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 720),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
  main.isReleasedWhenClosed = false
  main.animationBehavior = .none
  main.titleVisibility = .hidden
  configureNativeWindow(main)
  main.launcherController = self
  main.delegate = self
  window = main
  installTitlebarTitle(on: main)
  installLibraryButton(on: main)
  let content = installNativeContent(in: main)
  launcherContentView = content
  let stack = NSStackView(views: [inputView])
  stack.translatesAutoresizingMaskIntoConstraints = false
  content.addSubview(stack)
  NSLayoutConstraint.activate([
   stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
   stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
   stack.topAnchor.constraint(equalTo: content.topAnchor),
   stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
  ])
  composeStack = stack
 }
 var libraryWindow: NSWindow?
 var libraryWindowDelegate: LibraryWindowDelegate?
 var libraryScrollView: NSScrollView?
 var libraryListStack: NSStackView?
 var librarySearchField: NSSearchField?
 var libraryChipScrollView: NSScrollView?
 var libraryChipStack: NSStackView?
 var libraryTabStops: [NSView] = []
 var libraryFolderChipEntries: [LibraryEntry] = []
 var libraryFolderChipsWidth: CGFloat = 0
 var selectedLibraryFolder: String?
 var libraryFolderEditor: NSTextField?
 var libraryFolderEditorContainer: LibraryFolderChipEditorView?
 var libraryFolderEditorHint: NSTextField?
 var libraryFolderEditorBaseHint = ""
 var renamingLibraryFolder: String?
 var isCreatingLibraryFolder = false
 var libraryOverflowFolders: [String] = []
 var pendingLibraryDeletions: [String: Bool] = [:]
 var searchFocusCalls = 0
 var navigationCalls = 0
 var tabCalls = 0
 var escapeCalls = 0
 var closeCalls = 0
 // focusLibrarySearch(): Count search-focus requests and use the current
 // Library host window.
 @discardableResult func focusLibrarySearch() -> Bool {
  searchFocusCalls += 1
  // Search cannot receive focus before its field has been built.
  guard let field = librarySearchField else { return false }
  return libraryHostWindow?.makeFirstResponder(field) ?? false
 }
 // handleLibraryEscapeKey(): Record Escape routing and return the outcome
 // chosen by the test.
 func handleLibraryEscapeKey() -> Bool { escapeCalls += 1; return searchEscapeHandled }
 // handleLibraryNavigationKey(event): Record the Library navigation keys
 // handled by this fixture.
 func handleLibraryNavigationKey(_ event: NSEvent) -> Bool {
  // Consume Down Arrow so routing can be distinguished from other key events.
  if event.keyCode == 125 { navigationCalls += 1; return true }; return false
 }
 // moveLibraryFocus(forward): Count Tab navigation routed to the Library.
 func moveLibraryFocus(forward: Bool) -> Bool { tabCalls += 1; return true }
 // librarySearchMenu(): Supply an empty search menu without invoking unrelated
 // search actions.
 func librarySearchMenu() -> NSMenu { NSMenu() }
 // librarySearchChanged(sender): Keep this production dependency inactive in
 // the isolated fixture.
 @objc func librarySearchChanged(_ sender: NSSearchField) {}
 // libraryFolderChipClicked(sender): Keep this production dependency inactive
 // in the isolated fixture.
 @objc func libraryFolderChipClicked(_ sender: Any?) {}
 // libraryNewFolderChipClicked(sender): Keep this production dependency
 // inactive in the isolated fixture.
 @objc func libraryNewFolderChipClicked(_ sender: Any?) {}
 // libraryOverflowChipClicked(sender): Keep this production dependency inactive
 // in the isolated fixture.
 @objc func libraryOverflowChipClicked(_ sender: Any?) {}
 // libraryFolderChipMenu(name, entryCount): Supply an empty folder menu while
 // testing chip layout.
 func libraryFolderChipMenu(for name: String, entryCount: Int) -> NSMenu { NSMenu() }
 // fileDroppedEntry(id, folder): Keep this production dependency inactive in
 // the isolated fixture.
 func fileDroppedEntry(id: String, into folder: String?) {}
 // makeLibraryFolderEditor(text): Create the real folder editor and retain its
 // field for focus assertions.
 func makeLibraryFolderEditor(text: String) -> LibraryFolderChipEditorView {
  let editor = LibraryFolderChipEditorView(text: text, placeholder: "Folder name")
  libraryFolderEditorContainer = editor
  libraryFolderEditor = editor.textField
  return editor
 }
'''
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in [
    '    var libraryView:', '    var libraryDetachedContentView:', '    var libraryHostConstraints:',
    '    var libraryBackButton:', '    var libraryPositionButton:', '    var isLibraryEmbedded =',
    '    var libraryTitleLeadingConstraint:',
    '    var libraryEmbeddedPositionButton:', '    var libraryDetachedPositionButton:',
    '    var libraryHostWindow:', '    var isShowingLibrary:',
    '    let libraryContentSize =', '    func buildLibraryWindow()',
    '    func installLibraryTitlebarTitle(', '    func libraryWindowDidResize()',
    '    func reflowLibraryFolderChips()', '    func buildLibraryView(',
    '    func showLibraryEmptyState(',
    '    func libraryFolderNames(', '    func libraryFoldersInMRUOrder(',
    '    func rebuildLibraryFolderChips(',
    '    func updateLibraryPositionControls()', '    func libraryTitlebarButton(',
    '    func installTitlebarTitle(', '    func installLibraryButton(',
    '    func handleLibraryKeyEvent(', '    func mountLibraryView(', '    func presentLibrary(',
    '    @objc func showLibrary(', '    @objc func toggleLibraryPosition(', '    @objc func backFromLibrary(',
    '    func hideEmbeddedLibrary()', '    func setLibraryEmbedded(',
    '    func reinsetLauncherTrafficLights()', '    func launcherWindowDidResize()',
    '    func updateLauncherWindowTitle(', '    func refreshResultPaneState()',
    '    func libraryWindowWillClose()',
]:
    source += (MAIN[MAIN.index(marker):].splitlines()[0] if marker.startswith(('    let ', '    var ')) else block(marker)) + '\n'
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['    func windowWillClose(', '    func windowDidBecomeKey(', '    func windowWillUseStandardFrame(',
               '    func windowDidResize(']:
    source += block(marker, MAIN.index('final class LauncherController:')) + '\n'
source += r'''
}

// settle(window): Settle layout and pending window callbacks before checking
// geometry.
func settle(_ window: NSWindow) {
 window.contentView?.layoutSubtreeIfNeeded()
 RunLoop.main.run(until: Date().addingTimeInterval(0.03))
 window.contentView?.layoutSubtreeIfNeeded()
}
// trafficLightFrames(window): Read the native traffic-light frames in the order
// used by comparisons.
func trafficLightFrames(_ window: NSWindow) -> [NSRect] {
 [.closeButton, .miniaturizeButton, .zoomButton].map { (type: NSWindow.ButtonType) in
  let button = window.standardWindowButton(type)!
  let frame = button.convert(button.bounds, to: nil)
  return NSRect(x: frame.minX, y: window.frame.height - frame.maxY, width: frame.width, height: frame.height)
 }
}
// checkTrafficLights(window, expected, action): Verify that a window action
// preserves the expected traffic-light positions.
func checkTrafficLights(_ window: NSWindow, _ expected: [NSRect], after action: String) {
 let actual = trafficLightFrames(window)
 check(actual == expected, "Traffic lights stay fixed after \(action): \(actual), expected \(expected)")
}
// preview(window, name): Save an optional window snapshot when an artifact
// directory was supplied.
func preview(_ window: NSWindow, name: String) {
 // Skip snapshots when no destination or drawable window surface is available.
 guard CommandLine.arguments.count > 1, let view = window.contentView?.superview,
       let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
 view.cacheDisplay(in: view.bounds, to: bitmap)
 let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
 try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
 try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
}
// firstDescendant(type, root): Find a descendant by type without exposing
// production view internals to this fixture.
func firstDescendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
 // Return the root itself when it has the requested view type.
 if let match = root as? T { return match }
 // Search each child until the first matching view is found.
 for child in root.subviews {
  // Return the first matching descendant from the child hierarchy.
  if let match = firstDescendant(type, in: child) { return match }
 }
 return nil
}
// Verify and render the actual empty-Library presentation used in the screenshot state.
let emptyWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 320),
                           styleMask: [.borderless], backing: .buffered, defer: false)
emptyWindow.appearance = NSAppearance(named: .darkAqua)
let emptyTitle = "No saved items yet"
let emptySubtitle = "Click a result's bookmark button to save it here."
let emptyState = LibraryEmptyStateView(title: emptyTitle, subtitle: emptySubtitle, symbolName: "bookmark")
emptyWindow.contentView = emptyState
settle(emptyWindow)
let emptyIcon = firstDescendant(NSImageView.self, in: emptyState)
let emptyContent = firstDescendant(NSStackView.self, in: emptyState)!
let emptyLabels = emptyContent.arrangedSubviews.compactMap { $0 as? NSTextField }
let emptyHeading = emptyLabels[0]
let emptyGuidance = emptyLabels[1]
check(emptyIcon?.image != nil, "Empty Library shows its bookmark symbol")
check(emptyHeading.stringValue == emptyTitle && emptyGuidance.stringValue == emptySubtitle,
      "Empty Library keeps its heading and guidance text")
let iconFrame = emptyIcon!.convert(emptyIcon!.bounds, to: emptyState)
let headingFrame = emptyHeading.convert(emptyHeading.bounds, to: emptyState)
let guidanceFrame = emptyGuidance.convert(emptyGuidance.bounds, to: emptyState)
check(iconFrame.minY > headingFrame.maxY && headingFrame.minY > guidanceFrame.maxY,
      "Empty Library places the icon, heading, and guidance in order")
preview(emptyWindow, name: "library-empty-state")
// key(window, code, [characters = ""], [modifiers = []]): Create a window-local
// key event for focus and shortcut routing tests.
func key(_ window: NSWindow, code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
 NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                 windowNumber: window.windowNumber, context: nil, characters: characters,
                 charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
}
let controller = LauncherController()
controller.buildLibraryWindow()
controller.mountLibraryView(in: controller.libraryDetachedContentView!)
let library = controller.libraryWindow as! LibraryWindow
library.setFrameOrigin(NSPoint(x: screen.minX + 50, y: screen.minY + 50))
let entries = LibraryStore.folders.enumerated().map { LibraryEntry(id: "\($0.offset)", folder: $0.element) }
controller.rebuildLibraryFolderChips(entries: entries)
let list = controller.libraryListStack!
let originalEmptyFrame = library.frame
let viewport = controller.libraryScrollView!.contentView
// Check real scroll-view centering for all empty states at two window heights.
for symbol in ["bookmark", "folder", "magnifyingglass"] {
 controller.showLibraryEmptyState(title: emptyTitle, subtitle: emptySubtitle, symbolName: symbol)
 let guidance = list.arrangedSubviews.first!
 let content = firstDescendant(NSStackView.self, in: guidance)!
 for height in [CGFloat(560), CGFloat(740)] {
  library.setContentSize(NSSize(width: 760, height: height))
  settle(library)
  let contentFrame = content.convert(content.bounds, to: viewport)
  // The 12pt lift adds to the 6pt offset from the list's unequal insets.
  check(abs(contentFrame.midY - (viewport.bounds.midY - 18)) <= 1,
        "Empty \(symbol) guidance stays just above center at window height \(height); offset: \(contentFrame.midY - viewport.bounds.midY)")
  check(viewport.documentView!.frame.height <= viewport.bounds.height + 1,
        "Empty \(symbol) guidance does not add scrolling at height \(height)")
 }
 // Save the actual Library layout rather than only the standalone message view.
 if symbol == "bookmark" { preview(library, name: "library-empty-centered") }
 guidance.removeFromSuperview()
}
// Keep the message visible when its minimum height exceeds a short viewport.
library.setContentSize(NSSize(width: 520, height: 360))
controller.showLibraryEmptyState(title: emptyTitle, subtitle: emptySubtitle, symbolName: "folder")
settle(library)
let compactGuidance = list.arrangedSubviews.first!
let compactContent = firstDescendant(NSStackView.self, in: compactGuidance)!
check(viewport.bounds.contains(compactContent.convert(compactContent.bounds, to: viewport)),
      "Compact Library keeps the complete empty message visible")
compactGuidance.removeFromSuperview()
library.setFrame(originalEmptyFrame, display: false)
// Populate enough Library rows to exercise scrolling after a handoff.
for index in 0..<40 {
 let row = NSTextField(labelWithString: "Saved result \(index)")
 list.addArrangedSubview(row)
 row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
 row.heightAnchor.constraint(equalToConstant: 48).isActive = true
}
let rowStop = NSButton(title: "Rename", target: nil, action: nil)
list.addArrangedSubview(rowStop)
controller.libraryTabStops.append(rowStop)
let search = controller.librarySearchField!
search.stringValue = "Keep my search"
settle(library)
let libraryOriginal = library.frame
let initialHidden = controller.libraryOverflowFolders.count
let initialScrollHeight = controller.libraryScrollView!.frame.height
check(viewport.documentView!.frame.height > viewport.bounds.height,
      "Saved rows still scroll after replacing an empty state")
check(library.styleMask.contains(.resizable), "Library enables native edge resizing")
check(library.standardWindowButton(.zoomButton)!.isEnabled, "Library enables the zoom traffic light")
check(library.contentMinSize.width < library.contentView!.bounds.width, "Library can shrink horizontally")
check(library.contentMinSize.height < library.contentView!.bounds.height, "Library can shrink vertically")
check(library.contentMaxSize.width > screen.width, "Library has no fixed maximum width")
check(initialHidden > 0, "Narrow Library puts excess folders in overflow")

// Exercise the subclass event chain, delegate and real title accessory together.
doubleClick(library)
waitForFrame(library, library.screen!.visibleFrame, message: "Library fills the visible screen")
settle(library)
check(!library.styleMask.contains(.fullScreen), "Library maximize stays out of fullscreen")
check(abs(search.frame.width - (library.contentLayoutRect.width - 64)) < 1, "Search spans the Library content width")
check(abs(list.frame.width - (controller.libraryScrollView!.contentSize.width - 48)) < 1, "Rows expand with Library")
check(controller.libraryOverflowFolders.count < initialHidden, "Wider Library reveals more folders")
check(search.stringValue == "Keep my search", "Resize preserves the search query")
check(list.arrangedSubviews.count == 41, "Resize keeps the existing rows")
doubleClick(library)
waitForFrame(library, libraryOriginal, message: "Library restores its previous size and position")
settle(library)
check(controller.libraryOverflowFolders.count == initialHidden, "Restored width restores folder overflow")

library.setContentSize(nativeContentSize(NSSize(width: 920, height: 400), in: library))
settle(library)
let manualFrame = library.frame
check(controller.libraryScrollView!.frame.height < initialScrollHeight, "A shorter Library reduces the list viewport")
check(controller.libraryScrollView!.documentView!.frame.height > controller.libraryScrollView!.contentSize.height,
      "Long lists remain scrollable after resizing")
doubleClick(library)
waitForFrame(library, library.screen!.visibleFrame, message: "Manually resized Library maximizes")
doubleClick(library)
waitForFrame(library, manualFrame, message: "Library restores the latest manual size")
settle(library)

// A focused chip that moves into overflow transfers focus to the overflow control.
let chipStack = controller.libraryChipStack!
let lastFolder = chipStack.arrangedSubviews.compactMap { $0 as? LibraryFolderChipButton }.last {
 // Select a folder chip for the folder-navigation checks.
 if case .folder = $0.kind { return true }; return false
}!
check(library.makeFirstResponder(lastFolder), "Folder chips accept keyboard focus")
library.setContentSize(library.contentMinSize)
settle(library)
check((library.firstResponder as? LibraryFolderChipButton)?.kind == .overflow, "Hidden focused folder transfers focus to overflow")
check(chipStack.fittingSize.width <= controller.libraryChipScrollView!.contentSize.width - 8,
      "Folder chips and overflow fit at the minimum width")
check(controller.libraryTabStops.last === rowStop, "Folder reflow keeps row controls after chips in Tab order")
check(Set(controller.libraryTabStops.map(ObjectIdentifier.init)).count == controller.libraryTabStops.count,
      "Repeated resizing does not duplicate Tab stops")
check(library.makeFirstResponder(rowStop), "Row control accepts keyboard focus")
library.setContentSize(nativeContentSize(NSSize(width: 920, height: 450), in: library))
settle(library)
check(library.firstResponder === rowStop, "Resizing preserves row keyboard focus")

// Folder creation and rename must keep the same editor and unsaved text during resize.
for creating in [true, false] {
 controller.isCreatingLibraryFolder = creating
 controller.renamingLibraryFolder = creating ? nil : "English"
 controller.libraryTabStops.removeAll()
 controller.rebuildLibraryFolderChips(entries: entries)
 controller.libraryTabStops.append(rowStop)
 let editor = controller.libraryFolderEditor!
 editor.stringValue = "Unfinished folder name"
 library.setContentSize(nativeContentSize(NSSize(width: 820, height: 450), in: library))
 settle(library)
 check(controller.libraryFolderEditor === editor, "Resize keeps the active folder editor")
 check(editor.stringValue == "Unfinished folder name", "Resize preserves unfinished folder text")
 controller.isCreatingLibraryFolder = false
 controller.renamingLibraryFolder = nil
 controller.reflowLibraryFolderChips()
 settle(library)
 check(abs(controller.libraryFolderChipsWidth - 756) < 1, "Chips use the new width after editing ends")
 library.setContentSize(nativeContentSize(NSSize(width: 920, height: 450), in: library))
 settle(library)
}

library.sendEvent(key(library, code: 3, characters: "f", modifiers: .command))
library.sendEvent(key(library, code: 125))
library.sendEvent(key(library, code: 48, characters: "\t"))
library.sendEvent(key(library, code: 53))
check(controller.searchFocusCalls == 1, "Command-F still routes to Library search")
check(controller.navigationCalls == 1, "Arrow keys still route to Library rows")
check(controller.tabCalls == 1, "Tab still routes to Library controls")
check(controller.escapeCalls == 1, "Escape still routes to Library editing")
library.close()
check(controller.finalizeCalls == 1, "Library close still runs its cleanup handler")

// Placement defaults to the main window and survives new controller instances after a detach.
let hosted = LauncherController()
let fixtureApp = FixtureAppDelegate()
hosted.appDelegate = fixtureApp
hosted.buildWindow()
let mainWindow = hosted.window!
mainWindow.makeKeyAndOrderFront(nil)
settle(mainWindow)
let composerTrafficLights = trafficLightFrames(mainWindow)
preview(mainWindow, name: "composer-main")
(hosted.window as! FixtureLauncherWindow).fixtureIsKey = true
hosted.inputView.string = "Keep this draft"
let retainedResult = FixtureSession()
hosted.inlineResultSession = retainedResult
hosted.showLibrary(nil)
checkTrafficLights(mainWindow, composerTrafficLights, after: "opening Library before the next layout pass")
settle(mainWindow)
checkTrafficLights(mainWindow, composerTrafficLights, after: "opening Library")
let sharedView = hosted.libraryView!
check(hosted.isLibraryEmbedded, "Library opens in the main window by default")
check(hosted.libraryWindow == nil, "Embedded Library does not create a second window")
check(sharedView.superview === hosted.launcherContentView, "Library mounts inside the main content area")
check(hosted.composeStack!.isHidden, "Library hides the composer")
check(mainWindow.title == "\(appName) • Library", "Main title identifies Library")
check(fixtureApp.activeSession == nil, "Hidden results are unavailable to File commands")
check(retainedResult.pauseCount > 0, "Opening Library pauses hidden result audio")
check(hosted.libraryBackButton?.isHidden == false, "Embedded Library shows Back")
check(hosted.libraryPositionButton!.tooltipMessage == "Open Library in a Separate Window", "Embedded control offers detaching")
check(!hosted.libraryBackButton!.isBordered && !hosted.libraryPositionButton!.isBordered,
      "Library title-bar controls have no button outlines")
check(!sharedView.subviews.contains(where: { $0 is NSButton }), "Navigation controls leave the search area")
// Keep Library navigation buttons inside the title bar.
for button in [hosted.libraryBackButton!, hosted.libraryPositionButton!] {
 check(center(button).y >= mainWindow.contentLayoutRect.maxY, "Navigation control sits in the title bar")
 check(!(mainWindow as! NativeWindow).isTitlebarDoubleClick(mouse(mainWindow, center(button))),
       "Double-clicking a title-bar action does not maximize the window")
}
let originalMainFrame = mainWindow.frame
doubleClick(mainWindow as! NativeWindow)
waitForFrame(mainWindow, mainWindow.screen!.visibleFrame, message: "Embedded Library keeps title-bar maximize")
settle(mainWindow)
checkTrafficLights(mainWindow, composerTrafficLights, after: "maximizing embedded Library")
doubleClick(mainWindow as! NativeWindow)
waitForFrame(mainWindow, originalMainFrame, message: "Embedded Library restores the main window frame")
settle(mainWindow)
checkTrafficLights(mainWindow, composerTrafficLights, after: "restoring embedded Library")

hosted.librarySearchField!.stringValue = "Search remains"
hosted.selectedLibraryFolder = "Russian"
// Populate the hosted Library with enough rows to exercise its layout.
for index in 0..<30 {
 let row = NSTextField(labelWithString: "Saved result \(index)")
 hosted.libraryListStack!.addArrangedSubview(row)
 row.widthAnchor.constraint(equalTo: hosted.libraryListStack!.widthAnchor).isActive = true
 row.heightAnchor.constraint(equalToConstant: 48).isActive = true
}
settle(mainWindow)
preview(mainWindow, name: "library-main")
hosted.libraryScrollView!.contentView.scroll(to: NSPoint(x: 0, y: 320))
let scrollBeforeMove = hosted.libraryScrollView!.contentView.bounds.origin.y
(hosted.window as! FixtureLauncherWindow).fixtureIsKey = false
hosted.toggleLibraryPosition(nil)
let detachedWindow = hosted.libraryWindow!
settle(detachedWindow)
settle(mainWindow)
checkTrafficLights(mainWindow, composerTrafficLights, after: "detaching Library")
preview(detachedWindow, name: "library-detached")
check(!hosted.isLibraryEmbedded && detachedWindow.isVisible, "Detach opens Library in its own window")
check(preferencesStore.bool(forKey: PreferenceKey.libraryDetached), "Detach saves the placement choice")
check(hosted.libraryView === sharedView, "Detach reuses the same Library view")
check(sharedView.superview === hosted.libraryDetachedContentView, "Detach moves the view to the detached host")
check(hosted.composeStack!.isHidden == false, "Detach restores the main composer")
check(hosted.inputView.string == "Keep this draft" && hosted.inlineResultSession === retainedResult,
      "Detach preserves the draft and result session")
check(hosted.librarySearchField!.stringValue == "Search remains" && hosted.selectedLibraryFolder == "Russian",
      "Detach preserves the search and folder selection")
check(abs(hosted.libraryScrollView!.contentView.bounds.origin.y - scrollBeforeMove) < 1, "Detach preserves the list position")
check(hosted.finalizeCalls == 0, "Moving Library does not finalize pending deletions")
check(hosted.libraryBackButton!.isHidden, "Detached Library hides Back")
check(hosted.libraryPositionButton!.tooltipMessage == "Move Library to Main Window", "Detached control offers reattaching")
let refreshBeforeRepeat = hosted.refreshCalls
hosted.showLibrary(nil)
check(hosted.refreshCalls == refreshBeforeRepeat && hosted.libraryView === sharedView,
      "Opening visible Library only brings the existing view forward")

detachedWindow.close()
check(hosted.finalizeCalls == 1, "Closing detached Library finalizes pending deletions")
hosted.showLibrary(nil)
check(hosted.libraryHostWindow === detachedWindow && detachedWindow.isVisible, "Library reopens detached after closing")
let reopened = LauncherController()
reopened.showLibrary(nil)
check(reopened.window == nil && reopened.libraryWindow!.isVisible, "A new controller honors the saved detached choice")
reopened.libraryWindow!.close()

hosted.toggleLibraryPosition(nil)
settle(mainWindow)
checkTrafficLights(mainWindow, composerTrafficLights, after: "reattaching Library")
check(hosted.isLibraryEmbedded && !detachedWindow.isVisible,
      "Reattach hides the detached window (embedded: \(hosted.isLibraryEmbedded), detached visible: \(detachedWindow.isVisible))")
check(!preferencesStore.bool(forKey: PreferenceKey.libraryDetached), "Reattach saves main-window placement")
check(hosted.libraryView === sharedView && sharedView.superview === hosted.launcherContentView,
      "Reattach moves the same view back")
check(hosted.libraryHostWindow === mainWindow, "Keyboard actions now target the main window")
// Match the key-window state in which AppKit delivers these keyboard events.
(mainWindow as! FixtureLauncherWindow).fixtureIsKey = true
check(mainWindow.isKeyWindow, "The main window receives Library keyboard events")
let searchCallsBefore = hosted.searchFocusCalls
mainWindow.sendEvent(key(mainWindow, code: 3, characters: "f", modifiers: .command))
mainWindow.sendEvent(key(mainWindow, code: 125))
mainWindow.sendEvent(key(mainWindow, code: 48, characters: "\t"))
check(hosted.searchFocusCalls == searchCallsBefore + 1, "Embedded Library handles Command-F")
check(hosted.navigationCalls == 1 && hosted.tabCalls == 1, "Embedded Library handles arrows and Tab")
hosted.searchEscapeHandled = false
mainWindow.sendEvent(key(mainWindow, code: 53))
checkTrafficLights(mainWindow, composerTrafficLights, after: "returning to the composer before the next layout pass")
settle(mainWindow)
checkTrafficLights(mainWindow, composerTrafficLights, after: "returning to the composer")
check(!hosted.isLibraryEmbedded && mainWindow.isVisible, "Escape leaves embedded Library without closing the main window")
check(sharedView.isHidden && !hosted.composeStack!.isHidden, "Leaving Library restores the composer")
check(hosted.inlineResultSession === retainedResult && hosted.inputView.string == "Keep this draft", "Back preserves draft and result")
check(fixtureApp.activeSession === retainedResult,
      "Back restores File commands for the visible result (main key: \(mainWindow.isKeyWindow))")
check(mainWindow.title == "Langmin • Translate", "Back restores the main title")

hosted.showLibrary(nil)
check(hosted.isLibraryEmbedded, "Library reopens embedded after reattaching")
let finalizationsBeforeClose = hosted.finalizeCalls
mainWindow.close()
check(hosted.finalizeCalls == finalizationsBeforeClose + 1, "Closing the main window also closes embedded Library")
check(!hosted.isLibraryEmbedded && sharedView.isHidden, "Closed main window does not leave a hidden Library active")
check(hosted.closeComposerCalls == 1, "Main-window close still releases the result session")
let attachedAgain = LauncherController()
attachedAgain.showLibrary(nil)
check(attachedAgain.isLibraryEmbedded && attachedAgain.libraryWindow == nil, "A new controller honors the saved attached choice")
attachedAgain.window!.close()
print("\(checks) total window checks passed")
'''

with tempfile.TemporaryDirectory(prefix='langmin-titlebar-zoom-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', *swift_fixture_args(), '-O', '-module-cache-path', cache, '-target', f'{platform.machine()}-apple-macos14.0',
                    str(folder / 'main.swift'), '-o', str(folder / 'tests')], check=True)
    preview_dir = os.environ.get('LANGMIN_TEST_PREVIEW_DIR')
    subprocess.run([str(folder / 'tests')] + ([preview_dir] if preview_dir else []), check=True, timeout=30)
