#!/usr/bin/env python3
"""Check the native privacy reader and Pro footer without user preferences or StoreKit calls."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

from source_files import ROOT, app_path, app_source, swift_fixture_args
MAIN = app_source('main.swift')


# block(source, marker): Extract one brace-balanced production declaration for
# this isolated Swift fixture.
def block(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    # Include nested blocks when finding the end of the extracted declaration.
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


source = r'''
import Cocoa
import StoreKit
let appName = "Langmin"
let privacyPolicyURL = URL(string: "https://min.tools/langmin/privacy/")!
// localized(key, text): Resolve labels through the fixture’s controlled
// localization.
func localized(_ key: String, _ text: String) -> String { text }
// configureNativeWindow(window): Match the native title-bar appearance without
// starting the app delegate.
func configureNativeWindow(_ window: NSWindow) {
 window.titlebarAppearsTransparent = true
 window.titlebarSeparatorStyle = .none
}
// presentProAlert(title, body, [style = .informational]): Fail if layout checks
// unexpectedly open a purchase alert.
func presentProAlert(title: String, body: String, style: NSAlert.Style = .informational) { fatalError("Unexpected alert") }
// presentNothingToRestoreAlert(): Fail if layout checks unexpectedly enter the
// restore flow.
func presentNothingToRestoreAlert() { fatalError("Unexpected restore") }
// Supply the privacy action target without presenting another window.
class AppDelegate: NSObject { /* showPrivacyPolicy(sender): Keep privacy presentation inert while testing the Pro panel. */ func showPrivacyPolicy(_ sender: Any?) {} }
// Expose controlled entitlement and product state without store operations.
class ProStore {
 static let shared = ProStore()
 static let manageSubscriptionsURL = URL(string: "https://example.com")!
 static let termsOfUseURL = URL(string: "https://example.com")!
 // Provide the purchase outcomes referenced by the production panel.
 enum PurchaseOutcome { case unlocked, pending, cancelled }
 var entitlement = ProEntitlement(kind: .lifetime)
 var isPro: Bool { entitlement.isPro }
 var yearly: Product?, lifetime: Product?
 // loadProducts(): Prevent layout tests from fetching live products.
 func loadProducts() async throws { fatalError("Unexpected StoreKit access") }
 // purchase(product, confirmIn): Prevent layout tests from starting a purchase.
 func purchase(_ product: Product, confirmIn: NSWindow) async throws -> PurchaseOutcome { fatalError("Unexpected purchase") }
 // restore(): Prevent layout tests from restoring real transactions.
 func restore() async throws -> Bool { fatalError("Unexpected restore") }
 // statusText(): Return a stable entitlement label for panel snapshots.
 func statusText() -> String { "Pro · fixture" }
}
'''
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['let langminControlBorderColor =', 'final class NativeBackgroundView:', 'func nativeTitlebarHeight(',
               'func nativeContentSize(', 'func installNativeContent(']:
    source += block(MAIN, marker) + '\n'
source += block(app_source('EditionSupport.swift'), 'enum ProFeature {') + '\n'
source += app_source('ProEntitlementLogic.swift')
pro = app_source('ProStore.swift')
source += pro[pro.index('final class ProPaywallController:'):].replace('private ', '')
source += app_source('PrivacyPolicy.swift').replace('private ', '')
source += r'''
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let policyURL = URL(fileURLWithPath: CommandLine.arguments[2])
var checks = 0
// check(condition, message): Report failed fixture expectations with their case
// names.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
 // Stop this fixture when its named expectation does not hold.
 guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
 checks += 1
}
// snapshot(window, name): Capture the laid-out panel into the fixture’s
// artifact directory.
func snapshot(_ window: NSWindow, _ name: String) throws {
 window.layoutIfNeeded()
 RunLoop.main.run(until: Date().addingTimeInterval(0.05))
 let view = window.contentView!
 let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
 view.cacheDisplay(in: view.bounds, to: bitmap)
 try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
}
// links(text): Collect clickable URLs from the rendered policy text.
func links(_ text: NSAttributedString) -> [URL] {
 var urls: [URL] = []
 text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
  // Ignore text ranges that do not carry a URL link.
  if let url = value as? URL { urls.append(url) }
 }
 return urls
}
_ = NSApplication.shared
let rendered = PrivacyPolicyController.attributedPolicy("# Privacy\n\nA **bold** word and [website](https://example.com).\n\n## Contact\n\nWrite to privacy@example.com.\n\nAn *italic* word and `code`.")
check(rendered.string == "Privacy\nA bold word and website.\nContact\nWrite to privacy@example.com.\nAn italic word and code.\n", "Markdown keeps all readable text without markup")
check((rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 24, "The document title has heading typography")
check(links(rendered).contains(URL(string: "https://example.com")!), "Explicit Markdown links survive rendering")
check(links(rendered).contains(URL(string: "mailto:privacy@example.com")!), "Plain contact addresses become email links")
let codeRange = (rendered.string as NSString).range(of: "code")
check((rendered.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)?.isFixedPitch == true, "Inline code uses a monospace font")
let policy = PrivacyPolicyController.policyText(at: policyURL)
// Confirm that the bundled policy retains its main sections.
for section in ["Langmin Privacy Policy", "Data on your Mac", "Optional iCloud Library sync", "Changes and contact"] {
 check(policy.string.contains(section), "The bundled policy includes \(section)")
}
check(links(policy).contains(URL(string: "https://github.com/min-tools/langmin-macos")!), "The bundled GitHub contact link is clickable")
// Offer the online policy when the bundled resource cannot be located.
for missing in [nil, folder.appendingPathComponent("missing.md")] as [URL?] {
 check(links(PrivacyPolicyController.policyText(at: missing)).contains(privacyPolicyURL), "Missing resources offer an explicit online link inside the panel")
}
let empty = folder.appendingPathComponent("empty.md")
try "\n  ".write(to: empty, atomically: true, encoding: .utf8)
check(links(PrivacyPolicyController.policyText(at: empty)).contains(privacyPolicyURL), "An empty resource does not produce a blank window")

// Build offscreen; neither show() nor a modal purchase session is started by this fixture.
let reader = PrivacyPolicyController()
reader.buildWindow()
reader.textView.textStorage?.setAttributedString(policy)
let window = reader.window!
check(window.worksWhenModal, "Privacy remains usable while the Pro dialog is modal")
check(!reader.textView.isEditable && reader.textView.isSelectable, "The policy is read-only and supports selection/copy")
check(window.styleMask.contains(.resizable), "The policy window can be resized")
let scroll = reader.textView.enclosingScrollView!
let body = scroll.superview!
let close = body.subviews.compactMap { $0 as? NSButton }.first!
check(close.keyEquivalent == "\r", "Return dismisses the policy")
// Check the reader in both native appearances.
for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
 window.appearance = NSAppearance(named: appearance)
 // Keep text clear of both overlay and space-reserving scrollbars.
 for style: NSScroller.Style in [.overlay, .legacy] {
  scroll.scrollerStyle = style
  scroll.autohidesScrollers = false
  // Check normal and minimum window sizes.
  for size in [NSSize(width: 640, height: 580), NSSize(width: 420, height: 320)] {
   window.setContentSize(nativeContentSize(size, in: window))
   window.layoutIfNeeded()
   scroll.tile()
   reader.textView.layoutManager?.ensureLayout(for: reader.textView.textContainer!)
   let frame = close.convert(close.bounds, to: body)
   check(abs(body.bounds.maxX - frame.maxX - 28) < 1, "The policy button keeps its right inset")
   check(frame.size == close.intrinsicContentSize, "The policy button uses its natural macOS size")
   check(scroll.hasVerticalScroller && reader.textView.frame.height > scroll.contentSize.height, "Long policies scroll at normal and minimum sizes")
   let textOrigin = reader.textView.textContainerOrigin
   let textWidth = reader.textView.textContainer!.containerSize.width
   let textLeft = reader.textView.convert(textOrigin, to: body).x
   let textRight = reader.textView.convert(NSPoint(x: textOrigin.x + textWidth, y: textOrigin.y), to: body).x
   let scroller = scroll.verticalScroller!
   let scrollerFrame = scroller.convert(scroller.bounds, to: body)
   check(abs(textLeft - 28) < 1, "Moving the scrollbar preserves the text's leading inset")
   check(scrollerFrame.width > 0 && textRight <= scrollerFrame.minX - 4, "The full text column stays clear of both overlay and legacy scrollbars")
   check(abs(textWidth + 2 * textOrigin.x - scroll.contentSize.width) < 1, "Text reflows within its padding")
   reader.textView.scrollToBeginningOfDocument(nil)
   scroll.flashScrollers()
   try snapshot(window, "privacy-\(appearance.rawValue)-\(style == .overlay ? "overlay" : "legacy")-\(Int(size.width))")
  }
 }
}
reader.textView.scrollRangeToVisible(NSRange(location: policy.length - 1, length: 1))
check(reader.textView.visibleRect.maxY >= reader.textView.bounds.maxY - 25, "The end of the policy is reachable")

// Check footer sizing in purchased, loading, and error states.
for state in ["pro", "loading", "error"] {
 let panel = ProPaywallController(feature: nil)
 // Select the panel state without entering a store operation.
 switch state {
 // Show the existing-purchase confirmation.
 case "pro": panel.showProStatus()
 // Show the product-loading state.
 case "loading": panel.showLoading()
 // Show an unavailable-store message for the error case.
 default: panel.showError("The App Store is unavailable. Try again later.")
 }
 // Check each Pro panel state in both appearances.
 for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
  panel.window.appearance = NSAppearance(named: appearance)
  panel.window.layoutIfNeeded()
  let body = panel.content.superview!
  let frame = panel.closeButton.convert(panel.closeButton.bounds, to: body)
  check(abs(body.bounds.maxX - frame.maxX - 28) < 1, "The Pro footer stays right-aligned in \(state)")
  check(abs(frame.minY - 24) < 1, "The Pro footer has consistent bottom spacing in \(state)")
  check(frame.size == panel.closeButton.intrinsicContentSize, "The Pro close button uses its natural macOS size in \(state)")
  try snapshot(panel.window, "pro-\(state)-\(appearance.rawValue)")
 }
}
print("\(checks) privacy and Pro layout checks passed; no real preferences, provider calls or purchases")
'''

with tempfile.TemporaryDirectory(prefix='langmin-privacy-tests-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', *swift_fixture_args(), '-module-cache-path', cache, str(folder / 'main.swift'),
                    '-o', str(folder / 'tests')], check=True, cwd=ROOT)
    subprocess.run([str(folder / 'tests'), directory, str(ROOT / 'langmin/Resources/PRIVACY.md')],
                   check=True, timeout=30, cwd=ROOT)
    # Retain rendered artifacts only when a destination was explicitly requested.
    if target := os.environ.get('LANGMIN_TEST_ARTIFACTS'):
        output = Path(target)
        output.mkdir(parents=True, exist_ok=True)
        # Copy rendered fixture artifacts to the explicitly requested output directory.
        for image in folder.glob('*.png'):
            shutil.copyfile(image, output / image.name)
