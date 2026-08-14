#!/usr/bin/env python3
"""Exercise rich-text editing, Markdown round trips and atomic Library updates in isolated fixtures."""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile

from source_files import ROOT, app_path, app_source, swift_fixture_args
MAIN = app_source('main.swift')
EDITOR = app_source('ResultTextEditor.swift')


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


# Share the existing renderer fixture's setup; its executable checks start after this boundary.
builder = (ROOT / 'scripts/test_result_diff.py').read_text().split("source += r'''\n_ = NSApplication.shared")[0]
namespace = {'__file__': str(ROOT / 'scripts/test_result_diff.py')}
exec(compile(builder, 'renderer-fixture', 'exec'), namespace)
source = namespace['source'].replace('struct SourceImageAsset {', 'struct SourceImageAsset: Codable {')
source = source.replace('var config = Config()', 'var config = ViewerConfig(textPath: "", fontSize: 17, audioPath: "", title: "Fixture", cleanupDir: "")')
source = source.replace('final class ViewerSession {', r'''
// Suppress unrelated palette behavior in the editor fixture.
final class EditorFixturePanel { /* closePalette(): Keep palette dismissal inert in this isolated fixture. */ func closePalette() {} }
// Supply the Library notification interface without accessing a real Library.
final class EditorFixtureLauncher { /* libraryDidChange(): Ignore library notifications in the isolated editor fixture. */ func libraryDidChange() {} }
// Provide the minimal app-delegate surface needed by editor completion.
final class EditorFixtureDelegate {
 let launcherController = EditorFixtureLauncher()
 // updateMenuForActiveWindow(): Keep this production dependency inactive in the
 // isolated fixture.
 func updateMenuForActiveWindow() {}
}
// Host production editor and rendering methods with isolated files and controls.
final class ViewerSession: NSObject, NSWindowDelegate {
 var content = ""
 var resourcesReleased = false, isGeneratingNarration = false
 var hudNarration: NSObject?
 var followUpRunID: UUID?, illustrationRunID: UUID?
 var followUpModelPanel: EditorFixturePanel?
 var saveToLibraryButton: NSButton?
 var textEditor: ResultTextEditorView?
 var editingReplyID: String?
 var editorHiddenViews: [NSView] = []
 var savedLibraryID: String?
 var activeAudioPath = "", generatedAudioCleanupDir = ""
 var pronounceCache: [String: URL] = [:]
 var pronunciationCleanupDirs: Set<String> = []
 var narrationVoiceUsed: String?, narrationModelUsed: String?
 var saveAudioToolbarButton: NSButton?
 var resultToolbar: ResultToolbarView? = ResultToolbarView(frame: .zero)
 var audioControlsBar: NSView?, viewerRootView: NSView?, followUpComposer: NSView?
 var scrollViewBottomConstraint: NSLayoutConstraint?
 var playButton: NSButton?, progressSlider: NSSlider?
 var currentTimeLabel: NSTextField?, durationTimeLabel: NSTextField?
 var diffShown = false
 var narrationSegments: [Int] = []
 var viewerScrollView: NSScrollView?
 var hostWindow: NSWindow? { window }
 var narrationButton: NSButton?
 var appDelegate: EditorFixtureDelegate? = EditorFixtureDelegate()
 var errors: [String] = []
 // presentViewerError(title, details): Collect editor-save errors instead of
 // opening a viewer error dialog.
 func presentViewerError(_ title: String, details: String) { errors.append(title) }
 // removeNarrationCursorAttributes(): Keep this production dependency inactive
 // in the isolated fixture.
 func removeNarrationCursorAttributes() {}
 // stopAudio(): Keep this production dependency inactive in the isolated
 // fixture.
 func stopAudio() {}
 // stopHeadwordPronunciation(): Keep this production dependency inactive in the
 // isolated fixture.
 func stopHeadwordPronunciation() {}
 // clearNarrationHighlight(): Keep this production dependency inactive in the
 // isolated fixture.
 func clearNarrationHighlight() {}
 // updateResultViewButtons(): Keep this production dependency inactive in the
 // isolated fixture.
 func updateResultViewButtons() {}
 // applyResultText(): Refresh displayed text through the production Markdown
 // renderer.
 func applyResultText() { textView?.textStorage?.setAttributedString(markdownAttributedText(from: content)) }
 // narrationTooltip(): Use a fixed narration tooltip unrelated to the editing
 // assertions.
 func narrationTooltip() -> String { "Fixture" }
 // updateNarrationStats(): Keep this production dependency inactive in the
 // isolated fixture.
 func updateNarrationStats() {}
 // updateSaveToLibraryButton(): Keep this production dependency inactive in the
 // isolated fixture.
 func updateSaveToLibraryButton() {}
''')
# Draw the actual toolbar controls, keeping tooltip windows out of the fixture.
source += block(MAIN, 'let langminControlBorderColor =') + '\n'
tooltip = block(MAIN, 'final class TooltipButton:')
tooltip = tooltip.replace(block(tooltip, '    private func showTooltip()'), '    private func showTooltip() {}')
source += tooltip + '\n'
source += block(MAIN, 'final class ResultToolbarButtonGroup:') + '\n'
source += block(MAIN, 'final class ResultToolbarView:') + '\n'
source += EDITOR[:EDITOR.index('extension LibraryStore {')]
# Exercise the launcher's real keyboard handlers without its unrelated file-drop/OCR code.
source += "final class AudioFileImportController {}\n"
launcher_start = MAIN.index('final class LauncherInputView:')
source += MAIN[launcher_start:MAIN.index('    override func didChangeText()', launcher_start)] + '}\n'

# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['struct ViewerConfig {', 'struct LibraryEntry:', 'struct PronunciationRef:', 'struct NarrationChunkTiming:']:
    source += block(MAIN, marker) + '\n'
source += r'''
// Keep saved-entry fixtures underneath the task's temporary directory.
enum LibraryStore {
 // entryDirectory(id): Resolve an entry ID only within the fixture root.
 static func entryDirectory(id: String) -> URL { root.appendingPathComponent(id) }
 // invalidateEntryCache(): Keep this production dependency inactive in the
 // isolated fixture.
 static func invalidateEntryCache() {}
}
'''
source += block(EDITOR, 'extension LibraryStore {')
source += '\nextension ViewerSession {\n'
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['    func beginTextEditing(', '    func finishTextEditing(', '    func cancelTextEditing()', '    func confirmEndingTextEdit()',
               '    var hasAttachedNarration:', '    var editAudioRemovalWarning:', '    func removeAudioAfterTextEdit()',
               '    @objc func windowShouldClose(']:
    source += block(EDITOR, marker) + '\n'
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['    func dropExistingAudio(', '    func removeAudioControlsBar()', '    var audioAvailable:']:
    source += block(MAIN, marker) + '\n'
