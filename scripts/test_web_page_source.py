#!/usr/bin/env python3
"""Offline link-reading, style, image selection, transport and native layout checks.

Uses production helpers, intercepted HTTP requests, task-owned loopback servers,
and temporary files. Optional --live URL verifies page extraction without a model.
"""
from pathlib import Path
import os
import platform
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from source_files import ROOT, app_path, app_source, swift_fixture_args
MAIN = app_source('main.swift')
HUD = app_source('ClipboardProgressHUD.swift')


# block(marker, [text = MAIN]): Extract one brace-balanced production
# declaration for this isolated Swift fixture.
def block(marker, text=MAIN):
    start = text.index(marker)
    # Keep actor annotations: dropping one from the fixture would change the
    # executor behavior we are specifically testing.
    preceding = text[:start].splitlines(keepends=True)
    # Retain actor isolation when extracting an annotated production declaration.
    if preceding and preceding[-1].strip() == '@MainActor':
        start -= len(preceding[-1])
    end = text.index('{', start) + 1
    depth = 1
    # Include nested blocks when finding the end of the extracted declaration.
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


source = r'''
import Cocoa
import Foundation
import ImageIO
// Represent fixture failures using the app’s localized-error contract.
struct HelperFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
// detectLanguagePrefix(input): Leave language-prefix parsing outside this
// page-source fixture.
func detectLanguagePrefix(in input: String) -> (language: String?, input: String) { (nil, input) }
// preferredOutputLanguage(value): Represent automatic output language as an
// unspecified target.
func preferredOutputLanguage(_ value: String) -> String? { value == "auto" ? nil : value }
// extraLanguagesInstruction(values, result): Expose extra targets in the
// generated prompt for assertions.
func extraLanguagesInstruction(_ values: [String], result: String) -> String { "\nExtra languages: " + values.joined(separator: ", ") }
// applyLanguageLevel(input, level): Expose the requested reading level without
// rewriting the source.
func applyLanguageLevel(to input: String, level: String) -> String { input + "\nLanguage level: " + level }
// translationLanguageCode(value): Keep fixture language IDs unchanged.
func translationLanguageCode(for value: String) -> String? { value }
// Track source assets and publication threads for one launcher request.
final class LauncherRun: @unchecked Sendable {
 var sourcePage: WebPageSource?
 var returnsTransformedText = false
 var hudToken: UUID?
 var assetWriteOnMain: Bool?
 var sourceImages: [SourceImageAsset]? { didSet { assetWriteOnMain = Thread.isMainThread } }
 // init(sourcePage): Start a request with its supplied page snapshot.
 init(sourcePage: WebPageSource?) { self.sourcePage = sourcePage }
}
// Identify the provider whose sharing permission is being checked.
struct RemoteAIDestination { let consentID: String; let displayName: String }
var destinationUnderTest: RemoteAIDestination? = RemoteAIDestination(consentID: "provider-a", displayName: "Provider A")
// remoteTextDestination(model): Let tests change the destination while page
// preparation is suspended.
func remoteTextDestination(for model: String) -> RemoteAIDestination? { destinationUnderTest }
var scannedPageInput = ""
var secretScanHook: (() -> Void)?
// confirmRemoteSecretWarningIfNeeded(input, provider): Record the scanned text
// and optionally simulate a provider change during consent.
func confirmRemoteSecretWarningIfNeeded(input: String, provider: String?) -> Bool {
 precondition(Thread.isMainThread)
 scannedPageInput = input
 secretScanHook?()
 return true
}
// Provide the provider cases needed by extracted request code.
enum FixtureProvider { case apple, cloud }
// textProvider(model): Route this fixture through remote-provider preparation.
func textProvider(for model: String) -> (provider: FixtureProvider, model: String) { (.cloud, model) }
// Supply a dependency’s type identity without adding behavior to this fixture.
struct LauncherCancellationError: Error {}
// localized(key, english): Resolve labels through the fixture’s controlled
// localization.
func localized(_ key: String, _ english: String) -> String { english }
'''
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['struct ExplanationPrompt {', 'func promptLanguageNames(', 'func explanationLanguageRule(', 'func explanationPrompt(',
               'func summaryPrompt(', 'func translationSourceLanguageInstructions(', 'func appleIntelligencePrompt(']:
    source += block(marker) + '\n'
