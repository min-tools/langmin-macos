import Cocoa

// handleFocusedTextUndoRedoShortcut(event, textView): AppKit asks multiple
// views and sometimes the main window about key equivalents. Only the focused
// text view in the key window may consume Undo/Redo, even with no history.
func handleFocusedTextUndoRedoShortcut(_ event: NSEvent, in textView: NSTextView) -> Bool {
    // Handle undo keys only for the actual focused text view in its key window.
    guard event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "z",
          let window = textView.window, window.isKeyWindow, window.firstResponder === textView,
          event.window == nil || event.window === window else { return false }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        .subtracting([.capsLock, .numericPad, .function])
    // Command-Z requests undo from this text view's own history.
    if modifiers == .command {
        // Consume undo even when the local history has nothing left to undo.
        if let manager = textView.undoManager, manager.canUndo { manager.undo() }
    } else if modifiers == [.command, .shift] {
        // Command-Shift-Z requests redo from the same local history.
        // Redo only when the focused text view has a redo operation available.
        if let manager = textView.undoManager, manager.canRedo { manager.redo() }
    } else {
        // Leave other modifier combinations available to their normal handlers.
        return false
    }
    textView.needsDisplay = true
    return true
}

// Keep result editing shortcuts and redraw behavior local to the active text draft.
final class ResultEditorTextView: ViewerResultTextView {
    var format: ((String) -> Void)?
    var finishEditing: (() -> Void)?

    // didChangeText(): Repaint the editor viewport after text changes so moved
    // decorations do not leave trails.
    override func didChangeText() {
        super.didChangeText()
        redrawEditorViewport()
    }

    // setFrameSize(newSize): Repaint old text positions when a frame-size
    // change reflows the draft.
    override func setFrameSize(_ newSize: NSSize) {
        let previousSize = frame.size
        super.setFrameSize(newSize)
        // Repaint only when resizing changes the editor's geometry.
        if frame.size != previousSize { redrawEditorViewport() }
    }

    // redrawEditorViewport(): Invalidate the transparent viewport, including
    // space below a shortened document.
    private func redrawEditorViewport() {
        // TextKit's partial redraw can leave underlines and custom decorations at their old
        // positions. Repaint the transparent viewport, including space below a shortened document.
        needsDisplay = true
        // Without a scroll view, the text view's own invalidation is sufficient.
        guard let scroll = enclosingScrollView else { return }
        scroll.contentView.needsDisplay = true
        scroll.needsDisplay = true
        scroll.superview?.setNeedsDisplay(scroll.frame)
    }

    // keyDown(event): Handle Done, undo, redo, and formatting shortcuts before
    // ordinary editor typing.
    override func keyDown(with event: NSEvent) {
        // Consume the local Done shortcut before it can trigger the launcher.
        if handleFinishShortcut(event) { return }
        // Consume local undo and redo before formatting or normal typing.
        if handleFocusedTextUndoRedoShortcut(event, in: self) { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Route supported Command-letter formatting shortcuts to the editor toolbar actions.
        if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased(),
           ["b", "i", "u", "k"].contains(key) {
            format?(key)
            return
        }
        super.keyDown(with: event)
    }

    // performKeyEquivalent(event): Give the active editor's Done and undo
    // actions priority over application menu equivalents.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Give the focused draft's Done action priority over menu commands.
        if handleFinishShortcut(event) { return true }
        // Keep undo and redo from falling through to another window's menu actions.
        if handleFocusedTextUndoRedoShortcut(event, in: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    // handleFinishShortcut(event): Recognize Command-Return or Command-Enter
    // only for this focused editor in its key window.
    private func handleFinishShortcut(_ event: NSEvent) -> Bool {
        // Keep Done local to the active draft, including keyboards with a separate Enter key.
        guard event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
              let window, window.isKeyWindow, window.firstResponder === self,
              event.window == nil || event.window === window,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function]) == .command else { return false }
        // Save once per key press instead of repeatedly handling a held Return key.
        if !event.isARepeat { finishEditing?() }
        return true
    }
}

// Keep the native single-line field at its natural height inside a thin focus outline.
// This gives its placeholder, displayed value and shared field editor the same baseline.
private final class ResultLinkAddressContainer: NSView {
    weak var field: NSTextField?

    // draw(dirtyRect): Draw a thin URL-field outline and a focus treatment
    // around its native text field.
    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor.textBackgroundColor.withAlphaComponent(0.25).setFill()
        outline.fill()
        let focused = field?.currentEditor() != nil
        (focused ? NSColor.controlAccentColor : langminControlBorderColor).setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }

    // viewDidChangeEffectiveAppearance(): Refresh an unfocused URL outline when
    // the window appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // mouseDown(event): Give the URL field focus when its surrounding container
    // is clicked.
    override func mouseDown(with event: NSEvent) {
        // Focus the native URL field when its surrounding border is clicked.
        if let field { window?.makeFirstResponder(field) }
    }
}

// Keep link changes beside the formatting controls, with validation in the same popover.
final class ResultLinkEditorController: NSViewController, NSTextFieldDelegate {
    let address = NSTextField()
    private let addressContainer = ResultLinkAddressContainer()
    let actions = ResultToolbarButtonGroup()
    let validation = NSTextField(wrappingLabelWithString: "Enter a valid http, https, or mailto link.")
    var onApply: ((URL?) -> Void)?
    var onCancel: (() -> Void)?
    var onResize: ((NSSize) -> Void)?

