import Cocoa

// Compare rendered text so Markdown syntax never competes with the change markers.
enum ResultTextDiff {
    static let changeAttribute = NSAttributedString.Key("LangminDiffChange")

    // render(original, revised): Compare rendered text and formatting through a
    // builder with a shared work budget.
    static func render(original: NSAttributedString, revised: NSAttributedString) -> NSAttributedString {
        Builder(original: original, revised: revised).render()
    }

    // Keep each comparison fragment tied to its original attributed-string range.
    private struct Slice {
        let text: String
        let range: NSRange
    }

    // Build a readable attributed diff without allowing comparisons to allocate unbounded tables.
    private final class Builder {
        let original: NSAttributedString
        let revised: NSAttributedString
        let result = NSMutableAttributedString(string: "")
        // Share one budget across paragraph and word comparisons; never allocate an unbounded LCS table.
        var remainingCells = 1_000_000

        // init(original, revised): Retain the original and revised attributed
        // text for text and formatting comparisons.
        init(original: NSAttributedString, revised: NSAttributedString) {
            self.original = original
            self.revised = revised
        }

        // render(): Align paragraphs first, then render changed regions between
        // matching anchors.
        func render() -> NSAttributedString {
            let before = paragraphs(original.string)
            let after = paragraphs(revised.string)
            let anchors = matches(before.map(\.text), after.map(\.text))
            var oldIndex = 0
            var newIndex = 0
            // Render changed paragraph regions between unchanged anchors, including the final region.
            for (oldAnchor, newAnchor) in anchors + [(before.count, after.count)] {
                let oldRange = oldIndex..<oldAnchor
                let newRange = newIndex..<newAnchor
                // Pair equal-sized changed regions so word-level edits stay readable within paragraphs.
                if oldRange.count == newRange.count {
                    // Compare corresponding paragraphs within this balanced region.
                    for (old, new) in zip(oldRange, newRange) {
                        appendParagraph(before[old], after[new])
                    }
                } else {
                    // Splits, merges and large unmatched sections keep their complete block layout.
                    for old in oldRange { appendBlock(before[old], from: original, change: "deleted") }
                    // Render unmatched revised paragraphs as inserted blocks.
                    for new in newRange { appendBlock(after[new], from: revised, change: "inserted") }
                }
                // Append the unchanged anchor unless this is the terminal sentinel.
                if oldAnchor < before.count, newAnchor < after.count {
                    appendParagraph(before[oldAnchor], after[newAnchor])
                }
                oldIndex = oldAnchor + 1
                newIndex = newAnchor + 1
            }
            return result
        }

        // paragraphs(text): Keep paragraph endings separate from word matching,
        // including the final unterminated line.
        func paragraphs(_ text: String) -> [Slice] {
            let ns = text as NSString
            var slices: [Slice] = []
            var offset = 0
            // Split the string into paragraph ranges without losing its original UTF-16 offsets.
            while offset < ns.length {
                var end = 0
                var contentsEnd = 0
                ns.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd,
                                     for: NSRange(location: offset, length: 0))
                slices.append(Slice(text: ns.substring(with: NSRange(location: offset, length: contentsEnd - offset)),
                                    range: NSRange(location: offset, length: end - offset)))
                offset = end
            }
            return slices
        }

        // tokens(slice): Preserve whitespace and punctuation, and never split
        // an emoji or combining-character sequence.
        func tokens(_ slice: Slice) -> [Slice] {
            var slices: [Slice] = []
            var start = slice.text.startIndex
            var offset = slice.range.location
            var length = 0
            var previousKind = -1
            // Group characters into comparable word, whitespace, and punctuation fragments.
            for index in slice.text.indices {
                let character = slice.text[index]
                let kind = character.isWhitespace ? 0 : (character.isLetter || character.isNumber ? 1 : 2)
                // End the current fragment when its kind changes or punctuation needs its own token.
                if length > 0, kind != previousKind || kind == 2 {
                    slices.append(Slice(text: String(slice.text[start..<index]), range: NSRange(location: offset, length: length)))
                    start = index
                    offset += length
                    length = 0
                }
                length += character.utf16.count
                previousKind = kind
            }
            // Retain the final fragment after the character scan ends.
            if length > 0 {
                slices.append(Slice(text: String(slice.text[start...]), range: NSRange(location: offset, length: length)))
            }
            return slices
        }

