#!/usr/bin/env python3
"""Exercise formatted diffs with the real renderer and offscreen native text views."""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile

from source_files import ROOT, app_path, app_source, swift_fixture_args
MAIN = app_source('main.swift')
WEB = app_source('WebPageSource.swift')
IMAGE = app_source('DictionaryIllustration.swift')


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
// localized(key, english): Resolve labels through the fixture’s controlled
// localization.
func localized(_ key: String, _ english: String) -> String { english }
// Supply image metadata required by the renderer without loading real page assets.
struct SourceImageAsset { var id: String; var file: String; var pageURL: URL; var sourceURL: URL; var isValid: Bool { true } }
// Provide the typography and document fields needed by isolated diff rendering.
struct Config { var fontSize: CGFloat = 17; var textPath = ""; var sourceImages: [SourceImageAsset]?; var dictionaryHeadword: String? }
// Keep pronunciation voice setup disabled during rendering tests.
struct Preferences { let dictionaryVoice = "none" }
// loadAppPreferences(): Provide the preferences configured by this fixture.
func loadAppPreferences() -> Preferences { Preferences() }
// Supply the viewer base class without follow-up hover behavior.
class ResultConversationTextView: NSTextView {
 // updateFollowUpActionHover(point): Keep this production dependency inactive
 // in the isolated fixture.
 func updateFollowUpActionHover(at point: NSPoint) {}
}
// Host the real Markdown and diff renderers with recorded pronunciation requests.
final class ViewerSession {
 var config = Config()
 var window: NSWindow?
 var textView: NSTextView?
 var diffOriginalContent = ""
 var diffRevisedContent = ""
 var pronunciations: [(word: String, ipa: String)] = []
 // pronounceGlyphAttributedString(font, speak, ipa, tooltip): Record
 // pronunciation text and IPA instead of starting speech playback.
 func pronounceGlyphAttributedString(alongside font: NSFont, speak: String, ipa: String, tooltip: String) -> NSAttributedString? {
  pronunciations.append((speak, ipa))
  return NSAttributedString(string: "🔈", attributes: [.font: font])
 }
 // RENDERER
}
'''
renderer = MAIN[MAIN.index('    struct MarkdownFence {'):MAIN.index('    // Restore the normal generated result view.')]
renderer += MAIN[MAIN.index('    func markdownAttributedText(from markdown:'):MAIN.index('    // Build the always-visible result toolbar.')]
renderer += block(MAIN, '    func diffAttributedText()')
renderer += '\n' + block(MAIN, '    private func insertPronunciationSpeakers(').replace('private func', 'func')
renderer += '\n' + block(MAIN, '    private func posFramedText(')
source = source.replace('// RENDERER', renderer)
source += app_source('ResultTextFormatting.swift') + '\n'
source += block(MAIN, 'extension NSAttributedString.Key {') + '\n'
source += 'struct PreferenceOption { let id: String; let title: String; let note: String }\n'
source += MAIN[MAIN.index('let languageOptions:'):MAIN.index('// Override the UI language')]
source += block(MAIN, 'enum LanguageHeadingNames {') + '\n'
source += block(IMAGE, 'func dictionaryIllustrationCaption(') + '\n'
source += block(IMAGE, 'struct DictionaryIllustrationLayout:') + '\n'
source += block(IMAGE, 'class DictionaryIllustrationTextView:') + '\n'
source += block(MAIN, 'class ViewerResultTextView:').replace('private func drawBlockquoteBars', 'func drawBlockquoteBars') + '\n'
# Compile these production declarations with the fixture’s minimal dependencies.
for marker in ['struct SourceImageReference {', 'func sourceImageReferences(in markdown:', 'final class SourcePageImageAttachment:']:
    source += block(WEB, marker) + '\n'
source += r'''
_ = NSApplication.shared
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
// runs(text, change): Collect ranges marked with a particular diff change type.
func runs(_ text: NSAttributedString, change: String) -> [NSRange] {
 var ranges: [NSRange] = []
 text.enumerateAttribute(ResultTextDiff.changeAttribute, in: NSRange(location: 0, length: text.length)) { value, range, _ in
  // Keep only runs whose change attribute matches the requested type.
  if value as? String == change { ranges.append(range) }
 }
 return ranges
}
// projected(text): Project a diff onto the revised text by removing deletions
// and visual separators.
func projected(_ text: NSAttributedString) -> NSAttributedString {
 let result = NSMutableAttributedString(string: "")
 text.enumerateAttribute(ResultTextDiff.changeAttribute, in: NSRange(location: 0, length: text.length)) { value, range, _ in
  // Retain runs that belong to the revised result's visible content.
  if !["deleted", "separator"].contains(value as? String ?? "") { result.append(text.attributedSubstring(from: range)) }
 }
 return result
}
// normalized(text): Normalize rendering-only attributes before comparing
// semantic text formatting.
func normalized(_ text: NSAttributedString) -> NSAttributedString {
 let copy = NSMutableAttributedString(attributedString: text)
 let full = NSRange(location: 0, length: text.length)
 copy.removeAttribute(ResultTextDiff.changeAttribute, range: full)
 copy.removeAttribute(.foregroundColor, range: full)
 text.enumerateAttribute(.langminCodeBlock, in: full) { value, range, _ in
  // Normalize code-block identity without changing its contents.
  if value != nil { copy.addAttribute(.langminCodeBlock, value: true, range: range) }
 }
 return copy
}
@discardableResult
// verify(before, after, name): Render and compare a before/after pair through
// the production diff pipeline.
func verify(_ before: String, _ after: String, _ name: String) -> NSAttributedString {
 let old = session.markdownAttributedText(from: before)
 let new = session.markdownAttributedText(from: after)
 let oldSnapshot = NSAttributedString(attributedString: old)
 let newSnapshot = NSAttributedString(attributedString: new)
 let diff = ResultTextDiff.render(original: old, revised: new)
 let restored = projected(diff)
 check(restored.string == new.string, "\(name): revised text is recoverable, including whitespace; got \(restored.string.debugDescription)")
 check(normalized(restored).isEqual(to: normalized(new)), "\(name): revised formatting survives")
 check(old.isEqual(to: oldSnapshot) && new.isEqual(to: newSnapshot), "\(name): inputs are unchanged")
 // Every deleted run must retain the deletion strikethrough style.
 for range in runs(diff, change: "deleted") {
  check(diff.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int == 1, "\(name): deletions are struck through")
 }
 // Every run boundary must remain a valid composed-character boundary.
 let ns = diff.string as NSString
 diff.enumerateAttribute(ResultTextDiff.changeAttribute, in: NSRange(location: 0, length: diff.length)) { _, range, _ in
  check(ns.rangeOfComposedCharacterSequences(for: range) == range, "\(name): complete Unicode characters")
 }
 return diff
}
let before = """
Дизајн интерфејса

1. Шта је дизајн интерфејса и како се разликује од UX-а?
   Дизајн интерфејса (UI) бави се изгледом и понашањем екрана: распоредом, бојама, типографијом и стањима елемената.
   UX је шири појам који обухвата целокупно корисничко искуство.
   Руски: Дизайн интерфейса (UI) отвечает за внешний вид и поведение экранов.

2. Шта је визуелна хијерархија и како помаже кориснику?
   Визуелна хијерархија организује елементе по важности користећи величину, контраст, размак и позицију.

3. Како проверити резултат?
   Проверите текст и распоред.
"""
let after = """
Дизајн интерфејса

1. Шта је дизајн интерфејса и по чему се разликује од UX-а?
   Дизајн интерфејса (UI) бави се изгледом и начином рада екрана: распоредом, бојама, типографијом и стањима елемената.
   UX је шири појам. Он обухвата целокупно корисничко искуство.
   Руски: Дизайн интерфейса (UI) отвечает за внешний вид и поведение экранов.

2. Шта је визуелна хијерархија и како помаже кориснику?
   Визуелна хијерархија распоређује елементе по важности. За то се користе величина, контраст, размак и положај.

3. Како проверити резултат?
   Проверите текст и распоред.
"""
let example = verify(before, after, "Serbian and Russian numbered paragraphs")
check(example.string.components(separatedBy: "\n").count == 4, "Original list layout stays on four paragraphs")
let listIndex = (example.string as NSString).range(of: "1.\t").location
let style = example.attribute(.paragraphStyle, at: listIndex, effectiveRange: nil) as! NSParagraphStyle
check(style.headIndent >= 22 && style.firstLineHeadIndent == 0 && !style.tabStops.isEmpty, "List keeps its hanging indent and tab stop")
check(example.string.contains("како по чему"), "Replacements show the deletion before the insertion, with a gap")
session.diffOriginalContent = before
session.diffRevisedContent = after
check(normalized(session.diffAttributedText()).isEqual(to: normalized(example)), "Viewer uses the formatted diff renderer")

