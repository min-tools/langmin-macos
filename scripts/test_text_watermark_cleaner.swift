import Foundation

// expect(actual, expected, name): Compare cleaned text and report any
// unexpected character changes.
private func expect(_ actual: String, _ expected: String, _ name: String) {
    // Fail immediately when cleanup differs from the expected preserved text.
    guard actual == expected else {
        fputs("FAIL \(name)\nexpected: \(expected.debugDescription)\nactual:   \(actual.debugDescription)\n", stderr)
        exit(1)
    }
}

// scalar(value): Construct exact Unicode scalar fixtures without invisible
// source literals.
private func scalar(_ value: UInt32) -> String {
    String(UnicodeScalar(value)!)
}

@main
// Exercise prose cleanup while preserving meaningful Unicode and code.
private struct TextWatermarkCleanerTests {
    // main(): Run the deterministic cleanup cases without accessing user
    // preferences.
    static func main() {
        expect(
            TextWatermarkCleaner.clean("Hello\u{200B}World\u{00AD}!").text,
            "HelloWorld!",
            "zero-width and soft-hyphen removal"
        )
        expect(
            TextWatermarkCleaner.clean("Normal ASCII and café — fine.").text,
            "Normal ASCII and café — fine.",
            "ordinary prose preservation"
        )
        expect(
            TextWatermarkCleaner.clean("a\u{2003}b\u{3000}c").text,
            "a\u{2003}b\u{3000}c",
            "typographic space preservation"
        )
        expect(
            TextWatermarkCleaner.clean("a\u{2003}b\u{3000}c", normalizeSpaces: true).text,
            "a b c",
            "optional space normalization"
        )
        expect(
            TextWatermarkCleaner.clean("⚖️ 👨‍👩‍👧 ❤️‍🔥").text,
            "⚖️ 👨‍👩‍👧 ❤️‍🔥",
            "emoji glue preservation"
        )
        expect(
            TextWatermarkCleaner.clean("a\u{200D}b\u{FE0F}").text,
            "ab",
            "floating emoji glue removal"
        )
        expect(
            TextWatermarkCleaner.clean("می\u{200C}روم क्\u{200D}ष").text,
            "می\u{200C}روم क्\u{200D}ष",
            "orthographic joiner preservation"
        )
        expect(
            TextWatermarkCleaner.clean("السعر \u{2066}123 USD\u{2069}\u{200F}").text,
            "السعر \u{2066}123 USD\u{2069}\u{200F}",
            "bidirectional isolate preservation"
        )
        expect(
            TextWatermarkCleaner.clean("abc\u{202E}def\u{202C}").text,
            "abcdef",
            "bidirectional override removal"
        )
        expect(
            TextWatermarkCleaner.clean("English \u{202B}العربية\u{202C} end").text,
            "English \u{202B}العربية\u{202C} end",
            "paired bidirectional embedding preservation"
        )
        expect(
            TextWatermarkCleaner.clean(
                "a\(scalar(0xE000))b\(scalar(0xFDD0))c\(scalar(0xE0080))d"
            ).text,
            "abcd",
            "private and reserved carrier removal"
        )
        expect(
            TextWatermarkCleaner.clean("ᠠ\u{180B}ᠡ ក\u{17B4}ខ ᄀ\u{115F}ᅡ").text,
            "ᠠ\u{180B}ᠡ ក\u{17B4}ខ ᄀ\u{115F}ᅡ",
            "script-specific filler preservation"
        )

        let markdown = "Prose\u{200B} `let hidden = \"\u{200B}\"` end\u{2060}."
        expect(
            TextWatermarkCleaner.cleanMarkdown(markdown).text,
            "Prose `let hidden = \"\u{200B}\"` end.",
            "inline code preservation"
        )
        let fenced = "Before\u{200B}\n```swift\nlet hidden = \"\u{200B}\"\n```\nAfter\u{2060}"
        expect(
            TextWatermarkCleaner.cleanMarkdown(fenced).text,
            "Before\n```swift\nlet hidden = \"\u{200B}\"\n```\nAfter",
            "fenced code preservation"
        )
        let unlabelledFence = "```\n\u{200B}\n```\nOutside\u{200B}"
        expect(
            TextWatermarkCleaner.cleanMarkdown(unlabelledFence).text,
            "```\n\u{200B}\n```\nOutside",
            "unlabelled fence preservation"
        )

        print("TextWatermarkCleaner: all tests passed")
    }
}
