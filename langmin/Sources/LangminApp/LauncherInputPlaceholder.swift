import Cocoa

// installLauncherInputPlaceholder(field, input, scrollView, dropHint): Attach a
// click-through welcome state and keep it synchronized with real editor
// changes.
@discardableResult
func installLauncherInputPlaceholder(in field: LauncherFieldContainer, input: LauncherInputView,
                                     scrollView: NSScrollView, dropHint: NSTextField) -> LauncherInputPlaceholderView {
    let welcome = LauncherInputPlaceholderView(frame: .zero)
    welcome.translatesAutoresizingMaskIntoConstraints = false
    field.addSubview(welcome)
    input.usesCenteredPlaceholder = true
    input.setAccessibilityHelp(localized("drop_hint", "Drop or paste documents, images, or audio"))
    input.onPresentationChange = { [weak input, weak welcome, weak dropHint, weak field] in
        // Ignore presentation updates after the input or placeholder has gone away.
        guard let input, let welcome else { return }
        welcome.isHidden = !input.string.isEmpty || input.isImportingFiles
        // Avoid relaying out the hidden illustrations on every keystroke.
        if !welcome.isHidden { welcome.update(prompt: input.placeholderString, dragging: input.isReceivingFileDrop) }
        dropHint?.isHidden = input.string.isEmpty
        field?.isDropTarget = input.isReceivingFileDrop
    }
    NSLayoutConstraint.activate([
        welcome.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
        welcome.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
        welcome.topAnchor.constraint(equalTo: scrollView.topAnchor),
        welcome.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
    ])
    input.onPresentationChange?()
    return welcome
}

// Show the kinds of content the editor accepts without intercepting typing, clicks, or file drops.
final class LauncherInputPlaceholderView: NSView {
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let hintLabel = NSTextField(wrappingLabelWithString: localized("input_start_hint", "Type or paste here, or drop a file"))
    private let types = [
        LauncherInputTypeView(symbol: "doc.text", title: localized("input_documents", "Documents"), formats: "PDF · DOCX · TXT", tint: .systemBlue),
        LauncherInputTypeView(symbol: "photo", title: localized("input_images", "Images"), formats: "PNG · JPG · HEIC", tint: .systemPurple),
        LauncherInputTypeView(symbol: "waveform", title: localized("input_audio", "Audio"), formats: "M4A · MP3 · WAV", tint: .systemOrange)
    ]

    override var isFlipped: Bool { true }

    // init(frameRect): Use native labels and SF Symbols so the welcome state
    // follows the app's appearance.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [titleLabel, hintLabel] {
            label.alignment = .center
            label.maximumNumberOfLines = 3
            addSubview(label)
        }
        titleLabel.textColor = .secondaryLabelColor
        hintLabel.textColor = .secondaryLabelColor
        for type in types { addSubview(type) }
    }

    // init?(coder): The welcome state is constructed with its localized content
    // in code.
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // hitTest(point): Let the underlying NSTextView own selection, insertion,
    // and drag destinations everywhere.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // update(prompt, dragging): Follow the selected mode and make an accepted
    // file drag visibly different from idle input.
    func update(prompt: String, dragging: Bool) {
        titleLabel.stringValue = dragging ? localized("input_drop_title", "Drop to add text") : prompt
        titleLabel.textColor = dragging ? .controlAccentColor : .secondaryLabelColor
        for type in types { type.isDropTarget = dragging }
        needsLayout = true
    }

    // layout(): Keep the invitation centered, with a compact presentation at
    // the launcher's minimum height.
    override func layout() {
        super.layout()
        let compact = bounds.height < 300
        let width = min(380, max(0, bounds.width - 40))
        let x = (bounds.width - width) / 2
        titleLabel.font = .systemFont(ofSize: compact ? 16 : 20, weight: .semibold)
        hintLabel.font = .systemFont(ofSize: compact ? 12 : 14)
        let titleHeight = titleLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height ?? 24
        let hintHeight = hintLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height ?? 20
        let cardHeight: CGFloat = compact ? 80 : 89
        let titleGap: CGFloat = compact ? 6 : 10
        let cardGap: CGFloat = compact ? 12 : 26
        let height = titleHeight + titleGap + hintHeight + cardGap + cardHeight
        let top = max(8, (bounds.height - height) / 2)
        titleLabel.frame = NSRect(x: x, y: top, width: width, height: titleHeight)
        hintLabel.frame = NSRect(x: x, y: titleLabel.frame.maxY + titleGap, width: width, height: hintHeight)
        // Keep the cards smaller than the heading without narrowing its text.
        let spacing: CGFloat = compact ? 12 : 18
        let cardsWidth = min(width, 339)
        let cardsX = (bounds.width - cardsWidth) / 2
        let cardWidth = (cardsWidth - spacing * 2) / 3
        for (index, type) in types.enumerated() {
            type.isCompact = compact
            type.frame = NSRect(x: cardsX + CGFloat(index) * (cardWidth + spacing),
                                y: hintLabel.frame.maxY + cardGap, width: cardWidth, height: cardHeight)
        }
    }
}

// Show each accepted file type with its icon and example formats.
private final class LauncherInputTypeView: NSView {
    private let icon = NSImageView()
    private let titleLabel: NSTextField
    private let formatsLabel: NSTextField
    private let tint: NSColor
    var isCompact = false { didSet { needsLayout = true; needsDisplay = true } }
    var isDropTarget = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    // init(symbol, title, formats, tint): Pair each input type with familiar
    // document, photo, or waveform imagery.
    init(symbol: String, title: String, formats: String, tint: NSColor) {
        self.tint = tint
        titleLabel = NSTextField(wrappingLabelWithString: title)
        formatsLabel = NSTextField(labelWithString: formats)
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 26, weight: .regular))
        icon.contentTintColor = tint
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 2
        formatsLabel.font = .systemFont(ofSize: 8.5)
        formatsLabel.textColor = .secondaryLabelColor
        formatsLabel.alignment = .center
        for view in [icon, titleLabel, formatsLabel] { addSubview(view) }
    }

    // init?(coder): Content and its symbol are supplied together by the welcome
    // state.
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // viewDidChangeEffectiveAppearance(): Refresh the tinted outline when the
    // window changes appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // layout(): Keep icons, translated names, and format examples inside the
    // card at either size.
    override func layout() {
        super.layout()
        let size: CGFloat = isCompact ? 20 : 22
        let padding: CGFloat = 8
        let contentWidth = bounds.width - padding * 2
        let titleHeight = titleLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: contentWidth, height: 100)).height ?? 16
        // Center the contents as a group, including type names that wrap onto two lines.
        let contentHeight = size + 5 + titleHeight + 3 + 12
        let top = max(0, (bounds.height - contentHeight) / 2)
        icon.frame = NSRect(x: (bounds.width - size) / 2, y: top, width: size, height: size)
        titleLabel.frame = NSRect(x: padding, y: icon.frame.maxY + 5, width: contentWidth, height: titleHeight)
        formatsLabel.frame = NSRect(x: padding, y: titleLabel.frame.maxY + 3, width: contentWidth, height: 12)
    }

    // draw(dirtyRect): Soft colour suggests content types without making the
    // illustrations look like primary actions.
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        tint.withAlphaComponent(isDropTarget ? 0.12 : 0.055).setFill()
        path.fill()
        // Pale borders need more color on white; retain the quieter outline on dark surfaces.
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let borderOpacity: CGFloat = dark ? (isDropTarget ? 0.32 : 0.14) : (isDropTarget ? 0.65 : 0.42)
        tint.withAlphaComponent(borderOpacity).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
