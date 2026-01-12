import Foundation
import CoreGraphics

// Launcher layout, pinned modes, translation targets and labels.
// Kept separate from AppKit for unit tests.
enum LauncherLogic {
    // paletteLayout(anchor, bounds, width, listHeight, chromeHeight,
    // [opensUpward = nil]): Open toward the larger space, then keep that edge
    // fixed as the menu resizes. Scroll long lists within the available space.
    static func paletteLayout(
        anchor: CGRect, within bounds: CGRect, width: CGFloat,
        listHeight: CGFloat, chromeHeight: CGFloat, opensUpward: Bool? = nil
    ) -> (frame: CGRect, listHeight: CGFloat, opensUpward: Bool) {
        let gap: CGFloat = 6
        let above = max(0, bounds.maxY - anchor.maxY - gap)
        let below = max(0, anchor.minY - bounds.minY - gap)
        let upward = opensUpward ?? (above > below)
        let availableHeight = upward ? above : below
        let visibleList = max(0, min(listHeight, 430, availableHeight - chromeHeight))
        let height = chromeHeight + visibleList
        let fittedWidth = min(width, bounds.width)
        let x = min(max(anchor.minX, bounds.minX), bounds.maxX - fittedWidth)
        let y = upward ? anchor.maxY + gap : anchor.minY - gap - height
        // Keep the panel onscreen even when its anchor is partly outside the window.
        let fittedY = min(max(y, bounds.minY), max(bounds.minY, bounds.maxY - height))
        return (CGRect(x: x, y: fittedY, width: fittedWidth, height: height), visibleList, upward)
    }

    // chipRows(widths, spacing, maxRowWidth): Fill each row in order. A chip
    // wider than maxRowWidth gets a row of its own.
    static func chipRows(widths: [CGFloat], spacing: CGFloat, maxRowWidth: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var rowWidth: CGFloat = 0
        // Place chips in their original order while tracking the occupied row width.
        for (index, width) in widths.enumerated() {
            // Start a row for the first chip or when the next chip would overflow.
            if rows.isEmpty || (!rows[rows.count - 1].isEmpty && rowWidth + spacing + width > maxRowWidth) {
                rows.append([index])
                rowWidth = width
            } else {
                // Append a chip that still fits in the current row.
                rows[rows.count - 1].append(index)
                rowWidth += spacing + width
            }
        }
        return rows
    }

    // normalizedPinnedModes(stored, allModes): Keep known pinned modes in their
    // stored order. An empty list means all modes.
    static func normalizedPinnedModes(stored: [String], allModes: [String]) -> [String] {
        let known = stored.filter { allModes.contains($0) }
        return known.isEmpty ? allModes : known
    }

    // togglingPinnedMode(mode, pins, allModes): Keep at least one mode pinned
    // and order newly pinned modes by the standard mode list.
    static func togglingPinnedMode(_ mode: String, pins: [String], allModes: [String]) -> [String] {
        var result = pins
        // An already pinned mode is being removed from the shortlist.
        if result.contains(mode) {
            // Keep at least one mode pinned so the launcher retains an available action.
            guard result.count > 1 else { return pins }
            result.removeAll { $0 == mode }
            return result
        }
        result.append(mode)
        return allModes.filter { result.contains($0) }
    }

    // togglingTranslationTarget(id, targets): Keep at least one target
    // language; the first is the primary output language.
    static func togglingTranslationTarget(_ id: String, targets: [String]) -> [String] {
        var result = targets
        // An already selected language is being removed from the target list.
        if result.contains(id) {
            // Keep at least one translation target selected.
            guard result.count > 1 else { return targets }
            result.removeAll { $0 == id }
            return result
        }
        result.append(id)
        return result
    }

    // pushingRecentTarget(id, recents, [limit = 4]): Move the target to the
    // front, remove duplicates and keep at most limit entries.
    static func pushingRecentTarget(_ id: String, recents: [String], limit: Int = 4) -> [String] {
        var result = recents.filter { $0 != id }
        result.insert(id, at: 0)
        return Array(result.prefix(limit))
    }

    // recentTargetList(stored, currentID, padding, validIDs, [minimumCount =
    // 3], [limit = 4]): Use valid recent targets, include the primary target,
    // then fill any empty slots from defaults.
    static func recentTargetList(
        stored: [String],
        currentID: String,
        padding: [String],
        validIDs: [String],
        minimumCount: Int = 3,
        limit: Int = 4
    ) -> [String] {
        var ids = stored.filter { validIDs.contains($0) }
        // Include the currently selected valid item even if it was absent from the shortlist.
        if !ids.contains(currentID), validIDs.contains(currentID) {
            ids.insert(currentID, at: 0)
        }
        // Fill short lists with valid fallback choices that are not already present.
        for candidate in padding where !ids.contains(candidate) && validIDs.contains(candidate) {
            // Stop adding defaults as soon as the required minimum is reached.
            if ids.count >= minimumCount { break }
            ids.append(candidate)
        }
        return Array(ids.prefix(limit))
    }

    // translateChipSuffix(primaryTitle, isSetPrimary, targetCount): Show the
    // primary language and extra-target count. Omit the count for a per-run
    // language override.
    static func translateChipSuffix(primaryTitle: String, isSetPrimary: Bool, targetCount: Int) -> String {
        // Do not show a translation arrow without a primary language name.
        guard !primaryTitle.isEmpty else { return "" }
        // Indicate additional targets when the primary choice represents a language set.
        if isSetPrimary, targetCount > 1 {
            return "→ \(primaryTitle) +\(targetCount - 1)"
        }
        return "→ \(primaryTitle)"
    }

    // hotkeyBadge(index): Use the mode's position for its shortcut badge; omit
    // the badge for unknown modes.
    static func hotkeyBadge(forModeIndex index: Int?) -> String {
        // Omit the shortcut hint for a mode that has no numbered position.
        guard let index else { return "" }
        return "⌃⇧\(index + 1)"
    }

    // idList(stored): Read comma-separated IDs. The caller filters them against
    // the relevant catalog.
    static func idList(from stored: String) -> [String] {
        stored.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // encodedIDList(ids): Serialize ordered selection IDs in the preferences
    // list format.
    static func encodedIDList(_ ids: [String]) -> String {
        ids.joined(separator: ",")
    }
}
