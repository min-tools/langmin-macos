// Remove unwanted invisible Unicode characters on the device.
// Adapted from guillaumemeyer/watermarks-remover's Layer A cleaner under the MIT license.
// See Resources/THIRD_PARTY_NOTICES.md for attribution and license terms.

import Foundation

// Return cleaned text together with counts of removed and replaced Unicode scalars.
struct TextWatermarkCleaningResult: Equatable {
    let text: String
    let removedCount: Int
    let replacedCount: Int

    var changed: Bool { removedCount > 0 || replacedCount > 0 }

    static let empty = TextWatermarkCleaningResult(text: "", removedCount: 0, replacedCount: 0)

    // appending(other): Combine independently cleaned fragments without losing
    // their change counts.
    func appending(_ other: TextWatermarkCleaningResult) -> TextWatermarkCleaningResult {
        TextWatermarkCleaningResult(
            text: text + other.text,
            removedCount: removedCount + other.removedCount,
            replacedCount: replacedCount + other.replacedCount
        )
    }
}

// Remove suspicious invisible markers while preserving Unicode sequences needed for readable text.
enum TextWatermarkCleaner {
    // Potential invisible markers. Preserve them where needed for writing systems, emoji or layout.
    private static let stripCodePoints: Set<UInt32> = [
        0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5,
        0x180B, 0x180C, 0x180D, 0x180E, 0x180F,
        0x200B, 0x200C, 0x200D, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2060, 0x2061, 0x2062, 0x2063, 0x2064,
        0x2066, 0x2067, 0x2068, 0x2069,
        0x206A, 0x206B, 0x206C, 0x206D, 0x206E, 0x206F,
        0xFE00, 0xFE01, 0xFE02, 0xFE03, 0xFE04, 0xFE05, 0xFE06, 0xFE07,
        0xFE08, 0xFE09, 0xFE0A, 0xFE0B, 0xFE0C, 0xFE0D, 0xFE0E, 0xFE0F,
        0xFEFF, 0x3164, 0xFFA0, 0xFFF9, 0xFFFA, 0xFFFB
    ]

    private static let spaceHomoglyphs: Set<UInt32> = [
        0x00A0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
        0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000
    ]

