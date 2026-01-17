import Cocoa

// Create folders in an editable chip. Fit its width to the text, up to a limit,
// and show an orange outline for duplicate names.
final class LibraryFolderChipEditorView: NSView {
    let textField = NSTextField()
    private let icon = NSImageView()
    private let placeholder: String
    var isDuplicate = false { didSet { refreshColors() } }

    // init(text, placeholder): Create a compact inline folder editor with its
    // initial name and placeholder.
    init(text: String, placeholder: String) {
        self.placeholder = placeholder
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.borderWidth = 1

        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium))
        icon.contentTintColor = .systemBlue
        icon.translatesAutoresizingMaskIntoConstraints = false

        textField.stringValue = text
        textField.placeholderString = placeholder
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        textField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(textField)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 29),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        refreshColors()
    }

    // init?(coder): Folder editors require their initial text and are
    // constructed in code.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Grow with the text, up to the chip-width limit.
    override var intrinsicContentSize: NSSize {
        let font = textField.font ?? NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let textWidth = max(
            ceil((textField.stringValue as NSString).size(withAttributes: [.font: font]).width),
            ceil((placeholder as NSString).size(withAttributes: [.font: font]).width)
        )
        return NSSize(width: min(29 + textWidth + 6 + 12, 190), height: 26)
    }

    // refreshWidth(): Request a new intrinsic width after the editable folder
    // name changes.
    func refreshWidth() {
        invalidateIntrinsicContentSize()
    }

    // refreshColors(): Match the editor's outline and icon colors to its normal
    // or duplicate-name state.
    private func refreshColors() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        layer?.borderColor = (isDuplicate ? NSColor.systemOrange : NSColor.controlAccentColor).cgColor
        // Match the icon to the duplicate-name outline color.
        icon.contentTintColor = isDuplicate ? .systemOrange : .systemBlue
    }

    // viewDidChangeEffectiveAppearance(): Refresh folder-editor colors after an
    // appearance change.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }
}

// Library filter chip for All or a folder, plus the button for creating folders.
final class LibraryFolderChipButton: NSButton {
    // Distinguish the All view, a named folder, and the folder-creation action.
    enum Kind: Equatable {
        // Represent the unfiltered All view and its unfiling drop behavior.
        case all
        // Represent a named folder and its filing destination.
        case folder(String)
        // The add chip starts creation of a new folder.
        case add
        // Collapsed remainder: "⋯ N" opens the overflow palette.
        case overflow
    }

    let kind: Kind
    var isSelectedChip = false { didSet { needsDisplay = true } }
    // Drop callbacks for All and folder chips. Other chips reject entry drags.
    var onDropEntry: ((String) -> Void)?
    private let chipTitle: String
    private let count: Int?
    private var isHovered = false
    private var isDropTargeted = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    // init(kind, title, count, target, action): Create a folder capsule with
    // its optional item count and activation target.
    init(kind: Kind, title: String, count: Int?, target: AnyObject?, action: Selector?) {
        self.kind = kind
        self.chipTitle = title
        self.count = count
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        self.title = ""
        translatesAutoresizingMaskIntoConstraints = false
        focusRingType = .default
        // Choose accessibility text according to the chip's action.
        switch kind {
        // Describe the creation chip as a New Folder action.
        case .add:
            setAccessibilityLabel(localized("new_folder_menu", "New Folder\u{2026}"))
            toolTip = localized("new_folder_menu", "New Folder\u{2026}")
        // Describe the overflow chip as access to additional folders.
        case .overflow:
            setAccessibilityLabel(localized("more_folders", "More folders"))
            toolTip = localized("more_folders", "More folders")
        // Use the displayed title for All and named-folder chips.
        case .all, .folder:
            setAccessibilityLabel(title)
            // Filing destinations: rows drag onto these.
            registerForDraggedTypes([.langminLibraryEntry])
        }
    }