// Cover empty, inserted, deleted, and mixed block changes explicitly.
for (old, new, name) in [
 ("", "", "empty"), ("", "## Added\n\nText", "all inserted"), ("**Removed**", "", "all deleted"),
 ("Same\n\nText", "Same\n\nText", "unchanged"),
 ("one two", "one  two", "space inserted"), ("one  two", "one two", "space deleted"),
 ("First\n\nSecond", "First\n\nMiddle\n\nSecond", "paragraph inserted"),
 ("First\n\nMiddle\n\nSecond", "First\n\nSecond", "paragraph deleted"),
 ("First second.", "First\n\nsecond.", "split paragraph"),
 ("First\n\nsecond.", "First second.", "merged paragraphs"),
 ("Text", "Text\n\nLast", "new last paragraph"), ("First\n\nLast", "First", "deleted last paragraph"),
 ("Same\n\nSame\n\nOld", "Same\n\nNew\n\nSame", "repeated paragraphs"),
 ("- One\n- Two", "1. One\n2. Two", "list style changed"),
 ("- One\n  - Two", "- One\n- Two", "list depth changed"),
 ("First  \nOld\n\nLast", "First  \nNew\n\nLast", "hard line breaks"),
 ("Old\r\n\r\nText", "New\n\nText", "CRLF"),
 ("A **bold old** and *italic old* word.", "A **bold new** and *italic new* word.", "emphasis across changes"),
 ("Hello, world!", "Hello world.", "punctuation"),
 ("👩🏽‍💻 says café 🇷🇸 क्‍ष", "👨🏼‍💻 says café 🇷🇺 क्ष", "emoji, accents and Indic clusters"),
 ("你好世界。", "你好朋友。", "Chinese"), ("مرحبا بالعالم", "مرحبا بالجميع", "Arabic"),
 ("```swift\nlet a = 1\n  print(a)\n```", "```swift\nlet a = 2\n  print(a)\n```", "code indentation"),
 ("Use `old_value` here.", "Use `new_value` here.", "inline code"),
 ("> An old example.", "> A new example.", "blockquote"),
 ("| Key | Value |\n| --- | --- |\n| one | old |", "| Key | Value |\n| --- | --- |\n| one | new |", "table"),
 ("## Old\n\nParagraph", "## New\n\nParagraph", "heading")
] { verify(old, new, name) }
let emphasis = verify("A simple word.", "A **simple** word.", "formatting only")
let boldIndex = (emphasis.string as NSString).range(of: "simple").location
check(emphasis.attribute(ResultTextDiff.changeAttribute, at: boldIndex, effectiveRange: nil) as? String == "inserted", "Formatting-only edit is marked")
let link = verify("[Source](https://example.test/old)", "[Source](https://example.test/new)", "link destination changed")
check(!runs(link, change: "inserted").isEmpty, "Changed link target is marked")
check((link.attribute(.link, at: 0, effectiveRange: nil) as? URL)?.path == "/new", "Revised link target is retained")
let code = verify("```\nlet x = 1\n```", "```\nlet x = 1\n```", "unchanged code")
check(runs(code, change: "inserted").isEmpty && runs(code, change: "deleted").isEmpty, "Random code block IDs do not create false changes")
let changedCode = verify("`old`", "`new`", "code contrast")
let colorIndex = runs(changedCode, change: "inserted")[0].location
let color = changedCode.attribute(.foregroundColor, at: colorIndex, effectiveRange: nil) as! NSColor
NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
 check(color.usingColorSpace(.deviceRGB)!.greenComponent > 0.8, "Code edits stay bright on the black code background in light mode")
}