        // matches(before, after): Trim common ends first, making small edits to
        // long documents cheap.
        func matches(_ before: [String], _ after: [String]) -> [(Int, Int)] {
            var prefix = 0
            // Skip an already matching prefix before allocating comparison work.
            while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
            var oldEnd = before.count
            var newEnd = after.count
            // Skip a matching suffix so only the changed middle needs alignment.
            while oldEnd > prefix, newEnd > prefix, before[oldEnd - 1] == after[newEnd - 1] {
                oldEnd -= 1
                newEnd -= 1
            }
            var pairs = (0..<prefix).map { ($0, $0) }
            let rows = oldEnd - prefix
            let columns = newEnd - prefix
            // Allocate the comparison table only when both dimensions fit the remaining cell budget.
            if rows > 0, columns > 0, rows + 1 <= remainingCells / (columns + 1) {
                let width = columns + 1
                let cells = (rows + 1) * width
                remainingCells -= cells
                var table = [Int](repeating: 0, count: cells)
                // Build suffix match lengths from the last original fragment backward.
                for old in stride(from: rows - 1, through: 0, by: -1) {
                    // Compare each revised fragment against the current original fragment.
                    for new in stride(from: columns - 1, through: 0, by: -1) {
                        table[old * width + new] = before[prefix + old] == after[prefix + new]
                            ? table[(old + 1) * width + new + 1] + 1
                            : max(table[(old + 1) * width + new], table[old * width + new + 1])
                    }
                }
                var old = 0
                var new = 0
                // Recover matching pairs by walking the completed comparison table.
                while old < rows, new < columns {
                    // Matching fragments become anchors and advance both inputs.
                    if before[prefix + old] == after[prefix + new] {
                        pairs.append((prefix + old, prefix + new))
                        old += 1
                        new += 1
                    } else if table[(old + 1) * width + new] >= table[old * width + new + 1] {
                        // Skip an original fragment when that preserves at least as many future matches.
                        old += 1
                    } else {
                        // Otherwise skip a revised fragment to reach the next best anchor.
                        new += 1
                    }
                }
            }
            pairs += (0..<(before.count - oldEnd)).map { (oldEnd + $0, newEnd + $0) }
            return pairs
        }

        // appendParagraph(old, new): Preserve identical paragraphs and compare
        // changed text or formatting within the others.
        func appendParagraph(_ old: Slice, _ new: Slice) {
            // Reuse a paragraph unchanged only when both its text and meaningful formatting match.
            if old.text == new.text,
               comparable(original.attributedSubstring(from: old.range)).isEqual(to: comparable(revised.attributedSubstring(from: new.range))) {
                startParagraph()
                result.append(revised.attributedSubstring(from: new.range))
                return
            }
            let oldAttributes = original.attributes(at: old.range.location, effectiveRange: nil)
            let newAttributes = revised.attributes(at: new.range.location, effectiveRange: nil)
            // Changed list indentation or block type needs both layouts, not mixed paragraph attributes.
            let blockKeys: [NSAttributedString.Key] = [.paragraphStyle, .langminBlockquoteBar, .langminCodeBlock]
            // Render incompatible paragraph-level styles as whole-block replacement.
            if blockKeys.contains(where: { !equalAttribute($0, oldAttributes, newAttributes) }) {
                appendBlock(old, from: original, change: "deleted")
                appendBlock(new, from: revised, change: "inserted")
                return
            }
            startParagraph()
            let before = tokens(old)
            let after = tokens(new)
            let anchors = matches(before.map(\.text), after.map(\.text))
            var oldIndex = 0
            var newIndex = 0
            // Render word-level changes between matching token anchors.
            for (oldAnchor, newAnchor) in anchors + [(before.count, after.count)] {
                let deleted = combinedRange(before, oldIndex..<oldAnchor)
                let inserted = combinedRange(after, newIndex..<newAnchor)
                // Append deleted text using the revised paragraph's layout attributes.
                if let deleted { append(original, range: deleted, change: "deleted", paragraph: newAttributes) }
                if let inserted {
                    // A replacement needs a visible gap when neither side supplies its own space.
                    if deleted != nil, let last = lastCharacter(), !last.isWhitespace,
                       let first = revised.attributedSubstring(from: inserted).string.first, !first.isWhitespace {
                        appendSeparator(" ", attributes: newAttributes)
                    }
                    append(revised, range: inserted, change: "inserted")
                }
                // Render each real matched token with its formatting comparison.
                if oldAnchor < before.count, newAnchor < after.count {
                    appendMatchedToken(before[oldAnchor], after[newAnchor])
                }
                oldIndex = oldAnchor + 1
                newIndex = newAnchor + 1
            }
            let bodyLength = (new.text as NSString).length
            let ending = NSRange(location: new.range.location + bodyLength, length: new.range.length - bodyLength)
            // Preserve the revised paragraph's trailing newline and its attributes.
            if ending.length > 0 { result.append(revised.attributedSubstring(from: ending)) }
        }

        // combinedRange(slices, indices): Convert adjacent fragment indices
        // into one continuous attributed-string range.
        func combinedRange(_ slices: [Slice], _ indices: Range<Int>) -> NSRange? {
            // An empty fragment interval has no continuous text range to append.
            guard let first = indices.first, let last = indices.last else { return nil }
            return NSRange(location: slices[first].range.location,
                           length: NSMaxRange(slices[last].range) - slices[first].range.location)
        }

        // appendMatchedToken(old, new): Flag style and link-target changes even
        // when the visible word is unchanged.
        func appendMatchedToken(_ old: Slice, _ new: Slice) {
            let oldText = original.attributedSubstring(from: old.range)
            let newText = revised.attributedSubstring(from: new.range)
            let changed = !comparable(oldText).isEqual(to: comparable(newText))
            append(revised, range: new.range, change: changed ? "inserted" : nil)
        }