    // init(destination, hasLink): Build a compact link editor with an address
    // field, grouped actions, and inline validation.
    init(destination: String, hasLink: Bool) {
        super.init(nibName: nil, bundle: nil)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 52))
        view = root
        preferredContentSize = root.frame.size
        address.stringValue = destination
        address.font = .systemFont(ofSize: 13)
        address.placeholderAttributedString = NSAttributedString(string: "https://example.com", attributes: [
            .font: address.font!, .foregroundColor: NSColor.placeholderTextColor
        ])
        address.isBezeled = false
        address.isBordered = false
        address.drawsBackground = false
        address.focusRingType = .none
        // Long destinations scroll within the field instead of wrapping below its fixed height.
        address.usesSingleLineMode = true
        address.cell?.wraps = false
        address.cell?.isScrollable = true
        address.lineBreakMode = .byClipping
        address.setAccessibilityLabel(localized("edit_link", "Edit Link"))
        address.delegate = self
        address.target = self
        address.action = #selector(applyLink)
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        address.translatesAutoresizingMaskIntoConstraints = false
        addressContainer.field = address
        addressContainer.addSubview(address)
        NSLayoutConstraint.activate([
            address.leadingAnchor.constraint(equalTo: addressContainer.leadingAnchor, constant: 8),
            address.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor, constant: -8),
            address.centerYAnchor.constraint(equalTo: addressContainer.centerYAnchor),
            addressContainer.heightAnchor.constraint(equalToConstant: 28)
        ])

        // button(symbol, title, action): Create a consistently sized symbol
        // button for the link editor's action group.
        func button(_ symbol: String, _ title: String, _ action: Selector) -> TooltipButton {
            let button = TooltipButton(title: "", target: self, action: action)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.tooltipMessage = title
            button.setAccessibilityLabel(title)
            button.refusesFirstResponder = true
            button.contentTintColor = .secondaryLabelColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            return button
        }
        let apply = button("checkmark", localized("apply", "Apply"), #selector(applyLink))
        let remove = button("minus", localized("remove_link", "Remove Link"), #selector(removeLink))
        // Keep the same group width for new links and existing links.
        remove.isEnabled = hasLink
        let cancel = button("xmark", localized("cancel", "Cancel"), #selector(cancelLink))
        actions.orientation = .horizontal
        actions.spacing = 0
        actions.alignment = .centerY
        // Keep Apply, Remove, and Cancel together in one shared button group.
        for button in [apply, remove, cancel] { actions.addButton(button) }
        let row = NSStackView(views: [addressContainer, actions])
        row.spacing = 8
        row.alignment = .centerY
        validation.font = .systemFont(ofSize: 11)
        validation.textColor = .systemRed
        validation.isHidden = true
        // Constrain the control row and validation message within the popover.
        for child in [row, validation] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            row.heightAnchor.constraint(equalToConstant: 28),
            validation.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            validation.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            validation.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 7)
        ])
    }

    // init?(coder): Link editors require their current destination and are
    // constructed in code.
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // applyLink(): Validate the destination before applying it, keeping invalid
    // input visible for correction.
    @objc func applyLink() {
        // Keep an invalid destination visible and focus it for correction.
        guard let url = ResultTextFormatting.safeLink(address.stringValue) else {
            validation.isHidden = false
            onResize?(NSSize(width: 380, height: 84))
            view.window?.makeFirstResponder(address)
            return
        }
        onApply?(url)
    }

    // removeLink(): Remove the selected link through the shared apply callback.
    @objc func removeLink() { onApply?(nil) }
    // cancelLink(): Dismiss link editing without applying a destination change.
    @objc func cancelLink() { onCancel?() }

    // controlTextDidBeginEditing(notification): Refresh the field's focus
    // outline and disable prose substitutions while editing a URL.
    func controlTextDidBeginEditing(_ notification: Notification) {
        addressContainer.needsDisplay = true
        // URL typing should not inherit prose substitutions from the shared field editor.
        guard let editor = address.currentEditor() as? NSTextView else { return }
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
    }

    // controlTextDidEndEditing(notification): Remove the URL field's focused
    // appearance after its editor resigns.
    func controlTextDidEndEditing(_ notification: Notification) {
        addressContainer.needsDisplay = true
    }

    // controlTextDidChange(notification): Hide stale validation feedback when
    // the user starts correcting the URL.
    func controlTextDidChange(_ notification: Notification) {
        // Avoid resizing the popover when no validation message is showing.
        guard !validation.isHidden else { return }
        validation.isHidden = true
        onResize?(NSSize(width: 380, height: 52))
    }

    // control(control, textView, commandSelector): Use Escape to cancel link
    // editing and Return to apply the entered destination.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Escape cancels URL editing without changing the selected link.
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelLink(); return true }
        // Return applies the entered URL through the normal validation path.
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { applyLink(); return true }
        return false
    }
}

// Report toolbar width changes to the editor's responsive control layout.
final class ResultEditorToolbarView: NSView {
    var updateLayout: ((CGFloat) -> Void)?
    // layout(): Recalculate formatting-control layout using the toolbar's
    // current width.
    override func layout() {
        super.layout()
        updateLayout?(bounds.width)
    }
}

// A temporary rich-text draft. Only Done writes back to the result.
final class ResultTextEditorView: NSView, NSTextViewDelegate, NSPopoverDelegate {
    let input = ResultEditorTextView()
    let originalMarkdown: String
    let originalText: NSAttributedString
    let fontSize: CGFloat
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var formatButtons: [String: NSButton] = [:]
    let toolbarControls = ResultEditorToolbarView()
    let styleMenu = NSPopUpButton()
    let sizeMenu = NSPopUpButton()
    var linkPopover: NSPopover?
    private var overflowFormatKeys: [String] = []
    private var overflowHasStyles = false
    private var linkRange: NSRange?
    private let draftUndo = UndoManager()

    var hasChanges: Bool { !ResultTextFormatting.comparable(input.attributedString()).isEqual(to: ResultTextFormatting.comparable(originalText)) }
    var markdown: String { hasChanges ? ResultTextFormatting.markdown(from: input.attributedString()) : originalMarkdown }

