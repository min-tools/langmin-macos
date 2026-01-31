import Cocoa

// Name editor-only attributes used to preserve block identity and custom inline formatting.
extension NSAttributedString.Key {
    static let resultEditorBlock = NSAttributedString.Key("LangminEditorBlock")
    static let resultEditorHeading = NSAttributedString.Key("LangminEditorHeading")
    static let resultEditorSeparator = NSAttributedString.Key("LangminEditorSeparator")
    static let resultEditorSourceEntry = NSAttributedString.Key("LangminEditorSourceEntry")
    static let resultEditorFontSize = NSAttributedString.Key("LangminEditorFontSize")
    static let resultEditorScript = NSAttributedString.Key("LangminEditorScript")
    static let resultEditorScriptBaseSize = NSAttributedString.Key("LangminEditorScriptBaseSize")
}

// Keep the original Markdown for untouched blocks, including tables, images and citations.
// This metadata lives only in the editor; persisted results remain ordinary Markdown.
final class ResultEditorBlock: NSObject {
    let markdown: String
    let rendered: NSAttributedString

    // init(markdown, rendered): Capture a Markdown block with the exact
    // attributed text produced by its renderer.
    init(markdown: String, rendered: NSAttributedString) {
        self.markdown = markdown
        self.rendered = rendered
    }
}

// Round-trip editable attributed text to Markdown while preserving supported formatting.
enum ResultTextFormatting {
    // baseSize(attributes): Keep the unraised size so toggling superscript
    // never progressively shrinks the text.
    static func baseSize(in attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        (attributes[.resultEditorFontSize] as? CGFloat)
            ?? (attributes[.resultEditorScriptBaseSize] as? CGFloat)
            ?? (attributes[.font] as? NSFont)?.pointSize ?? 17
    }

    // script(attributes): Read explicit script formatting, falling back to the
    // text's existing baseline offset.
    static func script(in attributes: [NSAttributedString.Key: Any]) -> Int {
        // Prefer the editor's explicit script choice over inferred baseline positioning.
        if let explicit = attributes[.resultEditorScript] as? Int { return explicit }
        let offset = attributes[.baselineOffset] as? CGFloat ?? 0
        return offset > 0 ? 1 : (offset < 0 ? -1 : 0)
    }

