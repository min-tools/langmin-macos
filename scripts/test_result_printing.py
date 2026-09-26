#!/usr/bin/env python3
"""Render real result Markdown through native printing, without opening the app or sending a print job."""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile

from source_files import ROOT, app_path, app_source, swift_fixture_args
MAIN = app_source('main.swift')
WEB = app_source('WebPageSource.swift')


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
import PDFKit
// localized(key, english): Resolve labels through the fixture’s controlled
// localization.
func localized(_ key: String, _ english: String) -> String { english }
let plainTitleGap: CGFloat = 10
let appName = "Langmin"
// Supply the image metadata used by print rendering without page fetching.
struct SourceImageAsset {
 let id: String, file: String
 let sourceURL: URL, pageURL: URL
 var isValid: Bool { true }
}
// Provide document title, typography, and result fields for print fixtures.
struct Config {
 var title = "Explain — Learning with Langmin"
 var fontSize: CGFloat = 17
 var textPath = ""
 var textModel: String?
 var languageLevel = "off"
 var sourceImages: [SourceImageAsset]?
 var dictionaryHeadword: String?
 var illustrationModel: String?
 var conversation: ResultConversation?
}
// Result presentation must not consult obsolete saved toolbar overrides.
func loadAppPreferences() -> Never { fatalError("Result appearance no longer reads preferences") }
func languageLevelLetter(_ value: String) -> String? { value == "b" ? "B" : nil }
func narrationVoiceDisplayValue(_ voice: String) -> String { voice }
// TOOLTIP BUTTON
final class NativeBarBackgroundView: NSView {}
// Keep follow-up activity updates inactive while testing printing and toolbar layout.
final class ResultConversationTextView: NSTextView { /* updateFollowUpActivity(): Keep follow-up UI refreshes inert in this isolated fixture. */ func updateFollowUpActivity() {} }
// Suppress unrelated app-menu refreshes from viewer callbacks.
final class Delegate { /* updateMenuForActiveWindow(): Avoid changing app menus during this isolated fixture. */ func updateMenuForActiveWindow() {} }
// Host production printing, toolbar, and title-bar methods with fixture-owned views.
final class ViewerSession: NSObject {
 var config = Config()
 var content = ""
 var narrationVoiceUsed: String?, narrationModelUsed: String?
 var illustrationImage: NSImage?
 var window: NSWindow?
 var hostWindow: NSWindow? { window }
 var textView: NSTextView?
 var appDelegate: Delegate?
 var resultPrintOperation: NSPrintOperation?
 var isEmbedded = false
 // updateResultTitlebarWidth(): Keep this production dependency inactive in the
 // isolated fixture.
 func updateResultTitlebarWidth() {}
 weak var embeddedHostView: NSView?
 var resultToolbar: ResultToolbarView?
 var saveAudioToolbarButton: NSButton?, copyButton: NSButton?, shareButton: NSButton?, illustrationButton: NSButton?
 weak var resultActivitySpinner: NSProgressIndicator?
 var narrationButton: NSButton?, highlightToggleButton: NSButton?
 // ACTIVITY STATE
 var statsLabel: NSTextField?, resultDiffControl: ResultToolbarButtonGroup?
 var diffShown = false
 var narrationSegments: [Int] = []
 var resultTitleLabel: NSTextField?, saveToLibraryButton: NSButton?
 weak var resultTitleContainer: NSView?
 var audioAvailable = false, diffAvailable = false
 // updateCopyButtonMode(): Keep this production dependency inactive in the
 // isolated fixture.
 func updateCopyButtonMode() {}
 // updateSaveToLibraryButton(): Keep this production dependency inactive in the
 // isolated fixture.
 func updateSaveToLibraryButton() {}
 // narrationTooltip(): Supply a short narration label for toolbar measurements.
 func narrationTooltip() -> String { "Read" }
 // narrationHighlightTooltip(): Supply a predictable highlighting tooltip.
 func narrationHighlightTooltip() -> String { "Highlight" }
 // updateHighlightToggleAppearance(): Keep this production dependency inactive
 // in the isolated fixture.
 func updateHighlightToggleAppearance() {}
 // saveTextFromToolbar(sender): Keep this production dependency inactive in the
 // isolated fixture.
 @objc func saveTextFromToolbar(_ sender: Any?) {}
 // editTextFromToolbar(sender): Keep this production dependency inactive in the
 // isolated fixture.
 @objc func editTextFromToolbar(_ sender: Any?) {}
 // saveToLibraryFromToolbar(sender): Keep this production dependency inactive
 // in the isolated fixture.
 @objc func saveToLibraryFromToolbar(_ sender: Any?) {}
 // detachFromHostRequested(sender): Keep this production dependency inactive in
 // the isolated fixture.
 @objc func detachFromHostRequested(_ sender: Any?) {}
 // closeFromHostRequested(sender): Keep this production dependency inactive in
 // the isolated fixture.
 @objc func closeFromHostRequested(_ sender: Any?) {}
 // saveAudioFromToolbar(sender): Keep this production dependency inactive in
 // the isolated fixture.
 @objc func saveAudioFromToolbar(_ sender: Any?) {}
 // copyTextFromToolbar(sender): Keep this production dependency inactive in the
 // isolated fixture.
 @objc func copyTextFromToolbar(_ sender: Any?) {}
 // shareFromToolbar(sender): Keep this production dependency inactive in the
 // isolated fixture.
 @objc func shareFromToolbar(_ sender: Any?) {}
 // shareTextOnlyFromToolbar(sender): Keep this production dependency inactive
 // in the isolated fixture.
 @objc func shareTextOnlyFromToolbar(_ sender: Any?) {}
 // shareTextAndAudioFromToolbar(sender): Keep this production dependency
 // inactive in the isolated fixture.
 @objc func shareTextAndAudioFromToolbar(_ sender: Any?) {}
 // showIllustrationMenu(sender): Keep this production dependency inactive in
 // the isolated fixture.
 @objc func showIllustrationMenu(_ sender: Any?) {}
 // showNarrationMenu(sender): Keep this production dependency inactive in the
 // isolated fixture.
 @objc func showNarrationMenu(_ sender: Any?) {}
 // toggleNarrationHighlightMode(sender): Keep this production dependency
 // inactive in the isolated fixture.
 @objc func toggleNarrationHighlightMode(_ sender: Any?) {}
 // clearNarrationHighlight(): Keep this production dependency inactive in the
 // isolated fixture.
 func clearNarrationHighlight() {}
 // applyResultText(): Restore plain result text when a toolbar view switch is
 // exercised.
 func applyResultText() { textView?.textStorage?.setAttributedString(NSAttributedString(string: content)) }
 // applyNarrationCursorAttributes(segments): Keep this production dependency
 // inactive in the isolated fixture.
 func applyNarrationCursorAttributes(for segments: [Int]) {}
 // diffAttributedText(): Use fixed comparison content so toolbar checks do not
 // depend on diff generation.
 func diffAttributedText() -> NSAttributedString { NSAttributedString(string: "Fixture diff") }
 // TOOLBAR
 // RENDERER
}
'''
source += block(MAIN, 'extension NSAttributedString.Key {') + '\n'
source += block(MAIN, 'func cleanTitle(') + '\n' + block(MAIN, 'func appWindowTitle(') + '\n'
source += block(app_source('DictionaryIllustration.swift'), 'func dictionaryIllustrationCaption(') + '\n'
# Use the real button drawing without opening tooltip panels in the fixture.
source += block(MAIN, 'let langminControlBorderColor =') + '\n'
source += block(MAIN, 'final class NativeSeparator:') + '\n'
tooltip = block(MAIN, 'final class TooltipButton:')
tooltip = tooltip.replace(block(tooltip, '    private func showTooltip()'), '    private func showTooltip() {}')
source = source.replace('// TOOLTIP BUTTON', tooltip)
source += block(MAIN, 'final class ResultToolbarButtonGroup:') + '\n'
source += block(MAIN, 'final class ResultToolbarView:') + '\n'
source = source.replace('// ACTIVITY STATE', block(MAIN, '    var isGeneratingNarration =') + '\n' + block(MAIN, '    var illustrationRunID:'))
toolbar = block(MAIN, '    func makeViewerToolbar(width:') + '\n'
toolbar += block(MAIN, '    func makeShareMenu()') + '\n'
toolbar += block(MAIN, '    func makeEmbeddedHeader()') + '\n'
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['    func titleForLabel()', '    func setResultTitleMessage(', '    func applyRenamedLibraryTitle(', '    func makeResultTitleView(', '    func updateResultActivityIndicator()', '    func installResultTitlebarTitle(']:
    toolbar += block(MAIN, marker) + '\n'
toolbar += block(MAIN, '    var canSaveAudio:') + '\n'
toolbar += block(MAIN, '    func updateNarrationSaveButton()') + '\n'
toolbar += block(MAIN, '    func updateNarrationStats()') + '\n'
toolbar += block(MAIN, '    func updateResultViewButtons()') + '\n'
toolbar += block(MAIN, '    @objc func changeDisplayedText(') + '\n'
toolbar += MAIN[MAIN.index('    func toolbarButton('):MAIN.index('    // Draw matching document icons,')]
toolbar += block(MAIN, '    func saveGlyphImage(')
source = source.replace('// TOOLBAR', toolbar)
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['struct SourceImageReference {', 'func sourceImageReferences(in markdown:', 'final class SourcePageImageAttachment:']:
    source += block(WEB, marker) + '\n'
renderer = MAIN[MAIN.index('    struct MarkdownFence {'):MAIN.index('    // Restore the normal generated result view.')]
renderer += MAIN[MAIN.index('    func markdownAttributedText(from markdown:'):MAIN.index('    // Build the always-visible result toolbar.')]
source = source.replace('// RENDERER', renderer)
source += app_source('ResultTextFormatting.swift') + '\n'
source += next(line for line in MAIN.splitlines() if line.startswith('let defaultExplanationFontSize:')) + '\n'
source += block(MAIN, 'func viewerContentSize(') + '\n'
source += block(MAIN, 'enum PreferencesSection:') + '\n'
source += r'''
var checks = 0
// check(condition, message): Report failed fixture expectations with their case
// names.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
 // Stop this fixture when its named expectation does not hold.
 guard condition() else { fputs("FAILED: " + message + "\n", stderr); exit(1) }
 checks += 1
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
_ = NSApplication.shared
let session = ViewerSession()
check(cleanTitle("\n  ### Сербский\n\nA second heading") == "Сербский", "Markdown requests produce a single heading in window chrome")
check(cleanTitle("Word\r\n## Translation\u{2028}More") == "Word", "CRLF and Unicode line separators cannot enter titles")
check(cleanTitle("C++") == "C++" && cleanTitle("#hashtag") == "#hashtag", "Plain punctuation stays intact")
check(cleanTitle(nil) == "Langmin" && cleanTitle("  \n  ") == "Langmin", "Empty titles keep a stable fallback")
check(appWindowTitle(mode: "Dictionary", title: "### anchor\n## Српски") == "Langmin • Dictionary — anchor", "New Dictionary windows cannot receive multiline titles")
session.config.textPath = root.appendingPathComponent("result.md").path
let drawing = NSImage(size: NSSize(width: 900, height: 600), flipped: false) { rect in
 NSColor(calibratedRed: 0.90, green: 0.95, blue: 1, alpha: 1).setFill(); rect.fill()
 NSColor.systemBlue.setFill(); NSBezierPath(ovalIn: NSRect(x: 270, y: 100, width: 240, height: 240)).fill()
 NSColor.systemGreen.setFill(); NSBezierPath(roundedRect: NSRect(x: 440, y: 110, width: 220, height: 220), xRadius: 40, yRadius: 40).fill()
 return true
}
let png = NSBitmapImageRep(data: drawing.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try png.write(to: root.appendingPathComponent("source-image-1.png"))
session.config.sourceImages = [SourceImageAsset(id: "1", file: "source-image-1.png", sourceURL: URL(string: "https://example.test/diagram.png")!, pageURL: URL(string: "https://example.test/lesson")!)]
session.content = """
# Learning with Langmin

A clear explanation with **bold text**, *emphasis*, and a [source link](https://example.test/lesson).

## Key ideas

- Keep the original meaning.
- Ask a follow-up when something is unclear.
- Save the result to read it again later.

> Short examples help make a new word memorable.

![Two shapes illustrate a shared idea.](langmin-source-image:1)

## Example code

```swift
let greeting = "Hello, world!"
print(greeting)
```

| Word | Meaning |
| --- | --- |
| hello | a greeting |
| goodbye | a farewell |

## Sources
[1] [Lesson notes](https://example.test/lesson)
"""
session.config.conversation = ResultConversation(originalRequest: "Explain this lesson", modelID: "fixture", turns: [
 ResultFollowUpTurn(question: "Can you make it simpler?", answer: "Yes. **Read**, ask, and practise.\n\nUse one example at a time.", modelID: "fixture", modelName: "Example model"),
 ResultFollowUpTurn(question: "", answer: "This reply stays after its question is deleted.", modelID: "fixture", modelName: "Example model"),
 ResultFollowUpTurn(question: "This question stays after its reply is deleted.", answer: "", modelID: "fixture", modelName: "Example model"),
 ResultFollowUpTurn(question: "", answer: "", modelID: "fixture", modelName: "Example model")
])
session.illustrationImage = NSImage(data: png)
session.config.illustrationModel = "gpt-image-1"
check(session.printableResultText().string.contains("OpenAI · gpt-image-1"), "Print captions retain the recorded image model")
session.illustrationImage = nil
session.config.illustrationModel = nil
let original = session.printableResultText()
check(original.string.contains("Can you make it simpler?") && original.string.contains("Use one example at a time."), "Print includes completed questions and replies")
check(!original.string.contains("Copy reply") && !original.string.contains("Delete reply") && !original.string.contains("Replying"), "Print omits interactive controls")
check(original.string.components(separatedBy: "Example model").count == 3, "Deleted replies leave no empty author label")

// info(paper, [scale = 1]): Create print settings with explicit paper size and
// scale for reproducible pagination.
func info(_ paper: NSSize, scale: CGFloat = 1) -> NSPrintInfo {
 let info = NSPrintInfo(dictionary: [:])
 info.paperSize = paper
 info.topMargin = 40; info.bottomMargin = 40; info.leftMargin = 42; info.rightMargin = 42
 info.isHorizontallyCentered = false; info.isVerticallyCentered = false
 info.horizontalPagination = .fit; info.verticalPagination = .automatic
 info.scalingFactor = scale
 return info
}
// verifyLayout(view): Verify that text containers cover the document without
// losing glyphs.
func verifyLayout(_ view: ResultPrintView) {
 var covered = 0
 // Measure each page container's contribution to total rendered content.
 for container in view.layout.textContainers {
  let glyphs = view.layout.glyphRange(for: container)
  check(glyphs.location == covered, "Pages have no missing or duplicated glyphs")
  covered = NSMaxRange(glyphs)
  let used = view.layout.usedRect(for: container)
  check(used.maxY <= container.containerSize.height + 1, "Page content fits above the footer")
 }
 check(covered == view.layout.numberOfGlyphs, "Every glyph reaches a page")
}
// render(name, text, printInfo, [minPages = 1]): Render a document to PDF and
// verify its pagination and link geometry.
func render(_ name: String, text: NSAttributedString, printInfo: NSPrintInfo, minPages: Int = 1) throws {
 let view = ResultPrintView(title: session.titleForLabel(), text: text, fontSize: session.config.fontSize)
 view.paginate(with: printInfo)
 verifyLayout(view)
 let expectedPages = view.layout.textContainers.count
 check(expectedPages >= minPages, "Long content creates multiple pages")
 let url = root.appendingPathComponent(name + ".pdf")
 printInfo.jobDisposition = .save
 printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
 let operation = NSPrintOperation(view: view, printInfo: printInfo)
 operation.showsPrintPanel = false
 operation.showsProgressPanel = false
 check(operation.run(), "Native PDF save succeeds")
 let document = PDFDocument(url: url)!
 check(document.pageCount == expectedPages, "PDF has every laid-out page")
 check(document.string?.contains("Langmin") == true, "PDF text stays selectable")
 // Inspect every exported PDF page for content and annotation bounds.
 for index in 0..<document.pageCount {
  let page = document.page(at: index)!
  let printableArea = page.bounds(for: .mediaBox).insetBy(dx: 40, dy: 38)
  // Keep clickable PDF links inside the printable content area.
  for annotation in page.annotations {
   check(printableArea.contains(annotation.bounds), "PDF link targets stay inside the printed content")
  }
  check(page.string?.contains("Explain") == true && page.string?.contains("Langmin") == true, "Every page has its header and footer")
  let size = page.bounds(for: .mediaBox).size
  check(abs(size.width - printInfo.paperSize.width) < 1 && abs(size.height - printInfo.paperSize.height) < 1, "PDF respects paper size and orientation")
  // Render the saved PDF pages for visual checks.
  let context = CGContext(data: nil, width: Int(size.width * 1.5), height: Int(size.height * 1.5), bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(gray: 1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: size.width * 1.5, height: size.height * 1.5))
  context.scaleBy(x: 1.5, y: 1.5)
  context.drawPDFPage(page.pageRef!)
  let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
  try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("\(name)-\(index + 1).png"))
 }
 // The representative A4 result must include its saved follow-up conversation.
 if name == "result-a4" {
  check(document.string?.contains("Can you make it simpler?") == true, "PDF contains the conversation")
  let links = (0..<document.pageCount).flatMap { document.page(at: $0)!.annotations }.compactMap { $0.action as? PDFActionURL }
  check(links.contains { $0.url?.absoluteString == "https://example.test/lesson" }, "PDF citations stay clickable")
 }
}
try render("result-a4", text: original, printInfo: info(NSSize(width: 595, height: 842)), minPages: 2)
try render("result-letter", text: original, printInfo: info(NSSize(width: 612, height: 792)), minPages: 2)
try render("result-landscape", text: original, printInfo: info(NSSize(width: 842, height: 595)), minPages: 2)
try render("result-scaled", text: original, printInfo: info(NSSize(width: 595, height: 842), scale: 1.5), minPages: 2)
// A single paragraph spanning pages must survive without repeating or dropping text.
session.content = (1...200).map { "Sentence \($0) explains an idea with enough detail to wrap across the page." }.joined(separator: " ")
session.config.conversation = nil
try render("long-paragraph", text: session.printableResultText(), printInfo: info(NSSize(width: 595, height: 842)), minPages: 4)
let longPDF = PDFDocument(url: root.appendingPathComponent("long-paragraph.pdf"))!
let longText = longPDF.string!.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
// Require every numbered sentence to survive long-paragraph pagination.
for index in 1...200 { check(longText.contains("Sentence \(index) "), "Long paragraph retains sentence \(index)") }
// Changing the preview's paper size must discard old containers and reflow the whole document.
let changing = ResultPrintView(title: "Changing paper", text: session.printableResultText(), fontSize: 17)
changing.paginate(with: info(NSSize(width: 595, height: 842)))
let a4Pages = changing.layout.textContainers.count
changing.paginate(with: info(NSSize(width: 400, height: 500)))
verifyLayout(changing)
check(changing.layout.textContainers.count > a4Pages, "Smaller paper reflows content")
changing.paginate(with: info(NSSize(width: 595, height: 842)))
check(changing.layout.textContainers.count == a4Pages, "Restoring paper restores pagination")
// Printing an illustration does not alter the live view's image or narration offsets.
session.content = """
# good night

## English

### Interjection /ɡʊd ˈnaɪt/

1. Used to wish someone a pleasant night or to say goodbye before going to bed.
> *She kissed the children and said good night.*

**Synonyms:** sleep well, night

## Serbian

### Uzvik: laku noć /ˌlaku ˈnɔtɕ/

1. Koristi se da se nekome poželi prijatna noć ili da se pozdravi pre odlaska na spavanje.
> *Poljubila je decu i rekla im laku noć.*

**Sinonimi:** lepo spavaj, prijatna noć
"""
session.illustrationImage = drawing
let illustrated = session.printableResultText()
check(illustrated.string.contains("AI-generated illustration"), "Generated illustration is labelled")
try render("dictionary", text: illustrated, printInfo: info(NSSize(width: 595, height: 842)))
check(session.illustrationImage === drawing && drawing.size.width == 900, "Print leaves the source image untouched")
let darkText = NSMutableAttributedString(attributedString: original)
darkText.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: darkText.length))
let ink = ResultPrintView.paperText(darkText, fontSize: 17)
ink.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: ink.length)) { color, _, _ in
 check((color as! NSColor).usingColorSpace(.genericGray)!.whiteComponent < 0.6, "Print ink remains readable on white paper")
}
// Both result hosts must keep all toolbar buttons inside the window at their minimum width.
for width: CGFloat in [420, 440, 520, 800] {
 // Cover toolbar layouts both with and without a comparison switch.
 for diff in [false, true] {
  // Exercise controls with narration absent and attached.
  for audio in [false, true] {
   // Check idle and generating narration states for each toolbar combination.
   for generating in [false, true] {
    session.isGeneratingNarration = generating
    session.illustrationRunID = generating && !diff ? UUID() : nil
    session.diffAvailable = diff; session.audioAvailable = audio
    session.config.dictionaryHeadword = diff ? nil : "example"
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    let bar = session.makeViewerToolbar(width: width, height: 44)
    bar.frame.origin.y = 8
    window.contentView!.addSubview(bar)
    window.contentView!.layoutSubtreeIfNeeded()
    bar.needsLayout = true; bar.layoutSubtreeIfNeeded()
    let groups = session.resultToolbar!.buttonStack.arrangedSubviews.compactMap { $0 as? ResultToolbarButtonGroup }.filter { !$0.isHidden }
    check(!groups.flatMap { $0.arrangedSubviews }.contains { $0 is NSProgressIndicator }, "Generation adds no toolbar spinners")
    let buttons = groups.flatMap { $0.arrangedSubviews }.compactMap { $0 as? NSButton }
    // Ensure each visible toolbar button fits inside its group and available width.
    for button in groups.flatMap({ $0.arrangedSubviews }).filter({ !$0.isHidden }) {
     let frame = bar.convert(button.bounds, from: button)
     check(frame.minX >= 0 && frame.maxX <= width, "Toolbar buttons fit at \(width) points")
     // Buttons must leave sufficient space for the Result/Diff switch when it exists.
     if let control = session.resultDiffControl, diff {
      check(frame.maxX <= control.frame.minX - 10, "Buttons leave room for Result/Diff")
     }
    }
    check(groups.count == (diff ? 5 : 6), "Copy, Save, Share, narration and Edit have separate groups")
    check(buttons.last?.action == #selector(ViewerSession.editTextFromToolbar(_:)), "The toolbar exposes manual text editing")
    check(!buttons.contains { $0.action == #selector(ViewerSession.printResult(_:)) }, "Printing uses the Share menu instead of a toolbar button")
    check(buttons.first?.action == #selector(ViewerSession.copyTextFromToolbar(_:)), "Copy comes first")
    // Attached audio enables export only when regeneration is not running.
    if audio {
     check(session.saveAudioToolbarButton?.isEnabled == !generating, "Save Audio is disabled during generation")
    }
    let shareButton = buttons.first { $0.action == #selector(ViewerSession.shareFromToolbar(_:)) } as! TooltipButton
    check(shareButton.tooltipMessage == "Share" && (shareButton.superview as! ResultToolbarButtonGroup).arrangedSubviews.count == 1, "Share has its own group and a short tooltip")
    let menuItems = session.makeShareMenu().items
    check(menuItems.first?.action == #selector(ViewerSession.shareTextOnlyFromToolbar(_:)), "Share offers text")
    check(menuItems.contains { $0.action == #selector(ViewerSession.shareTextAndAudioFromToolbar(_:)) } == audio, "Share offers audio only when available")
    check(menuItems[menuItems.count - 2].isSeparatorItem, "Print is separated from sharing options")
    let printItem = menuItems.last!
    check(printItem.title == "Print…" && printItem.action == #selector(ViewerSession.printResult(_:)) && printItem.target === session, "Share menu prints the current result")
    check(printItem.keyEquivalent == "p" && printItem.keyEquivalentModifierMask == .command, "Print displays its keyboard shortcut")
    // Check equal sizing and spacing of the Result/Diff choices.
    if diff, let viewButtons = session.resultDiffControl {
     let choices = viewButtons.arrangedSubviews.compactMap { $0 as? NSButton }
     session.textView = NSTextView()
     check(choices.count == 2 && choices.allSatisfy(\.isEnabled), "Both outlined view choices remain clickable")
     choices[1].performClick(nil)
     check(session.diffShown && session.textView!.string == "Fixture diff", "Diff button displays the comparison")
     check(choices[1].state == .on && choices[0].state == .off, "Only Diff is selected")
     choices[1].performClick(nil)
     check(choices[1].state == .on, "Clicking the current view keeps it selected")
     choices[0].performClick(nil)
     check(!session.diffShown && session.textView!.string == session.content, "Result button restores the original result")
     check(choices[0].state == .on && choices[1].state == .off, "Only Result is selected")
    }
    // Capture the compact layout when the full audio toolbar is present.
    if width == 440 && audio {
     // Inspect compact toolbar appearance in both light and dark modes.
     for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
      window.appearance = NSAppearance(named: appearance)
      window.contentView!.wantsLayer = true
      window.contentView!.layer!.backgroundColor = NSColor(calibratedWhite: appearance == .aqua ? 0.96 : 0.12, alpha: 1).cgColor
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 880, pixelsHigh: 120, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
      bitmap.size = window.contentView!.bounds.size
      window.contentView!.cacheDisplay(in: window.contentView!.bounds, to: bitmap)
      let name = "toolbar-" + (diff ? "diff" : "dictionary") + (generating ? "-regenerating" : "") + (appearance == .aqua ? "-light.png" : "-dark.png")
      try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
     }
    }
   }
  }
 }
}
// Fixed toolbar actions stay present while audio and text availability change.
session.diffAvailable = false; session.audioAvailable = false
session.config.dictionaryHeadword = nil
let compact = session.makeViewerToolbar(width: 440, height: 44) as! ResultToolbarView
func visibleItems(_ bar: ResultToolbarView) -> [NSView] { bar.buttonStack.arrangedSubviews.filter { !$0.isHidden } }
check(visibleItems(compact).count == 5, "Copy, Save, Share, narration and Edit are always offered for text")
let audioButton = session.toolbarButton(image: session.saveGlyphImage(audio: true), fallbackTitle: "Audio", tooltip: "Save Audio", action: #selector(ViewerSession.saveAudioFromToolbar(_:)))
compact.addButton(audioButton, to: .save)
check(visibleItems(compact).count == 5, "New audio joins the existing Save group")
compact.removeButton(audioButton)
check(visibleItems(compact).count == 5, "Removing audio preserves text export")
let previousContent = session.content
session.content = ""
let empty = session.makeViewerToolbar(width: 440, height: 44) as! ResultToolbarView
check(visibleItems(empty).count == 4, "Empty results omit narration while retaining the other actions")
session.content = previousContent
// The screenshot's details include a text model and voice, never a speech model.
session.config.textModel = "Fixture text model"
session.config.languageLevel = "b"
session.narrationVoiceUsed = "Fixture voice"
session.narrationModelUsed = "Fixture speech model TTS"
session.audioAvailable = true
session.updateNarrationStats()
check(session.statsLabel?.stringValue == "Model: Fixture text model · Level: B · Voice: Fixture voice", "Model details retain the voice without a speech model")
session.audioAvailable = false
session.updateNarrationStats()
check(session.statsLabel?.stringValue == "Model: Fixture text model · Level: B", "Removing audio removes voice details")
check(defaultExplanationFontSize == 14, "Results use the fixed 14-point default")
check(!PreferencesSection.allCases.map(\.rawValue).contains("window"), "Settings no longer contains a Window page")
for screen in [NSRect(x: 0, y: 0, width: 1280, height: 800), NSRect(x: 0, y: 0, width: 1920, height: 1080)] {
 let size = viewerContentSize(for: screen)
 check(size.width > size.height && size.width <= screen.width - 40 && size.height <= screen.height - 40,
       "Separate result windows use landscape sizing within the screen")
}
session.isGeneratingNarration = false
session.illustrationRunID = nil
// Header actions use the same group, with complete hover fills at its ends and center.
let headerWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
let header = session.makeEmbeddedHeader()
headerWindow.contentView!.addSubview(header)
NSLayoutConstraint.activate([
 header.leadingAnchor.constraint(equalTo: headerWindow.contentView!.leadingAnchor),
 header.trailingAnchor.constraint(equalTo: headerWindow.contentView!.trailingAnchor),
 header.topAnchor.constraint(equalTo: headerWindow.contentView!.topAnchor),
 header.bottomAnchor.constraint(equalTo: headerWindow.contentView!.bottomAnchor)
])
headerWindow.contentView!.layoutSubtreeIfNeeded()
let headerGroup = header.subviews.compactMap { $0 as? ResultToolbarButtonGroup }.first!
let headerButtons = headerGroup.arrangedSubviews.compactMap { $0 as? TooltipButton }
check(headerButtons.count == 3 && headerGroup.bounds.width == 84, "Header actions form one compact group")
check(abs(header.bounds.maxX - headerGroup.frame.maxX - 6) < 0.1, "Header keeps its right inset")
check(headerButtons.map(\.action) == [#selector(ViewerSession.saveToLibraryFromToolbar(_:)), #selector(ViewerSession.detachFromHostRequested(_:)), #selector(ViewerSession.closeFromHostRequested(_:))], "Header actions keep their order and targets")
let activity = session.resultActivitySpinner!
check(activity.isHidden, "Idle results have no loader")
// Finish or cancel either task first; the other must keep the shared loader visible.
for (image, audio) in [(true, false), (true, true), (false, true), (false, false), (false, true), (true, true), (true, false), (false, false)] {
 session.illustrationRunID = image ? UUID() : nil
 session.isGeneratingNarration = audio
 headerWindow.contentView!.layoutSubtreeIfNeeded()
 check(session.resultActivitySpinner === activity, "Both tasks use the same title loader")
 check(activity.isHidden == !(image || audio), "Loader tracks overlapping generation")
 check((activity.toolTip?.contains("illustration") ?? false) == image, "Loader describes pending image generation")
 check((activity.toolTip?.contains("narration") ?? false) == audio, "Loader describes pending audio generation")
 // Image or audio activity must fit beside the result title.
 if image || audio {
  let label = session.resultTitleLabel!
  let titleFrame = header.convert(label.alignmentRect(forFrame: label.bounds), from: label)
  let loaderFrame = header.convert(activity.bounds, from: activity)
  check(abs(loaderFrame.minX - titleFrame.maxX - 8) < 0.1, "Loader follows the title by 8 points")
  check(activity.frame.width == 12, "Title loader keeps its compact size")
 }
}
// Multiline persisted titles must also fit the inline header during both kinds of generation.
session.config.title = "Langmin • Dictionary — anchor\n\n### Сербский\nAnother line"
session.isEmbedded = true
session.setResultTitleMessage("Preparing\nnarration…")
check(session.resultTitleLabel!.stringValue == "Dictionary — anchor — Preparing narration…", "Inline titles and temporary messages remain one line")
headerWindow.contentView!.layoutSubtreeIfNeeded()
check(session.resultTitleLabel!.frame.height < 24, "Multiline input cannot grow the header label")
session.applyRenamedLibraryTitle("Langmin • Dictionary — renamed\n### Serbian")
check(session.resultTitleLabel!.stringValue == "Dictionary — renamed — Preparing narration…", "Library rename preserves status without restoring multiline titles")
session.setResultTitleMessage(nil)
session.isEmbedded = false

// Long titles truncate before the loader and header actions.
session.illustrationRunID = UUID()
session.resultTitleLabel!.stringValue = String(repeating: "A long dictionary title ", count: 8)
// Check title-bar accessories at compact and wider window widths.
for width: CGFloat in [320, 440] {
 headerWindow.setContentSize(NSSize(width: width, height: 40))
 headerWindow.contentView!.layoutSubtreeIfNeeded()
 let loaderFrame = header.convert(activity.bounds, from: activity)
 check(loaderFrame.maxX <= headerGroup.frame.minX - 12, "Long titles leave room for loader and actions")
 check(activity.frame.width == 12 && session.resultTitleLabel!.frame.width > 0, "Narrow headers keep title and loader visible")
}
session.config.title = "Dictionary — Love"
session.resultTitleLabel!.stringValue = session.config.title
headerWindow.contentView!.layoutSubtreeIfNeeded()
let hoverEvent = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
// Capture header controls in both system appearances.
for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
 headerWindow.appearance = NSAppearance(named: appearance)
 headerWindow.contentView!.wantsLayer = true
 headerWindow.contentView!.layer!.backgroundColor = NSColor(calibratedWhite: appearance == .aqua ? 0.96 : 0.12, alpha: 1).cgColor
 // Inspect each header button's hover appearance in turn.
 for (index, button) in headerButtons.enumerated() {
  button.mouseEntered(with: hoverEvent)
  // Compare hovered and pressed states for each header action.
  for pressed in [false, true] {
   button.isHighlighted = pressed
   let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 880, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
   bitmap.size = headerWindow.contentView!.bounds.size
   headerWindow.contentView!.cacheDisplay(in: headerWindow.contentView!.bounds, to: bitmap)
   let name = "header-\(index)-" + (pressed ? "pressed" : "hover") + (appearance == .aqua ? "-light.png" : "-dark.png")
   try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
  }
  button.isHighlighted = false
  button.mouseExited(with: hoverEvent)
 }
}
// Moving an active result to a native title bar restores the shared loader.
activity.stopAnimation(nil)
let resultWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
session.config.title = "Langmin • Dictionary — anchor\n\n### Сербский\nAnother heading"
session.installResultTitlebarTitle(on: resultWindow)
resultWindow.layoutIfNeeded()
let titlebarActivity = session.resultActivitySpinner!
check(session.resultTitleLabel!.stringValue == "Langmin • Dictionary — anchor", "Native title bars sanitize older saved multiline titles")
// Repeated activity transitions must not grow or clip the result title bar.
for pending in [true, false, true] {
 session.illustrationRunID = pending ? UUID() : nil
 resultWindow.layoutIfNeeded()
 let label = session.resultTitleLabel!
 let container = session.resultTitleContainer!
 let labelFrame = container.convert(label.bounds, from: label)
 check(label.usesSingleLineMode && label.maximumNumberOfLines == 1, "Native title remains explicitly single-line")
 check(labelFrame.height < 24 && labelFrame.minY >= 0 && labelFrame.maxY <= container.bounds.height, "Native title fits vertically when the spinner changes")
 check(abs(labelFrame.midY - container.bounds.midY) < 1, "Title remains centered beside traffic lights")
}

// Capture the native title strip with the original malformed title and an active image loader.
NSApp.setActivationPolicy(.accessory)
NSApp.finishLaunching()
resultWindow.appearance = NSAppearance(named: .darkAqua)
resultWindow.orderBack(nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
resultWindow.layoutIfNeeded()
// Capture the native title-bar strip when its frame view is available.
if let frameView = resultWindow.contentView?.superview {
 let strip = NSRect(x: 0, y: frameView.bounds.maxY - 50, width: frameView.bounds.width, height: 50)
 let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(strip.width * 2), pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
 bitmap.size = strip.size
 frameView.cacheDisplay(in: strip, to: bitmap)
 try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("native-title-multiline.png"))
}
check(!titlebarActivity.isHidden && titlebarActivity !== activity, "Native title bar restores pending generation")
session.isGeneratingNarration = true
session.illustrationRunID = nil
check(!titlebarActivity.isHidden, "Native title loader keeps running for narration")
session.isGeneratingNarration = false
check(titlebarActivity.isHidden, "Native title loader stops when generation ends")
let base = PDFDocument(url: root.appendingPathComponent("result-a4.pdf"))!
let scaled = PDFDocument(url: root.appendingPathComponent("result-scaled.pdf"))!
let baseHeading = base.findString("Key ideas", withOptions: [])[0].bounds(for: base.page(at: 0)!)
let scaledHeading = scaled.findString("Key ideas", withOptions: [])[0].bounds(for: scaled.page(at: 0)!)
check(abs(scaledHeading.height / baseHeading.height - 1.5) < 0.1, "150% scaling enlarges the printed type")
print("\(checks) printing checks passed; PDFs saved only in the test folder")
'''
with tempfile.TemporaryDirectory(prefix='langmin-print-tests-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', *swift_fixture_args(), '-module-cache-path', cache, '-target', f'{platform.machine()}-apple-macos14.0',
                    str(folder / 'main.swift'), str(app_path('ResultConversation.swift')),
                    str(app_path('ResultPrinting.swift')), '-o', str(folder / 'tests')], check=True)
    subprocess.run([str(folder / 'tests'), directory], check=True, timeout=60)
    # Retain rendered artifacts only when a destination was explicitly requested.
    if target := os.environ.get('LANGMIN_TEST_ARTIFACTS'):
        output = Path(target)
        output.mkdir(parents=True, exist_ok=True)
        # Copy rendered fixture artifacts to the explicitly requested output directory.
        for artifact in folder.iterdir():
            # Retain rendered images and PDFs, excluding intermediate fixture files.
            if artifact.suffix in ('.png', '.pdf'):
                shutil.copyfile(artifact, output / artifact.name)