    // init(markdown, text, fontSize): Create a separate editable draft and undo
    // history from the rendered result.
    init(markdown: String, text: NSAttributedString, fontSize: CGFloat) {
        originalMarkdown = markdown
        originalText = NSAttributedString(attributedString: text)
        self.fontSize = fontSize
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let basic = ResultToolbarButtonGroup()
        let scripts = ResultToolbarButtonGroup()
        let inserts = ResultToolbarButtonGroup()
        let paragraphs = ResultToolbarButtonGroup()
        // Build inline formatting controls from their shared command and symbol definitions.
        for (group, key, symbol, title) in [
            (basic, "b", "bold", "Bold (⌘B)"), (basic, "i", "italic", "Italic (⌘I)"),
            (basic, "u", "underline", "Underline (⌘U)"), (basic, "s", "strikethrough", "Strikethrough"),
            (scripts, "sup", "", "Superscript"), (scripts, "sub", "", "Subscript"),
            (inserts, "code", "chevron.left.forwardslash.chevron.right", "Inline code"), (inserts, "k", "link", "Link (⌘K)"),
            (paragraphs, "bullets", "list.bullet", "Bullet List"), (paragraphs, "numbers", "list.number", "Numbered List"),
            (paragraphs, "quote", "text.quote", "Quote")
        ] {
            let button = TooltipButton(title: "", target: self, action: #selector(formatClicked(_:)))
            // Use readable text glyphs for superscript and subscript instead of oversized symbols.
            if key == "sup" || key == "sub" {
                button.title = key == "sup" ? "x²" : "x₂"
                button.font = .systemFont(ofSize: 13, weight: .medium)
            } else {
                // Link and code symbols have a wider silhouette than the letter controls.
                let iconSize: CGFloat = key == "k" ? 11 : (key == "code" ? 12 : 13)
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular))
                button.imagePosition = .imageOnly
            }
            button.identifier = NSUserInterfaceItemIdentifier(key)
            button.tooltipMessage = title
            button.setAccessibilityLabel(title)
            button.isBordered = false
            button.setButtonType(.pushOnPushOff)
            (button.cell as? NSButtonCell)?.showsStateBy = []
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.refusesFirstResponder = true
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            group.addButton(button)
            formatButtons[key] = button
        }
        // Let preferred widths include padding without increasing the window's fitting width.
        let flexibleWidth = NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.fittingSizeCompression.rawValue - 1)
        styleMenu.addItems(withTitles: ["Paragraph", "Heading 1", "Heading 2", "Heading 3", "Bullet List", "Numbered List", "Quote"])
        styleMenu.target = self
        styleMenu.action = #selector(changeParagraphStyle(_:))
        styleMenu.setAccessibilityLabel(localized("text_style", "Text style"))
        styleMenu.refusesFirstResponder = true
        styleMenu.isBordered = false
        styleMenu.font = .systemFont(ofSize: 13)
        styleMenu.translatesAutoresizingMaskIntoConstraints = false
        styleMenu.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let styleWidth = styleMenu.widthAnchor.constraint(equalToConstant: 120)
        styleWidth.priority = flexibleWidth
        styleWidth.isActive = true
        styleMenu.setContentHuggingPriority(.init(1), for: .horizontal)
        styleMenu.setContentCompressionResistancePriority(flexibleWidth, for: .horizontal)
        let styles = ResultToolbarButtonGroup()
        styles.addButton(styleMenu)
        // Point sizes apply to the selection; the paragraph menu remains independent.
        sizeMenu.addItem(withTitle: "—")
        sizeMenu.lastItem?.isEnabled = false
        // Populate the font-size menu with supported common point sizes.
        for size in [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 28, 32, 36, 48, 64, 72] {
            sizeMenu.addItem(withTitle: String(size))
            sizeMenu.lastItem?.representedObject = CGFloat(size)
        }
        sizeMenu.target = self
        sizeMenu.action = #selector(changeFontSize(_:))
        sizeMenu.setAccessibilityLabel("Text size")
        sizeMenu.toolTip = "Text size (points)"
        sizeMenu.refusesFirstResponder = true
        sizeMenu.isBordered = false
        sizeMenu.font = .systemFont(ofSize: 13)
        sizeMenu.translatesAutoresizingMaskIntoConstraints = false
        sizeMenu.heightAnchor.constraint(equalToConstant: 28).isActive = true
        sizeMenu.widthAnchor.constraint(equalToConstant: 56).isActive = true
        styles.addButton(sizeMenu)

        let more = ResultToolbarButtonGroup()
        let moreButton = TooltipButton(title: "", target: self, action: #selector(showMoreFormatting(_:)))
        moreButton.identifier = NSUserInterfaceItemIdentifier("moreFormatting")
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More formatting")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        moreButton.imagePosition = .imageOnly
        moreButton.tooltipMessage = "More formatting"
        moreButton.setAccessibilityLabel("More formatting")
        moreButton.isBordered = false
        moreButton.refusesFirstResponder = true
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        moreButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        more.addButton(moreButton)

        let completion = ResultToolbarButtonGroup()
        var completionButtons: [(button: NSButton, width: NSLayoutConstraint, title: NSAttributedString, preferredWidth: CGFloat, symbol: String)] = []
        // Build the completion buttons with separate cancel and save title colors.
        for (title, action, color) in [
            (localized("cancel", "Cancel"), #selector(cancelEditing), NSColor.secondaryLabelColor),
            (localized("done", "Done"), #selector(finishEditing), NSColor.controlAccentColor)
        ] {
            let button = TooltipButton(title: title, target: self, action: action)
            button.isBordered = false
            button.refusesFirstResponder = true
            button.tooltipMessage = action == #selector(finishEditing) ? title + " (⌘↩)" : title
            button.setAccessibilityLabel(title)
            button.font = .systemFont(ofSize: 13)
            button.contentOffset.y = 0.75
            button.contentTintColor = color
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: button.font!, .foregroundColor: color])
            button.cell?.lineBreakMode = .byTruncatingTail
            // Low hugging lets the preferred width add real space around the label.
            button.setContentHuggingPriority(.init(1), for: .horizontal)
            button.setContentCompressionResistancePriority(flexibleWidth, for: .horizontal)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            let width = button.widthAnchor.constraint(equalToConstant: ceil(button.attributedTitle.size().width) + 28)
            width.priority = flexibleWidth
            width.isActive = true
            completion.addButton(button)
            completionButtons.append((button, width, button.attributedTitle, width.constant, action == #selector(cancelEditing) ? "xmark" : "checkmark"))
        }
        let left = NSStackView()
        left.orientation = .horizontal
        left.alignment = .centerY
        left.spacing = 12
        // Apply consistent alignment and spacing to each toolbar group.
        for group in [basic, scripts, inserts, paragraphs, styles, more, completion] {
            group.orientation = .horizontal
            group.alignment = .centerY
            group.spacing = 0
            group.translatesAutoresizingMaskIntoConstraints = false
            // Keep formatting groups on the leading side, separate from completion actions.
            if group !== completion { left.addArrangedSubview(group) }
        }
        // Constrain both toolbar halves while allowing space between them.
        for group in [left, completion] {
            group.translatesAutoresizingMaskIntoConstraints = false
            toolbarControls.addSubview(group)
            group.centerYAnchor.constraint(equalTo: toolbarControls.centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: toolbarControls.leadingAnchor),
            completion.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 12),
            completion.trailingAnchor.constraint(equalTo: toolbarControls.trailingAnchor)
        ])
        var previousLayout = ""
        toolbarControls.updateLayout = { [weak self] availableWidth in
            // Stop responsive-layout work if the editor has been released.
            guard let self else { return }
            let completionWidth = completionButtons.reduce(CGFloat(0)) { $0 + $1.preferredWidth }
            var hideParagraphs = false, hideScripts = false, hideStyle = false, hideStrike = false, compact = false
            // requiredWidth(): Measure the visible control groups for the
            // current toolbar compaction choices.
            func requiredWidth() -> CGFloat {
                let widths: [CGFloat] = [hideStrike ? 96 : 128, hideScripts ? 0 : 64, 64,
                    hideParagraphs ? 0 : 96, hideStyle ? 56 : 176,
                    hideParagraphs ? 32 : 0, compact ? 64 : completionWidth]
                let visible = widths.filter { $0 > 0 }
                return visible.reduce(0, +) + CGFloat(visible.count - 1) * 12
            }
            // Move secondary commands into an explicit menu instead of squeezing buttons or labels.
            if requiredWidth() > availableWidth { hideParagraphs = true }
            // Move script controls into overflow when the current groups no longer fit.
            if requiredWidth() > availableWidth { hideScripts = true }
            // Compact the paragraph-style control if hiding scripts is insufficient.
            if requiredWidth() > availableWidth { hideStyle = true }
            // Use compact completion buttons if the toolbar still overflows.
            if requiredWidth() > availableWidth { compact = true }
            // Move strikethrough into overflow as the next width-saving step.
            if requiredWidth() > availableWidth { hideStrike = true }
            let layout = "\(hideParagraphs)-\(hideScripts)-\(hideStyle)-\(hideStrike)-\(compact)"
            // Skip rebuilding controls when the same compaction choices still fit.
            guard layout != previousLayout else { return }
            previousLayout = layout
            paragraphs.isHidden = hideParagraphs
            scripts.isHidden = hideScripts
            self.styleMenu.isHidden = hideStyle
            self.formatButtons["s"]?.isHidden = hideStrike
            more.isHidden = !hideParagraphs
            self.overflowFormatKeys = (hideStrike ? ["s"] : []) + (hideScripts ? ["sup", "sub"] : [])
                + (hideParagraphs ? ["bullets", "numbers", "quote"] : [])
            self.overflowHasStyles = hideStyle
            // Update completion titles or symbols to match the selected compact layout.
            for item in completionButtons {
                item.button.image = compact ? NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title.string)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)) : nil
                item.button.imagePosition = compact ? .imageOnly : .noImage
                item.button.attributedTitle = compact ? NSAttributedString(string: "") : item.title
                item.width.constant = compact ? 32 : item.preferredWidth
            }
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // Allow rich-text edits and undo without importing arbitrary graphics.
        input.isEditable = true
        input.isSelectable = true
        input.isRichText = true
        input.importsGraphics = false
        input.allowsUndo = true
        // Disable automatic substitutions so editing preserves the generated
        // text.
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticLinkDetectionEnabled = false
        input.drawsBackground = false
        input.textColor = .labelColor
        input.insertionPointColor = .controlAccentColor
        // Wrap content within the editor while allowing vertical growth.
        input.textContainerInset = NSSize(width: 32, height: 28)
        input.textContainer?.lineFragmentPadding = 0
        input.textContainer?.widthTracksTextView = true
        input.isHorizontallyResizable = false
        input.isVerticallyResizable = true
        input.autoresizingMask = [.width]
        input.minSize = NSSize(width: 0, height: 0)
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // Load the editable result and route formatting and completion actions.
        input.textStorage?.setAttributedString(text)
        input.typingAttributes = [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor]
        input.delegate = self
        input.format = { [weak self] in self?.format($0) }
        input.finishEditing = { [weak self] in self?.finishEditing() }
        scroll.documentView = input

        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        refreshFormatState()
    }

    // init?(coder): Result editors require their original Markdown and
    // attributed draft supplied in code.
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    // undoManager(view): Use this draft's undo manager instead of another
    // window's editing history.
    func undoManager(for view: NSTextView) -> UndoManager? { draftUndo }
    // textViewDidChangeSelection(notification): Refresh formatting controls
    // when the user changes the text selection.
    func textViewDidChangeSelection(_ notification: Notification) { refreshFormatState() }
    // textDidChange(notification): Dismiss a link popover whose selection range
    // is stale and refresh formatting state.
    func textDidChange(_ notification: Notification) {
        // The popover's range belongs to the draft it opened on, never to later text changes.
        dismissLinkEditor()
        refreshFormatState()
    }
    // finishEditing(): Ask the owning result to save the current draft.
    @objc private func finishEditing() { onDone?() }
    // cancelEditing(): Ask the owning result to discard the current draft.
    @objc private func cancelEditing() { onCancel?() }
    // formatClicked(sender): Route a formatting button's stored command to the
    // shared formatting handler.
    @objc private func formatClicked(_ sender: NSButton) { format(sender.identifier?.rawValue ?? "") }

    // showMoreFormatting(sender): Anchor the overflow formatting menu beneath
    // its button in either coordinate orientation.
    @objc private func showMoreFormatting(_ sender: NSButton) {
        let y = sender.isFlipped ? sender.bounds.maxY + 4 : sender.bounds.minY - 4
        formattingOverflowMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: sender)
    }

    // formattingOverflowMenu(): Hidden controls remain available with the same
    // selection state and actions.
    func formattingOverflowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Recreate overflow items from the formatting controls currently hidden from the toolbar.
        for key in overflowFormatKeys {
            // Skip commands that no longer have a matching toolbar button.
            guard let button = formatButtons[key] as? TooltipButton else { continue }
            let item = NSMenuItem(title: button.tooltipMessage, action: #selector(applyOverflowFormatting(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = button.state
            menu.addItem(item)
        }
        // Add heading choices when paragraph-style controls have moved into overflow.
        if overflowHasStyles {
            // Separate heading choices from any existing inline-format items.
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            // Offer Paragraph and the three supported heading levels in overflow.
            for choice in 0...3 {
                let item = NSMenuItem(title: styleMenu.itemTitle(at: choice), action: #selector(applyOverflowFormatting(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = "style:\(choice)"
                item.state = selectedParagraphChoices.allSatisfy { $0 == choice } ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }

    // applyOverflowFormatting(sender): Dispatch overflow choices to paragraph
    // styling or inline formatting as appropriate.
    @objc private func applyOverflowFormatting(_ sender: NSMenuItem) {
        // Ignore menu items without a stored formatting command.
        guard let key = sender.representedObject as? String else { return }
        // Dispatch encoded paragraph-style choices to the paragraph formatter.
        if key.hasPrefix("style:"), let choice = Int(key.dropFirst(6)) { setParagraphStyle(choice) }
        // Dispatch other overflow commands to the inline formatter.
        else { format(key) }
    }

    // replaceDraft(text, selection, action): Register formatting as a single
    // undoable edit, alongside native typing undo.
    func replaceDraft(_ text: NSAttributedString, selection: NSRange, action: String) {
        let old = NSAttributedString(attributedString: input.attributedString())
        let oldSelection = input.selectedRange()
        draftUndo.registerUndo(withTarget: self) { editor in
            editor.replaceDraft(old, selection: oldSelection, action: action)
        }
        draftUndo.setActionName(action)
        input.textStorage?.setAttributedString(text)
        input.setSelectedRange(selection)
        input.didChangeText()
        window?.makeFirstResponder(input)
        refreshFormatState()
    }

    // format(key): Apply a selected formatting command to the current selection
    // or typing attributes.
    func format(_ key: String) {
        // Link formatting opens its dedicated destination editor.
        if key == "k" { editLink(); return }
        // List and quote commands apply to complete selected paragraphs.
        if let choice = ["bullets": 4, "numbers": 5, "quote": 6][key] {
            setParagraphStyle(selectedParagraphChoices.allSatisfy { $0 == choice } ? 0 : choice)
            return
        }
        // Ignore unsupported inline command keys.
        guard ["b", "i", "u", "s", "sup", "sub", "code"].contains(key) else { return }
        let range = input.selectedRange()
        let current = range.length > 0 ? input.attributedString().attributes(at: range.location, effectiveRange: nil) : input.typingAttributes
        let enabling = !selectedAttributes.allSatisfy { isActive(key, attributes: $0) }
        // updated(attributes): Transform one attribute run while preserving
        // unrelated text styling.
        func updated(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            // Use the shared typography rules to toggle raised or lowered text without cumulative shrinking.
            if key == "sup" || key == "sub" {
                return ResultTextFormatting.typography(attributes, script: enabling ? (key == "sup" ? 1 : -1) : 0)
            }
            var result = attributes
            // Switch code typography while preserving the run's existing emphasis.
            if key == "code" {
                let previous = attributes[.font] as? NSFont ?? .systemFont(ofSize: fontSize)
                let traits = NSFontManager.shared.traits(of: previous)
                let weight: NSFont.Weight = traits.contains(.boldFontMask) ? .semibold : .regular
                var font = enabling ? NSFont.monospacedSystemFont(ofSize: previous.pointSize, weight: weight)
                    : NSFont.systemFont(ofSize: previous.pointSize, weight: weight)
                // Retain italic emphasis when changing between proportional and monospaced fonts.
                if traits.contains(.italicFontMask) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                result[.font] = font
                // Keep the selection's size when reopening; ordinary rendered code uses a smaller default.
                result[.resultEditorFontSize] = ResultTextFormatting.baseSize(in: attributes)
                // Record or clear inline-code membership to match the toggle state.
                if enabling { result[.langminInlineCode] = true } else { /* Set or remove the semantic code marker with the requested toggle state. */ result.removeValue(forKey: .langminInlineCode) }
                // Remove display-only code padding before recalculating the run's normal kerning.
                if let spacing = result.removeValue(forKey: .langminInlineCodeTrailingSpacing) as? NSNumber {
                    let kern = (result[.kern] as? NSNumber)?.doubleValue ?? 0
                    result[.kern] = kern - spacing.doubleValue
                }
                result[.foregroundColor] = result[.link] == nil ? NSColor.labelColor : NSColor.linkColor
            } else if key == "b" || key == "i" {
                // Toggle font traits for bold and italic commands.
                let font = result[.font] as? NSFont ?? .systemFont(ofSize: fontSize)
                let trait: NSFontTraitMask = key == "b" ? .boldFontMask : .italicFontMask
                result[.font] = enabling ? NSFontManager.shared.convert(font, toHaveTrait: trait)
                    : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
            } else {
                // Use text-decoration attributes for underline and strikethrough commands.
                let attribute: NSAttributedString.Key = key == "u" ? .underlineStyle : .strikethroughStyle
                // Add or remove the selected decoration according to the toggle state.
                if enabling { result[attribute] = NSUnderlineStyle.single.rawValue } else { /* Apply or remove underline and strikethrough using their native attributes. */ result.removeValue(forKey: attribute) }
            }
            return result
        }
        // With a caret, change future typing attributes instead of rewriting existing text.
        guard range.length > 0 else {
            input.typingAttributes = updated(current)
            window?.makeFirstResponder(input)
            refreshFormatState()
            return
        }
        let changed = NSMutableAttributedString(attributedString: input.attributedString())
        input.attributedString().enumerateAttributes(in: range) { attributes, run, _ in
            changed.setAttributes(updated(attributes), range: run)
        }
        replaceDraft(changed, selection: range, action: localized("format_text", "Format Text"))
    }

    // isActive(key, attributes): Read whether one attribute run has the
    // requested inline format enabled.
    func isActive(_ key: String, attributes: [NSAttributedString.Key: Any]) -> Bool {
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: fontSize)
        // Read the selected run's active state for the requested formatting command.
        switch key {
        // Bold state comes from the font's traits.
        case "b": return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        // Italic state comes from the font's traits.
        case "i": return NSFontManager.shared.traits(of: font).contains(.italicFontMask)
        // Underline is active when the run has a nonzero underline style.
        case "u": return (attributes[.underlineStyle] as? Int ?? 0) != 0
        // Strikethrough is active when the run has a nonzero strike style.
        case "s": return (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        // Positive script position identifies superscript.
        case "sup": return ResultTextFormatting.script(in: attributes) > 0
        // Negative script position identifies subscript.
        case "sub": return ResultTextFormatting.script(in: attributes) < 0
        // Code state comes from the editor's inline-code attribute.
        case "code": return attributes[.langminInlineCode] != nil
        // The remaining formatting query checks link membership.
        default: return attributes[.link] != nil
        }
    }

    private var selectedAttributes: [[NSAttributedString.Key: Any]] {
        let range = input.selectedRange()
        // Use typing attributes when there is no selected text to inspect.
        guard range.length > 0 else { return [input.typingAttributes] }
        var result: [[NSAttributedString.Key: Any]] = []
        let text = input.attributedString()
        // Invisible paragraph breaks and spaces should not make uniformly styled text look mixed.
        text.enumerateAttributes(in: range) { attributes, run, _ in
            // Ignore whitespace-only runs when determining the visible selection's format state.
            if text.attributedSubstring(from: run).string.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil {
                result.append(attributes)
            }
        }
        return result.isEmpty ? [text.attributes(at: range.location, effectiveRange: nil)] : result
    }

    // changeFontSize(sender): Read the selected numeric font size before
    // applying it to the draft.
    @objc func changeFontSize(_ sender: NSPopUpButton) {
        // Ignore size-menu items that do not carry a numeric point size.
        guard let size = sender.selectedItem?.representedObject as? CGFloat else { return }
        setFontSize(size)
    }

    // setFontSize(size): Apply a bounded font size to selected text or to newly
    // typed text when the selection is empty.
    func setFontSize(_ size: CGFloat) {
        // Reject nonfinite or unsupported sizes before changing text attributes.
        guard size.isFinite, (6...96).contains(size) else { return }
        let range = input.selectedRange()
        // Apply a caret-only size choice to future typing.
        if range.length == 0 {
            input.typingAttributes = ResultTextFormatting.typography(input.typingAttributes, size: size)
            window?.makeFirstResponder(input)
            refreshFormatState()
            return
        }
        let changed = NSMutableAttributedString(attributedString: input.attributedString())
        input.attributedString().enumerateAttributes(in: range) { attributes, run, _ in
            changed.setAttributes(ResultTextFormatting.typography(attributes, size: size), range: run)
        }
        replaceDraft(changed, selection: range, action: "Text Size")
    }

    // refreshFormatState(): Reflect mixed selections and active paragraph
    // styles in the editor's formatting controls.
    func refreshFormatState() {
        let selection = selectedAttributes
        let paragraphs = selectedParagraphChoices
        // Refresh each formatting button from the current text and paragraph selections.
        for (key, button) in formatButtons {
            let active: Bool
            // List and quote buttons are active only when every selected paragraph matches.
            if let choice = ["bullets": 4, "numbers": 5, "quote": 6][key] {
                active = paragraphs.allSatisfy { $0 == choice }
            // Inline buttons are active only when every meaningful selected run has that format.
            } else { /* Mark a formatting control active only when the whole selection matches. */ active = selection.allSatisfy { isActive(key, attributes: $0) } }
            button.state = active ? .on : .off
            button.contentTintColor = active ? .controlAccentColor : .secondaryLabelColor
            // Refresh the script button's attributed title without changing its compact glyph.
            if key == "sup" || key == "sub" {
                button.attributedTitle = NSAttributedString(string: key == "sup" ? "x²" : "x₂", attributes: [
                    .font: button.font!, .foregroundColor: button.contentTintColor!
                ])
            }
        }
        let sizes = selection.map { ResultTextFormatting.baseSize(in: $0) }
        // Display whole points when the selected runs share the same font size.
        if let size = sizes.first, sizes.allSatisfy({ abs($0 - size) < 0.05 }) {
            // Round imported fractional sizes for display without changing their text.
            let displayedSize = size.rounded()
            sizeMenu.item(at: 0)?.title = String(Int(displayedSize))
            sizeMenu.selectItem(at: sizeMenu.itemArray.firstIndex { ($0.representedObject as? CGFloat) == displayedSize } ?? 0)
        } else {
            // Use a mixed-value marker when selected runs have different font sizes.
            sizeMenu.item(at: 0)?.title = "—"
            sizeMenu.selectItem(at: 0)
        }
        styleMenu.selectItem(at: paragraphs.first ?? 0)
    }

    private var selectedParagraphChoices: [Int] {
        let text = input.string as NSString
        let selection = input.selectedRange()
        var index = min(selection.location, text.length)
        let last = min(text.length, selection.length > 0 ? NSMaxRange(selection) - 1 : index)
        var choices: [Int] = []
        repeat {
            let range = text.paragraphRange(for: NSRange(location: index, length: 0))
            let attributes = index < text.length ? input.attributedString().attributes(at: index, effectiveRange: nil) : input.typingAttributes
            let paragraph = text.substring(with: range)
            var choice = min(3, attributes[.resultEditorHeading] as? Int ?? 0)
            // Recognize quote paragraphs from their quotation-bar attribute.
            if attributes[.langminBlockquoteBar] != nil { choice = 6 }
            // Recognize bullet paragraphs from the renderer's marker and tab.
            if paragraph.hasPrefix("•\t") { choice = 4 }
            // Recognize numbered paragraphs from their numeric marker and tab.
            else if paragraph.range(of: #"^\d+\.\t"#, options: .regularExpression) != nil { choice = 5 }
            choices.append(choice)
            let next = NSMaxRange(range)
            // Stop if a malformed or empty paragraph range cannot advance the scan.
            if next <= index { break }
            index = next
        // Include every paragraph touched by the selection.
        } while index <= last
        return choices
    }

    // changeParagraphStyle(sender): Apply the paragraph style selected in the
    // toolbar menu.
    @objc func changeParagraphStyle(_ sender: NSPopUpButton) {
        setParagraphStyle(sender.indexOfSelectedItem)
    }

    // setParagraphStyle(choice): Transform the selected paragraphs while
    // preserving the draft's supported inline formatting.
    func setParagraphStyle(_ choice: Int) {
        // Ignore paragraph-style indices outside the supported menu choices.
        guard (0...6).contains(choice) else { return }
        let whole = input.attributedString()
        let selected = input.selectedRange()
        let range = (whole.string as NSString).paragraphRange(for: selected)
        // Configure typing and paragraph attributes directly when the paragraph is empty.
        if range.length == 0 {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.paragraphSpacing = 12
            let level = (1...3).contains(choice) ? choice : 0
            let size = (fontSize * ([1: 1.5, 2: 1.3, 3: 1.16][level] ?? 1)).rounded()
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: level > 0 ? .semibold : .regular),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: style
            ]
            // Remember a heading level only for an actual heading choice.
            if level > 0 { attributes[.resultEditorHeading] = level }
            // Give an empty quote paragraph its normal text indent and quotation styling.
            if choice == 6 {
                style.firstLineHeadIndent = 20; style.headIndent = 20
                attributes[.langminBlockquoteBar] = true
            }
            input.typingAttributes = attributes
            // Reserve a marker gutter when starting an empty list paragraph.
            if choice == 4 || choice == 5 {
                style.headIndent = 24
                style.tabStops = [NSTextTab(textAlignment: .left, location: 24)]
                input.insertText(NSAttributedString(string: choice == 4 ? "•\t" : "1.\t", attributes: attributes), replacementRange: selected)
            }
            window?.makeFirstResponder(input)
            refreshFormatState()
            return
        }
        let changed = NSMutableAttributedString(attributedString: whole)
        let fragment = NSMutableAttributedString(attributedString: whole.attributedSubstring(from: range))
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 12
        fragment.removeAttribute(.resultEditorHeading, range: NSRange(location: 0, length: fragment.length))
        fragment.removeAttribute(.langminBlockquoteBar, range: NSRange(location: 0, length: fragment.length))
        fragment.removeAttribute(.langminCodeBlock, range: NSRange(location: 0, length: fragment.length))
        var index = 0, ordinal = 1
        // Transform each selected paragraph without letting an earlier marker change invalidate later offsets.
        while index < fragment.length {
            var paragraph = (fragment.string as NSString).paragraphRange(for: NSRange(location: index, length: 0))
            let line = (fragment.string as NSString).substring(with: paragraph)
            // Remove a previous list marker before applying the newly selected paragraph style.
            if let marker = line.range(of: #"^(?:•|\d+\.)\t"#, options: .regularExpression) {
                fragment.deleteCharacters(in: NSRange(location: index, length: NSRange(marker, in: line).length))
                paragraph = (fragment.string as NSString).paragraphRange(for: NSRange(location: index, length: 0))
            }
            // Insert the requested bullet or sequential number for a list paragraph.
            if choice == 4 || choice == 5 {
                let marker = choice == 4 ? "•\t" : "\(ordinal).\t"
                fragment.insert(NSAttributedString(string: marker, attributes: [.font: NSFont.systemFont(ofSize: fontSize)]), at: index)
                paragraph.length += (marker as NSString).length
                ordinal += 1
            }
            index = NSMaxRange(paragraph)
        }
        let full = NSRange(location: 0, length: fragment.length)
        let level = (1...3).contains(choice) ? choice : 0
        let size = (fontSize * ([1: 1.5, 2: 1.3, 3: 1.16][level] ?? 1)).rounded()
        let beforeStyle = NSAttributedString(attributedString: fragment)
        beforeStyle.enumerateAttributes(in: full) { attributes, run, _ in
            let previous = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: fontSize)
            let traits = NSFontManager.shared.traits(of: previous)
            let bold = level > 0 || (traits.contains(.boldFontMask) && previous.pointSize <= fontSize)
            var font = attributes[.langminInlineCode] != nil
                ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
                : NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            // Retain italic emphasis when changing paragraph typography.
            if traits.contains(.italicFontMask) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var updated = attributes
            updated[.font] = font
            updated[.foregroundColor] = attributes[.link] == nil ? NSColor.labelColor : NSColor.linkColor
            updated[.paragraphStyle] = style
            // Replace a stored inline size so it cannot override the new paragraph style.
            if attributes[.resultEditorFontSize] != nil { updated[.resultEditorFontSize] = size }
            updated.removeValue(forKey: .resultEditorScriptBaseSize)
            fragment.setAttributes(ResultTextFormatting.typography(updated), range: run)
        }
        // Record the chosen heading level across the transformed paragraph fragment.
        if level > 0 { fragment.addAttribute(.resultEditorHeading, value: level, range: full) }
        // Align list body text after its marker gutter.
        if choice == 4 || choice == 5 {
            style.headIndent = 24
            style.tabStops = [NSTextTab(textAlignment: .left, location: 24)]
        }
        // Apply quotation indentation and its visual bar for the quote choice.
        if choice == 6 {
            style.firstLineHeadIndent = 20; style.headIndent = 20
            fragment.addAttribute(.langminBlockquoteBar, value: true, range: full)
        }
        changed.replaceCharacters(in: range, with: fragment)
        replaceDraft(changed, selection: NSRange(location: range.location, length: fragment.length), action: "Text Style")
    }

    // editLink(): Open or dismiss link editing, expanding an insertion point to
    // its containing link when needed.
    func editLink() {
        // A second Link click closes the current popover and restores draft focus.
        if let popover = linkPopover, popover.isShown { dismissLinkEditor(restoreFocus: true); return }
        let text = input.attributedString()
        var range = input.selectedRange()
        // With the caret in a link, edit its whole label without requiring a selection.
        if range.length == 0, range.location < text.length {
            var existingRange = NSRange()
            // With the caret inside a link, use its complete label range.
            if text.attribute(.link, at: range.location, longestEffectiveRange: &existingRange,
                              in: NSRange(location: 0, length: text.length)) != nil { range = existingRange }
        }
        // Require a valid nonempty range and a visible toolbar anchor before opening link editing.
        guard range.length > 0, NSMaxRange(range) <= text.length, let anchor = formatButtons["k"], window != nil else { NSSound.beep(); return }
        let existing = text.attribute(.link, at: range.location, effectiveRange: nil)
        var hasLink = false
        text.enumerateAttribute(.link, in: range) { value, _, _ in /* Detect an existing link so its editor can offer removal. */ if value != nil { hasLink = true } }
        let controller = ResultLinkEditorController(
            destination: (existing as? URL)?.absoluteString ?? (existing as? String ?? ""), hasLink: hasLink)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        controller.onApply = { [weak self] url in self?.applyLink(url) }
        controller.onCancel = { [weak self] in self?.dismissLinkEditor(restoreFocus: true) }
        controller.onResize = { [weak popover] in popover?.contentSize = $0 }
        input.setSelectedRange(range)
        linkRange = range
        linkPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        controller.view.window?.makeFirstResponder(controller.address)
        controller.address.selectText(nil)
    }

    // applyLink(url): Apply or remove a link only while the popover's
    // remembered draft range remains valid.
    func applyLink(_ url: URL?) {
        // Dismiss stale link editing if its remembered range no longer fits the draft.
        guard let range = linkRange, NSMaxRange(range) <= input.attributedString().length else { dismissLinkEditor(); return }
        let changed = NSMutableAttributedString(attributedString: input.attributedString())
        changed.removeAttribute(.link, range: range)
        changed.removeAttribute(.underlineStyle, range: range)
        changed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        // Add a new destination and standard link appearance only when a URL was supplied.
        if let url { changed.addAttributes([.link: url, .foregroundColor: NSColor.linkColor, .underlineStyle: 1], range: range) }
        dismissLinkEditor()
        replaceDraft(changed, selection: range, action: localized("edit_link", "Edit Link"))
    }

    // dismissLinkEditor([restoreFocus = false]): Clear the link popover and its
    // selection range, optionally restoring editor focus.
    func dismissLinkEditor(restoreFocus: Bool = false) {
        let popover = linkPopover
        linkPopover = nil
        linkRange = nil
        popover?.close()
        // Restore typing focus when the caller explicitly requests it.
        if restoreFocus { window?.makeFirstResponder(input) }
    }

    // popoverDidClose(notification): Clear link-edit state only when the
    // closing popover is the one this editor owns.
    func popoverDidClose(_ notification: Notification) {
        // Ignore close notifications from unrelated or already replaced popovers.
        guard let popover = notification.object as? NSPopover, popover === linkPopover else { return }
        linkPopover = nil
        linkRange = nil
    }

    // viewWillMove(newWindow): Dismiss link editing before removing the editor
    // from its window.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Close the link popover before its editor leaves the window.
        if newWindow == nil { dismissLinkEditor() }
        super.viewWillMove(toWindow: newWindow)
    }
}