        // comparable(text): Normalize per-render code-block identities before
        // comparing meaningful formatting.
        func comparable(_ text: NSAttributedString) -> NSAttributedString {
            let copy = NSMutableAttributedString(attributedString: text)
            text.enumerateAttribute(.langminCodeBlock, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                // Compare code-block membership independently of its per-render block identifier.
                if value != nil { copy.addAttribute(.langminCodeBlock, value: true, range: range) }
            }
            return copy
        }

        // equalAttribute(key, lhs, rhs): Compare attribute values while
        // treating code-block membership separately from its unique ID.
        func equalAttribute(_ key: NSAttributedString.Key, _ lhs: [NSAttributedString.Key: Any],
                            _ rhs: [NSAttributedString.Key: Any]) -> Bool {
            // Treat all present code-block identifiers as equivalent formatting.
            if key == .langminCodeBlock { return (lhs[key] != nil) == (rhs[key] != nil) }
            // An attribute missing from both runs is unchanged.
            if lhs[key] == nil, rhs[key] == nil { return true }
            // Noncomparable or one-sided attribute values cannot be treated as equal.
            guard let left = lhs[key] as? NSObject, let right = rhs[key] as? NSObject else { return false }
            return left.isEqual(right)
        }

        // appendBlock(slice, text, change): Append a complete inserted or
        // deleted block at a paragraph boundary.
        func appendBlock(_ slice: Slice, from text: NSAttributedString, change: String) {
            startParagraph()
            append(text, range: slice.range, change: change)
        }

        // startParagraph(): Start a paragraph only when the preceding result
        // has not already ended with a newline.
        func startParagraph() {
            // Add a separator only when the preceding block has no ending newline.
            if result.length > 0, lastCharacter()?.isNewline != true {
                appendSeparator("\n", attributes: result.attributes(at: result.length - 1, effectiveRange: nil))
            }
        }

        // lastCharacter(): Read the last complete character without splitting a
        // composed Unicode sequence.
        func lastCharacter() -> Character? {
            // An empty diff has no last character to inspect.
            guard result.length > 0 else { return nil }
            let ns = result.mutableString
            return ns.substring(with: ns.rangeOfComposedCharacterSequence(at: ns.length - 1)).first
        }

        // appendSeparator(text, attributes): Mark layout separators separately
        // from inserted or deleted content.
        func appendSeparator(_ text: String, attributes: [NSAttributedString.Key: Any]) {
            var style = attributes
            style[ResultTextDiff.changeAttribute] = "separator"
            result.append(NSAttributedString(string: text, attributes: style))
        }

        // append(source, range, change, [paragraph = nil]): Overlay change
        // colors without dropping fonts, links, indentation or code/quote
        // backgrounds.
        func append(_ source: NSAttributedString, range: NSRange, change: String?,
                    paragraph: [NSAttributedString.Key: Any]? = nil) {
            let text = NSMutableAttributedString(attributedString: source.attributedSubstring(from: range))
            let fullRange = NSRange(location: 0, length: text.length)
            // Use the surrounding revised paragraph's layout for inline changes.
            if let paragraph {
                // Replace only paragraph-level attributes, preserving the changed text's inline formatting.
                for key: NSAttributedString.Key in [.paragraphStyle, .langminCodeBlock, .langminBlockquoteBar] {
                    text.removeAttribute(key, range: fullRange)
                    // Restore each paragraph attribute only when the revised paragraph defines it.
                    if let value = paragraph[key] { text.addAttribute(key, value: value, range: fullRange) }
                }
            }
            // Mark changed text for insertion or deletion styling.
            if let change {
                text.addAttribute(ResultTextDiff.changeAttribute, value: change, range: fullRange)
                // Code has a dark background in both appearances.
                let snapshot = NSAttributedString(attributedString: text)
                snapshot.enumerateAttributes(in: fullRange) { attributes, run, _ in
                    let onCode = attributes[.langminCodeBlock] != nil || attributes[.langminInlineCode] != nil
                    text.addAttribute(.foregroundColor, value: Self.color(deleted: change == "deleted", onCode: onCode), range: run)
                }
                // Strike through deleted text so its removal remains clear without relying only on color.
                if change == "deleted" {
                    text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange)
                }
            }
            result.append(text)
        }

        // color(deleted, onCode): Choose readable insertion or deletion colors
        // for the background and appearance.
        static func color(deleted: Bool, onCode: Bool) -> NSColor {
            NSColor(name: nil) { appearance in
                let dark = onCode || appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                // Use the deletion color pair; the other return path supplies insertion colors.
                if deleted {
                    return dark ? NSColor(calibratedRed: 1, green: 0.46, blue: 0.42, alpha: 1)
                        : NSColor(calibratedRed: 0.72, green: 0.18, blue: 0.16, alpha: 1)
                }
                return dark ? NSColor(calibratedRed: 0.42, green: 0.88, blue: 0.52, alpha: 1)
                    : NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.18, alpha: 1)
            }
        }
    }
}