source += block('final class TextRequestHandle {') + '\n'
source += 'struct PromptBuilder {\n' + block('    func linkedPagePrompt(') + '\n}\n'
source += r'''
// Supply the paths and font size used by source-image rendering.
struct ViewerConfig { let textPath: String; var sourceImages: [SourceImageAsset]?; let fontSize: CGFloat = 16 }
// Host the production image renderer with minimal text-formatting dependencies.
final class Renderer {
 var config: ViewerConfig
 // init(config): Attach the source-image configuration under test.
 init(config: ViewerConfig) { self.config = config }
 // viewerParagraphStyle(): Use a stable paragraph style for image-placement
 // checks.
 func viewerParagraphStyle() -> NSParagraphStyle { NSParagraphStyle.default }
 // viewerTextAttributes(size, color, paragraphStyle): Supply the font and color
 // attributes needed by caption layout.
 func viewerTextAttributes(size: CGFloat, color: NSColor, paragraphStyle: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
  [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraphStyle]
 }
 // appendMarkdownParagraph(string, result): Append plain paragraphs; rich
 // Markdown behavior has its own fixture.
 func appendMarkdownParagraph(_ string: String, to result: NSMutableAttributedString) { result.append(NSAttributedString(string: string + "\n")) }
 // markdownInlineText(string, baseAttributes): This fixture checks image
 // loading and placement; the editor suite exercises rich caption rendering.
 func markdownInlineText(_ string: String, baseAttributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
  NSAttributedString(string: string, attributes: baseAttributes)
 }
'''
source += block('    func appendSourcePageImage(') + '\n}\n'
# Exercise the launcher's progress-to-HUD path and verify main-thread access before touching AppKit.
source += r'''
// Expose the active HUD token and status field to production progress updates.
final class ClipboardProgressHUDController {
 var activeToken: UUID?
 var statusLabel: NSTextField? = NSTextField(labelWithString: "GPT-6 Astra")
'''
source += block('    func update(token: UUID?, status: String)', HUD) + '\n}\n'
source += r'''
// Host the real HUD update method with a controlled HUD instance.
final class FixtureAppDelegate {
 let clipboardHUDController = ClipboardProgressHUDController()
'''
source += block('    func updateClipboardHUD(for run: LauncherRun, status: String)') + '\n}\n'
source += r'''
// Record page preparation, cancellation, and image publication for one run.
final class LauncherHandoff: @unchecked Sendable {
 var activeRun: LauncherRun?
 var activeTextTask: TextRequestHandle?
 var failure: Error?
 var preparationFinished = false
 // failLauncherRun(run, error, title, tempDir): Capture a preparation failure
 // only for the request still owned by this launcher.
 func failLauncherRun(_ run: LauncherRun, error: Error, title: String?, tempDir: URL?) {
  // Ignore a late failure after another request has replaced this run.
  guard activeRun === run else { return }
  failure = error
  preparationFinished = true
  activeTextTask = nil
  activeRun = nil
 }
 let ui = FixtureAppDelegate()
 var progressThreads: [Bool] = []
 var appDelegate: FixtureAppDelegate? { Thread.isMainThread ? ui : nil }
 // updateFooterStatus(busy, text): Record whether each footer update reached
 // the main thread.
 func updateFooterStatus(busy: Bool, text: String) { progressThreads.append(Thread.isMainThread) }
'''
source += block('    func updateGenerationProgress(_ run: LauncherRun, status: String)') + '\n'
source += block('    func linkedPageResult(') + '\n'
source += block('    func prepareLinkedSourceIfNeeded(') + '\n}\n'
source += r'''
// materializeSourceImages(markdown, page, directory, includeImages): This
// overload injects an offline fetch while retaining the actual async
// materializer, image decoder, cancellation checks and file writes.
func materializeSourceImages(markdown: String, page: WebPageSource, directory: URL, includeImages: Bool) async throws -> (String, [SourceImageAsset]) {
 try await materializeSourceImages(markdown: markdown, page: page, directory: directory, includeImages: includeImages, fetch: { url in
  precondition(!Thread.isMainThread, "Image work must stay off the UI thread")
  try await Task.sleep(nanoseconds: 40_000_000)
  // Simulate one missing image without contacting a server.
  if url.lastPathComponent == "missing.png" { throw URLError(.fileDoesNotExist) }
  return try Data(contentsOf: root.appendingPathComponent("handoff-fixture.png"))
 })
}
'''