    // typography(attributes, [size = nil], [script = nil]): Apply base font
    // size and script position without repeatedly shrinking raised or lowered
    // text.
    static func typography(_ attributes: [NSAttributedString.Key: Any], size: CGFloat? = nil, script: Int? = nil) -> [NSAttributedString.Key: Any] {
        var result = attributes
        let base = size ?? baseSize(in: attributes)
        let position = script ?? self.script(in: attributes)
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: base)
        result[.font] = NSFontManager.shared.convert(font, toSize: position == 0 ? base : max(base * 0.72, 6))
        // Remember an explicitly selected base size for later serialization and script toggles.
        if let size { result[.resultEditorFontSize] = size }
        // Remember an explicit baseline choice even when it means returning to normal text.
        if let script { result[.resultEditorScript] = script }
        // Clear inherited raising or lowering when the chosen position is the normal baseline.
        if position == 0 {
            result.removeValue(forKey: .baselineOffset)
            result.removeValue(forKey: .resultEditorScriptBaseSize)
        } else {
            // Apply a proportional baseline shift for superscript or subscript.
            result[.baselineOffset] = base * (position > 0 ? 0.30 : -0.20)
            result[.resultEditorScriptBaseSize] = base
        }
        return result
    }

    // rememberBlock(markdown, range, text): Remember a nonempty rendered block
    // so unchanged text can reuse its original Markdown.
    static func rememberBlock(markdown: String, range: NSRange, in text: NSMutableAttributedString) {
        // Empty ranges cannot carry a meaningful remembered Markdown block.
        guard range.length > 0 else { return }
        let block = ResultEditorBlock(markdown: markdown, rendered: text.attributedSubstring(from: range))
        text.addAttribute(.resultEditorBlock, value: block, range: range)
    }

    // comparable(text): Remove render-specific identity and normalize
    // equivalent typography before comparing blocks.
    static func comparable(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        copy.removeAttribute(.resultEditorBlock, range: NSRange(location: 0, length: copy.length))
        // AppKit may substitute an equivalent system-font family during layout. Markdown stores
        // size and emphasis, so that substitution must not turn an untouched block into an edit.
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            // Skip runs without a font when normalizing typography for comparison.
            guard let font = value as? NSFont else { return }
            let traits = NSFontManager.shared.traits(of: font)
            var normalized = NSFont.systemFont(ofSize: font.pointSize, weight: traits.contains(.boldFontMask) ? .semibold : .regular)
            // Retain italic emphasis while normalizing equivalent system-font families.
            if traits.contains(.italicFontMask) { normalized = NSFontManager.shared.convert(normalized, toHaveTrait: .italicFontMask) }
            copy.addAttribute(.font, value: normalized, range: range)
        }
        return copy
    }

    // markdown(text): Serialize changed paragraphs while copying unchanged
    // source blocks verbatim.
    static func markdown(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        var result: [String] = []
        var index = 0
        // Serialize the document block by block while preserving unchanged original Markdown.
        while index < text.length {
            var range = NSRange()
            let block = text.attribute(.resultEditorBlock, at: index, longestEffectiveRange: &range,
                                       in: NSRange(location: 0, length: text.length)) as? ResultEditorBlock
            // Reuse a remembered block only when it covers the current complete block boundary.
            if let block, range.location == index,
               (NSMaxRange(range) == text.length || string.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)) == "\n") {
                let current = comparable(text.attributedSubstring(from: range))
                let original = NSMutableAttributedString(attributedString: block.rendered)
                // The renderer trims the last block's terminating newline.
                if !current.string.hasSuffix("\n"), original.string.hasSuffix("\n") {
                    original.deleteCharacters(in: NSRange(location: original.length - 1, length: 1))
                }
                // Emit the original Markdown when the block's meaningful text and formatting are unchanged.
                if current.isEqual(to: comparable(original)) {
                    result.append(block.markdown)
                    index = NSMaxRange(range)
                    continue
                }
            }
            // The viewer adds a caption below each source image. Fold an edited caption
            // back into its image syntax instead of appending it beside the old caption.
            if let block, range.location == index, range.length > 1,
               string.substring(with: NSRange(location: index, length: 2)) == "\u{fffc}\n",
               let image = sourceImageReferences(in: block.markdown).first, let id = image.id {
                let captionStart = index + 2
                let captionRange = string.paragraphRange(for: NSRange(location: captionStart, length: 0))
                let captionEnd = min(NSMaxRange(captionRange), NSMaxRange(range))
                let caption = NSMutableAttributedString(attributedString: text.attributedSubstring(
                    from: NSRange(location: captionStart, length: max(0, captionEnd - captionStart))))
                // Keep trailing paragraph breaks out of the serialized image caption.
                while caption.string.hasSuffix("\n") { caption.deleteCharacters(in: NSRange(location: caption.length - 1, length: 1)) }
                // The caption's page link is a viewer action, not part of the image label.
                caption.removeAttribute(.link, range: NSRange(location: 0, length: caption.length))
                result.append("![" + markdownInlineStyles(caption, heading: false) + "](langmin-source-image:" + id + ")")
                index = captionEnd
                // Consume block-ending newlines already represented by the reused Markdown.
                while index < NSMaxRange(range), string.substring(with: NSRange(location: index, length: 1)) == "\n" { index += 1 }
                continue
            }
            // Code paragraphs share a block ID. Save the whole run so an edit cannot split
            // one fence into several fences or discard blank lines between statements.
            var codeRange = NSRange()
            // Handle a code-block run as literal code instead of ordinary paragraph formatting.
            if text.attribute(.langminCodeBlock, at: index, longestEffectiveRange: &codeRange,
                              in: NSRange(location: 0, length: text.length)) != nil {
                codeRange = NSRange(location: index, length: NSMaxRange(codeRange) - index)
                var code = string.substring(with: codeRange)
                // Remove one trailing code newline before enclosing the block in a fence.
                if code.hasSuffix("\n") { code.removeLast() }
                let sourceLine = block?.markdown.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
                let marker = sourceLine.first
                let fenceLength = sourceLine.prefix(while: { $0 == marker }).count
                // Reuse the original fence style and language when the saved opening line is valid.
                if (marker == "`" || marker == "~"), fenceLength >= 3 {
                    let language = String(sourceLine.dropFirst(fenceLength))
                    let fence = String(repeating: "`", count: max(3, longestBacktickRun(code) + 1))
                    result.append(fence + language + "\n" + code + "\n" + fence)
                } else if block != nil {
                    // Tables use the same monospaced view but must remain Markdown tables.
                    result.append(code)
                } else {
                    // Choose a new fence longer than any literal backtick run in the code.
                    let fence = String(repeating: "`", count: max(3, longestBacktickRun(code) + 1))
                    result.append(fence + "\n" + code + "\n" + fence)
                }
                index = NSMaxRange(codeRange)
                continue
            }
            let paragraph = string.paragraphRange(for: NSRange(location: index, length: 0))
            let remaining = NSRange(location: index, length: NSMaxRange(paragraph) - index)
            // Append a paragraph only when its attributed content can be serialized.
            if let markdown = markdownParagraph(text.attributedSubstring(from: remaining)) {
                result.append(markdown)
            }
            index = NSMaxRange(paragraph)
        }
        return result.joined(separator: "\n\n")
    }

    // markdownParagraph(paragraph): Serialize one attributed paragraph with its
    // block style and inline formatting.
    static func markdownParagraph(_ paragraph: NSAttributedString) -> String? {
        let text = NSMutableAttributedString(attributedString: paragraph)
        // Strip paragraph-ending line separators before generating its block syntax.
        while text.string.hasSuffix("\n") || text.string.hasSuffix("\r") {
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        }
        // An empty paragraph contributes only an empty serialized block.
        guard text.length > 0 else { return "" }
        let attributes = text.attributes(at: 0, effectiveRange: nil)
        // A Sources divider is generated decoration; an explicit rule remains Markdown.
        // Check the characters too, so text typed in place of a divider is still saved.
        if let separator = attributes[.resultEditorSeparator] as? String,
           text.string.allSatisfy({ $0 == "─" }) {
            return separator == "sources" ? nil : "---"
        }
        // Preserve code as a fenced block instead of escaping its contents as prose.
        if attributes[.langminCodeBlock] != nil {
            let fence = String(repeating: "`", count: max(3, longestBacktickRun(text.string) + 1))
            return fence + "\n" + text.string + "\n" + fence
        }
        var prefix = ""
        // Citation numbers belong to Sources syntax and must not become escaped prose.
        if attributes[.resultEditorSourceEntry] != nil,
           let marker = text.string.range(of: #"^\[\d{1,3}\][ \t]+"#, options: .regularExpression) {
            prefix = String(text.string[marker])
            let range = NSRange(marker, in: text.string)
            var customized = false
            text.enumerateAttributes(in: range) { attributes, _, _ in
                customized = customized || attributes[.resultEditorFontSize] != nil || attributes[.resultEditorScript] != nil
            }
            // Retain a manually formatted source number when rebuilding its prefix.
            if customized { prefix = markdownInline(text.attributedSubstring(from: range)) }
            text.deleteCharacters(in: range)
            return prefix + markdownInline(text)
        }
        let heading = attributes[.resultEditorHeading] as? Int ?? 0
        // Restore heading syntax with a bounded heading level.
        if heading > 0 { prefix = String(repeating: "#", count: min(heading, 6)) + " " }
        // Restore the quote marker for paragraphs carrying quotation-bar formatting.
        if attributes[.langminBlockquoteBar] != nil { prefix = "> " }
        // Convert rendered list markers and tabs back into Markdown list syntax.
        if let match = text.string.range(of: #"^(?:•|\d+\.)\t"#, options: .regularExpression) {
            let marker = String(text.string[match]).replacingOccurrences(of: "•", with: "-")
            let indent = (attributes[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
            prefix = String(repeating: "  ", count: min(6, max(0, Int(indent / 24))))
                + marker.replacingOccurrences(of: "\t", with: " ")
            text.deleteCharacters(in: NSRange(match, in: text.string))
        }
        return prefix + markdownInline(text, heading: heading > 0)
    }

    // markdownInline(text, [heading = false]): Serialize complete link ranges
    // once, even when their labels contain several style runs.
    static func markdownInline(_ text: NSAttributedString, heading: Bool = false) -> String {
        var result = ""
        // Wrap each complete link once. Inline emphasis can split its attributes into runs,
        // but splitting a Sources entry into several links would lose part of its label.
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { link, range, _ in
            let content = text.attributedSubstring(from: range)
            let label = markdownInlineStyles(content, heading: heading)
            let destination = (link as? URL)?.absoluteString ?? (link as? String ?? "")
            // Wrap valid text-only link labels in one complete Markdown link.
            if let url = safeLink(destination), !content.string.contains("\u{fffc}") {
                let encoded = url.absoluteString.replacingOccurrences(of: "(", with: "%28")
                    .replacingOccurrences(of: ")", with: "%29")
                result += "[" + label + "](" + encoded + ")"
            // Preserve the visible label when the destination or attachment content cannot form a safe text link.
            } else { /* Keep an unlinked label as ordinary Markdown text. */ result += label }
        }
        return result
    }

    // markdownInlineStyles(text, heading): Serialize inline traits while
    // ignoring display-only attributes that should not split Markdown spans.
    static func markdownInlineStyles(_ text: NSAttributedString, heading: Bool) -> String {
        var result = ""
        let runs = NSMutableAttributedString(attributedString: text)
        // Display-only spacing on a code span's final character must not split its backtick run.
        for key in [NSAttributedString.Key.kern, .langminInlineCodeTrailingSpacing] {
            runs.removeAttribute(key, range: NSRange(location: 0, length: runs.length))
        }
        runs.enumerateAttributes(in: NSRange(location: 0, length: runs.length)) { attributes, range, _ in
            let raw = runs.attributedSubstring(from: range).string
            // Image attachments retain their source block; deleting one removes it.
            if raw == "\u{fffc}" {
                // Reuse remembered Markdown for content represented by an editor block.
                if let block = attributes[.resultEditorBlock] as? ResultEditorBlock { result += block.markdown }
                return
            }
            let leading = String(raw.prefix(while: { $0.isWhitespace }))
            let trailing = String(raw.reversed().prefix(while: { $0.isWhitespace }).reversed())
            let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Preserve whitespace-only runs without adding empty style delimiters.
            guard !body.isEmpty else { result += raw; return }
            var value = escaped(body)
            // Use a safe backtick delimiter around literal inline code.
            if attributes[.langminInlineCode] != nil {
                let ticks = String(repeating: "`", count: longestBacktickRun(body) + 1)
                let padding = body.hasPrefix("`") || body.hasSuffix("`") ? " " : ""
                // Foundation loses backtick styling inside link labels; a supported tag retains it.
                value = attributes[.link] != nil ? "<code>" + escaped(body) + "</code>"
                    : ticks + padding + body + padding + ticks
            }
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 15)
            let traits = NSFontManager.shared.traits(of: font)
            // Foundation drops nested Markdown emphasis in links and code. Supported tags
            // preserve those styles while keeping each link and code span intact.
            let linked = attributes[.link] != nil
            let useTags = linked || attributes[.langminInlineCode] != nil
            // Retain bold emphasis without adding redundant bold markers around an entire heading.
            if traits.contains(.boldFontMask) && !heading { value = useTags ? "<b>" + value + "</b>" : "**" + value + "**" }
            // Preserve italic emphasis using the selected serialization form.
            if traits.contains(.italicFontMask) { value = useTags ? "<i>" + value + "</i>" : "*" + value + "*" }
            // Preserve strikethrough using tags or Markdown delimiters as appropriate.
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { value = useTags ? "<s>" + value + "</s>" : "~~" + value + "~~" }
            // Serialize explicit underlining separately from the normal underline of a link.
            if (attributes[.underlineStyle] as? Int ?? 0) != 0, attributes[.link] == nil {
                value = "<u>" + value + "</u>"
            }
            // Markdown has no size or baseline syntax. Persist only these supported inline
            // HTML styles; the renderer interprets them without loading arbitrary HTML.
            if let script = attributes[.resultEditorScript] as? Int {
                // Record an explicit return to normal baseline so inherited script styling stays cleared.
                if script == 0 { value = "<span style=\"vertical-align: baseline\">" + value + "</span>" }
                // Use superscript or subscript tags for raised or lowered text.
                else { let tag = script > 0 ? "sup" : "sub"; value = "<\(tag)>" + value + "</\(tag)>" }
            }
            // Retain an explicitly chosen point size in the supported inline style form.
            if let size = attributes[.resultEditorFontSize] as? CGFloat {
                value = "<span style=\"font-size: \(size)pt\">" + value + "</span>"
            }
            result += leading + value + trailing
        }
        return result
    }

    // escaped(text): Escape Markdown punctuation when serializing literal text.
    static func escaped(_ text: String) -> String {
        let special = Set("\\`*_{}[]<>()#+-.!|~")
        return text.map { special.contains($0) ? "\\" + String($0) : String($0) }.joined()
    }

    // longestBacktickRun(text): Find the longest backtick sequence so code
    // spans can use a safe enclosing delimiter.
    static func longestBacktickRun(_ text: String) -> Int {
        var current = 0, longest = 0
        // Measure consecutive backticks to choose a delimiter that cannot close inside the content.
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }

    // safeLink(input): Links can open web pages or compose email; never persist
    // executable or app-internal actions.
    static func safeLink(_ input: String) -> URL? {
        // Accept only supported link schemes and a valid destination after trimming input whitespace.
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme),
              scheme == "mailto" || url.host?.isEmpty == false else { return nil }
        return url
    }

    // Represent the supported inline tags that survive editing and Markdown round-tripping.
    enum InlineStyle {
        // Carry the inline formats that the editor can preserve when saving Markdown.
        case underline, bold, italic, strikethrough, code, size(CGFloat), script(Int)
    }

    // Pair a temporary parser token with the inline style it represents.
    struct InlineStyleMarker {
        let token: String
        let style: InlineStyle
    }

    // prepareInlineStyles(source): Recognize a small set of balanced tags,
    // leaving escaped examples and code literal. Unique markers let Markdown
    // parse emphasis and links inside each styled range.
    static func prepareInlineStyles(_ source: String) -> (source: String, markers: [InlineStyleMarker]) {
        // Skip tag preparation entirely when no opening tag marker exists.
        guard source.contains("<") else { return (source, []) }
        var index = source.startIndex
        var codeTicks = 0
        var opens: [(range: Range<String.Index>, name: String, style: InlineStyle)] = []
        var tags: [(Range<String.Index>, String)] = []
        var markers: [InlineStyleMarker] = []
        let token = "LangminStyle" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // Scan source characters while tracking escapes and inline-code boundaries.
        while index < source.endIndex {
            let character = source[index]
            // Treat the next prose character as escaped instead of interpreting it as a style tag.
            if character == "\\", codeTicks == 0 {
                index = source.index(after: index)
                // Skip the escaped character only when one remains in the string.
                if index < source.endIndex { index = source.index(after: index) }
                continue
            }
            // Measure a backtick run before deciding whether code begins or ends.
            if character == "`" {
                let start = index
                // Consume the entire run so only an equal-length delimiter can close code.
                while index < source.endIndex && source[index] == "`" { index = source.index(after: index) }
                let count = source.distance(from: start, to: index)
                // Enter code at its opener and leave it only at a matching delimiter.
                if codeTicks == 0 { codeTicks = count } else if codeTicks == count { /* Open a code span, or close it only with the same backtick count. */ codeTicks = 0 }
                continue
            }
            // Recognize bounded style tags only outside inline code.
            if codeTicks == 0, character == "<", let close = source[index...].prefix(96).firstIndex(of: ">") {
                let end = source.index(after: close)
                let tag = String(source[index..<end])
                // Remember supported opening tags for properly nested matching.
                if let style = inlineStyle(for: tag) {
                    let name = tag.hasPrefix("<span ") ? "span" : String(tag.dropFirst().dropLast())
                    opens.append((index..<end, name, style))
                    index = end
                    continue
                }
                // Pair a closing tag only with the most recent compatible opener.
                if let open = opens.last, tag == "</" + open.name + ">" {
                    opens.removeLast()
                    let id = token + String(markers.count)
                    markers.append(InlineStyleMarker(token: id, style: open.style))
                    tags.append((open.range, id + "Open"))
                    tags.append((index..<end, id + "Close"))
                    index = end
                    continue
                }
            }
            index = source.index(after: index)
        }
        let prepared = NSMutableString(string: source)
        // Replace tag ranges from the end so earlier source offsets stay valid.
        for (range, replacement) in tags.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            prepared.replaceCharacters(in: NSRange(range, in: source), with: replacement)
        }
        return (prepared as String, markers)
    }

    // inlineStyle(tag): Map a supported inline tag to its text-formatting
    // operation.
    private static func inlineStyle(for tag: String) -> InlineStyle? {
        // Translate supported tag spellings into editor formatting operations.
        switch tag {
        // Recognize explicit underlining.
        case "<u>": return .underline
        // Recognize explicit bold text.
        case "<b>": return .bold
        // Recognize explicit italic text.
        case "<i>": return .italic
        // Recognize explicit strikethrough.
        case "<s>": return .strikethrough
        // Recognize literal inline code styling.
        case "<code>": return .code
        // Recognize superscript positioning.
        case "<sup>": return .script(1)
        // Recognize subscript positioning.
        case "<sub>": return .script(-1)
        // Recognize an explicit return to the normal baseline.
        case "<span style=\"vertical-align: baseline\">": return .script(0)
        // Handle bounded point-size spans after the fixed tag forms.
        default:
            let prefix = "<span style=\"font-size: "
            // Reject malformed, nonfinite, or unsupported point-size values.
            guard tag.hasPrefix(prefix), tag.hasSuffix("pt\">"),
                  let size = Double(tag.dropFirst(prefix.count).dropLast(4)), size.isFinite,
                  (6...96).contains(size) else { return nil }
            return .size(CGFloat(size))
        }
    }

    // removingInlineStyleTags(source): Strip only recognized inline style tags
    // while retaining their enclosed text.
    static func removingInlineStyleTags(_ source: String) -> String {
        let prepared = prepareInlineStyles(source)
        return prepared.markers.reduce(prepared.source) { text, marker in
            text.replacingOccurrences(of: marker.token + "Open", with: "")
                .replacingOccurrences(of: marker.token + "Close", with: "")
        }
    }

    // applyInlineStyles(text, markers): Apply outer inline styles before inner
    // overrides while retaining links and existing emphasis.
    static func applyInlineStyles(in text: NSMutableAttributedString, markers: [InlineStyleMarker]) {
        // Apply outer tags first so an inner size or baseline can override its parent,
        // while preserving link destinations and existing emphasis.
        for marker in markers.reversed() {
            let string = text.string as NSString
            let open = string.range(of: marker.token + "Open")
            let close = string.range(of: marker.token + "Close")
            // Ignore missing or reversed marker pairs instead of applying an invalid range.
            guard open.location != NSNotFound, close.location != NSNotFound, close.location >= NSMaxRange(open) else { continue }
            let range = NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open))
            let value = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
            let original = NSAttributedString(attributedString: value)
            original.enumerateAttributes(in: NSRange(location: 0, length: original.length)) { attributes, run, _ in
                // Apply the marker's style to each existing attribute run inside it.
                switch marker.style {
                // Add underline while preserving the run's other attributes.
                case .underline: value.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: run)
                // Add strikethrough while preserving the run's other attributes.
                case .strikethrough: value.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run)
                // Change the requested font trait without replacing unrelated formatting.
                case .bold, .italic:
                    let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 17)
                    let trait: NSFontTraitMask
                    // Choose bold for the bold marker and italic for the other emphasis marker.
                    if case .bold = marker.style { trait = .boldFontMask } else { /* Choose the font trait corresponding to the parsed emphasis marker. */ trait = .italicFontMask }
                    value.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: run)
                // Use a monospaced font and mark the run as inline code.
                case .code:
                    let previous = attributes[.font] as? NSFont ?? .systemFont(ofSize: 17)
                    let traits = NSFontManager.shared.traits(of: previous)
                    var font = NSFont.monospacedSystemFont(ofSize: previous.pointSize, weight: .regular)
                    // Preserve existing bold emphasis when converting a run to code typography.
                    if traits.contains(.boldFontMask) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                    // Preserve existing italic emphasis when converting a run to code typography.
                    if traits.contains(.italicFontMask) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                    value.addAttributes([.font: font, .langminInlineCode: true], range: run)
                // Apply the explicit point size through the shared typography rules.
                case .size(let size): value.setAttributes(typography(attributes, size: size), range: run)
                // Apply script position through the shared typography rules.
                case .script(let script): value.setAttributes(typography(attributes, script: script), range: run)
                }
            }
            text.replaceCharacters(in: NSRange(location: open.location, length: NSMaxRange(close) - open.location), with: value)
        }
    }
}