// Many combinations catch missing endings, duplicate whitespace and incorrect match ranges.
let fragments = ["alpha beta", "gamma!", "👩🏽‍💻 café", "## Title", "- List", "> Quote", "", "Руски текст"]
var seed: UInt64 = 17
// next(limit): Produce deterministic pseudo-random choices for repeatable diff
// stress cases.
func next(_ limit: Int) -> Int {
 seed = seed &* 6364136223846793005 &+ 1442695040888963407
 return Int((seed >> 32) % UInt64(limit))
}
// Exercise many generated block combinations with a fixed random seed.
for index in 0..<160 {
 let old = (0..<next(7)).map { _ in fragments[next(fragments.count)] }.joined(separator: "\n\n")
 let new = (0..<next(7)).map { _ in fragments[next(fragments.count)] }.joined(separator: "\n\n")
 verify(old, new, "generated case \(index)")
}
let start = Date()
let long = (0..<4000).map { "Paragraph \($0) keeps its words and structure." }.joined(separator: "\n\n")
let longEdit = verify(long, long.replacingOccurrences(of: "Paragraph 2000", with: "Changed paragraph 2000"), "long document, small edit")
check(runs(longEdit, change: "deleted").count == 1, "Long document keeps an inline diff for its small edit")
let longBefore = (0..<2400).map { "before\($0)" }.joined(separator: " ")
let longAfter = (0..<2400).map { "after\($0)" }.joined(separator: " ")
verify(longBefore, longAfter, "word comparison budget")
let manyBefore = (0..<1200).map { "Old \($0)" }.joined(separator: "\n\n")
let manyAfter = (0..<1201).map { "New \($0)" }.joined(separator: "\n\n")
verify(manyBefore, manyAfter, "paragraph comparison budget")
let elapsed = Date().timeIntervalSince(start)
check(elapsed < 15, "Long-document comparisons finish within 15 seconds (\(elapsed))")
print("Long-document fixtures: \(String(format: "%.2f", elapsed))s")