    // draggingEntered(sender): ---- Drop target (All and folder chips) ----
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Accept a drag only when this chip has a filing handler and a valid entry payload.
        guard
            onDropEntry != nil,
            sender.draggingPasteboard.string(forType: .langminLibraryEntry) != nil
        // Reject unsupported drag content without activating drop-target feedback.
        else { return [] }
        isDropTargeted = true
        return .generic
    }

    // draggingExited(sender): Clear drop-target highlighting when a dragged
    // entry leaves the chip.
    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTargeted = false
    }

    // draggingEnded(sender): Clear drop-target highlighting after a drag
    // session ends.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTargeted = false
    }

    // performDragOperation(sender): Pass a valid dropped entry ID to the chip's
    // filing handler.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTargeted = false
        // Require a filing handler and entry ID before accepting the drop.
        guard
            let onDropEntry,
            let id = sender.draggingPasteboard.string(forType: .langminLibraryEntry)
        // Report an unsuccessful drop when the entry payload cannot be resolved.
        else { return false }
        onDropEntry(id)
        return true
    }

    // init?(coder): Folder chips are constructed in code with their kind and
    // action.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    private var titleFont: NSFont { NSFont.systemFont(ofSize: 12.5, weight: .medium) }
    private var countFont: NSFont { NSFont.systemFont(ofSize: 11.5, weight: .regular) }
    // Folder chips carry their count as a tiny raised superscript.
    private var superscriptCountFont: NSFont { NSFont.systemFont(ofSize: 9, weight: .medium) }

    private var showsFolderGlyph: Bool {
        // Only named-folder chips display the folder glyph.
        if case .folder = kind { return true }
        return false
    }

    // Limit chip width and truncate long names so folder actions remain accessible.
    private let maxChipWidth: CGFloat = 200

    override var intrinsicContentSize: NSSize {
        let height: CGFloat = 26
        // Give the icon-only Add chip its compact fixed width.
        if case .add = kind {
            return NSSize(width: 30, height: height)
        }
        var width: CGFloat = 22
        // Reserve horizontal space for a named folder's glyph.
        if showsFolderGlyph { width += 18 }
        width += ceil((chipTitle as NSString).size(withAttributes: [.font: titleFont]).width)
        // Include the count using the typography appropriate to the chip kind.
        if let count {
            let font = showsFolderGlyph ? superscriptCountFont : countFont
            let gap: CGFloat = showsFolderGlyph ? 3 : 6
            width += gap + ceil(("\(count)" as NSString).size(withAttributes: [.font: font]).width)
        }
        return NSSize(width: min(width, maxChipWidth), height: height)
    }

    // updateTrackingAreas(): Keep folder-chip hover tracking aligned with its
    // current bounds.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Replace the previous hover region after the chip's bounds change.
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // mouseEntered(event): Show folder-chip hover feedback.
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    // mouseExited(event): Remove folder-chip hover feedback.
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    // keyDown(event): Activate a focused folder chip with Return or Enter
    // before deferring other keys to AppKit.
    override func keyDown(with event: NSEvent) {
        // Activate a focused folder chip with Return or Enter.
        if event.keyCode == 36 || event.keyCode == 76 {
            performClick(nil)
            return
        }
        super.keyDown(with: event)
    }

    // drawFocusRingMask(): Match the keyboard focus ring to the folder chip's
    // capsule shape.
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    // draw(dirtyRect): Draw the folder chip's selection, hover, drop state,
    // title, and optional count.
    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSBezierPath(
            roundedRect: bounds,
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        )
        // Use the accent fill for the selected Library folder.
        if isSelectedChip {
            NSColor.controlAccentColor.setFill()
        } else {
            // Use a quieter background for unselected folders, brightening it on hover.
            NSColor.labelColor.withAlphaComponent(isHovered ? 0.12 : 0.07).setFill()
        }
        capsule.fill()
        // Show a ring while the chip is a drop target.
        if isDropTargeted {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1),
                xRadius: (bounds.height - 2) / 2,
                yRadius: (bounds.height - 2) / 2
            )
            ring.lineWidth = 2
            ring.stroke()
        }

        let primary: NSColor = isSelectedChip ? .white : .labelColor
        let quiet: NSColor = isSelectedChip
            ? NSColor.white.withAlphaComponent(0.72)
            : .secondaryLabelColor

        // Draw the creation chip as an icon-only action.
        if case .add = kind {
            // Draw the plus only when the system symbol can be loaded.
            if let plus = tintedSymbol("plus", color: quiet, pointSize: 11.5) {
                plus.draw(in: NSRect(
                    x: (bounds.width - plus.size.width) / 2,
                    y: (bounds.height - plus.size.height) / 2,
                    width: plus.size.width,
                    height: plus.size.height
                ))
            }
            return
        }

        var x: CGFloat = 11
        // Include the folder glyph for named folders when its symbol is available.
        if showsFolderGlyph,
           let glyph = tintedSymbol("folder", color: isSelectedChip ? primary : .systemBlue, pointSize: 10.5) {
            // Optically raised half a point (flipped coordinates, so up is
            // a smaller y).
            glyph.draw(in: NSRect(
                x: x,
                y: (bounds.height - glyph.size.height) / 2 - 0.5,
                width: glyph.size.width,
                height: glyph.size.height
            ))
            x += 18
        }
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: primary]
        let text = chipTitle as NSString
        let textSize = text.size(withAttributes: titleAttributes)
        // Reserve count width before truncating the folder name.
        var countReserve: CGFloat = 0
        // Reserve count width before fitting the folder title.
        if let count {
            let font = showsFolderGlyph ? superscriptCountFont : countFont
            let gap: CGFloat = showsFolderGlyph ? 3 : 6
            countReserve = gap + ceil(("\(count)" as NSString).size(withAttributes: [.font: font]).width)
        }
        let maxTitleWidth = max(0, bounds.width - x - countReserve - 11)
        let drawnTitleWidth = min(ceil(textSize.width), maxTitleWidth)
        // Draw the full title when the allocated space is sufficient.
        if drawnTitleWidth >= ceil(textSize.width) {
            text.draw(at: NSPoint(x: x, y: (bounds.height - textSize.height) / 2), withAttributes: titleAttributes)
        } else if drawnTitleWidth > 0 {
            // Truncate a title that has some space but cannot fit completely.
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            var truncating = titleAttributes
            truncating[.paragraphStyle] = paragraph
            text.draw(
                in: NSRect(
                    x: x,
                    y: (bounds.height - textSize.height) / 2,
                    width: drawnTitleWidth,
                    height: textSize.height
                ),
                withAttributes: truncating
            )
        }
        x += drawnTitleWidth
        // Draw a count only when the caller supplied one.
        if let count {
            if showsFolderGlyph {
                // Draw the count smaller and raised toward the label's cap height.
                let countAttributes: [NSAttributedString.Key: Any] = [
                    .font: superscriptCountFont,
                    .foregroundColor: quiet
                ]
                let countText = "\(count)" as NSString
                let countSize = countText.size(withAttributes: countAttributes)
                countText.draw(
                    at: NSPoint(x: x + 3, y: (bounds.height - countSize.height) / 2 - 4),
                    withAttributes: countAttributes
                )
            } else {
                // Use an ordinary inline count for chips without a folder glyph.
                let countAttributes: [NSAttributedString.Key: Any] = [.font: countFont, .foregroundColor: quiet]
                let countText = "\(count)" as NSString
                let countSize = countText.size(withAttributes: countAttributes)
                countText.draw(
                    at: NSPoint(x: x + 6, y: (bounds.height - countSize.height) / 2),
                    withAttributes: countAttributes
                )
            }
        }
    }
}