// Persist edited Library text together with its conversation and audio metadata.
extension LibraryStore {
    // setEditedResponse(id, markdown, conversation): Stage changed text first;
    // one atomic metadata write commits it with the conversation and audio
    // state.
    static func setEditedResponse(id: String, markdown: String?, conversation: ResultConversation?) throws -> LibraryEntry {
        let directory = entryDirectory(id: id)
        let metadata = directory.appendingPathComponent("entry.json")
        var entry = try JSONDecoder().decode(LibraryEntry.self, from: Data(contentsOf: metadata))
        let previousText = entry.textFile
        let previousRevised = entry.diffRevisedFile
        let previousAudio = entry.audioFile
        let name = markdown.map { _ in "edited-\(UUID().uuidString).md" }
        do {
            // Write changed Markdown to its newly staged file before updating entry metadata.
            if let markdown, let name {
                try markdown.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
                entry.textFile = name
                // Point revised diff content at the new text when the entry already tracks an original version.
                if entry.diffOriginalFile != nil { entry.diffRevisedFile = name }
            }
            entry.conversation = conversation
            entry.audioFile = nil
            entry.audioTimings = nil
            entry.narrationVoice = nil
            entry.narrationModel = nil
            entry.pronunciations = nil
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entry).write(to: metadata, options: .atomic)
        } catch {
            // Remove a staged text file if committing metadata fails.
            // Delete only the new staged file, preserving the previously committed response.
            if let name { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
            throw error
        }
        invalidateEntryCache()
        // Drop audio only after the edited text and metadata have committed. These locations
        // belong to the Library store; unrelated paths from edited metadata are never removed.
        if let file = previousAudio, file == (file as NSString).lastPathComponent, file.hasPrefix("audio."),
           ![entry.textFile, entry.diffOriginalFile, entry.diffRevisedFile, entry.illustrationFile].contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("pronounce", isDirectory: true))
        // Only remove replaced files created by this store; never follow paths from edited metadata.
        if name != nil {
            // Remove replaced text files only when they are safe entry-local names and no longer referenced.
            for file in Set([previousText, previousRevised].compactMap { $0 })
            where file != entry.textFile && file != entry.diffOriginalFile && file == (file as NSString).lastPathComponent
                && (file == "text.md" || file == "diff-revised.txt" || file.hasPrefix("edited-")) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            }
        }
        return entry
    }
}