# Exercise the editor's real Escape routing without adding unrelated speech or follow-up providers.
source += block(MAIN, '    func handleEscapeKey()').split('        if followUpRunID')[0] + '        return false\n    }\n'
source += block(app_source('ResultFollowUp.swift'), '    var exportedResultMarkdown:') + '\n}\n'
source += r'''
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
NSApp.finishLaunching()
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let session = ViewerSession()
var checks = 0
// check(condition, message): Report failed fixture expectations with their case
// names.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
 // Stop this fixture when its named expectation does not hold.
 guard condition() else { fputs("FAILED: \(message)\n", stderr); exit(1) }
 checks += 1
}
// editor(markdown): Construct an editor using production editable Markdown
// rendering.
func editor(_ markdown: String) -> ResultTextEditorView {
 ResultTextEditorView(markdown: markdown, text: session.markdownAttributedText(from: markdown, forEditing: true), fontSize: 17)
}
// select(value, editor): Select a named text range before applying a formatting
// command.
func select(_ value: String, in editor: ResultTextEditorView) {
 let range = (editor.input.string as NSString).range(of: value)
 check(range.location != NSNotFound, "Selection exists: \(value)")
 editor.input.setSelectedRange(range)
}
let original = """
# Meaning of Cosmos

**Cosmos** usually means the universe, with *many* galaxies.

## Russian

Космос — это Вселенная. [1]

1. First example
   - Nested example
2. Second example

> Keep this quotation.

| Name | Value |
| --- | --- |
| Cosmos | Universe |

```swift
let cosmos = "<u>not underline</u>"
```

## Sources
[1] [Reference](https://example.test/reference)
"""
let draft = editor(original)
check(!draft.hasChanges && draft.markdown == original, "Entering and leaving Edit preserves exact source")
check(draft.input.string == session.markdownAttributedText(from: original).string, "Editing retains the rendered content")
select("usually", in: draft)
draft.format("b")
check(draft.hasChanges, "Formatting marks the draft changed")
check(draft.markdown.contains("**usually**"), "Bold uses Markdown")
check(draft.markdown.contains("1. First example\n   - Nested example\n2. Second example"), "Untouched nested lists retain their source")
check(draft.markdown.contains("| Name | Value |\n| --- | --- |"), "Untouched tables retain their source")
check(draft.markdown.contains("```swift\nlet cosmos = \"<u>not underline</u>\"\n```"), "Untouched code retains language and literal tags")
check(draft.markdown.contains("[1] [Reference](https://example.test/reference)"), "Sources survive unrelated edits")
check(session.markdownAttributedText(from: draft.markdown).string == draft.input.string, "Formatting does not change visible text")
draft.input.undoManager!.undo()
check(!draft.hasChanges && draft.markdown == original, "Undo restores the original result and formatting")
draft.input.undoManager!.redo()
check(draft.hasChanges, "Redo reapplies formatting")

// Check italic, underline, and strikethrough command serialization.
for (key, marker) in [("i", "*word*"), ("u", "<u>word</u>"), ("s", "~~word~~")] {
 let value = editor("A word here.")
 select("word", in: value)
 value.format(key)
 check(value.markdown.contains(marker), "Formatting emits \(key)")
 let rendered = session.markdownAttributedText(from: value.markdown)
 check(rendered.string == "A word here.", "\(key) round trip retains text: \(rendered.string)")
 let index = (rendered.string as NSString).range(of: "word").location
 check(value.isActive(key, attributes: rendered.attributes(at: index, effectiveRange: nil)), "\(key) survives reopening")
}
// attributes(needle, text): Text size and baseline are independent inline
// styles, including complete source entries.
func attributes(_ needle: String, in text: NSAttributedString) -> [NSAttributedString.Key: Any] {
 let range = (text.string as NSString).range(of: needle)
 check(range.location != NSNotFound, "Formatted text retains \(needle)")
 return text.attributes(at: range.location, effectiveRange: nil)
}
let sizedLink = editor("Judo. [Cambridge Dictionary](https://example.test/karate)")
select("Cambridge Dictionary", in: sizedLink)
sizedLink.setFontSize(12)
let sizedReopened = session.markdownAttributedText(from: sizedLink.markdown)
let sizedAttributes = attributes("Cambridge Dictionary", in: sizedReopened)
check((sizedAttributes[.font] as? NSFont)?.pointSize == 12, "A smaller reference link keeps its exact size after saving")
check((sizedAttributes[.link] as? URL)?.absoluteString == "https://example.test/karate", "Resizing keeps the original link destination")
check((attributes("Judo", in: sizedReopened)[.font] as? NSFont)?.pointSize == session.config.fontSize, "Resizing a selection leaves surrounding text unchanged")
sizedLink.input.undoManager!.undo()
check(!sizedLink.hasChanges, "One undo restores the original font size")
sizedLink.input.undoManager!.redo()
check(sizedLink.hasChanges, "Font-size changes support redo")
select("Judo. Cambridge Dictionary", in: sizedLink)
sizedLink.refreshFormatState()
check(sizedLink.sizeMenu.title == "—", "Mixed text sizes are shown as mixed")
sizedLink.sizeMenu.selectItem(withTitle: "14")
sizedLink.changeFontSize(sizedLink.sizeMenu)
check((attributes("Judo", in: sizedLink.input.attributedString())[.font] as? NSFont)?.pointSize == 14, "The toolbar size picker applies a uniform size to mixed text")
let emptySize = editor("")
emptySize.setFontSize(11)
emptySize.format("sup")
emptySize.input.insertText("note", replacementRange: emptySize.input.selectedRange())
let typedAttributes = attributes("note", in: session.markdownAttributedText(from: emptySize.markdown))
check(ResultTextFormatting.baseSize(in: typedAttributes) == 11 && ResultTextFormatting.script(in: typedAttributes) == 1, "New typing retains its chosen size and superscript through saving")

var citationRevision = "Citation [1][2]."
// Repeat citation edits to catch cumulative size or baseline drift.
for pass in 1...4 {
 let citation = editor(citationRevision)
 select("[1][2]", in: citation)
 check(citation.formatButtons["sup"]?.state == .on, "Existing raised citations activate the superscript button")
 citation.format("sup")
 let baseline = session.markdownAttributedText(from: citation.markdown)
 check(ResultTextFormatting.script(in: attributes("[1]", in: baseline)) == 0, "Turning superscript off survives automatic citation formatting")
 check((attributes("[2]", in: baseline)[.font] as? NSFont)?.pointSize == session.config.fontSize, "Turning superscript off restores the full base size")
 citation.input.undoManager!.undo()
 check(!citation.hasChanges, "Superscript changes are undoable")
 citation.format("sup")
 citation.format("sup")
 citationRevision = citation.markdown
 let raised = attributes("[1]", in: session.markdownAttributedText(from: citationRevision))
 check(abs((raised[.font] as! NSFont).pointSize - session.config.fontSize * 0.72) < 0.01, "Repeated edits do not shrink superscript again (pass \(pass))")
}
let manualSup = editor("Read [reference](https://example.test/ref).")
select("reference", in: manualSup)
manualSup.format("b")
manualSup.format("sup")
manualSup.setFontSize(14)
let raisedLink = attributes("reference", in: session.markdownAttributedText(from: manualSup.markdown))
check(ResultTextFormatting.script(in: raisedLink) == 1 && ResultTextFormatting.baseSize(in: raisedLink) == 14, "Explicit superscript and size combine on a link")
check(raisedLink[.link] != nil && manualSup.isActive("b", attributes: raisedLink), "Sizing superscript preserves bold text and links")
manualSup.format("sup")
check((attributes("reference", in: manualSup.input.attributedString())[.font] as? NSFont)?.pointSize == 14, "Leaving superscript restores the chosen size")

// Subscript shares the baseline controls, while code remains editable Markdown with emphasis and links.
let chemical = editor("H2O")
select("2", in: chemical)
chemical.formatButtons["sub"]!.performClick(nil)
check(chemical.formatButtons["sub"]!.state == .on && chemical.formatButtons["sup"]!.state == .off, "The subscript button indicates the selected baseline")
check(chemical.markdown.contains("<sub>2</sub>"), "Subscript is saved explicitly")
let lowered = attributes("2", in: session.markdownAttributedText(from: chemical.markdown))
check(ResultTextFormatting.script(in: lowered) == -1 && (lowered[.baselineOffset] as! CGFloat) < 0, "Subscript remains below the baseline after reopening")
chemical.input.undoManager!.undo()
check(!chemical.hasChanges, "Subscript is one undoable change")
chemical.format("sub")
chemical.format("sup")
check(chemical.formatButtons["sub"]!.state == .off && chemical.formatButtons["sup"]!.state == .on, "Superscript and subscript are mutually exclusive")
chemical.format("sup")
check((attributes("2", in: chemical.input.attributedString())[.font] as! NSFont).pointSize == session.config.fontSize, "Changing baseline twice restores the original text size")
let typedSub = editor("")
typedSub.format("sub")
typedSub.input.insertText("2", replacementRange: typedSub.input.selectedRange())
check(ResultTextFormatting.script(in: attributes("2", in: session.markdownAttributedText(from: typedSub.markdown))) == -1, "Subscript can be selected before typing")

// Check inline code across plain, bold, linked, and bold-linked text.
for source in ["Use value here.", "Use **value** here.", "Use [value](https://example.test/code) here.", "Use **[value](https://example.test/code)** here."] {
 let code = editor(source)
 select("value", in: code)
 let before = attributes("value", in: code.input.attributedString())
 code.formatButtons["code"]!.performClick(nil)
 check(code.markdown.contains(before[.link] == nil ? "`value`" : "<code>value</code>"), "The code button saves inline code, including linked labels")
 let reopened = session.markdownAttributedText(from: code.markdown)
 let styled = attributes("value", in: reopened)
 check(styled[.langminInlineCode] != nil && (styled[.font] as! NSFont).isFixedPitch, "Inline code reopens in a monospaced font: \(source) → \(code.markdown); font: \(styled[.font]!)")
 check(abs((styled[.font] as! NSFont).pointSize - (before[.font] as! NSFont).pointSize) < 0.01, "Inline code keeps the chosen text size")
 check(code.isActive("b", attributes: styled) == code.isActive("b", attributes: before), "Inline code preserves bold emphasis: \(source) → \(code.markdown); font: \(styled[.font]!)")
 check((styled[.link] as? URL) == (before[.link] as? URL), "Inline code preserves the selected link")
 code.input.undoManager!.undo()
 check(!code.hasChanges, "Inline code can be undone in one step")
 code.input.undoManager!.redo()
 code.format("code")
 check(!code.markdown.contains("`value`") && !code.markdown.contains("<code>") && !code.isActive("code", attributes: attributes("value", in: code.input.attributedString())), "The code button toggles back to ordinary text")
}
let literalCode = editor("Use \\`value\\` here.")
select("`value`", in: literalCode)
literalCode.format("code")
check(session.markdownAttributedText(from: literalCode.markdown).string == literalCode.input.string, "Code containing literal backticks round trips without changing text")
let typingCode = editor("")
typingCode.format("code")
typingCode.input.insertText("value", replacementRange: typingCode.input.selectedRange())
check(attributes("value", in: session.markdownAttributedText(from: typingCode.markdown))[.langminInlineCode] != nil, "Inline code can be selected before typing")
let existingCode = editor("Use `value` here.")
select("here", in: existingCode)
existingCode.format("b")
check(existingCode.markdown.contains("`value`"), "Editing beside existing code keeps its padded final character inside one code span")
check(session.markdownAttributedText(from: existingCode.markdown).string == existingCode.input.string, "Editing beside code does not add stray backticks")

// Check list and quote conversion across multiple selected paragraphs.
for (key, prefix) in [("bullets", "- "), ("numbers", "1. "), ("quote", "> ")] {
 let paragraphs = editor("First **item**.\n\nSecond item.")
 paragraphs.input.selectAll(nil)
 paragraphs.formatButtons[key]!.performClick(nil)
 check(paragraphs.markdown.hasPrefix(prefix) && paragraphs.markdown.contains("**item**"), "The \(key) button formats selected paragraphs and retains emphasis")
 check(paragraphs.formatButtons[key]!.state == .on, "The \(key) button reflects the current paragraph style")
 paragraphs.input.undoManager!.undo()
 check(!paragraphs.hasChanges, "Paragraph shortcut \(key) is one undoable edit")
 paragraphs.input.undoManager!.redo()
 paragraphs.format(key)
 check(paragraphs.formatButtons[key]!.state == .off && !paragraphs.markdown.hasPrefix(prefix), "The \(key) button toggles back to paragraphs")
}

let smallFooter = editor("Text.\n\n## Sources\n[1] [Cambridge Dictionary](https://example.test/karate)")
select("[1] Cambridge Dictionary", in: smallFooter)
smallFooter.setFontSize(11)
select("Sources", in: smallFooter)
smallFooter.setFontSize(12)
var footerRevision = smallFooter.markdown
// Repeat source-footer edits to catch formatting and spacing drift.
for pass in 1...3 {
 let footer = editor(footerRevision)
 check((attributes("[1]", in: footer.input.attributedString())[.font] as? NSFont)?.pointSize == 11, "Source numbers keep their selected size (pass \(pass))")
 check((attributes("Cambridge Dictionary", in: footer.input.attributedString())[.font] as? NSFont)?.pointSize == 11, "Source links keep their selected size")
 check((attributes("Sources", in: footer.input.attributedString())[.font] as? NSFont)?.pointSize == 12, "Sources headings keep their selected size")
 check(ResultTextFormatting.script(in: attributes("[1]", in: footer.input.attributedString())) == 0, "Resized source numbers stay on the baseline")
 check(footer.input.string.components(separatedBy: "Sources").count == 2, "Customized Sources stay a single footer")
 select("[1] Cambridge Dictionary", in: footer)
 check(footer.sizeMenu.title == "11", "Reference spacing does not make a uniform text size appear mixed")
 select("Cambridge Dictionary", in: footer)
 footer.format("i")
 footerRevision = footer.markdown
}
let partialCitation = editor("Citation [12].")
select("12", in: partialCitation)
partialCitation.setFontSize(11)
let partialCitationAttributes = attributes("12", in: session.markdownAttributedText(from: partialCitation.markdown))
check(abs((partialCitationAttributes[.font] as! NSFont).pointSize - 11 * 0.72) < 0.01, "Automatic citations preserve individually resized digits")
let partialNumber = editor("Text.\n\n## Sources\n[12] [Reference](https://example.test)")
select("12", in: partialNumber)
partialNumber.format("b")
partialNumber.setFontSize(10)
let partialNumberReopened = session.markdownAttributedText(from: partialNumber.markdown)
check((attributes("12", in: partialNumberReopened)[.font] as? NSFont)?.pointSize == 10, "Partially styled source numbers preserve their size")
check(partialNumber.isActive("b", attributes: attributes("12", in: partialNumberReopened)), "Partially styled source numbers preserve their emphasis")
let nestedStyles = session.markdownAttributedText(from: #"<span style="font-size: 12pt"><sup>outer <span style="font-size: 16pt">inner</span></sup></span>"#)
check(ResultTextFormatting.baseSize(in: attributes("outer", in: nestedStyles)) == 12, "Outer sizes apply to superscripts")
check(ResultTextFormatting.baseSize(in: attributes("inner", in: nestedStyles)) == 16, "Inner sizes override outer sizes")
// Keep escaped or code-quoted formatting tags literal.
for literal in [#"`<sup>[1]</sup>`"#, #"\<sup>[1]\</sup>"#, #"`<span style="font-size: 12pt">small</span>`"#] {
 let rendered = session.markdownAttributedText(from: literal)
 check(rendered.string.contains("<"), "Code and escaped tag examples remain literal")
}
// Reject invalid font-size values before they reach editor typography.
for invalid in ["0", "-4", "nan", "999999"] {
 let prepared = ResultTextFormatting.prepareInlineStyles("<span style=\"font-size: \(invalid)pt\">word</span>")
 check(prepared.markers.isEmpty, "Invalid text sizes are not interpreted")
}

let combined = editor("word")
select("word", in: combined)
// Apply combined font and decoration styles to the same selection.
for key in ["b", "i", "u"] { combined.format(key) }
let combinedText = session.markdownAttributedText(from: combined.markdown)
check(combinedText.string == "word", "Combined inline styles preserve text")
// Verify that every combined style survives serialization and rendering.
for key in ["b", "i", "u"] {
 check(combined.isActive(key, attributes: combinedText.attributes(at: 0, effectiveRange: nil)), "Combined style \(key) survives")
}
// Check partial selections inside already styled words.
for (source, selection, key) in [("**Cosmos**", "sm", "i"), ("*Cosmos*", "Cos", "b")] {
 let partial = editor(source)
 select(selection, in: partial)
 partial.format(key)
 let rendered = session.markdownAttributedText(from: partial.markdown)
 check(rendered.string == "Cosmos", "Partial-word formatting preserves text: \(partial.markdown)")
 let selectedIndex = (rendered.string as NSString).range(of: selection).location
 check(partial.isActive(key, attributes: rendered.attributes(at: selectedIndex, effectiveRange: nil)), "Partial-word formatting survives reopening: \(partial.markdown)")
}
let literalTags = session.markdownAttributedText(from: #"\<u\>literal\</u\> and <u>underlined</u> and `<u>code</u>`"#)
check(literalTags.string == "<u>literal</u> and underlined and <u>code</u>", "Escaped tags and code remain literal beside real underlines")
check(literalTags.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil, "Literal underline tags do not apply formatting")

// Editing one line must preserve a code block's boundaries, blank lines and language.
let codeDraft = editor("```swift\nlet value = 1\n\nprint(value)\n```\n\nAfter code.")
select("1", in: codeDraft)
codeDraft.input.insertText("2", replacementRange: codeDraft.input.selectedRange())
check(codeDraft.markdown.contains("```swift\nlet value = 2\n\nprint(value)\n```"), "Edited multiline code stays in one fenced block with its language")
let tableDraft = editor("| Name | Value |\n| --- | --- |\n| Cosmos | Universe |")
select("Universe", in: tableDraft)
tableDraft.input.insertText("Space", replacementRange: tableDraft.input.selectedRange())
check(!tableDraft.markdown.contains("```") && tableDraft.markdown.contains("Space"), "Editing a table cell retains Markdown table syntax")

// A styled source label remains one complete link, including literal punctuation.
let sourceStyle = editor("## Sources\n[1] [Reference \\*literal\\*](https://example.test)")
select("Ref", in: sourceStyle)
sourceStyle.format("b")
let sourceStyledText = session.markdownAttributedText(from: sourceStyle.markdown)
check(sourceStyledText.string.contains("[1] Reference *literal*"), "Partially styled source labels retain all text and literal punctuation")
let sourceBoldIndex = (sourceStyledText.string as NSString).range(of: "Ref").location
check(sourceStyle.isActive("b", attributes: sourceStyledText.attributes(at: sourceBoldIndex, effectiveRange: nil)), "Source label emphasis survives saving")

// An edited image caption must not duplicate the original caption on every save.
let imageFile = root.appendingPathComponent("source-image-1.png")
let imagePixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
try! imagePixels.representation(using: .png, properties: [:])!.write(to: imageFile)
session.config.textPath = root.appendingPathComponent("images.md").path
session.config.sourceImages = [SourceImageAsset(id: "1", file: "source-image-1.png", pageURL: URL(string: "https://example.test/page")!, sourceURL: URL(string: "https://example.test/image")!)]
let imageDraft = editor("![Old caption](langmin-source-image:1)")
select("Old caption", in: imageDraft)
imageDraft.input.insertText("New caption", replacementRange: imageDraft.input.selectedRange())
check(imageDraft.markdown == "![New caption](langmin-source-image:1)", "Editing a caption keeps one image and one updated caption")
let revisedImage = editor(imageDraft.markdown)
select("New caption", in: revisedImage)
revisedImage.format("b")
let renderedImage = session.markdownAttributedText(from: revisedImage.markdown)
check(renderedImage.string == revisedImage.input.string && !revisedImage.markdown.contains("Old caption"), "Repeated caption edits preserve a single visible caption")
let captionIndex = (renderedImage.string as NSString).range(of: "New caption").location
check(revisedImage.isActive("b", attributes: renderedImage.attributes(at: captionIndex, effectiveRange: nil)), "Caption emphasis survives reopening")
session.config.sourceImages = nil
session.config.textPath = ""

// Editing a Sources footer must never persist its generated line glyphs as document text.
let sourced = "What is love?\n\nLove means care.\n\n## Sources\n[3] [Reference](https://example.test/reference)\n[11] [Second](https://example.test/second)"
var sourceRevision = sourced
// Repeat source-reference edits to catch accumulating separators or trailing artifacts.
for revision in 1...4 {
 let edit = editor(sourceRevision)
 let label = (edit.input.string as NSString).range(of: revision == 1 ? "Reference" : "Reference \(revision - 1)")
 edit.input.insertText("Reference \(revision)", replacementRange: label)
 sourceRevision = edit.markdown
 check(!sourceRevision.contains("─"), "Editing Sources does not save generated divider glyphs (pass \(revision))")
 let reopened = session.markdownAttributedText(from: sourceRevision)
 let dividerLines = reopened.string.components(separatedBy: "\n").filter { !$0.isEmpty && $0.allSatisfy { $0 == "─" } }
 check(dividerLines.count == 1, "Repeated edits keep exactly one Sources divider")
 check(reopened.string.contains("[3] Reference \(revision)") && reopened.string.contains("[11] Second"), "Source labels and citation numbers survive editing")
 let sourceIndex = (reopened.string as NSString).range(of: "Reference \(revision)").location
 check((reopened.attribute(.link, at: sourceIndex, effectiveRange: nil) as? URL)?.absoluteString == "https://example.test/reference", "Editing a source label retains its link")
}
let rule = editor("Before\n\n---\n\nAfter")
rule.input.selectAll(nil)
rule.format("i")
check(!rule.markdown.contains("─") && rule.markdown.contains("---"), "Formatting an explicit divider keeps it as Markdown")
let lineGlyphs = String(repeating: "─", count: 80)
let polluted = sourced.replacingOccurrences(of: "## Sources", with: lineGlyphs + "\n\n" + lineGlyphs + "\n\n## Sources")
let repaired = editor(polluted)
let repairedLines = repaired.input.string.components(separatedBy: "\n").filter { !$0.isEmpty && $0.allSatisfy { $0 == "─" } }
check(repairedLines.count == 1, "Existing duplicated footer glyphs display as one divider")
select("care", in: repaired)
repaired.input.insertText("kindness", replacementRange: repaired.input.selectedRange())
check(!repaired.markdown.contains("─"), "Saving an edit cleans the old duplicated-divider pattern")
let literalRule = "Literal line:\n\n" + lineGlyphs + "\n\nKeep this paragraph.\n\n## Sources\n[1] [Reference](https://example.test)"
check(session.markdownAttributedText(from: literalRule).string.contains(lineGlyphs + "\nKeep this paragraph."), "Literal line glyphs away from Sources are retained")
let fencedRule = "```\n" + lineGlyphs + "\nSources\n```"
check(session.markdownAttributedText(from: fencedRule).string.contains(lineGlyphs + "\nSources"), "Code containing line glyphs and Sources is unchanged")
let replacedRule = editor("Before\n\n---\n\nAfter")
let ruleRange = (replacedRule.input.string as NSString).range(of: session.sourceSeparatorText(entries: [], sourceFontSize: max(session.config.fontSize * 0.74, 11)))
replacedRule.input.insertText("A note", replacementRange: ruleRange)
check(replacedRule.markdown.contains("A note"), "Typing over a separator preserves the replacement text")

let linked = editor("Visit the site.")
select("the site", in: linked)
let changed = NSMutableAttributedString(attributedString: linked.input.attributedString())
changed.addAttribute(.link, value: URL(string: "https://example.test/a(b)?q=test")!, range: linked.input.selectedRange())
linked.replaceDraft(changed, selection: linked.input.selectedRange(), action: "Link")
let linkText = session.markdownAttributedText(from: linked.markdown)
let linkIndex = (linkText.string as NSString).range(of: "the site").location
check(linkText.attribute(.link, at: linkIndex, effectiveRange: nil) != nil, "Links survive Markdown round trip")
check(ResultTextFormatting.safeLink("https://example.test") != nil, "HTTPS links accepted")
check(ResultTextFormatting.safeLink("javascript:alert(1)") == nil, "Executable URLs rejected")
check(ResultTextFormatting.safeLink("langmin-followup-delete-reply:1") == nil, "App action URLs rejected")

let heading = editor("A new heading")
select("A new heading", in: heading)
heading.styleMenu.selectItem(at: 2)
heading.changeParagraphStyle(heading.styleMenu)
check(heading.markdown == "## A new heading", "Heading style exports Markdown")
let blank = editor("")
blank.styleMenu.selectItem(at: 1)
blank.changeParagraphStyle(blank.styleMenu)
blank.input.insertText("New heading", replacementRange: NSRange(location: 0, length: 0))
check(blank.markdown == "# New heading", "A heading can be started in an empty response")
let bullets = editor("One\n\nTwo")
bullets.input.selectAll(nil)
bullets.styleMenu.selectItem(at: 4)
bullets.changeParagraphStyle(bullets.styleMenu)
check(bullets.markdown.contains("- One") && bullets.markdown.contains("- Two"), "List style applies to selected paragraphs")
check(bullets.styleMenu.indexOfSelectedItem == 4, "The style menu reflects a selected bullet list")
let unicode = editor("Космос 👨‍👩‍👧‍👦 — svemir.")
select("Космос 👨‍👩‍👧‍👦", in: unicode)
unicode.format("i")
check(session.markdownAttributedText(from: unicode.markdown).string == unicode.input.string, "Unicode and composed emoji survive edits")
let deleted = editor(original)
deleted.input.selectAll(nil)
deleted.input.insertText("", replacementRange: deleted.input.selectedRange())
check(deleted.markdown.isEmpty, "Deleting the entire response stays empty")
let joined = editor("First\n\nSecond")
let newline = (joined.input.string as NSString).range(of: "\n")
joined.input.insertText(" ", replacementRange: newline)
check(session.markdownAttributedText(from: joined.markdown).string == "First Second", "Removing a paragraph break is not undone by block metadata")

// Saved edits commit new text and metadata before removing all attached audio files.
let directory = root.appendingPathComponent("saved")
try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try! original.write(to: directory.appendingPathComponent("text.md"), atomically: true, encoding: .utf8)
try! "original input".write(to: directory.appendingPathComponent("diff-original.txt"), atomically: true, encoding: .utf8)
try! Data([1, 2, 3]).write(to: directory.appendingPathComponent("audio.m4a"))
let savedPronunciations = directory.appendingPathComponent("pronounce")
try! FileManager.default.createDirectory(at: savedPronunciations, withIntermediateDirectories: true)
try! Data([4, 5]).write(to: savedPronunciations.appendingPathComponent("p0.caf"))
let conversation = ResultConversation(originalRequest: "Explain cosmos", modelID: "fixture")
let entry = LibraryEntry(id: "saved", title: "Cosmos", mode: "rewrite", createdAt: 0, fontSize: 17,
 textFile: "text.md", audioFile: "audio.m4a", diffOriginalFile: "diff-original.txt", diffRevisedFile: nil,
 textModel: "Fixture", narrationVoice: "voice", narrationModel: "model", dictionaryHeadword: nil,
 audioTimings: [NarrationChunkTiming(start: 0, text: "old text")],
 pronunciations: [PronunciationRef(key: "fixture", file: "pronounce/p0.caf")], conversation: conversation)
try! JSONEncoder().encode(entry).write(to: directory.appendingPathComponent("entry.json"))
let saved = try! LibraryStore.setEditedResponse(id: "saved", markdown: "Edited response", conversation: conversation)
check(try! String(contentsOf: directory.appendingPathComponent(saved.textFile), encoding: .utf8) == "Edited response", "Saved edits use the new text file")
check(saved.diffRevisedFile == saved.textFile, "Diff follows the edited revision")
check(saved.audioFile == nil && saved.audioTimings == nil && saved.narrationVoice == nil && saved.narrationModel == nil, "Saved edits clear narration metadata and timings")
check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio.m4a").path), "Saved narration is deleted after editing")
check(saved.pronunciations == nil && !FileManager.default.fileExists(atPath: savedPronunciations.path), "Saved pronunciation clips are also removed")
check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("text.md").path), "Replaced text file is cleaned up")
let decoded = try! JSONDecoder().decode(LibraryEntry.self, from: Data(contentsOf: directory.appendingPathComponent("entry.json")))
check(decoded.textFile == saved.textFile && decoded.conversation == conversation && decoded.audioFile == nil && decoded.pronunciations == nil, "Reopening sees edited text without old audio")
// Require edits to a missing saved entry to fail without creating one.
do {
 _ = try LibraryStore.setEditedResponse(id: "missing", markdown: "must fail", conversation: nil)
 check(false, "Missing entry must fail")
// Persistence failure must be surfaced rather than reported as a successful save.
} catch { check(true, "Persistence failure is reported") }

// editingSession(markdown, name, [saved = false]): Create an isolated saved or
// temporary viewer session ready for editing.
func editingSession(_ markdown: String, name: String, saved: Bool = false) -> ViewerSession {
 let value = ViewerSession()
 value.content = markdown
 value.config.cleanupDir = root.path
 value.config.textPath = root.appendingPathComponent(name + ".md").path
 try! markdown.write(toFile: value.config.textPath, atomically: true, encoding: .utf8)
 value.savedLibraryID = saved ? "saved" : nil
 value.textEditor = editor(markdown)
 return value
}
// attachAudio(value, name): Attach a fixture narration file for
// save-and-remove-audio checks.
func attachAudio(to value: ViewerSession, name: String) -> URL {
 let url = root.appendingPathComponent(name + ".m4a")
 try! Data([1, 2, 3]).write(to: url)
 value.activeAudioPath = url.path
 value.config.audioPath = url.path
 value.config.audioTimings = [NarrationChunkTiming(start: 0, text: value.content)]
 value.narrationVoiceUsed = "Voice"
 value.narrationModelUsed = "Model"
 let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
 let scroll = NSScrollView(frame: rootView.bounds)
 let bar = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
 rootView.addSubview(scroll)
 rootView.addSubview(bar)
 value.viewerRootView = rootView
 value.viewerScrollView = scroll
 value.audioControlsBar = bar
 value.saveAudioToolbarButton = NSButton()
 return url
}
let temporary = editingSession("Old text", name: "temporary")
let temporaryAudio = attachAudio(to: temporary, name: "temporary-audio")
let temporaryBar = temporary.audioControlsBar!
temporary.textEditor!.input.selectAll(nil)
temporary.textEditor!.input.insertText("New text", replacementRange: temporary.textEditor!.input.selectedRange())
chooseAlertButton("Cancel", contains: temporary.editAudioRemovalWarning)
check(!temporary.finishTextEditing(), "Cancelling the audio warning leaves editing open")
check(temporary.content == "Old text" && temporary.textEditor?.input.string == "New text" && temporary.audioAvailable, "The cancelled warning keeps the draft, original text and audio")
check(try! String(contentsOfFile: temporary.config.textPath, encoding: .utf8) == "Old text", "Cancelling does not save the edited text")
chooseAlertButton("Save", contains: temporary.editAudioRemovalWarning)
check(temporary.finishTextEditing(), "Done commits a temporary result")
check(temporary.content == "New text" && temporary.exportedResultMarkdown == "New text", "Exports and follow-ups use edited content")
check(temporary.savedLibraryID == nil, "Editing does not add a temporary result to the Library")
check(!temporary.audioAvailable && temporary.config.audioPath.isEmpty && temporary.config.audioTimings == nil, "Done clears narration paths and timings")
check(!FileManager.default.fileExists(atPath: temporaryAudio.path), "The session's original audio is removed from disk")
check(temporary.audioControlsBar == nil && temporaryBar.superview == nil && temporary.saveAudioToolbarButton == nil, "Playback and Save Audio controls disappear after saving edits")
check(try! String(contentsOfFile: temporary.config.textPath, encoding: .utf8) == "New text", "Done updates the backing text file")
let styled = editingSession("Keep the words", name: "styled")
_ = attachAudio(to: styled, name: "styled-audio")
select("words", in: styled.textEditor!)
styled.textEditor!.format("b")
chooseAlertButton("Save", contains: styled.editAudioRemovalWarning)
check(styled.finishTextEditing() && !styled.audioAvailable, "Saving formatting edits follows the same audio-removal rule")
let unchanged = editingSession("No edits", name: "unchanged")
_ = attachAudio(to: unchanged, name: "unchanged-audio")
check(unchanged.finishTextEditing() && unchanged.audioAvailable, "Done with no changes keeps audio without a warning")
let cancelled = editingSession("Keep this", name: "cancelled")
_ = attachAudio(to: cancelled, name: "cancelled-audio")
cancelled.textEditor!.input.selectAll(nil)
cancelled.textEditor!.input.insertText("Discard this", replacementRange: cancelled.textEditor!.input.selectedRange())
cancelled.cancelTextEditing()
check(cancelled.content == "Keep this" && cancelled.textEditor == nil && cancelled.audioAvailable, "Cancel leaves the result and narration intact")
let emptyOriginal = editingSession("Generated text", name: "empty-original")
emptyOriginal.config.diffOriginalPath = root.appendingPathComponent("empty-original-input.txt").path
emptyOriginal.config.diffRevisedPath = emptyOriginal.config.textPath
emptyOriginal.diffRevisedContent = "Generated text"
emptyOriginal.textEditor!.input.selectAll(nil)
emptyOriginal.textEditor!.input.insertText("Edited text", replacementRange: emptyOriginal.textEditor!.input.selectedRange())
check(emptyOriginal.finishTextEditing() && emptyOriginal.diffRevisedContent == "Edited text", "Diff updates even when the original input is empty")
let missing = editingSession("Before failure", name: "failed", saved: true)
missing.savedLibraryID = "missing"
let failedAudio = attachAudio(to: missing, name: "failed-audio")
missing.textEditor!.input.selectAll(nil)
missing.textEditor!.input.insertText("Keep my draft", replacementRange: missing.textEditor!.input.selectedRange())
chooseAlertButton("Save", contains: missing.editAudioRemovalWarning)
check(!missing.finishTextEditing(), "Done reports persistence errors")
check(missing.textEditor?.input.string == "Keep my draft" && missing.content == "Before failure", "Failed save retains the draft and original result")
check(missing.audioAvailable && FileManager.default.fileExists(atPath: failedAudio.path) && missing.audioControlsBar != nil, "A failed save keeps audio files and controls intact")
let reply = editingSession("Original answer", name: "reply")
let turn = ResultFollowUpTurn(question: "Question", answer: "Old reply", modelID: "fixture", modelName: "Fixture")
reply.config.conversation = ResultConversation(originalRequest: "Original request", modelID: "fixture", turns: [turn])
reply.editingReplyID = turn.id
reply.textEditor = editor("Old reply")
reply.textEditor!.input.selectAll(nil)
reply.textEditor!.input.insertText("Edited reply", replacementRange: reply.textEditor!.input.selectedRange())
let replyClip = root.appendingPathComponent("reply-pronunciation.caf")
try! Data([6, 7]).write(to: replyClip)
reply.pronounceCache = ["reply": replyClip]
chooseAlertButton("Save", contains: reply.editAudioRemovalWarning)
check(reply.finishTextEditing() && reply.content == "Original answer", "Editing a reply leaves the original answer intact")
check(reply.config.conversation?.turns.first?.answer == "Edited reply" && reply.exportedResultMarkdown.contains("Edited reply"), "Edited replies reach conversation and exports")
check(reply.pronounceCache.isEmpty && !FileManager.default.fileExists(atPath: replyClip.path), "Saving a reply removes pronunciation-only audio after warning")
let starred = editingSession("Before starring", name: "starred", saved: true)
starred.textEditor!.input.selectAll(nil)
starred.textEditor!.input.insertText("Edited saved text", replacementRange: starred.textEditor!.input.selectedRange())
check(starred.finishTextEditing(), "Done updates a newly saved result")
check(!starred.config.textPath.hasPrefix(directory.path + "/"), "A newly saved session retains its own backing text")
try! FileManager.default.removeItem(at: directory)
check(try! String(contentsOfFile: starred.config.textPath, encoding: .utf8) == "Edited saved text", "Removing the saved copy does not delete the open edited result")

// Render the real editor at the narrow result width and verify its text area lays out.
let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 420, height: 660),
 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
// Keep AppKit from shrinking this fixture to the toolbar's fitting height.
window.contentMinSize = NSSize(width: 420, height: 660)
// Give editor previews a native window background in both appearances.
class PreviewBackground: NSView {
 // draw(dirtyRect): Paint only the invalidated preview area with the current
 // system background color.
 override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}
let view = PreviewBackground(frame: NSRect(x: 0, y: 0, width: 420, height: 660))
window.contentView = view
let toolbar = ResultToolbarView(frame: NSRect(x: 0, y: 616, width: 420, height: 44))
toolbar.translatesAutoresizingMaskIntoConstraints = false
view.addSubview(toolbar)
let normalCopy = TooltipButton(title: "Copy", target: nil, action: nil)
normalCopy.widthAnchor.constraint(equalToConstant: 28).isActive = true
normalCopy.heightAnchor.constraint(equalToConstant: 28).isActive = true
toolbar.addButton(normalCopy, to: .copy)
let divider = NSBox()
divider.boxType = .separator
divider.translatesAutoresizingMaskIntoConstraints = false
toolbar.addSubview(divider)
let normalText = ViewerResultTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 616))
normalText.isEditable = false
view.addSubview(normalText)
let previouslyHidden = NSView()
previouslyHidden.isHidden = true
view.addSubview(previouslyHidden)
NSLayoutConstraint.activate([
 toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
 toolbar.topAnchor.constraint(equalTo: view.topAnchor), toolbar.heightAnchor.constraint(equalToConstant: 44),
 toolbar.buttonStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 22),
 toolbar.buttonStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
 divider.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor), divider.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
 divider.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor)
])
// Compare editing with an already presented result, after AppKit's initial window layout.
window.orderFront(nil)
window.setContentSize(NSSize(width: 420, height: 660))
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
window.layoutIfNeeded()
view.layoutSubtreeIfNeeded()
let toolbarBeforeEditing = toolbar.frame
let previewSession = ViewerSession()
previewSession.window = window
previewSession.viewerRootView = view
previewSession.resultToolbar = toolbar
previewSession.content = original
previewSession.textView = normalText
previewSession.beginTextEditing(replyID: nil)
let preview = previewSession.textEditor!
window.orderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
check(preview.input.bounds.width > 300, "Editor text wraps to the available width")
check(toolbar.frame == toolbarBeforeEditing && !toolbar.isHidden, "Editing keeps the exact existing toolbar frame: \(toolbarBeforeEditing) → \(toolbar.frame); content: \(view.frame)")
check(preview.toolbarControls.superview === toolbar && !divider.isHidden, "Editing replaces controls inside the original toolbar and keeps its divider")
check(toolbar.buttonStack.isHidden && normalText.isHidden && previouslyHidden.isHidden, "Result actions and body are hidden during editing")
check(preview.subviews.count == 1 && preview.subviews.first is NSScrollView, "The editor body has no separate title or formatting row")
// Exercise toolbar fitting from compact to wide result windows.
for width: CGFloat in [420, 560, 720, 900, 1200] {
 window.setContentSize(NSSize(width: width, height: 660))
 window.layoutIfNeeded()
 view.layoutSubtreeIfNeeded()
 let groups = preview.toolbarControls.subviews.flatMap { view -> [NSView] in
  // Treat an existing button group as one layout unit during overlap checks.
  if view is ResultToolbarButtonGroup { return [view] }
  return (view as! NSStackView).arrangedSubviews.filter { !$0.isHidden }
 }.sorted { toolbar.convert($0.bounds, from: $0).minX < toolbar.convert($1.bounds, from: $1).minX }
 check(abs(preview.frame.maxY - toolbar.frame.minY) < 0.1, "The editor body starts directly below the toolbar")
 // Check each visible group against the toolbar's available geometry.
 for group in groups {
  let frame = toolbar.convert(group.bounds, from: group)
  check(frame.minX >= 21.9 && frame.maxX <= toolbar.bounds.width - 21.9, "All editor controls fit inside the normal toolbar margins at width \(width)")
  check(abs(frame.midY - toolbar.bounds.midY) < 0.1 && frame.height == 28, "Editor controls use the normal button height and vertical center")
 }
 check(zip(groups, groups.dropFirst()).allSatisfy {
  toolbar.convert($0.bounds, from: $0).maxX + 11.9 <= toolbar.convert($1.bounds, from: $1).minX
 }, "Editor control groups keep their spacing and never overlap")
 let completion = (groups.last as! NSStackView).arrangedSubviews.compactMap { $0 as? NSButton }
 check(completion.allSatisfy { width == 420 ? $0.image != nil && $0.title.isEmpty : !$0.title.isEmpty }, "Narrow windows use confirmation icons; wider windows retain Done and Cancel labels")
 // Completion buttons must keep padding around their visible titles.
 for button in completion where !button.title.isEmpty {
  check(button.bounds.width >= button.attributedTitle.size().width + 27, "Completion labels retain their horizontal padding at width \(width)")
 }
 let overflow = preview.formattingOverflowMenu()
 let commands = Set(overflow.items.compactMap { $0.representedObject as? String })
 // Every hidden formatting button must remain reachable through overflow actions.
 for (key, button) in preview.formatButtons {
  check(button.isHiddenOrHasHiddenAncestor == commands.contains(key), "Every hidden format remains accessible in More formatting at width \(width): \(key)")
  // Visible formatting buttons retain equal hit-area dimensions.
  if !button.isHiddenOrHasHiddenAncestor { check(button.bounds.width == 32 && button.bounds.height == 28, "Formatting buttons have equal, roomy hit areas") }
 }
 check(preview.styleMenu.isHidden == commands.contains("style:0"), "Paragraph styles move into More formatting only when needed")
 // The narrow layout also exercises overflow actions against a selected word.
 if width == 420 {
  select("usually", in: preview)
  let item = overflow.items.first { $0.representedObject as? String == "sub" }!
  check(NSApp.sendAction(item.action!, to: item.target, from: item), "A hidden command can be selected from More formatting")
  check(preview.formatButtons["sub"]!.state == .on, "The overflow command changes the selected text")
  preview.input.undoManager!.undo()
 }
 // Wide windows should expose all formatting commands without overflow.
 if width >= 900 { check(commands.isEmpty, "Wide windows show every formatting command directly") }
 let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
 view.cacheDisplay(in: view.bounds, to: bitmap)
 try! bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("toolbar-\(Int(width)).png"))
}
window.setContentSize(NSSize(width: 420, height: 660))
// Capture the editor in both system appearances.
for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
 window.appearance = NSAppearance(named: appearanceName)
 view.needsDisplay = true
 RunLoop.main.run(until: Date().addingTimeInterval(0.05))
 view.layoutSubtreeIfNeeded()
 let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
 window.appearance!.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
 try! bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("editor-\(appearanceName.rawValue).png"))
}

// Link changes stay in an anchored editor, preserving the original selection and draft undo.
window.makeKeyAndOrderFront(nil)
select("usually", in: preview)
let linkSelection = preview.input.selectedRange()
preview.editLink()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
check(preview.linkPopover?.isShown == true && NSApp.modalWindow == nil, "Link editing uses a nonmodal popover")
let linkEditor = preview.linkPopover!.contentViewController as! ResultLinkEditorController
check(linkEditor.address.currentEditor() != nil, "The link address receives keyboard focus")
linkEditor.address.stringValue = "javascript:alert(1)"
(linkEditor.actions.arrangedSubviews[0] as! NSButton).performClick(nil)
check(!linkEditor.validation.isHidden && !preview.hasChanges, "Invalid URLs show inline validation without changing text")
check(preview.linkPopover?.isShown == true, "Invalid addresses keep the inline editor open")
let longDestination = "https://example.test/us/dictionary/english/karate?source=library&language=en"
let addressEditor = linkEditor.address.currentEditor() as! NSTextView
addressEditor.selectAll(nil)
addressEditor.insertText(longDestination, replacementRange: addressEditor.selectedRange())
addressEditor.layoutManager!.ensureLayout(for: addressEditor.textContainer!)
var addressLines = 0
addressEditor.layoutManager!.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: addressEditor.layoutManager!.numberOfGlyphs)) { _, _, _, _, _ in addressLines += 1 }
check(addressLines == 1 && addressEditor.string == longDestination, "A long editable URL stays on one scrolling line without losing characters")
linkEditor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
check(linkEditor.validation.isHidden, "Typing clears the previous validation error")
check(linkEditor.control(linkEditor.address, textView: linkEditor.address.currentEditor() as! NSTextView,
 doCommandBy: #selector(NSResponder.insertNewline(_:))), "Return applies the link")
check(preview.linkPopover == nil && preview.input.selectedRange() == linkSelection, "Applying restores the original selection")
check((preview.input.attributedString().attribute(.link, at: linkSelection.location, effectiveRange: nil) as? URL)?.host == "example.test", "The selected text receives the entered link")
preview.input.undoManager!.undo()
check(!preview.hasChanges, "The inline link is one undoable change")
preview.input.undoManager!.redo()
preview.input.setSelectedRange(NSRange(location: linkSelection.location + 1, length: 0))
preview.editLink()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
let existingLinkEditor = preview.linkPopover!.contentViewController as! ResultLinkEditorController
check(preview.input.selectedRange() == linkSelection, "A caret inside an existing link selects its full label")
check(existingLinkEditor.address.stringValue == longDestination, "Existing links preserve the complete long address")
check(existingLinkEditor.address.frame.width > 150, "The compact link editor leaves room for an address")
(existingLinkEditor.actions.arrangedSubviews[1] as! NSButton).performClick(nil)
check(preview.input.attributedString().attribute(.link, at: linkSelection.location, effectiveRange: nil) == nil, "Remove Link keeps the label and removes its URL")
preview.input.undoManager!.undo()
check(preview.input.attributedString().attribute(.link, at: linkSelection.location, effectiveRange: nil) != nil, "Removing a link supports undo")
let beforeCancel = preview.markdown
preview.editLink()
let cancellingLinkEditor = preview.linkPopover!.contentViewController as! ResultLinkEditorController
cancellingLinkEditor.address.stringValue = "https://example.test/discarded"
check(cancellingLinkEditor.control(cancellingLinkEditor.address, textView: cancellingLinkEditor.address.currentEditor() as! NSTextView,
 doCommandBy: #selector(NSResponder.cancelOperation(_:))), "Escape cancels link editing")
check(preview.linkPopover == nil && preview.markdown == beforeCancel, "Cancelling the popover leaves the draft unchanged")
preview.editLink()
preview.linkPopover!.performClose(nil)
check(preview.linkPopover == nil && preview.markdown == beforeCancel, "Dismissing the popover does not apply its address")
preview.editLink()
let keyboardSession = ViewerSession()
keyboardSession.textEditor = preview
check(keyboardSession.handleEscapeKey() && preview.linkPopover == nil && keyboardSession.textEditor === preview, "Escape routed through the result window closes only the link editor")
check(preview.markdown == beforeCancel, "Closing the link editor with Escape keeps the text draft")
preview.editLink()
previewSession.cancelTextEditing()
check(preview.linkPopover == nil, "Leaving the text editor closes its link popover")
check(preview.toolbarControls.superview == nil && !toolbar.buttonStack.isHidden && !normalText.isHidden, "Cancel restores the original result toolbar and body")
check(previouslyHidden.isHidden && !divider.isHidden, "Restoring the result preserves pre-existing visibility and the divider")
window.close()

// Shortcut dispatch must stay with the focused editor, even when a launcher input or
// another result window has its own undo history. Use real AppKit keyboard/menu routing.
let shortcutMainWindow = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 700, height: 440),
 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
shortcutMainWindow.isReleasedWhenClosed = false
shortcutMainWindow.contentMinSize = NSSize(width: 700, height: 440)
let shortcutRoot = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 440))
shortcutMainWindow.contentView = shortcutRoot
let launcherInput = LauncherInputView(frame: NSRect(x: 0, y: 0, width: 320, height: 440))
launcherInput.isEditable = true
launcherInput.allowsUndo = true
launcherInput.string = "Main original"
shortcutRoot.addSubview(launcherInput)
let inlineEditor = editor("Inline original")
inlineEditor.translatesAutoresizingMaskIntoConstraints = true
inlineEditor.frame = NSRect(x: 340, y: 0, width: 360, height: 440)
shortcutRoot.addSubview(inlineEditor)
let detachedWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 440),
 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
detachedWindow.isReleasedWhenClosed = false
detachedWindow.contentMinSize = NSSize(width: 420, height: 440)
let detachedEditor = editor("Detached original")
detachedWindow.contentView = detachedEditor
let fixtureMenu = NSMenu()
let appMenuItem = NSMenuItem(title: "Langmin Fixture", action: nil, keyEquivalent: "")
appMenuItem.submenu = NSMenu(title: "Langmin Fixture")
fixtureMenu.addItem(appMenuItem)
let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
let editMenu = NSMenu(title: "Edit")
let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
redoItem.keyEquivalentModifierMask = [.command, .shift]
editMenu.addItem(undoItem)
editMenu.addItem(redoItem)
editMenuItem.submenu = editMenu
fixtureMenu.addItem(editMenuItem)
NSApp.mainMenu = fixtureMenu
// focus(text, window): Acquire real text focus before checking key-equivalent
// ownership.
func focus(_ text: NSTextView, in window: NSWindow) {
 NSApp.activate(ignoringOtherApps: true)
 window.makeKeyAndOrderFront(nil)
 window.makeFirstResponder(text)
 // WindowServer activation is asynchronous, especially during a full build/test run.
 // Wait for real focus instead of assuming it arrives within 100 milliseconds.
 let deadline = Date().addingTimeInterval(2)
 repeat {
  let next = min(Date().addingTimeInterval(0.05), deadline)
  // Pump queued AppKit events while waiting for the fixture window to become active.
  if let event = NSApp.nextEvent(matching: .any, until: next, inMode: .default, dequeue: true) {
   NSApp.sendEvent(event)
  }
  // Reassert key-window and text focus once the fixture app is active.
  if NSApp.isActive {
   window.makeKey()
   window.makeFirstResponder(text)
  }
  // Stop waiting as soon as the intended editor owns keyboard input.
  if window.isKeyWindow && window.firstResponder === text { break }
 // Bound the focus retry so a missing key window cannot hang the suite.
 } while Date() < deadline
 check(window.isKeyWindow && window.firstResponder === text, "The shortcut fixture focuses the intended text view (key: \(window.isKeyWindow), responder: \(String(describing: window.firstResponder)))")
}
// replace(text, value): Replace fixture text through normal editing so Undo
// records the change.
func replace(_ text: NSTextView, with value: String) {
 text.insertText(value, replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
 text.breakUndoCoalescing()
 RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
// shortcut(window, [redo = false], [extra = []]): Create Undo or Redo key
// events addressed to the selected fixture window.
func shortcut(in window: NSWindow, redo: Bool = false, extra: NSEvent.ModifierFlags = []) -> NSEvent {
 let flags: NSEvent.ModifierFlags = redo ? [.command, .shift] : [.command]
 // Preserve native keyboard-layout metadata used by menu equivalents. These events are
 // sent only to this fixture's NSApplication, never posted to the system event stream.
 precondition(window.isKeyWindow)
 let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 6, keyDown: true)!
 event.flags = CGEventFlags(rawValue: UInt64(flags.union(extra).rawValue))
 return NSEvent(cgEvent: event)!
}
focus(launcherInput, in: shortcutMainWindow)
replace(launcherInput, with: "Main edited")
focus(inlineEditor.input, in: shortcutMainWindow)
replace(inlineEditor.input, with: "Inline edited")
check(!launcherInput.performKeyEquivalent(with: shortcut(in: shortcutMainWindow)), "An unfocused launcher input cannot claim the editor's Undo shortcut")
check(launcherInput.string == "Main edited", "The launcher's undo history remains untouched")
NSApp.sendEvent(shortcut(in: shortcutMainWindow))
check(inlineEditor.input.string == "Inline original" && launcherInput.string == "Main edited", "Cmd-Z undoes only the focused inline result")
NSApp.sendEvent(shortcut(in: shortcutMainWindow, redo: true))
check(inlineEditor.input.string == "Inline edited", "Cmd-Shift-Z redoes the inline result exactly once")

focus(detachedEditor.input, in: detachedWindow)
replace(detachedEditor.input, with: "Detached edited")
check(!launcherInput.performKeyEquivalent(with: shortcut(in: detachedWindow)), "The main window cannot claim another window's Undo shortcut")
check(!inlineEditor.input.performKeyEquivalent(with: shortcut(in: detachedWindow)), "Inactive result editors cannot claim another window's shortcuts")
NSApp.sendEvent(shortcut(in: detachedWindow, extra: .capsLock))
check(detachedEditor.input.string == "Detached original", "Cmd-Z works in a detached editor with Caps Lock enabled")
check(inlineEditor.input.string == "Inline edited" && launcherInput.string == "Main edited", "Detached Undo leaves both main-window histories alone")
NSApp.sendEvent(shortcut(in: detachedWindow, redo: true))
check(detachedEditor.input.string == "Detached edited", "Cmd-Shift-Z redoes only the detached editor")
check(NSApp.sendAction(Selector(("undo:")), to: nil, from: undoItem), "The Edit menu resolves Undo through the active responder chain")
check(detachedEditor.input.string == "Detached original", "Edit > Undo affects the detached editor")
check(NSApp.sendAction(Selector(("redo:")), to: nil, from: redoItem), "The Edit menu resolves Redo through the active responder chain")
check(detachedEditor.input.string == "Detached edited", "Edit > Redo uses the same draft history")
select("Detached", in: detachedEditor)
detachedEditor.format("b")
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
NSApp.sendEvent(shortcut(in: detachedWindow))
check(!detachedEditor.isActive("b", attributes: attributes("Detached", in: detachedEditor.input.attributedString())), "Keyboard Undo also reverses toolbar formatting")
NSApp.sendEvent(shortcut(in: detachedWindow, redo: true))
check(detachedEditor.isActive("b", attributes: attributes("Detached", in: detachedEditor.input.attributedString())), "Keyboard Redo restores toolbar formatting")
detachedEditor.input.undoManager!.removeAllActions()
// An editor with empty history must still consume both Undo and Redo.
for redo in [false, true] {
 check(detachedEditor.input.performKeyEquivalent(with: shortcut(in: detachedWindow, redo: redo)), "An empty draft history still owns Undo and Redo")
 NSApp.sendEvent(shortcut(in: detachedWindow, redo: redo))
}
check(launcherInput.string == "Main edited" && inlineEditor.input.string == "Inline edited", "An empty draft never falls back to undoing another window")
check(!handleFocusedTextUndoRedoShortcut(shortcut(in: detachedWindow, extra: .option), in: detachedEditor.input), "Other modifier combinations are not claimed as Undo")

// returnKey([code = 36], [flags = .command]): Done uses the same active-draft
// routing as Undo, leaving ordinary Return available for typing.
func returnKey(code: CGKeyCode = 36, flags: NSEvent.ModifierFlags = .command) -> NSEvent {
 let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: code, keyDown: true)!
 event.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
 return NSEvent(cgEvent: event)!
}
var inlineDone = 0, detachedDone = 0, launcherSubmits = 0
inlineEditor.onDone = { inlineDone += 1 }
detachedEditor.onDone = { detachedDone += 1 }
launcherInput.onSubmit = { launcherSubmits += 1 }
check(!inlineEditor.input.performKeyEquivalent(with: returnKey()), "An inactive editor cannot claim another window's Done shortcut")
NSApp.sendEvent(returnKey())
check(detachedDone == 1 && inlineDone == 0 && launcherSubmits == 0, "Cmd-Return invokes Done once in the detached editor")
NSApp.sendEvent(returnKey(code: 76, flags: [.command, .numericPad, .capsLock]))
check(detachedDone == 2, "Cmd-Enter on the numeric keypad also invokes Done")
let repeatedReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
 timestamp: 0, windowNumber: detachedWindow.windowNumber, context: nil, characters: "\r",
 charactersIgnoringModifiers: "\r", isARepeat: true, keyCode: 36)!
check(detachedEditor.input.performKeyEquivalent(with: repeatedReturn) && detachedDone == 2, "Holding the shortcut does not repeatedly invoke Done")
focus(inlineEditor.input, in: shortcutMainWindow)
NSApp.sendEvent(returnKey())
check(inlineDone == 1 && detachedDone == 2 && launcherSubmits == 0, "Cmd-Return finishes the inline editor without submitting the main input")
inlineEditor.input.setSelectedRange(NSRange(location: inlineEditor.input.attributedString().length, length: 0))
NSApp.sendEvent(returnKey(flags: []))
check(inlineEditor.input.string.hasSuffix("\n") && inlineDone == 1, "Return without Command still inserts a newline")

// The link address uses AppKit's shared field editor, whose shortcuts must remain native.
let addressWindow = NSWindow(contentRect: NSRect(x: 140, y: 140, width: 380, height: 52),
 styleMask: [.titled], backing: .buffered, defer: false)
addressWindow.isReleasedWhenClosed = false
let addressController = ResultLinkEditorController(destination: "https://example.test/original", hasLink: true)
addressWindow.contentViewController = addressController
addressWindow.makeKeyAndOrderFront(nil)
addressWindow.makeFirstResponder(addressController.address)
let urlInput = addressController.address.currentEditor() as! NSTextView
focus(urlInput, in: addressWindow)
check(!inlineEditor.input.performKeyEquivalent(with: returnKey()) && !detachedEditor.input.performKeyEquivalent(with: returnKey()), "A focused link field cannot accidentally finish a background draft")
replace(urlInput, with: "https://example.test/edited")
check(!launcherInput.performKeyEquivalent(with: shortcut(in: addressWindow)) && !detachedEditor.input.performKeyEquivalent(with: shortcut(in: addressWindow)), "Response and launcher views cannot claim the link field's Undo")
NSApp.sendEvent(shortcut(in: addressWindow))
check(urlInput.string == "https://example.test/original", "Cmd-Z undoes typing inside the link address")
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
editMenu.update()
NSApp.sendEvent(shortcut(in: addressWindow, redo: true))
check(urlInput.string == "https://example.test/edited", "Cmd-Shift-Z redoes typing inside the link address (value: \(urlInput.string), canRedo: \(urlInput.undoManager?.canRedo == true), menu: \(redoItem.isEnabled))")
check(detachedEditor.input.string == "Detached edited" && launcherInput.string == "Main edited", "Editing a link address preserves other text histories")
addressWindow.close()

focus(launcherInput, in: shortcutMainWindow)
NSApp.sendEvent(shortcut(in: shortcutMainWindow))
check(launcherInput.string == "Main original", "The launcher can undo normally when it is focused")
NSApp.sendEvent(shortcut(in: shortcutMainWindow, redo: true))
check(launcherInput.string == "Main edited", "The launcher can redo normally when it is focused")
NSApp.sendEvent(returnKey())
check(launcherSubmits == 1 && inlineDone == 1 && detachedDone == 2, "Cmd-Return still submits the main input when it is focused")
detachedWindow.close()
shortcutMainWindow.close()
NSApp.mainMenu = nil

// An opaque fixture host lets AppKit capture native controls without the popover material's masks.
let linkPreviewWindow = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 380, height: 52),
 styleMask: [.titled], backing: .buffered, defer: false)
linkPreviewWindow.isReleasedWhenClosed = false
let linkPreview = ResultLinkEditorController(destination: longDestination, hasLink: true)
let linkBackground = PreviewBackground(frame: NSRect(x: 0, y: 0, width: 380, height: 52))
linkPreviewWindow.contentView = linkBackground
linkBackground.addSubview(linkPreview.view)
linkPreviewWindow.makeKeyAndOrderFront(nil)
linkPreviewWindow.makeFirstResponder(linkPreview.address)
linkPreview.address.selectText(nil)
// Check the link popover's baseline and focus outline in both appearances.
for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
 linkPreviewWindow.appearance = NSAppearance(named: appearanceName)
 linkBackground.needsDisplay = true
 linkBackground.layoutSubtreeIfNeeded()
 RunLoop.main.run(until: Date().addingTimeInterval(0.05))
 let bitmap = linkBackground.bitmapImageRepForCachingDisplay(in: linkBackground.bounds)!
 linkPreviewWindow.appearance!.performAsCurrentDrawingAppearance { linkBackground.cacheDisplay(in: linkBackground.bounds, to: bitmap) }
 try! bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("link-editor-\(appearanceName.rawValue).png"))
}
linkPreviewWindow.close()

// Keyboard Done must retain the same confirmation and persistence path as the toolbar button.
let shortcutSave = editingSession("Before keyboard save", name: "keyboard-save")
let shortcutAudio = attachAudio(to: shortcutSave, name: "keyboard-save-audio")
let saveWindow = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 420, height: 440),
 styleMask: [.titled], backing: .buffered, defer: false)
saveWindow.isReleasedWhenClosed = false
saveWindow.contentView = shortcutSave.viewerRootView
shortcutSave.window = saveWindow
let saveEditor = shortcutSave.textEditor!
saveEditor.translatesAutoresizingMaskIntoConstraints = true
saveEditor.frame = saveWindow.contentView!.bounds
saveWindow.contentView!.addSubview(saveEditor)
saveEditor.onDone = { [weak shortcutSave] in _ = shortcutSave?.finishTextEditing() }
focus(saveEditor.input, in: saveWindow)
replace(saveEditor.input, with: "Saved from the keyboard")
chooseAlertButton("Cancel", contains: shortcutSave.editAudioRemovalWarning)
NSApp.sendEvent(returnKey())
check(shortcutSave.textEditor === saveEditor && shortcutSave.content == "Before keyboard save" && shortcutSave.audioAvailable, "Cancelling keyboard Done keeps the draft and attached audio")
focus(saveEditor.input, in: saveWindow)
chooseAlertButton("Save", contains: shortcutSave.editAudioRemovalWarning)
NSApp.sendEvent(returnKey())
check(shortcutSave.textEditor == nil && shortcutSave.content == "Saved from the keyboard", "Confirming keyboard Done commits the response and exits editing")
check(try! String(contentsOfFile: shortcutSave.config.textPath, encoding: .utf8) == "Saved from the keyboard", "Keyboard Done persists the edited response")
check(!shortcutSave.audioAvailable && !FileManager.default.fileExists(atPath: shortcutAudio.path), "Keyboard Done removes attached audio only after confirmation")
saveWindow.close()

// Real native close requests must respect Save, Discard and Cancel for a dirty editor.
let closing = editingSession("Before closing", name: "closing")
let closeWindow = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 420, height: 240),
 styleMask: [.titled, .closable], backing: .buffered, defer: false)
closeWindow.isReleasedWhenClosed = false
closeWindow.delegate = closing
closing.window = closeWindow
closeWindow.orderFront(nil)
closing.textEditor!.input.selectAll(nil)
closing.textEditor!.input.insertText("Keep this draft", replacementRange: closing.textEditor!.input.selectedRange())
// chooseAlertButton(title, [warning = nil]): Choose a specific fixture alert
// button after the modal dialog appears.
func chooseAlertButton(_ title: String, contains warning: String? = nil) {
 DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
  // find(view): Find the requested button recursively in the alert's content
  // hierarchy.
  func find(in view: NSView) -> NSButton? {
   // Return only a button whose visible title matches the requested action.
   if let button = view as? NSButton, button.title == title { return button }
   return view.subviews.lazy.compactMap { find(in: $0) }.first
  }
  // Fail clearly when the expected confirmation dialog or action was not presented.
  guard let content = NSApp.modalWindow?.contentView, let button = find(in: content) else {
   fputs("FAILED: Expected fixture alert button\n", stderr); exit(1)
  }
  // Check warning wording when the caller supplied an expected message.
  if let warning {
   // hasWarning(view): Search descendant labels for the exact expected warning
   // text.
   func hasWarning(_ view: NSView) -> Bool {
    (view as? NSTextField)?.stringValue == warning || view.subviews.contains(where: hasWarning)
   }
   check(hasWarning(content), "Saving warns that attached audio will be removed")
  }
  button.performClick(nil)
 }
}
chooseAlertButton("Cancel")
closeWindow.performClose(nil)
check(closeWindow.isVisible && closing.textEditor?.input.string == "Keep this draft", "Cancel vetoes closing and keeps the draft")
_ = attachAudio(to: closing, name: "closing-audio")
chooseAlertButton("Save", contains: closing.editAudioRemovalWarning)
closeWindow.performClose(nil)
check(!closeWindow.isVisible && closing.content == "Keep this draft" && !closing.audioAvailable, "Closing warns once and removes audio only after saving")
print("\(checks) text editor checks passed")
'''
with tempfile.TemporaryDirectory(prefix='langmin-editor-tests-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', *swift_fixture_args(), '-O', '-module-cache-path', cache, '-target', f'{platform.machine()}-apple-macos14.0',
                    str(folder / 'main.swift'), str(app_path('ResultDiff.swift')),
                    str(app_path('ResultConversation.swift')), '-o', str(folder / 'tests')], check=True)
    subprocess.run([str(folder / 'tests'), directory], check=True, timeout=60)
    # Retain rendered artifacts only when a destination was explicitly requested.
    if target := os.environ.get('LANGMIN_TEST_ARTIFACTS'):
        output = Path(target)
        output.mkdir(parents=True, exist_ok=True)
        # Copy rendered fixture artifacts to the explicitly requested output directory.
        for artifact in folder.glob('*.png'):
            shutil.copyfile(artifact, output / artifact.name)