source += r'''
let root = URL(fileURLWithPath: CommandLine.arguments[1])
NSSetUncaughtExceptionHandler { exception in
 fputs("Uncaught AppKit exception: \(exception)\n\(exception.callStackSymbols.joined(separator: "\n"))\n", stderr)
}
var checks = 0
// check(condition, message): Report failed fixture expectations with their case
// names.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
 // Stop this fixture when its named expectation does not hold.
 guard condition() else { fputs("FAILED: " + message + "\n", stderr); exit(1) }
 checks += 1
}
// response(url, [mime = "text/html"], [status = 200]): Construct the response
// metadata used by HTML extraction tests.
func response(_ url: URL, mime: String = "text/html", status: Int = 200) -> HTTPURLResponse {
 HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
}
let pageURL = URL(string: "https://example.test/forum/topic")!
let fixtureHTML = """
<!doctype html><html><head><title>Dropdown &amp; details</title><script>SECRET SCRIPT</script></head>
<body><nav>UNRELATED NAVIGATION</nav>
<div class='crawler-post'><div class='creator'>Reporter</div><div class='post'>
<p>“Проверка” — 日本語. Debian 12 and version 2.660: the period selector shows &lt;span&gt; markup instead of a label.</p>
<table><tr><td>Version</td><td>8.2</td></tr></table>
<p>The screenshot documents the broken menu:</p>
<a class='lightbox' href='/images/original.png'><img src='/images/thumbnail.png' width='690' height='150' alt='Broken menu'></a>
<img src='/avatar.png' class='avatar' width='48' height='48'>
<img src='file:///private/hidden.png' width='500' height='400'>
<div style='display: none'>HIDDEN CONTENT</div></div></div>
<div class='crawler-post'><div class='creator'>Responder</div><p>Confirmed on a second server. No fix is available yet.</p>
<img data-src='https://cdn.example.test/confirmation.jpg' width='600' height='200' alt='Confirmation'>
</div><footer>FOOTER BOILERPLATE</footer></body></html>
"""

// Intercept URLSession requests to test transport failures without credentials, DNS, or existing
// services.
final class FixtureProtocol: URLProtocol, @unchecked Sendable {
 static var status = 200
 static var mime = "text/html"
 static var payload = Data(fixtureHTML.utf8)
 static var advertisedSize: Int?
 static var delay: TimeInterval = 0
 static var requests: [URLRequest] = []
 private let lock = NSLock()
 private var stopped = false
 // canInit(request): Intercept every request made by this fixture session.
 override class func canInit(with request: URLRequest) -> Bool { true }
 // canonicalRequest(request): Preserve the request so assertions see its
 // original URL and headers.
 override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
 // startLoading(): Deliver the configured response and optionally delay its
 // body.
 override func startLoading() {
  Self.requests.append(request)
  var headers = ["Content-Type": Self.mime]
  // Allow tests to exercise the advertised download-size limit.
  if let size = Self.advertisedSize { headers["Content-Length"] = String(size) }
  let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: headers)!
  let payload = Self.payload
  client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
  DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [self] in
   lock.lock(); defer { lock.unlock() }
   // Do not deliver delayed bytes after cancellation.
   guard !stopped else { return }
   client?.urlProtocol(self, didLoad: payload)
   client?.urlProtocolDidFinishLoading(self)
  }
 }
 // stopLoading(): Mark a cancelled request under the same lock used by delayed
 // delivery.
 override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}
// interceptedFetch(): Run the real fetcher against the fixture protocol without
// DNS lookups.
func interceptedFetch() async throws -> Data {
 let config = URLSessionConfiguration.ephemeral
 config.protocolClasses = [FixtureProtocol.self]
 return try await fetchWebResource(pageURL, image: false, configuration: config, validateHost: { url in
  // Keep public-URL validation active even though transport is intercepted.
  guard isPublicWebURL(url) else { throw URLError(.badURL) }
 }).0
}
// makePNG([width = 900], [height = 250]): Draw a reproducible screenshot-like
// image for decoding and layout tests.
func makePNG(width: Int = 900, height: Int = 250) -> Data {
 let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
 let context = NSGraphicsContext(bitmapImageRep: bitmap)!
 NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
 NSColor(calibratedRed: 0.11, green: 0.22, blue: 0.34, alpha: 1).setFill()
 NSRect(x: 0, y: 0, width: width, height: height).fill()
 let text = "Show statistics for period  ▾\nA screenshot from the linked page"
 text.draw(in: NSRect(x: 36, y: 54, width: width - 72, height: height - 80), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.white])
 NSGraphicsContext.restoreGraphicsState()
 return bitmap.representation(using: .png, properties: [:])!
}

// runTests(): Exercise extraction, access boundaries, cancellation, and
// rendered image layout.
@MainActor func runTests() async throws {
 _ = NSApplication.shared
 check((Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any])?["NSAllowsLocalNetworking"] as? Bool == true, "Test executable uses the app's local HTTP transport configuration")
 let page = try extractWebPage(data: Data(fixtureHTML.utf8), response: response(pageURL))
 check(page.text.contains("“Проверка” — 日本語"), "Unicode survives HTML tidy parsing")
 check(page.text.contains("<span>"), "HTML entities preserve technical meaning")
 check(page.text.contains("No fix is available yet"), "Replies are extracted along with the report")
 check(page.text.contains("Reporter") && page.text.contains("Responder"), "Forum attribution is preserved")
 check(!page.text.contains("SECRET SCRIPT") && !page.text.contains("UNRELATED") && !page.text.contains("HIDDEN") && !page.text.contains("FOOTER"), "UI and scripts excluded")
 check(page.images.count == 2, "Only two article images, no avatar/local URL")
 check(page.images[0].url.path == "/images/original.png", "Original screenshot preferred")
 check(page.images[1].url.host == "cdn.example.test", "Lazy CDN image resolves")
 check(page.images[0].description.contains("broken menu"), "Image selection has source context")
 check(page.title == "Dropdown & details", "Title entities decoded")
 check(webPageInputURL(" <https://example.test/page> ") != nil, "Wrapped pasted link recognized")
 check(webPageInputURL("Review https://example.test/page") == nil, "Embedded prose link stays literal")
 // Reject local addresses, credentials, and unsupported URL forms.
 for bad in ["file:///private/image.png", "https://u:p@example.test/a", "http://localhost/", "http://127.0.0.1/", "http://10.0.0.1/", "http://[::1]/", "http://[::ffff:127.0.0.1]/", "http://192.168.1.2/", "http://100.64.0.1/", "https://printer.local/", "https://example.test:0/", "http://2130706433/"] {
  check(!isPublicWebURL(URL(string: bad)!), "Reject unsafe URL " + bad)
 }
 // Keep valid public addresses adjacent to reserved ranges reachable.
 for address in ["192.0.78.17", "192.0.1.1", "192.0.3.1", "198.51.99.1", "198.51.101.1", "203.0.112.1", "203.0.114.1"] {
  check(isPublicWebAddress(address), "Public neighbors of reserved subnets remain reachable: " + address)
 }
 // Reject reserved, multicast, and private address ranges.
 for address in ["192.0.0.1", "192.0.2.1", "192.88.99.2", "198.18.0.1", "198.19.255.254", "198.51.100.1", "203.0.113.1", "224.0.0.1", "240.0.0.1"] {
  check(!isPublicWebAddress(address), "Reserved and non-public subnets remain blocked: " + address)
 }
 check(isPublicWebURL(pageURL) && isPublicWebAddress("8.8.8.8") && isPublicWebAddress("2606:4700:4700::1111"), "Public web addresses accepted")

 // Ports are validated by range, with no fixed list of accepted services.
 for address in ["http://localhost:1313/docs?", "http://127.0.0.1:3000/", "http://[::1]:8080/", "http://192.168.1.2:4567/", "http://preview.local:1/", "https://example.test:8443/", "http://example.test:65535/"] {
  let url = URL(string: address)!
  let access = WebResourceAccess(explicitURL: url)
  check(webPageInputURL(address) == url && access.allows(url), "Direct web URL accepted on its specified port: " + address)
  try access.validate(url)
 }
 // Reject malformed or credential-bearing local-preview URLs.
 for bad in ["file:///private/page.html", "http://user:password@localhost:1313/", "http://localhost:0/", "http://localhost:65536/"] {
  let url = URL(string: bad)!
  check(!isWebURL(url) && !WebResourceAccess(explicitURL: url).allows(url), "Direct input still rejects unsupported URLs: " + bad)
 }
 check(isPublicWebURL(URL(string: "https://example.test:8443/")!), "Public resources also accept custom ports")
 let previewURL = URL(string: "http://localhost:1313/docs?")!
 let previewAccess = WebResourceAccess(explicitURL: previewURL)
 let ownImage = URL(string: "http://localhost:1313/diagram.png")!
 check(previewAccess.allows(ownImage), "Direct local page can use its own images")
 try previewAccess.validateRedirect(from: previewURL, to: ownImage)
 // Keep local-preview permission restricted to its exact origin.
 for target in ["http://localhost:1314/", "http://127.0.0.1:1313/", "http://[::1]:1313/", "http://192.168.1.2:1313/", "https://localhost:1313/"] {
  let url = URL(string: target)!
  check(!previewAccess.allows(url), "Page cannot switch private origin: " + target)
  // Attempt an origin-changing redirect under local-preview permission.
  do { try previewAccess.validateRedirect(from: previewURL, to: url); check(false, "Expected private redirect rejection") }
  // An origin change must fail even when the first page had local access.
  catch { check(true, "Private redirect remains blocked") }
 }
 // Attempt to return from a public page to the original local service.
 do { try previewAccess.validateRedirect(from: pageURL, to: ownImage); check(false, "Public page must not return to entered local origin") }
 // A public redirect must not inherit permission from an earlier local hop.
 catch { check(true, "Public redirect cannot reuse local access from an earlier hop") }
 check(!previewAccess.forPage(at: pageURL).allows(ownImage), "Public landing page cannot inherit local image access")
 let privateHTML = Data(fixtureHTML.replacingOccurrences(of: "file:///private/hidden.png", with: "http://localhost:1313/private.png").utf8)
 let publicPage = try extractWebPage(data: privateHTML, response: response(pageURL), access: WebResourceAccess(explicitURL: pageURL))
 check(publicPage.images.count == 2 && publicPage.images.allSatisfy { isPublicWebURL($0.url) }, "Public page cannot select a localhost image")
 // Require a page containing only scripts to fail extraction.
 do { _ = try extractWebPage(data: Data("<html><body><script>app()</script></body></html>".utf8), response: response(pageURL)); fatalError("Expected empty-page error") }
 // Treat script-only pages as unavailable content.
 catch { check(true, "Script-only page reports unavailable content") }
 // Require a browser challenge to fail extraction.
 do { _ = try extractWebPage(data: Data("<html><title>Just a moment...</title><body>Please enable Javascript and verify your browser before continuing with this webpage.</body></html>".utf8), response: response(pageURL)); fatalError("Expected challenge error") }
 // Treat browser challenges as errors rather than article text.
 catch { check(true, "Browser challenge does not become summary input") }
 let latin = "<html><head><meta charset='windows-1252'></head><body><p>Café — déjà vu. " + String(repeating: "Example text. ", count: 10) + "</p></body></html>"
 let latinPage = try extractWebPage(data: latin.data(using: .windowsCP1252)!, response: response(pageURL))
 check(latinPage.text.contains("Café — déjà vu"), "Legacy HTML encoding decodes correctly")
 let plain = try extractWebPage(data: Data("A small plain text page with useful content.".utf8), response: response(pageURL, mime: "text/plain"))
 check(plain.text.contains("useful content"), "Plain text pages supported")
 let limited = WebPageSource(url: pageURL, title: "Long", text: "BEGIN " + String(repeating: "middle ", count: 3000) + " END", images: [], truncated: false).limited(to: 1000)
 check(limited.truncated && limited.text.hasPrefix("BEGIN") && limited.text.hasSuffix("END"), "Long pages retain opening and conclusion with limitation")
 let encoded = page.promptInput(original: "</input>\"", includeImages: true)
 let json = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as! [String: Any]
 check(json["page_text"] as? String == page.text, "Untrusted data stays JSON-escaped")
 // Preserve language and reading-level options across all summary lengths.
 for style in ["short", "standard", "detailed"] {
  let base = summaryPrompt(input: pageURL.absoluteString, style: style, outputLanguage: "Russian", extraLanguages: ["Spanish"], languageLevel: "c")
  let local = appleIntelligencePrompt(base)
  check(local.instructions.hasPrefix(base.instructions) && local.appleResponseWordLimit == base.appleResponseWordLimit, "Apple preserves summary style/language/level: " + style)
  let linked = PromptBuilder().linkedPagePrompt(base, run: LauncherRun(sourcePage: page), detailed: style == "detailed")
  check(linked.input.contains("No fix is available yet"), "Model receives real page for " + style)
  check(linked.instructions.contains("untrusted source DATA"), "Linked source instructions survive " + style)
  check(linked.instructions.contains("at most TWO") == (style == "detailed"), "Only Detailed allows images")
 }
 let detailed = summaryPrompt(input: "page", style: "detailed", outputLanguage: "auto")
 check(detailed.instructions.contains("several purposeful paragraphs"), "Detailed demands substantive depth")
 let explained = PromptBuilder().linkedPagePrompt(explanationPrompt(question: pageURL.absoluteString, effort: "detailed", outputLanguage: "auto", research: false), run: LauncherRun(sourcePage: page), detailed: true)
 check(appleIntelligencePrompt(explained).instructions.hasPrefix(explained.appleInstructions!), "Apple Explain retains source/image/depth rules")


 // Exercise provider changes both before and during the secret scan.
 for changeDuringScan in [false, true] {
  destinationUnderTest = RemoteAIDestination(consentID: "provider-a", displayName: "Provider A")
  let preparing = LauncherHandoff()
  let preparingRun = LauncherRun(sourcePage: nil)
  preparing.activeRun = preparingRun
  var didContinue = false
  check(preparing.prepareLinkedSourceIfNeeded(input: pageURL.absoluteString, mode: "explain", model: "fixture", run: preparingRun, tempDir: root,
      loadPage: { _ in try await Task.sleep(nanoseconds: 30_000_000); return page },
      continuation: { didContinue = true; preparing.preparationFinished = true }), "Bare URL enters page preparation")
  // Change providers from inside the consent callback.
  if changeDuringScan {
   secretScanHook = { destinationUnderTest = RemoteAIDestination(consentID: "provider-b", displayName: "Provider B") }
  } else {
      // Change providers before page preparation begins.
   destinationUnderTest = RemoteAIDestination(consentID: "provider-b", displayName: "Provider B")
  }
  // Let asynchronous preparation reach its publication or failure point.
  while !preparing.preparationFinished { await Task.yield() }
  secretScanHook = nil
  check(!didContinue && preparing.failure != nil && preparingRun.sourcePage == nil, "Changing endpoints while loading or scanning requires a fresh request")
 }
 destinationUnderTest = RemoteAIDestination(consentID: "provider-a", displayName: "Provider A")
 let preparing = LauncherHandoff()
 let preparingRun = LauncherRun(sourcePage: nil)
 preparing.activeRun = preparingRun
 check(preparing.prepareLinkedSourceIfNeeded(input: pageURL.absoluteString, mode: "summarize", model: "fixture", run: preparingRun, tempDir: root,
     loadPage: { _ in try await Task.sleep(nanoseconds: 30_000_000); return page },
     continuation: { preparing.preparationFinished = true }), "Summary uses the same page preparation")
 // Wait for the unchanged-provider control case to finish.
 while !preparing.preparationFinished { await Task.yield() }
 check(preparing.failure == nil && preparingRun.sourcePage?.text == page.text, "Unchanged destination continues normally")
 check(scannedPageInput.contains(page.text) && scannedPageInput.contains("Dropdown & details") && scannedPageInput.contains("Broken menu"), "Secret scan preserves literal body text and covers page title and image metadata")

 let data = try await interceptedFetch()
 check(data == Data(fixtureHTML.utf8), "Bounded HTTP reader streams actual fixture bytes")
 check(FixtureProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil }, "Reader carries no auth or cookies")
 // Reject HTTP failures before treating their bodies as page content.
 for status in [401, 403, 404, 429, 500] {
  FixtureProtocol.status = status
  // Require each configured HTTP failure to surface as an error.
  do { _ = try await interceptedFetch(); fatalError("Expected HTTP error") } catch { check(true, "HTTP error \(status) surfaced") }
 }
 FixtureProtocol.status = 200; FixtureProtocol.mime = "application/pdf"
 // Require non-page content to fail MIME validation.
 do { _ = try await interceptedFetch(); fatalError("Expected MIME rejection") } catch { check(true, "Non-page content rejected") }
 FixtureProtocol.mime = "text/html"; FixtureProtocol.advertisedSize = 2_000_001
 // Require excessive advertised size to fail before reading the body.
 do { _ = try await interceptedFetch(); fatalError("Expected size rejection") } catch { check(true, "Oversized response headers rejected") }
 FixtureProtocol.advertisedSize = nil; FixtureProtocol.payload = Data(repeating: 65, count: 2_000_001)
 // Require the streaming limit to work without a size header.
 do { _ = try await interceptedFetch(); fatalError("Expected streaming size limit") } catch { check(true, "Streaming body limit works without Content-Length") }
 FixtureProtocol.payload = Data(fixtureHTML.utf8); FixtureProtocol.delay = 1
 let cancelled = Task { try await interceptedFetch() }
 try await Task.sleep(nanoseconds: 30_000_000); cancelled.cancel()
 // Require cancellation to stop a delayed page download.
 do { _ = try await cancelled.value; fatalError("Expected cancellation") } catch { check(true, "Page download cancels") }
 FixtureProtocol.delay = 0

 let png = makePNG()

 // Exercise real URLSession redirects and image downloads against servers
 // owned by this test. No existing workstation services are contacted.
 try png.write(to: root.appendingPathComponent("local-diagram.png"))
 // Exercise each temporary local server address supplied by the harness.
 for address in CommandLine.arguments[2].split(separator: ",") {
  let localBase = URL(string: String(address))!
  let local = try await loadWebPage(localBase.appendingPathComponent("docs"))
  check(local.url.absoluteString.hasSuffix("/docs/") && local.text.contains("Local preview content"), "Local page and same-origin slash redirect load: \(local.url)")
  check(local.images.count == 1 && local.images[0].url.path == "/diagram.png", "Local image accepted while another private service is excluded")
  check(local.limited(to: 100).access.allows(local.images[0].url), "Page truncation retains explicit local access")
  let imageFolder = root.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: imageFolder, withIntermediateDirectories: true)
  let (text, images) = try await materializeSourceImages(markdown: "Local explanation.\n\n![Diagram](langmin-source-image:1)", page: local, directory: imageFolder, includeImages: true, fetch: nil)
  check(images.count == 1 && images[0].isValid && text.contains(local.url.absoluteString), "Local image downloads and attribution is retained")
  let copyFolder = root.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: copyFolder, withIntermediateDirectories: true)
  let saved = try copySourceImageAssets(images, from: imageFolder, to: copyFolder)
  check(saved == images && NSImage(contentsOf: copyFolder.appendingPathComponent(images[0].file)) != nil, "Local source image survives Library asset copying")
  check(sourceImageMarkdownForExport(text, assets: images).contains(local.images[0].url.absoluteString), "Export keeps the local source image URL")
  // Reject redirects that exceed the allowed origin or hop count.
  for path in ["cross-port", "redirect-loop"] {
   // Attempt each disallowed local redirect and require rejection.
   do { _ = try await loadWebPage(localBase.appendingPathComponent(path)); check(false, "Expected redirect rejection") }
   // The rejected redirect must surface as an error.
   catch { check(true, "Cross-port or excessive local redirect is blocked") }
  }
  // Require explicit local permission even for a derived resource URL.
  do { _ = try await fetchWebResource(localBase.appendingPathComponent("private-target"), image: false); check(false, "Derived request must not gain local permission") }
  // Local requests require permission for the specific origin.
  catch { check(true, "Local HTTP request without explicit origin is blocked before transport") }
  // Require image redirects to stay within the approved access scope.
  do { _ = try await fetchWebResource(localBase.appendingPathComponent("image-to-private"), image: true, access: local.access); check(false, "Expected image redirect rejection") }
  // An image redirect must not extend access to another local service.
  catch { check(true, "Local image cannot redirect into another private service") }
 }

 // Detailed mode must update progress on MainActor after awaiting a selected image download.
 try png.write(to: root.appendingPathComponent("handoff-fixture.png"))
 // Check image handoff both with and without a clipboard HUD.
 for hasHUD in [false, true] {
  let handoff = LauncherHandoff()
  let run = LauncherRun(sourcePage: page)
  handoff.activeRun = run
  // Attach a matching HUD token for the progress-label checks.
  if hasHUD {
   run.hudToken = UUID()
   handoff.ui.clipboardHUDController.activeToken = run.hudToken
  }
  let result = try await handoff.linkedPageResult("Useful explanation.\n\n![Screenshot](langmin-source-image:1)", run: run, detailed: true, tempDir: root)
  // Record a failure without trapping AppKit or showing another crash dialog.
  guard handoff.progressThreads == [true], run.assetWriteOnMain == true else {
   fputs("FAIL: Detailed image handoff accessed progress UI or run state off the main thread\n", stderr)
   exit(1)
  }
  check(true, "Detailed progress and post-await asset handoff run on the main thread")
  check(result.contains("Useful explanation") && run.sourceImages?.count == 1, "Detailed result completes with an image")
  check(handoff.ui.clipboardHUDController.statusLabel?.stringValue == "GPT-6 Astra", "Image-loading progress keeps the HUD model name visible")
  check(!hasHUD || handoff.ui.clipboardHUDController.statusLabel?.accessibilityHelp() == "Loading page images…", "Active clipboard HUD exposes image-loading progress to assistive technology")
 }
 // An already-running background task must also enter the coordinator safely.
 let detachedHandoff = LauncherHandoff()
 let detachedRun = LauncherRun(sourcePage: page)
 detachedHandoff.activeRun = detachedRun
 _ = try await Task.detached {
  try await detachedHandoff.linkedPageResult("Explanation.\n\n![Image](langmin-source-image:1)", run: detachedRun, detailed: true, tempDir: root)
 }.value
 check(detachedHandoff.progressThreads == [true] && detachedRun.assetWriteOnMain == true, "Background callers hop to the UI actor")

 let noImageHandoff = LauncherHandoff()
 let noImageRun = LauncherRun(sourcePage: page)
 noImageHandoff.activeRun = noImageRun
 _ = try await noImageHandoff.linkedPageResult("Detailed prose without images.", run: noImageRun, detailed: true, tempDir: root)
 check(noImageHandoff.progressThreads.isEmpty && noImageRun.assetWriteOnMain == true, "Text-only Detailed result commits on the UI actor")
 let failedPage = WebPageSource(url: page.url, title: page.title, text: page.text,
   images: [WebPageImage(id: "1", url: URL(string: "https://example.test/missing.png")!, description: "Missing")], truncated: false)
 let failedRun = LauncherRun(sourcePage: failedPage)
 noImageHandoff.activeRun = failedRun
 let failedResult = try await noImageHandoff.linkedPageResult("Keep this answer.\n\n![Missing](langmin-source-image:1)", run: failedRun, detailed: true, tempDir: root)
 check(failedResult.contains("Keep this answer") && failedRun.sourceImages == nil && failedRun.assetWriteOnMain == true, "Image failure returns readable prose on the UI actor")

 // Invalidate a suspended request as Stop or a new submission would. Its late image must not publish
 // assets or overwrite the new result.
 let staleHandoff = LauncherHandoff()
 let staleRun = LauncherRun(sourcePage: page)
 staleHandoff.activeRun = staleRun
 let staleTask = Task { @MainActor in
  try await staleHandoff.linkedPageResult("Answer.\n\n![Screenshot](langmin-source-image:1)", run: staleRun, detailed: true, tempDir: root)
 }
 // Wait until image work has started before replacing the active run.
 while staleHandoff.progressThreads.isEmpty { await Task.yield() }
 let replacement = LauncherRun(sourcePage: page)
 staleHandoff.activeRun = replacement
 // Require a replaced run’s image task to reject publication.
 do { _ = try await staleTask.value; fatalError("Stale run unexpectedly published") }
 // Reject completion from the run that has been replaced.
 catch is LauncherCancellationError {
  check(staleRun.assetWriteOnMain == nil && staleHandoff.activeRun === replacement, "Stale image completion cannot publish over a replacement run")
 }
 let cancelHandoff = LauncherHandoff()
 let cancelRun = LauncherRun(sourcePage: page)
 cancelHandoff.activeRun = cancelRun
 let cancelTask = Task { @MainActor in
  try await cancelHandoff.linkedPageResult("Answer.\n\n![Screenshot](langmin-source-image:1)", run: cancelRun, detailed: true, tempDir: root)
 }
 // Wait until image work has started before cancelling its task.
 while cancelHandoff.progressThreads.isEmpty { await Task.yield() }
 cancelHandoff.activeRun = nil
 cancelTask.cancel()
 // Require a cancelled image task to reject publication.
 do { _ = try await cancelTask.value; fatalError("Cancelled run unexpectedly completed") }
 // Cancellation must prevent the unfinished assets from being published.
 catch is CancellationError { check(cancelRun.assetWriteOnMain == nil, "Cancelling during image handoff prevents publication") }

 let normalized = normalizedSourceImagePNG(png)!
 check(NSImage(data: normalized) != nil, "Downloaded image decodes to a local PNG")
 check(normalizedSourceImagePNG(Data("not an image".utf8)) == nil, "Invalid image rejected")
 check(normalizedSourceImagePNG(makePNG(width: 1, height: 1)) == nil, "Tracking pixel rejected")

 let literalCode = #"Use `![example](https://example.test/image.png)` as syntax."# + "\n\n```markdown\n![Fenced](langmin-source-image:1)\n```\n\n~~~markdown\n![Tilde](https://example.test/image.png)\n~~~\n\n" + #"\![Escaped](langmin-source-image:1)"# + "\n\n    ![Indented](langmin-source-image:1)\n"
 check(sourceImageReferences(in: literalCode).isEmpty, "Image syntax inside code and escaped examples stays literal")
 let (preservedCode, codeAssets) = try await materializeSourceImages(markdown: literalCode, page: page, directory: root, includeImages: true,
   fetch: { _ in fatalError("Quoted image syntax must never fetch") })
 check(preservedCode.hasPrefix(literalCode) && codeAssets.isEmpty, "Image materialization preserves technical code examples byte for byte")
 check(sourceImageMarkdownForExport(literalCode, assets: nil) == literalCode, "Markdown export preserves quoted image examples")
 let mixedCode = literalCode + "\n![Actual](langmin-source-image:1)\n"
 check(sourceImageReferences(in: mixedCode).count == 1, "Only actual prose image is selected beside code examples")
 check(sourceImageReferences(in: "😀 Before.\n![Actual](langmin-source-image:1)").first?.range.location == 11, "Image range preserves UTF-16 offsets after Unicode text")

 var fetched: [URL] = []
 let markdown = "## The reported issue\n\nThe menu displays literal markup.\n\n![Original report](langmin-source-image:1)\n\nConfirmed by a second user.\n\n![Confirmation](langmin-source-image:2)\n![Duplicate](langmin-source-image:1)\n![Unknown](langmin-source-image:8)\n![External](https://untrusted.test/image.png)"
 let (output, assets) = try await materializeSourceImages(markdown: markdown, page: page, directory: root, includeImages: true, fetch: { url in fetched.append(url); return png })
 check(fetched.count == 2 && assets.count == 2, "Only selected candidates downloaded once, capped at two")
 check(!output.contains("Unknown") && !output.contains("External") && !output.contains("Duplicate"), "Unknown, external and duplicate images removed")
 check(output.contains("### Sources") && output.contains(pageURL.absoluteString), "Page attribution always attached")
 let (short, shortAssets) = try await materializeSourceImages(markdown: markdown, page: page, directory: root, includeImages: false, fetch: { _ in fatalError("Short must not fetch") })
 check(shortAssets.isEmpty && !short.contains("langmin-source-image"), "Short results never fetch/embed images")
 let (failed, failedAssets) = try await materializeSourceImages(markdown: markdown, page: page, directory: root, includeImages: true, fetch: { _ in throw URLError(.timedOut) })
 check(failedAssets.isEmpty && failed.contains("The menu displays literal markup") && !failed.contains("langmin-source-image"), "Image failure preserves prose and removes broken placeholder")
 let cancellation = Task { try await materializeSourceImages(markdown: markdown, page: page, directory: root, includeImages: true, fetch: { _ in try await Task.sleep(nanoseconds: 5_000_000_000); return png }) }
 cancellation.cancel()
 // Require image materialization to propagate cancellation.
 do { _ = try await cancellation.value; fatalError("Expected image cancellation") } catch { check(true, "Image cancellation propagates") }
 let export = sourceImageMarkdownForExport(output, assets: assets)
 check(!export.contains("langmin-source-image") && export.contains("/images/original.png"), "Exported Markdown has portable public image links")
 let saved = root.appendingPathComponent("Saved")
 try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
 let refs = try copySourceImageAssets(assets, from: root, to: saved)
 let encodedAssets = try JSONEncoder().encode(refs)
 let reopened = try JSONDecoder().decode([SourceImageAsset].self, from: encodedAssets)
 check(reopened == assets && reopened.allSatisfy { FileManager.default.fileExists(atPath: saved.appendingPathComponent($0.file).path) }, "Image references and local pixels survive save/reopen")
 let invalid = SourceImageAsset(id: "../private", file: "../private.png", sourceURL: pageURL, pageURL: pageURL)
 check(!invalid.isValid, "Imported asset traversal rejected")

 // Render the actual viewer image block in light/dark and narrow/wide panes.
 let renderer = Renderer(config: ViewerConfig(textPath: saved.appendingPathComponent("text.md").path, sourceImages: reopened))
 // Check image placement at both narrow and wide reading widths.
 for width in [320.0, 720.0] {
  // Check that image placement remains valid in both appearances.
  for dark in [false, true] {
   let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 550))
   textView.isEditable = false
   textView.textContainerInset = NSSize(width: 24, height: 24)
   textView.textContainer?.lineFragmentPadding = 0
   textView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
   textView.backgroundColor = dark ? NSColor(calibratedWhite: 0.085, alpha: 1) : .white
   let attributed = NSMutableAttributedString(string: "The menu displays literal markup.\n\n", attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor])
   check(renderer.appendSourcePageImage("![Original report](langmin-source-image:1)", to: attributed), "Native image block rendered")
   attributed.append(NSAttributedString(string: "A second user confirms the same issue.\nNo fix is confirmed in the source.", attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor]))
   textView.textStorage?.setAttributedString(attributed)
   textView.layoutManager?.ensureLayout(for: textView.textContainer!)
   let imageRange = (attributed.string as NSString).range(of: "\u{fffc}")
   check(imageRange.location != NSNotFound, "Result contains real text attachment")
   let glyphs = textView.layoutManager!.glyphRange(forCharacterRange: imageRange, actualCharacterRange: nil)
   let bounds = textView.layoutManager!.boundingRect(forGlyphRange: glyphs, in: textView.textContainer!)
   check(bounds.width <= width - 48 && bounds.height <= 420, "Source image fits result pane")
   let bitmap = textView.bitmapImageRepForCachingDisplay(in: textView.bounds)!
   textView.cacheDisplay(in: textView.bounds, to: bitmap)
   try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("source-\(Int(width))-\(dark ? "dark" : "light").png"))
  }
 }
 // Run public-page checks only when the caller explicitly requests a live URL.
 if CommandLine.arguments.count > 4 && CommandLine.arguments[3] == "--live" {
  let live = try await loadWebPage(URL(string: CommandLine.arguments[4])!)
  check(live.text.count > 500, "Live page has substantive content")
  check(!live.text.contains("â€"), "Live Unicode punctuation preserved")
  print("Live page: \(live.text.count) characters, \(live.images.count) content images")
  try live.text.write(to: root.appendingPathComponent("live-page.txt"), atomically: true, encoding: .utf8)
  // Verify image decoding when the live page provides an image candidate.
  if let candidate = live.images.first {
   let data = try await fetchWebResource(candidate.url, image: true, access: live.access).0
   check(normalizedSourceImagePNG(data) != nil, "Live source screenshot downloads and decodes")
   try normalizedSourceImagePNG(data)!.write(to: root.appendingPathComponent("live-image.png"))
  }
 }
 print("\(checks) web-page checks passed; no model calls or credentials used")
}
var finished = false
Task { @MainActor in
 // Run the asynchronous page checks and report unexpected failures.
 do { try await runTests() } catch { fputs("Unexpected test failure: \(error)\n", stderr); exit(1) }
 finished = true
}
// Keep AppKit callbacks running until the asynchronous fixture finishes.
while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
'''
with tempfile.TemporaryDirectory(prefix='langmin-web-tests-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = Path(os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules')))
    # Embed the app's ATS configuration in the command-line test executable;
    # URLSession should exercise the same HTTP rules as the shipped bundle.
    executable = folder / 'tests'
    info_path = folder / 'TestInfo.plist'
    app_info = plistlib.loads((ROOT / 'langmin/LangminInfo.plist').read_bytes())
    info_path.write_bytes(plistlib.dumps({
        'NSAppTransportSecurity': app_info['NSAppTransportSecurity'],
        'NSLocalNetworkUsageDescription': 'Connect to temporary loopback servers for Langmin source-reader tests.',
    }))
    subprocess.run(['swiftc', *swift_fixture_args(), '-O', '-module-cache-path', str(cache), '-target', f'{platform.machine()}-apple-macos14.0',
                    str(folder / 'main.swift'), str(app_path('WebPageSource.swift')),
                    str(app_path('ResultConversation.swift')),
                    '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist', '-Xlinker', str(info_path),
                    '-o', str(executable)], check=True, cwd=ROOT)

    # Serve only generated page and image data for local transport fixtures.
    class FixtureHandler(BaseHTTPRequestHandler):
        # log_message(self, *_): Suppress routine server access logs so failures
        # remain easy to read.
        def log_message(self, *_):
            pass

        # do_GET(self): Return the controlled redirect, image, or HTML response
        # for each fixture route.
        def do_GET(self):
            path = urlsplit(self.path).path
            self.server.requests.append(path)
            assert not self.headers.get('Authorization') and not self.headers.get('Cookie')
            redirects = {'/docs': '/docs/', '/cross-port': private_url,
                         '/image-to-private': private_url, '/redirect-loop': '/redirect-loop'}
            # Redirect routes exercise the fetcher's origin and redirect-limit rules.
            if path in redirects:
                self.send_response(302)
                self.send_header('Location', redirects[path])
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            # The image route serves the fixture's generated PNG.
            if path == '/diagram.png':
                payload = (folder / 'local-diagram.png').read_bytes()
                mime = 'image/png'
            # Serve a readable article for the normal local-preview path.
            else:
                payload = ("<html><title>Local preview</title><body><article><p>"
                           + "Local preview content. " * 40
                           + "</p><img src='/diagram.png' width='900' height='250' alt='Local diagram'>"
                           + f"<img src='{private_url}' width='900' height='250' alt='Private service'>"
                           + "</article></body></html>").encode()
                mime = 'text/html'
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    # Run the same transport checks against an IPv6 loopback listener.
    class IPv6Server(ThreadingHTTPServer):
        address_family = socket.AF_INET6

    servers = []
    # Start temporary servers and guarantee shutdown after the Swift fixture exits.
    try:
        # All sockets use dynamically assigned ports and serve only fixture data.
        private = ThreadingHTTPServer(('127.0.0.1', 0), FixtureHandler)
        primary = ThreadingHTTPServer(('127.0.0.1', 0), FixtureHandler)
        ipv6 = IPv6Server(('::1', 0), FixtureHandler)
        servers = [private, primary, ipv6]
        private_url = f'http://127.0.0.1:{private.server_port}/private-target'
        # Record requests and start each fixture server on its assigned port.
        for server in servers:
            server.requests = []
            threading.Thread(target=server.serve_forever, daemon=True).start()
        addresses = ','.join([f'http://localhost:{primary.server_port}/',
                              f'http://127.0.0.1:{primary.server_port}/',
                              f'http://[::1]:{ipv6.server_port}/'])
        subprocess.run([str(executable), directory, addresses] + sys.argv[1:], check=True, timeout=100, cwd=ROOT)
        assert not private.requests, 'A redirected request or image contacted the unapproved private service'
        assert all('/private-target' not in server.requests for server in servers)
    finally:
        # Stop every temporary listener even after a fixture failure.
        for server in servers:
            server.shutdown()
            server.server_close()
    # Retain rendered artifacts only when a destination was explicitly requested.
    if target := os.environ.get('LANGMIN_TEST_ARTIFACTS'):
        output = Path(target)
        output.mkdir(parents=True, exist_ok=True)
        # Copy rendered fixture artifacts to the explicitly requested output directory.
        for artifact in list(folder.glob('source-*.png')) + list(folder.glob('live-*')):
            shutil.copyfile(artifact, output / artifact.name)