// Coordinate entering, saving, and cancelling text edits within a result session.
extension ViewerSession {
    // editTextFromToolbar(sender): Begin editing the main result from its
    // toolbar action.
    @objc func editTextFromToolbar(_ sender: Any?) { beginTextEditing(replyID: nil) }

    // beginTextEditing(replyID): Open a draft only when the result is available
    // and no generation would conflict with editing.
    func beginTextEditing(replyID: String?) {
        // Require a live result, no existing editor, and a host with a toolbar.
        guard !resourcesReleased, textEditor == nil, let root = viewerRootView, let toolbar = resultToolbar else { return }
        // Wait for active generation and narration transfer to finish before opening a draft.
        guard !isGeneratingNarration, hudNarration == nil, followUpRunID == nil, illustrationRunID == nil else {
            presentViewerError("Finish generation before editing", details: "Wait for the current response, narration, or illustration to finish, or cancel it first.")
            return
        }
        let markdown: String
        // Editing a follow-up starts from that reply's current answer.
        if let replyID {
            // Abort if the requested reply no longer exists in the conversation.
            // Require the selected reply to still exist before opening its editor.
            guard let answer = config.conversation?.turns.first(where: { $0.id == replyID })?.answer else { return }
            markdown = answer
        // Editing the main result starts from its current content.
        } else { /* Edit the main result when no follow-up reply was selected. */ markdown = content }
        // Stop playback and dismiss the model palette before entering editing
        // mode.
        stopAudio()
        stopHeadwordPronunciation()
        clearNarrationHighlight()
        followUpModelPanel?.closePalette()
        // Keep the selected reply and its editor callbacks together.
        editingReplyID = replyID
        let editor = ResultTextEditorView(markdown: markdown, text: markdownAttributedText(from: markdown, forEditing: true),
                                          fontSize: config.fontSize)
        editor.onDone = { [weak self] in _ = self?.finishTextEditing() }
        editor.onCancel = { [weak self] in self?.cancelTextEditing() }
        textEditor = editor
        // Replace the result body with editing controls while retaining the
        // toolbar.
        editorHiddenViews = root.subviews.filter { !$0.isHidden && $0 !== toolbar }
        editorHiddenViews.forEach { $0.isHidden = true }
        toolbar.setEditingControls(editor.toolbarControls)
        root.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editor.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            editor.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        // Defer Library saving until editing finishes, then focus the text.
        saveToLibraryButton?.isEnabled = false
        root.layoutSubtreeIfNeeded()
        hostWindow?.makeFirstResponder(editor.input)
        appDelegate?.updateMenuForActiveWindow()
    }