let richBefore = "# A short lesson\n\nRead **old words** and *an example*. Visit [the source](https://example.test/old).\n\n> An old quote.\n\nUse `old_value` here.\n\n```swift\nlet value = 1\nprint(value)\n```"
let richAfter = "# A clear lesson\n\nRead **new words** and *an example*. Visit [the source](https://example.test/new).\n\n> A clear quote.\n\nUse `new_value` here.\n\n```swift\nlet value = 2\nprint(value)\n```"
let rich = verify(richBefore, richAfter, "rich visual fixture")
// snapshot(text, name, appearance): Render an isolated diff preview for visual
// inspection.
func snapshot(_ text: NSAttributedString, name: String, appearance: NSAppearance.Name) {
 let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
 window.appearance = NSAppearance(named: appearance)
 let view = ViewerResultTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 820))
 view.isEditable = false
 view.isRichText = true
 view.drawsBackground = true
 view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
 view.textContainerInset = NSSize(width: 28, height: 24)
 view.textContainer?.containerSize = NSSize(width: 664, height: CGFloat.greatestFiniteMagnitude)
 view.textContainer?.widthTracksTextView = true
 view.backgroundColor = .textBackgroundColor
 window.contentView = view
 view.textStorage?.setAttributedString(text)
 view.layoutManager?.ensureLayout(for: view.textContainer!)
 window.layoutIfNeeded()
 window.displayIfNeeded()
 // Draw through TextKit directly; offscreen NSTextView layer caches can omit glyphs.
 let image = NSImage(size: view.bounds.size, flipped: true) { _ in
  window.appearance!.performAsCurrentDrawingAppearance {
   view.drawBackground(in: view.bounds)
   let layout = view.layoutManager!
   let glyphs = layout.glyphRange(for: view.textContainer!)
   layout.drawBackground(forGlyphRange: glyphs, at: view.textContainerOrigin)
   layout.drawGlyphs(forGlyphRange: glyphs, at: view.textContainerOrigin)
   view.drawBlockquoteBars(in: view.bounds)
  }
  return true
 }
 let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
 try! rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
}
// Capture representative diff layouts in both system appearances.
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
 let suffix = appearance == .aqua ? "light" : "dark"
 snapshot(example, name: "diff-list-" + suffix, appearance: appearance)
 snapshot(session.markdownAttributedText(from: after), name: "result-list-" + suffix, appearance: appearance)
 snapshot(rich, name: "diff-rich-" + suffix, appearance: appearance)
 snapshot(session.markdownAttributedText(from: richAfter), name: "result-rich-" + suffix, appearance: appearance)
}
// IPA-free local entries retain word and example pronunciation without speaking language labels.
session.config.dictionaryHeadword = "Karate"
let localDictionary = NSMutableAttributedString(attributedString: session.markdownAttributedText(from: "# Karate\n\n## English\n\n## Noun\n\n1. A martial art.\n> *She practices karate.*\n\n## French\n\n## Nom: karaté\n\n1. Un art martial.\n> *Elle pratique le karaté.*"))
session.insertPronunciationSpeakers(into: localDictionary)
check(session.pronunciations.contains { $0.word == "Karate" && $0.ipa.isEmpty }, "IPA-free original word uses normal voice pronunciation")
check(session.pronunciations.contains { $0.word == "karaté" && $0.ipa.isEmpty }, "IPA-free translated heading pronounces its own word")
check(session.pronunciations.filter { $0.word == "Karate" }.count == 1 && session.pronunciations.count == 4, "One icon per word and example; no language-label icons")
session.pronunciations = []
session.config.dictionaryHeadword = "record"
let transcribedDictionary = NSMutableAttributedString(attributedString: session.markdownAttributedText(from: "# record\n\n## Noun /ˈrɛkɔːd/\n\n1. Stored information.\n\n## Verb /rɪˈkɔːd/\n\n1. Store information."))
session.insertPronunciationSpeakers(into: transcribedDictionary)
check(session.pronunciations.map(\.word).sorted() == ["the record", "to record"], "IPA headings preserve POS stress hints without a duplicate title button")
session.pronunciations = []
session.config.dictionaryHeadword = "river"
let mixedPronunciations = NSMutableAttributedString(attributedString: session.markdownAttributedText(from: "# river\n\n## English\n\n## Noun\n\n1. A natural stream.\n\n## French\n\n## Nom: rivière /ʁi.vjɛʁ/\n\n1. Un cours d'eau."))
session.insertPronunciationSpeakers(into: mixedPronunciations)
check(session.pronunciations.contains { $0.word == "river" && $0.ipa.isEmpty }, "A translated IPA heading must not suppress pronunciation of the original word")
check(session.pronunciations.contains { $0.word == "rivière" && !$0.ipa.isEmpty }, "Translated IPA playback remains available beside the original fallback")
session.pronunciations = []
session.config.dictionaryHeadword = "record"
let originalColonHeading = NSMutableAttributedString(attributedString: session.markdownAttributedText(from: "# record\n\n## Noun: record /ˈrɛkɔːd/\n\n1. Stored information."))
session.insertPronunciationSpeakers(into: originalColonHeading)
check(session.pronunciations.map(\.word) == ["the record"], "An original colon heading keeps its IPA button without a duplicate title button")
session.pronunciations = []
session.config.dictionaryHeadword = "summer"
let asciiPronunciation = NSMutableAttributedString(attributedString: session.markdownAttributedText(from: "# summer\n\n## English\n\n## Noun /ˈsʌmə/\n\n1. A season.\n\n## French\n\n## Nom: été /ete/\n\n1. Une saison."))
session.insertPronunciationSpeakers(into: asciiPronunciation)
check(session.pronunciations.contains { $0.word == "été" && $0.ipa.isEmpty }, "A plain voice fallback never speaks a trailing ASCII IPA transcription")
print("\(checks) diff and dictionary pronunciation checks passed")
'''
with tempfile.TemporaryDirectory(prefix='langmin-diff-tests-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', *swift_fixture_args(), '-O', '-module-cache-path', cache, '-target', f'{platform.machine()}-apple-macos14.0',
                    str(folder / 'main.swift'), str(app_path('ResultDiff.swift')),
                    '-o', str(folder / 'tests')], check=True)
    subprocess.run([str(folder / 'tests'), directory], check=True, timeout=60)
    # Retain rendered artifacts only when a destination was explicitly requested.
    if target := os.environ.get('LANGMIN_TEST_ARTIFACTS'):
        output = Path(target)
        output.mkdir(parents=True, exist_ok=True)
        # Copy rendered fixture artifacts to the explicitly requested output directory.
        for artifact in folder.glob('*.png'):
            shutil.copyfile(artifact, output / artifact.name)