    private static let preservableBidiCodePoints: Set<UInt32> = [
        0x061C, 0x200E, 0x200F, 0x2066, 0x2067, 0x2068, 0x2069
    ]
    private static let emojiGlueCodePoints: Set<UInt32> = [0x200D, 0xFE0E, 0xFE0F]
    private static let scriptJoiners: Set<UInt32> = [0x200C, 0x200D]
    private static let mongolianVariationSelectors: Set<UInt32> = [0x180B, 0x180C, 0x180D, 0x180F]
    private static let khmerInherentVowels: Set<UInt32> = [0x17B4, 0x17B5]
    private static let hangulFillers: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0]
    private static let orthographicFormatControls: Set<UInt32> = [
        0x0600, 0x0601, 0x0602, 0x0603, 0x0604, 0x0605,
        0x06DD, 0x070F, 0x08E2, 0x110BD, 0x110CD
    ]

    // cleanMarkdown(text, [normalizeSpaces = false]): Clean prose while
    // preserving code blocks and inline code byte for byte; invisible
    // characters may be intentional in code.
    static func cleanMarkdown(_ text: String, normalizeSpaces: Bool = false) -> TextWatermarkCleaningResult {
        // An empty Markdown document requires no cleanup or change counting.
        guard !text.isEmpty else { return .empty }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result = TextWatermarkCleaningResult.empty
        var fence: (marker: Character, count: Int)?

        // Track fenced-code state across lines while preserving original line boundaries.
        for (index, line) in lines.enumerated() {
            let fenceRun = markdownFenceRun(in: line)
            let cleanedLine: TextWatermarkCleaningResult

            // Keep every line inside a fenced code block literal.
            if let activeFence = fence {
                cleanedLine = unchanged(line)
                // Leave code mode only for a compatible closing fence.
                if let fenceRun,
                   fenceRun.marker == activeFence.marker,
                   fenceRun.count >= activeFence.count,
                   fenceRun.isClosing {
                    fence = nil
                }
            } else if let fenceRun {
                // An opening fence begins a region whose contents must remain untouched.
                fence = (fenceRun.marker, fenceRun.count)
                cleanedLine = unchanged(line)
            } else {
                // Outside fences, clean prose while protecting inline code spans.
                cleanedLine = cleanInlineCodeAware(line, normalizeSpaces: normalizeSpaces)
            }

            result = result.appending(cleanedLine)
            // Restore line separators without appending an extra newline after the final line.
            if index + 1 < lines.count {
                result = result.appending(unchanged("\n"))
            }
        }

        return result
    }

    // clean(text, [normalizeSpaces = false]): Preserve special spaces by
    // default; they can control line breaks, alignment and word spacing.
    static func clean(_ text: String, normalizeSpaces: Bool = false) -> TextWatermarkCleaningResult {
        // Return zero changes immediately for empty plain text.
        guard !text.isEmpty else { return .empty }

        let scalars = Array(text.unicodeScalars)
        let validFlagTags = validFlagTagIndices(in: scalars)
        let validBidiEmbeddings = validBidiEmbeddingIndices(in: scalars)
        var output = String.UnicodeScalarView()
        var removedCount = 0
        var replacedCount = 0
        var previousKept: Unicode.Scalar?

        // Inspect Unicode scalars with their original positions and neighboring context.
        for (index, scalar) in scalars.enumerated() {
            let value = scalar.value
            let previousInput = index > 0 ? scalars[index - 1] : nil
            let nextInput = index + 1 < scalars.count ? scalars[index + 1] : nil

            // Preserve markers that are needed by a valid writing, emoji, or layout sequence.
            if shouldPreserve(
                scalar,
                previousKept: previousKept,
                previousInput: previousInput,
                nextInput: nextInput,
                index: index,
                validFlagTags: validFlagTags,
                validBidiEmbeddings: validBidiEmbeddings
            ) {
                output.append(scalar)
                // Keep the last substantive scalar available when intervening glue characters are preserved.
                if !isGlue(value) { previousKept = scalar }
                continue
            }

            // Remove unsupported invisible markers and count each removed scalar.
            if shouldStrip(scalar) {
                removedCount += 1
                continue
            }

            // Normalize space lookalikes only when the caller enabled that optional cleanup.
            if normalizeSpaces, spaceHomoglyphs.contains(value) {
                output.append(" ".unicodeScalars.first!)
                previousKept = " ".unicodeScalars.first
                replacedCount += 1
                continue
            }

            output.append(scalar)
            previousKept = scalar
        }

        return TextWatermarkCleaningResult(
            text: String(output),
            removedCount: removedCount,
            replacedCount: replacedCount
        )
    }

    // shouldPreserve(scalar, previousKept, previousInput, nextInput, index,
    // validFlagTags, validBidiEmbeddings): Preserve an otherwise removable
    // scalar when neighboring text gives it a writing or layout role.
    private static func shouldPreserve(
        _ scalar: Unicode.Scalar,
        previousKept: Unicode.Scalar?,
        previousInput: Unicode.Scalar?,
        nextInput: Unicode.Scalar?,
        index: Int,
        validFlagTags: Set<Int>,
        validBidiEmbeddings: Set<Int>
    ) -> Bool {
        let value = scalar.value

        // Directional marks, isolates, and complete LRE/RLE...PDF pairs are
        // legitimate in mixed right-to-left and left-to-right prose.
        if validBidiEmbeddings.contains(index) || preservableBidiCodePoints.contains(value) {
            return true
        }

        // Variation selectors need a preceding base character to justify preservation.
        if let previousInput {
            // Retain supplementary selectors immediately following an ideograph.
            if isSupplementaryVariationSelector(value), isCJKIdeograph(previousInput.value) {
                return true
            }
            // Retain Mongolian variation selectors after a Mongolian base.
            if mongolianVariationSelectors.contains(value), isMongolianBase(previousInput.value) {
                return true
            }
            // Retain supported basic variation selectors after an ideograph.
            if (0xFE00...0xFE0D).contains(value), isCJKIdeograph(previousInput.value) {
                return true
            }
        }

        // Keep selectors and joiners within emoji sequences; remove them when used alone.
        if emojiGlueCodePoints.contains(value) {
            // Preserve text and emoji presentation selectors after a compatible base.
            if (value == 0xFE0E || value == 0xFE0F),
               let previousInput,
               isEmojiBase(previousInput.value) {
                return true
            }
            // Preserve zero-width joiners when their neighboring scalars form a supported sequence.
            if value == 0x200D,
               let previousKept,
               let nextInput,
               isEmojiBase(previousKept.value),
               isEmojiBase(nextInput.value) {
                return true
            }
        }

        // ZWJ/ZWNJ are meaningful between letters from the same joining script.
        if scriptJoiners.contains(value),
           let previousInput,
           let nextInput,
           let previousScript = joiningScript(previousInput),
           previousScript == joiningScript(nextInput) {
            return true
        }

        // Keep tag characters only when they belong to a complete flag sequence.
        if (0xE0020...0xE007F).contains(value), validFlagTags.contains(index) {
            return true
        }
        // Allow a Mongolian selector whose preceding retained text provides its base.
        if mongolianVariationSelectors.contains(value),
           let previousKept,
           isMongolianLetter(previousKept) {
            return true
        }
        // Keep Khmer inherent-vowel controls in the script context that gives them meaning.
        if khmerInherentVowels.contains(value),
           let previousKept,
           isKhmerLetter(previousKept) {
            return true
        }
        // Preserve Hangul fillers alongside compatible jamo.
        if hangulFillers.contains(value),
           let previousKept,
           isHangulJamo(previousKept.value) {
            return true
        }
        // Keep supported orthographic controls used by writing systems.
        if orthographicFormatControls.contains(value) {
            return true
        }
        // Keep specialized layout controls only near text from their associated script range.
        if let scriptRange = layoutControlScriptRange(value),
           (previousInput.map { scriptRange.contains($0.value) } == true ||
            nextInput.map { scriptRange.contains($0.value) } == true) {
            return true
        }

        return false
    }

    // shouldStrip(scalar): Identify candidate invisible or reserved scalars
    // before context-sensitive preservation checks.
    private static func shouldStrip(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return stripCodePoints.contains(value)
            || isSupplementaryVariationSelector(value)
            || (0xE0001...0xE007F).contains(value)
            || isReservedIgnorable(value)
            || isNoncharacter(value)
            || isPrivateUse(value)
            || scalar.properties.generalCategory == .format
    }

    // validFlagTagIndices(scalars): Locate complete emoji flag-tag sequences so
    // their component tags remain intact.
    private static func validFlagTagIndices(in scalars: [Unicode.Scalar]) -> Set<Int> {
        var result = Set<Int>()
        var index = 0

        // Scan for complete tag-based flag sequences.
        while index < scalars.count {
            // Advance past scalars that are not the flag-sequence base.
            guard scalars[index].value == 0x1F3F4 else {
                index += 1
                continue
            }

            var end = index + 1
            // Collect tag characters following the flag base.
            while end < scalars.count, (0xE0020...0xE007E).contains(scalars[end].value) {
                end += 1
            }
            // Preserve only a nonempty tag sequence terminated by the cancel tag.
            if end > index + 1, end < scalars.count, scalars[end].value == 0xE007F {
                result.formUnion((index + 1)...end)
                index = end + 1
            } else {
                // Resume scanning when the candidate flag sequence is incomplete.
                index += 1
            }
        }

        return result
    }

    // validBidiEmbeddingIndices(scalars): Locate matched bidirectional
    // embeddings so intentional text direction remains intact.
    private static func validBidiEmbeddingIndices(in scalars: [Unicode.Scalar]) -> Set<Int> {
        var result = Set<Int>()
        var stack: [(value: UInt32, index: Int)] = []

        // Track directional openers and closers in their original order.
        for (index, scalar) in scalars.enumerated() {
            // Distinguish directional opening controls from their closing control.
            switch scalar.value {
            // Remember embedding and override openers so later closers can be matched.
            case 0x202A, 0x202B, 0x202D, 0x202E:
                stack.append((scalar.value, index))
            // Resolve a directional closing control against its most recent opener.
            case 0x202C:
                // Ignore an unmatched closing control.
                guard let opener = stack.popLast() else { continue }
                // Preserve matched embeddings while leaving directional overrides subject to cleanup.
                if opener.value == 0x202A || opener.value == 0x202B {
                    result.insert(opener.index)
                    result.insert(index)
                }
            // Ordinary scalars do not change the directional-control stack.
            default:
                continue
            }
        }

        return result
    }

    // joiningScript(scalar): Classify joining-script letters and marks for
    // context-sensitive joiner preservation.
    private static func joiningScript(_ scalar: Unicode.Scalar) -> Int? {
        // Punctuation and controls do not establish a joining-script context.
        guard isLetterOrMark(scalar) else { return nil }
        // Use supported code-point blocks to identify compatible script neighbors.
        switch scalar.value {
        // Identify the Arabic-script range used by joiner preservation.
        case 0x0600...0x08FF: return 1
        // Identify the supported Indic-script range used by joiner preservation.
        case 0x0900...0x0DFF: return 2
        // Identify the supported Tibetan and Myanmar range used by joiner preservation.
        case 0x0F00...0x109F: return 3
        // Identify Khmer text for script-specific joiner checks.
        case 0x1780...0x17FF: return 4
        // Identify Mongolian text for script-specific joiner checks.
        case 0x1800...0x18AF: return 5
        // Other blocks do not establish a supported joining-script group here.
        default: return nil
        }
    }

    // isLetterOrMark(scalar): Distinguish letters and combining marks from
    // punctuation, controls, and other scalars.
    private static func isLetterOrMark(_ scalar: Unicode.Scalar) -> Bool {
        // Use Unicode character categories to recognize substantive letters and combining marks.
        switch scalar.properties.generalCategory {
        // Letters and combining marks can provide the script context for a format control.
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        // Other categories do not count as letters or marks.
        default:
            return false
        }
    }

    // isMongolianLetter(scalar): Recognize Mongolian letters and marks that can
    // require script-specific controls.
    private static func isMongolianLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x1800...0x18AF).contains(scalar.value) && isLetterOrMark(scalar)
    }

    // isKhmerLetter(scalar): Recognize Khmer letters and marks that can require
    // script-specific controls.
    private static func isKhmerLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x1780...0x17FF).contains(scalar.value) && isLetterOrMark(scalar)
    }

    // isHangulJamo(value): Recognize modern and extended Hangul jamo used in
    // composed syllables.
    private static func isHangulJamo(_ value: UInt32) -> Bool {
        (0x1100...0x11FF).contains(value)
            || (0xA960...0xA97C).contains(value)
            || (0xD7B0...0xD7C6).contains(value)
            || (0x3131...0x318E).contains(value)
            || (0xFFA1...0xFFDC).contains(value)
    }

    // isGlue(value): Identify scalars that connect emoji or script sequences
    // and require neighboring context.
    private static func isGlue(_ value: UInt32) -> Bool {
        emojiGlueCodePoints.contains(value)
            || scriptJoiners.contains(value)
            || (0xE0020...0xE007F).contains(value)
            || mongolianVariationSelectors.contains(value)
            || khmerInherentVowels.contains(value)
            || hangulFillers.contains(value)
            || isSupplementaryVariationSelector(value)
            || (0xFE00...0xFE0F).contains(value)
    }

    // isEmojiBase(value): Recognize code-point ranges that can act as emoji
    // bases in preservation checks.
    private static func isEmojiBase(_ value: UInt32) -> Bool {
        (0x1F000...0x1FAFF).contains(value)
            || (0x2190...0x25FF).contains(value)
            || (0x2600...0x27BF).contains(value)
            || (0x2B00...0x2BFF).contains(value)
            || [0x203C, 0x2049, 0x2139, 0x2934, 0x2935,
                0x00A9, 0x00AE, 0x2122, 0x3030, 0x303D, 0x3297, 0x3299].contains(value)
            || value == 0x0023
            || value == 0x002A
            || (0x0030...0x0039).contains(value)
    }

    // isCJKIdeograph(value): Recognize ideographs that can legitimately carry
    // supplementary variation selectors.
    private static func isCJKIdeograph(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x323AF).contains(value)
    }

    // isMongolianBase(value): Recognize the Mongolian block for its
    // script-specific variation rules.
    private static func isMongolianBase(_ value: UInt32) -> Bool {
        (0x1800...0x18AF).contains(value)
    }

    // isSupplementaryVariationSelector(value): Recognize supplementary
    // variation selectors used to distinguish glyph forms.
    private static func isSupplementaryVariationSelector(_ value: UInt32) -> Bool {
        (0xE0100...0xE01EF).contains(value)
    }

    // layoutControlScriptRange(value): Map specialized layout controls to the
    // script range that gives them meaning.
    private static func layoutControlScriptRange(_ value: UInt32) -> ClosedRange<UInt32>? {
        // Choose the text range that gives each specialized layout-control block meaning.
        switch value {
        // Associate these controls with their hieroglyphic text range.
        case 0x13430...0x1343F: return 0x13000...0x143FF
        // Associate these controls with their shorthand text range.
        case 0x1BCA0...0x1BCA3: return 0x1BC00...0x1BCA3
        // Associate these controls with their musical-symbol range.
        case 0x1D173...0x1D17A: return 0x1D100...0x1D1FF
        // Other values have no specialized layout range in this check.
        default: return nil
        }
    }

    // isReservedIgnorable(value): Identify reserved default-ignorable code
    // points that have no supported text role here.
    private static func isReservedIgnorable(_ value: UInt32) -> Bool {
        value == 0x2065
            || value == 0xE0000
            || (0xFFF0...0xFFF8).contains(value)
            || (0xE0080...0xE00FF).contains(value)
            || (0xE01F0...0xE0FFF).contains(value)
    }

    // isNoncharacter(value): Recognize Unicode noncharacters across the basic
    // and supplementary planes.
    private static func isNoncharacter(_ value: UInt32) -> Bool {
        (0xFDD0...0xFDEF).contains(value) || (value & 0xFFFE) == 0xFFFE
    }

    // isPrivateUse(value): Recognize private-use ranges whose meaning cannot be
    // inferred from standard Unicode properties.
    private static func isPrivateUse(_ value: UInt32) -> Bool {
        (0xE000...0xF8FF).contains(value)
            || (0xF0000...0xFFFFD).contains(value)
            || (0x100000...0x10FFFD).contains(value)
    }

    // Describe a possible Markdown fence for preserving code content during cleanup.
    private struct MarkdownFenceRun {
        let marker: Character
        let count: Int
        let isClosing: Bool
    }

    // markdownFenceRun(line): Recognize valid indentation and delimiters before
    // entering or leaving a fenced code block.
    private static func markdownFenceRun(in line: String) -> MarkdownFenceRun? {
        let leadingSpaces = line.prefix { $0 == " " }.count
        // More than three leading spaces do not form a fenced-code marker here.
        guard leadingSpaces <= 3 else { return nil }
        let content = line.dropFirst(leadingSpaces)
        // Only backticks and tildes can introduce a code fence.
        guard let marker = content.first, marker == "`" || marker == "~" else { return nil }
        let count = content.prefix { $0 == marker }.count
        // A code fence needs at least three consecutive matching markers.
        guard count >= 3 else { return nil }
        let rest = content.dropFirst(count)
        let isClosing = rest.allSatisfy { $0 == " " || $0 == "\t" }
        return MarkdownFenceRun(marker: marker, count: count, isClosing: isClosing)
    }

    // cleanInlineCodeAware(line, normalizeSpaces): Clean prose around inline
    // code while preserving the code span's literal content.
    private static func cleanInlineCodeAware(
        _ line: String,
        normalizeSpaces: Bool
    ) -> TextWatermarkCleaningResult {
        let characters = Array(line)
        var result = TextWatermarkCleaningResult.empty
        var proseStart = 0
        var index = 0

        // Find inline-code delimiters while retaining the prose between them for cleanup.
        while index < characters.count {
            // Continue scanning ordinary characters until a backtick delimiter begins.
            guard characters[index] == "`" else {
                index += 1
                continue
            }

            let openingStart = index
            // Measure the full opening delimiter so embedded shorter runs remain literal code.
            while index < characters.count, characters[index] == "`" { index += 1 }
            let delimiterLength = index - openingStart
            var closingStart: Int?
            var search = index

            // Search for a closing run with the same delimiter length.
            while search < characters.count {
                // Skip code characters that cannot start a closing delimiter.
                guard characters[search] == "`" else {
                    search += 1
                    continue
                }
                let runStart = search
                // Measure each candidate closing backtick run in full.
                while search < characters.count, characters[search] == "`" { search += 1 }
                // Only an equal-length run closes this inline-code span.
                if search - runStart == delimiterLength {
                    closingStart = runStart
                    break
                }
            }

            // Leave unmatched backticks in prose instead of protecting the rest of the line as code.
            guard let closingStart else { continue }
            // Clean prose before the matched code span, then preserve the span itself.
            if proseStart < openingStart {
                result = result.appending(clean(
                    String(characters[proseStart..<openingStart]),
                    normalizeSpaces: normalizeSpaces
                ))
            }
            let closingEnd = closingStart + delimiterLength
            result = result.appending(unchanged(String(characters[openingStart..<closingEnd])))
            proseStart = closingEnd
            index = closingEnd
        }

        // Clean any prose remaining after the last preserved inline-code span.
        if proseStart < characters.count {
            result = result.appending(clean(
                String(characters[proseStart...]),
                normalizeSpaces: normalizeSpaces
            ))
        }
        return result
    }

    // unchanged(text): Wrap preserved text with zero removal and replacement
    // counts.
    private static func unchanged(_ text: String) -> TextWatermarkCleaningResult {
        TextWatermarkCleaningResult(text: text, removedCount: 0, replacedCount: 0)
    }
}