    var hasAttachedNarration: Bool {
        audioAvailable || !pronounceCache.isEmpty ||
            (!config.audioPath.isEmpty && FileManager.default.fileExists(atPath: config.audioPath))
    }

    var editAudioRemovalWarning: String {
        localized("save_edits_remove_audio_detail", "Saving removes all attached audio. You can regenerate narration and pronunciation clips anytime.")
    }

    // finishTextEditing([confirmAudioRemoval = true]): Persistence must succeed
    // before replacing the result or dropping any attached audio.
    @discardableResult
    func finishTextEditing(confirmAudioRemoval: Bool = true) -> Bool {
        // No active draft means there is nothing to save.
        guard let editor = textEditor else { return true }
        // Close an unchanged draft without rewriting saved content or removing audio.
        guard editor.hasChanges else { cancelTextEditing(); return true }
        // Ask before a text change would invalidate attached narration.
        if confirmAudioRemoval, hasAttachedNarration {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = localized("save_edits_remove_audio", "Save edits and remove audio?")
            alert.informativeText = editAudioRemovalWarning
            alert.addButton(withTitle: localized("save", "Save"))
            alert.addButton(withTitle: localized("cancel", "Cancel"))
            // Keep the draft open when the user declines audio removal.
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        let markdown = editor.markdown
        var conversation = config.conversation
        // Apply edited reply text to its matching conversation turn.
        if let id = editingReplyID {
            // Do not save into a conversation whose edited reply was removed.
            // Reject saving an edit after its conversation turn has been removed.
            guard let index = conversation?.turns.firstIndex(where: { $0.id == id }) else { return false }
            conversation?.turns[index].answer = markdown
        }
        var stagedPrivateText: URL?
        // Persist the accepted draft according to whether it belongs to a saved entry or temporary result.
        do {
            if let id = savedLibraryID {
                // A newly saved session still owns temporary assets. Keep its text independent
                // so removing the Library copy cannot delete the open document's backing file.
                if editingReplyID == nil, !config.cleanupDir.isEmpty {
                    let url = URL(fileURLWithPath: config.textPath).deletingLastPathComponent()
                        .appendingPathComponent("edited-\(UUID().uuidString).md")
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                    stagedPrivateText = url
                }
                let entry = try LibraryStore.setEditedResponse(id: id, markdown: editingReplyID == nil ? markdown : nil,
                    conversation: conversation)
                // Refresh the main result's saved text paths when its Library entry was edited.
                if editingReplyID == nil {
                    let directory = LibraryStore.entryDirectory(id: id)
                    config.textPath = stagedPrivateText?.path ?? directory.appendingPathComponent(entry.textFile).path
                    config.diffRevisedPath = entry.diffRevisedFile.map { stagedPrivateText?.path ?? directory.appendingPathComponent($0).path }
                }
            } else if editingReplyID == nil {
                // For an unsaved main result, write to its existing temporary text file.
                try markdown.write(toFile: config.textPath, atomically: true, encoding: .utf8)
                // Keep the revised diff path aligned with the updated main text file.
                if config.diffOriginalPath != nil { config.diffRevisedPath = config.textPath }
            }
        } catch {
            // Keep the draft open and report persistence failure.
            // Clean up only the newly staged private text from the failed save.
            if let stagedPrivateText { try? FileManager.default.removeItem(at: stagedPrivateText) }
            presentViewerError("Could not save edits", details: error.localizedDescription)
            return false
        }
        // Replace main content only when the edit targets the main result.
        if editingReplyID == nil {
            content = markdown
            // Keep the in-memory revised diff text aligned with the saved main content.
            if config.diffOriginalPath != nil { diffRevisedContent = markdown }
        }
        config.conversation = conversation
        let origin = viewerScrollView?.contentView.bounds.origin
        cancelTextEditing()
        removeAudioAfterTextEdit()
        diffShown = false
        updateResultViewButtons()
        applyResultText()
        // Restore the previous reading position within the resized document bounds.
        if let origin, let scroll = viewerScrollView {
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: origin, size: scroll.contentView.bounds.size)).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        (narrationButton as? TooltipButton)?.tooltipMessage = narrationTooltip()
        updateNarrationStats()
        // Refresh the Library listing after saving an edit to a saved entry.
        if savedLibraryID != nil { appDelegate?.launcherController.libraryDidChange() }
        return true
    }

