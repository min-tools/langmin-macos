import Foundation
import CoreGraphics

// expect(actual, expected, name): Compare text results and print both values
// when a launcher rule differs.
private func expect(_ actual: String, _ expected: String, _ name: String) {
    // Terminate on a mismatched text expectation.
    guard actual == expected else {
        fputs("FAIL \(name)\nexpected: \(expected.debugDescription)\nactual:   \(actual.debugDescription)\n", stderr)
        exit(1)
    }
}

// expect(actual, expected, name): Compare ordered identifier lists without
// losing their order in failure output.
private func expect(_ actual: [String], _ expected: [String], _ name: String) {
    // Terminate when selected or recent identifiers differ from the expected list.
    guard actual == expected else {
        fputs("FAIL \(name)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
}

// expect(actual, expected, name): Compare chip-row groupings with their
// expected row membership.
private func expect(_ actual: [[Int]], _ expected: [[Int]], _ name: String) {
    // Fail when any chip was assigned to the wrong row.
    guard actual == expected else {
        fputs("FAIL \(name)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
}

private let allModes = ["proofread", "rewrite", "explain", "summarize", "translate", "dictionary"]

@main
// Run pure launcher behavior checks without launching AppKit windows.
private struct LauncherLogicTests {
    // main(): Exercise placement, chip layout, selection, and display-label
    // rules together.
    static func main() {
        palettePlacementTests()
        chipRowTests()
        pinnedModeTests()
        translationTargetTests()
        recentTargetTests()
        idListTests()
        labelTests()
        print("LauncherLogic: all tests passed")
    }

    // palettePlacementTests(): Check palette positioning against host and
    // screen constraints.
    static func palettePlacementTests() {
        // check(condition, name): Report the particular placement rule that
        // failed.
        func check(_ condition: Bool, _ name: String) {
            // A failed placement condition terminates the fixture.
            guard condition else {
                fputs("FAIL \(name)\n", stderr)
                exit(1)
            }
        }

        // Bottom controls open upward and keep the menu inside the launcher.
        let bounds = CGRect(x: 108, y: 308, width: 1100, height: 700)
        let chip = CGRect(x: 460, y: 360, width: 140, height: 36)
        let root = LauncherLogic.paletteLayout(
            anchor: chip, within: bounds, width: 380, listHeight: 212, chromeHeight: 0
        )
        check(root.opensUpward && bounds.contains(root.frame), "bottom chip opens inside the window")
        check(root.frame.minY == chip.maxY + 6, "upward palette stays attached to chip")

        // Larger submenus stay inside the window on the same side of the control.
        let drilled = LauncherLogic.paletteLayout(
            anchor: chip, within: bounds, width: 380, listHeight: 1600, chromeHeight: 82,
            opensUpward: root.opensUpward
        )
        check(drilled.opensUpward && bounds.contains(drilled.frame), "tall submenu stays inside the window")
        check(drilled.frame.minY == root.frame.minY, "submenu preserves bottom edge")
        check(drilled.listHeight == 430, "long lists scroll at their normal height cap")
        let filtered = LauncherLogic.paletteLayout(
            anchor: chip, within: bounds, width: 380, listHeight: 40, chromeHeight: 82,
            opensUpward: drilled.opensUpward
        )
        check(filtered.frame.minY == root.frame.minY, "filtering preserves bottom edge")

        // Top anchors, including the action search, keep opening down.
        let top = CGRect(x: 980, y: 920, width: 120, height: 30)
        let down = LauncherLogic.paletteLayout(
            anchor: top, within: bounds, width: 380, listHeight: 280, chromeHeight: 82
        )
        check(!down.opensUpward && bounds.contains(down.frame), "top menu opens down and fits horizontally")
        check(down.frame.maxY == top.minY - 6, "downward palette stays attached to anchor")

        // Cap the menu height using the supplied window bounds, including negative display origins.
        let smallBounds = CGRect(x: -1300, y: 100, width: 900, height: 300)
        let smallChip = CGRect(x: -550, y: 110, width: 120, height: 36)
        let small = LauncherLogic.paletteLayout(
            anchor: smallChip, within: smallBounds, width: 380, listHeight: 1600, chromeHeight: 82
        )
        check(small.opensUpward && smallBounds.contains(small.frame), "short secondary-display window contains menu")
        check(small.listHeight == 166, "short window reserves chrome and scrolls remaining rows")
    }

    // chipRowTests(): Check chip wrapping at representative widths and row
    // limits.
    static func chipRowTests() {
        expect(
            LauncherLogic.chipRows(widths: [], spacing: 10, maxRowWidth: 500),
            [],
            "no chips produce no rows"
        )
        expect(
            LauncherLogic.chipRows(widths: [100, 100, 100], spacing: 10, maxRowWidth: 500),
            [[0, 1, 2]],
            "chips that fit stay on one row"
        )
        // 100 + 10 + 100 + 10 + 100 = 320 exactly: the boundary chip still fits.
        expect(
            LauncherLogic.chipRows(widths: [100, 100, 100], spacing: 10, maxRowWidth: 320),
            [[0, 1, 2]],
            "exact-width row is not split"
        )
        // One point narrower forces the last chip down.
        expect(
            LauncherLogic.chipRows(widths: [100, 100, 100], spacing: 10, maxRowWidth: 319),
            [[0, 1], [2]],
            "one point of overflow wraps the last chip"
        )
        expect(
            LauncherLogic.chipRows(widths: [200, 200, 200, 200, 200], spacing: 10, maxRowWidth: 500),
            [[0, 1], [2, 3], [4]],
            "five equal chips wrap into two-per-row"
        )
        expect(
            LauncherLogic.chipRows(widths: [600, 600], spacing: 10, maxRowWidth: 500),
            [[0], [1]],
            "oversized chips each get their own row"
        )
        expect(
            LauncherLogic.chipRows(widths: [600, 100, 100], spacing: 10, maxRowWidth: 500),
            [[0], [1, 2]],
            "an oversized first chip does not orphan the rest"
        )
    }

    // pinnedModeTests(): Check pin toggles and preservation of the selected
    // mode.
    static func pinnedModeTests() {
        expect(
            LauncherLogic.normalizedPinnedModes(stored: [], allModes: allModes),
            allModes,
            "empty stored pins mean all modes pinned"
        )
        expect(
            LauncherLogic.normalizedPinnedModes(stored: ["translate", "proofread"], allModes: allModes),
            ["translate", "proofread"],
            "stored pin order is preserved"
        )
        expect(
            LauncherLogic.normalizedPinnedModes(stored: ["ghost", "unknown"], allModes: allModes),
            allModes,
            "only unknown pins fall back to all modes"
        )
        expect(
            LauncherLogic.normalizedPinnedModes(stored: ["ghost", "explain"], allModes: allModes),
            ["explain"],
            "unknown pins are dropped from a mixed list"
        )
        expect(
            LauncherLogic.togglingPinnedMode("translate", pins: ["proofread", "translate"], allModes: allModes),
            ["proofread"],
            "unpinning removes the mode"
        )
        expect(
            LauncherLogic.togglingPinnedMode("proofread", pins: ["proofread"], allModes: allModes),
            ["proofread"],
            "the last pin cannot be removed"
        )
        expect(
            LauncherLogic.togglingPinnedMode("rewrite", pins: ["translate", "proofread"], allModes: allModes),
            ["proofread", "rewrite", "translate"],
            "pinning re-canonicalizes into the standard mode order"
        )
        expect(
            LauncherLogic.togglingPinnedMode(
                "dictionary",
                pins: ["proofread", "rewrite", "explain", "summarize", "translate"],
                allModes: allModes
            ),
            allModes,
            "pinning the sixth mode restores the full set"
        )
    }

    // translationTargetTests(): Check ordered translation-target selection and
    // toggle behavior.
    static func translationTargetTests() {
        expect(
            LauncherLogic.togglingTranslationTarget("de", targets: ["ru", "sr"]),
            ["ru", "sr", "de"],
            "ticking a language appends it"
        )
        expect(
            LauncherLogic.togglingTranslationTarget("sr", targets: ["ru", "sr"]),
            ["ru"],
            "unticking a language removes it"
        )
        expect(
            LauncherLogic.togglingTranslationTarget("ru", targets: ["ru"]),
            ["ru"],
            "the last language cannot be unticked"
        )
        expect(
            LauncherLogic.togglingTranslationTarget("ru", targets: ["ru", "sr", "en"]),
            ["sr", "en"],
            "unticking the primary promotes the next language"
        )
    }

    // recentTargetTests(): Check recent-target ordering, deduplication, and
    // size limits.
    static func recentTargetTests() {
        expect(
            LauncherLogic.pushingRecentTarget("de", recents: ["ru", "sr"]),
            ["de", "ru", "sr"],
            "a new recent goes to the front"
        )
        expect(
            LauncherLogic.pushingRecentTarget("sr", recents: ["ru", "sr"]),
            ["sr", "ru"],
            "an existing recent moves to the front without duplicating"
        )
        expect(
            LauncherLogic.pushingRecentTarget("fr", recents: ["ru", "sr", "en", "de"]),
            ["fr", "ru", "sr", "en"],
            "the recents list caps at four entries"
        )

        let valid = ["ru", "sr", "en", "de", "es", "fr"]
        expect(
            LauncherLogic.recentTargetList(stored: [], currentID: "sr", padding: ["en", "es", "de"], validIDs: valid),
            ["sr", "en", "es"],
            "an empty history seeds from the current target and padding"
        )
        expect(
            LauncherLogic.recentTargetList(stored: ["ru", "sr"], currentID: "sr", padding: ["en"], validIDs: valid),
            ["ru", "sr", "en"],
            "a listed current target is not duplicated"
        )
        expect(
            LauncherLogic.recentTargetList(stored: ["ru"], currentID: "xx", padding: ["en", "es"], validIDs: valid),
            ["ru", "en", "es"],
            "an invalid current target is skipped"
        )
        expect(
            LauncherLogic.recentTargetList(
                stored: ["ru", "sr", "en", "de", "es"],
                currentID: "ru",
                padding: ["fr"],
                validIDs: valid
            ),
            ["ru", "sr", "en", "de"],
            "the recent list caps at four entries"
        )
        expect(
            LauncherLogic.recentTargetList(stored: ["ghost", "ru"], currentID: "ru", padding: [], validIDs: valid),
            ["ru"],
            "unknown stored ids are dropped"
        )
        expect(
            LauncherLogic.recentTargetList(stored: ["ru", "sr", "en"], currentID: "ru", padding: ["es"], validIDs: valid),
            ["ru", "sr", "en"],
            "padding stops once the minimum count is reached"
        )
    }

    // idListTests(): Check serialization and normalization of identifier lists.
    static func idListTests() {
        expect(
            LauncherLogic.idList(from: "proofread,translate,dictionary"),
            ["proofread", "translate", "dictionary"],
            "mode ids survive the id-list round trip unfiltered"
        )
        expect(
            LauncherLogic.idList(from: LauncherLogic.encodedIDList(["rewrite", "explain"])),
            ["rewrite", "explain"],
            "encode and decode are inverses"
        )
        expect(
            LauncherLogic.idList(from: " proofread , translate ,,"),
            ["proofread", "translate"],
            "whitespace and empty entries are dropped"
        )
        expect(LauncherLogic.idList(from: ""), [], "empty storage decodes to an empty list")
    }

    // labelTests(): Check compact labels for selected modes and languages.
    static func labelTests() {
        expect(
            LauncherLogic.translateChipSuffix(primaryTitle: "Српски", isSetPrimary: true, targetCount: 1),
            "→ Српски",
            "a single target shows no count"
        )
        expect(
            LauncherLogic.translateChipSuffix(primaryTitle: "Српски", isSetPrimary: true, targetCount: 3),
            "→ Српски +2",
            "extra targets show as a +N tail"
        )
        expect(
            LauncherLogic.translateChipSuffix(primaryTitle: "Deutsch", isSetPrimary: false, targetCount: 3),
            "→ Deutsch",
            "an explicit per-run override hides the count"
        )
        expect(
            LauncherLogic.translateChipSuffix(primaryTitle: "", isSetPrimary: true, targetCount: 2),
            "",
            "a missing title produces no suffix"
        )
        expect(LauncherLogic.hotkeyBadge(forModeIndex: 0), "⌃⇧1", "the first mode gets ⌃⇧1")
        expect(LauncherLogic.hotkeyBadge(forModeIndex: 5), "⌃⇧6", "the sixth mode gets ⌃⇧6")
        expect(LauncherLogic.hotkeyBadge(forModeIndex: nil), "", "unknown modes get no badge")
    }
}