    // removeAudioAfterTextEdit(): Library assets were cleared with the commit.
    // Remove session-owned copies as well, while leaving externally supplied
    // files alone. Clear the paths so reopening or saving to the Library cannot
    // restore them.
    func removeAudioAfterTextEdit() {
        let audioPaths = Set([activeAudioPath, config.audioPath] + pronounceCache.values.map(\.path))
        stopHeadwordPronunciation()
        dropExistingAudio()
        // Restrict temporary audio cleanup to this result's own cleanup directory.
        if !config.cleanupDir.isEmpty {
            let root = URL(fileURLWithPath: config.cleanupDir).standardizedFileURL.path + "/"
            // Inspect only the nonempty audio paths attached to the result.
            for path in audioPaths where !path.isEmpty {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                // Delete only owned audio files that are not also referenced as text or illustration assets.
                if url.path.hasPrefix(root),
                   ![config.textPath, config.diffOriginalPath, config.diffRevisedPath, config.illustrationPath].contains(url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        pronunciationCleanupDirs.forEach { try? FileManager.default.removeItem(atPath: $0) }
        pronunciationCleanupDirs = []
        pronounceCache = [:]
        config.audioPath = ""
        config.narrationVoice = nil
        config.narrationModel = nil
    }

    // cancelTextEditing(): Remove the draft editor and restore the result's
    // normal toolbar and content.
    func cancelTextEditing() {
        // Do nothing when the draft has already been removed.
        guard let editor = textEditor else { return }
        hostWindow?.makeFirstResponder(nil)
        resultToolbar?.setEditingControls(nil)
        editor.removeFromSuperview()
        textEditor = nil
        editingReplyID = nil
        editorHiddenViews.forEach { $0.isHidden = false }
        editorHiddenViews = []
        updateSaveToLibraryButton()
        hostWindow?.makeFirstResponder(textView)
        appDelegate?.updateMenuForActiveWindow()
    }

    // confirmEndingTextEdit(): Closing or detaching must not silently discard a
    // draft. Cancel leaves the editor intact.
    func confirmEndingTextEdit() -> Bool {
        // Allow closing when no text edit is active.
        guard let editor = textEditor else { return true }
        // Discard an unchanged draft without asking the user to save it.
        guard editor.hasChanges else { cancelTextEditing(); return true }
        let alert = NSAlert()
        alert.messageText = localized("save_text_changes", "Save your text changes?")
        // Use warning styling when saving would also remove attached audio.
        if hasAttachedNarration {
            alert.alertStyle = .warning
            alert.informativeText = editAudioRemovalWarning
        }
        alert.addButton(withTitle: localized("save", "Save"))
        alert.addButton(withTitle: localized("discard_changes", "Discard Changes"))
        alert.addButton(withTitle: localized("cancel", "Cancel"))
        // Apply the user's save, discard, or keep-editing decision.
        switch alert.runModal() {
        // Save using the audio warning already shown by this confirmation.
        case .alertFirstButtonReturn: return finishTextEditing(confirmAudioRemoval: false)
        // Discard the draft and allow the requested close action.
        case .alertSecondButtonReturn: cancelTextEditing(); return true
        // Keep editing for cancellation or any unrecognized alert response.
        default: return false
        }
    }

    // windowShouldClose(sender): Resolve unsaved result edits before allowing
    // its detached window to close.
    @objc func windowShouldClose(_ sender: NSWindow) -> Bool { confirmEndingTextEdit() }
}

// Apply unsaved-edit handling to results embedded in the main launcher.
extension LauncherController {
    // windowShouldClose(sender): Ask the inline result to resolve its draft
    // before the launcher closes.
    @objc func windowShouldClose(_ sender: NSWindow) -> Bool {
        inlineResultSession?.confirmEndingTextEdit() ?? true
    }
}

// Protect open result drafts when the user quits the application.
extension AppDelegate {
    // applicationShouldTerminate(sender): Allow termination only after every
    // open result accepts ending its text edit.
    @objc func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Resolve drafts in detached results and the launcher's inline result before quitting.
        for session in sessions + [launcherController.inlineResultSession].compactMap({ $0 }) {
            // Cancel application termination when any result asks to keep editing.
            guard session.confirmEndingTextEdit() else { return .terminateCancel }
        }
        return .terminateNow
    }
}
