import Cocoa

private let printKeepWithNext = NSAttributedString.Key("LangminPrintKeepWithNext")

// Prepare and print result content without interactive viewer controls.
extension ViewerSession {
    // printableResultText(): Rebuild from completed messages so hover controls
    // and loading indicators never reach the page.
    func printableResultText() -> NSAttributedString {
        let text = NSMutableAttributedString(string: "")
        var label = viewerTextAttributes(weight: .semibold, size: config.fontSize * 0.85)
        label[printKeepWithNext] = true
        // Include the result illustration as a print-safe image attachment when present.
        if let image = illustrationImage {
            let attachment = NSTextAttachment()
            attachment.image = image
            text.append(NSAttributedString(attachment: attachment))
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacing = 12
            text.append(NSAttributedString(string: "\n" + dictionaryIllustrationCaption(model: config.illustrationModel) + "\n\n",
                                          attributes: viewerTextAttributes(size: config.fontSize * 0.8, paragraphStyle: style)))
        }
        text.append(markdownAttributedText(from: content))
        // Print completed conversation turns after the main result.
        for turn in config.conversation?.turns ?? [] {
            // Include a user label only for a nonempty question.
            if !turn.question.isEmpty {
                text.append(NSAttributedString(string: "\n\n" + localized("followup_you", "You") + "\n",
                                              attributes: label))
                text.append(NSAttributedString(string: turn.question, attributes: viewerTextAttributes()))
            }
            // Include the answering model label only for a completed nonempty response.
            if !turn.answer.isEmpty {
                text.append(NSAttributedString(string: "\n\nLangmin · " + turn.modelName + "\n",
                                              attributes: label))
                text.append(markdownAttributedText(from: turn.answer))
            }
        }
        return text
    }

    // printResult(sender): The same print sheet serves the inline pane,
    // detached windows and File > Print.
    @objc func printResult(_ sender: Any?) {
        // Avoid starting a second print operation or competing with an attached sheet.
        guard let hostWindow, hostWindow.attachedSheet == nil,
              resultPrintOperation == nil, NSPrintOperation.current == nil else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 40
        info.bottomMargin = 40
        info.leftMargin = 42
        info.rightMargin = 42
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.scalingFactor = 1
        let view = ResultPrintView(title: titleForLabel(), text: printableResultText(), fontSize: config.fontSize)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = titleForLabel()
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        resultPrintOperation = operation
        appDelegate?.updateMenuForActiveWindow()
        operation.runModal(for: hostWindow, delegate: self,
                           didRun: #selector(resultPrintDidFinish(_:success:contextInfo:)), contextInfo: nil)
    }

    // resultPrintDidFinish(operation, success, contextInfo): Release the
    // completed print operation and refresh menu availability.
    @objc func resultPrintDidFinish(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        resultPrintOperation = nil
        appDelegate?.updateMenuForActiveWindow()
    }
}

// Keep printed images compact and centered, even on wide paper.
private final class ResultPrintImageAttachment: NSTextAttachment {
    var maximumHeight: CGFloat = 200
    // attachmentBounds(textContainer, lineFrag, position, charIndex): Scale
    // printed attachments to fit the line and page without enlarging their
    // source image.
    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: NSRect,
                                   glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        // Skip missing or zero-sized images instead of producing invalid print geometry.
        guard let size = image?.size, size.width > 0, size.height > 0 else { return .zero }
        let width = min(300, max(1, lineFrag.width - 2))
        let scale = min(1, width / size.width, maximumHeight / size.height)
        return NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
    }

    // cardImage(source): Draw the original image into rounded edges without
    // resizing or changing the saved asset.
    static func cardImage(_ source: NSImage) -> NSImage {
        NSImage(size: source.size, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            let radius = min(rect.width, rect.height) * 0.04
            let outline = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            outline.addClip()
            source.draw(in: rect)
            NSColor(calibratedWhite: 0, alpha: 0.12).setStroke()
            outline.lineWidth = min(rect.width, rect.height) * 0.003
            outline.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }
}

// Flow text through one TextKit container per page so page breaks fall between lines and images.
final class ResultPrintView: NSView {
    private let title: String
    let storage: NSTextStorage
    let layout = NSLayoutManager()
    private(set) var pageSize = NSSize.zero
    private var printScale: CGFloat = 1
    private let headerHeight: CGFloat = 34
    private let footerHeight: CGFloat = 26
    override var isFlipped: Bool { true }
    override var printJobTitle: String { title }

    // init(title, text, fontSize): Create a light-appearance print view with a
    // dedicated, print-safe text storage.
    init(title: String, text: NSAttributedString, fontSize: CGFloat) {
        self.title = title
        storage = NSTextStorage(attributedString: Self.paperText(text, fontSize: fontSize))
        super.init(frame: .zero)
        appearance = NSAppearance(named: .aqua)
        storage.addLayoutManager(layout)
    }

    // init?(coder): Print views require their result text and are not decoded
    // from a nib.
    required init?(coder: NSCoder) { nil }

    // paperText(source, fontSize): Keep emphasis, lists, code and links, with
    // fixed ink colors and comfortable print sizes.
    static func paperText(_ source: NSAttributedString, fontSize: CGFloat) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: source)
        let scale = 11.5 / max(1, fontSize)
        // Scale display fonts to paper while preserving their existing traits.
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: fontSize)
            var printed: [NSAttributedString.Key: Any] = [
                .font: NSFontManager.shared.convert(font, toSize: min(26, max(8, font.pointSize * scale))),
                .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)
            ]
            // Scale paragraph spacing, indents, and tabs with the text.
            let style = ((attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            style.lineSpacing *= scale
            style.paragraphSpacing *= scale
            style.paragraphSpacingBefore *= scale
            style.firstLineHeadIndent *= scale
            style.headIndent *= scale
            style.tailIndent *= scale
            style.defaultTabInterval *= scale
            style.tabStops = style.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location * scale, options: $0.options) }
            printed[.paragraphStyle] = style
            // Keep headings and image-related content with the block that follows them.
            if font.pointSize > fontSize * 1.02 || attributes[printKeepWithNext] != nil || attributes[.attachment] != nil {
                printed[printKeepWithNext] = true
            }
            // Retain inline decorations that remain meaningful on paper.
            for key in [NSAttributedString.Key.strikethroughStyle, .underlineStyle, .baselineOffset, .kern] {
                // Copy a decoration only when it was explicitly present in the source.
                if let value = attributes[key] { printed[key] = value }
            }
            if let link = attributes[.link] {
                // TextKit preserves these as clickable links in the PDF.
                printed[.link] = link
                printed[.foregroundColor] = NSColor(calibratedRed: 0.05, green: 0.30, blue: 0.62, alpha: 1)
            }
            // Give code a light paper-friendly background independent of the screen theme.
            if attributes[.langminInlineCode] != nil || attributes[.langminCodeBlock] != nil {
                printed[.backgroundColor] = NSColor(calibratedWhite: 0.95, alpha: 1)
            }
            // Replace screen attachments with images sized for the printed page.
            if let original = attributes[.attachment] as? NSTextAttachment, let image = original.image {
                let attachment = ResultPrintImageAttachment()
                attachment.image = ResultPrintImageAttachment.cardImage(image)
                printed[.attachment] = attachment
                style.alignment = .center
                style.paragraphSpacing = 8
            }
            text.setAttributes(printed, range: range)
        }
        return text
    }

    // paginate(info): Reflow when the print panel changes paper size,
    // orientation or scale.
    func paginate(with info: NSPrintInfo) {
        let scale = max(0.1, info.scalingFactor)
        let size = NSSize(width: max(72, info.paperSize.width - info.leftMargin - info.rightMargin),
                          height: max(124, info.paperSize.height - info.topMargin - info.bottomMargin))
        // Reuse existing pagination when paper size and scaling are unchanged.
        guard size != pageSize || scale != printScale else { return }
        pageSize = size
        printScale = scale
        // Discard old page containers before laying out the new page geometry.
        while !layout.textContainers.isEmpty { layout.removeTextContainer(at: 0) }
        let bodyHeight = max(64, size.height / scale - headerHeight - footerHeight)
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            (value as? ResultPrintImageAttachment)?.maximumHeight = min(200, bodyHeight * 0.4)
        }
        var end = 0
        repeat {
            let container = NSTextContainer(containerSize: NSSize(width: size.width / scale,
                                                                 height: bodyHeight))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            keepHeadingWithBody(in: container)
            let range = layout.glyphRange(for: container)
            end = NSMaxRange(range)
            // Empty documents still have a page. The minimum page height fits every supported font and image.
            if range.length == 0 { break }
        // Continue creating pages until every text glyph has a destination.
        } while end < layout.numberOfGlyphs
        frame.size = NSSize(width: size.width, height: size.height * CGFloat(layout.textContainers.count))
    }

    // keepHeadingWithBody(container): Move a trailing heading or message label
    // to the next page with its first line of text.
    private func keepHeadingWithBody(in container: NSTextContainer) {
        let glyphs = layout.glyphRange(for: container)
        // The last page needs no adjustment to avoid an orphaned heading on a later page.
        guard NSMaxRange(glyphs) < layout.numberOfGlyphs else { return }
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let string = storage.string as NSString
        var last = NSMaxRange(characters)
        // Ignore trailing whitespace when deciding whether the page ends with a heading.
        while last > characters.location && UnicodeScalar(string.character(at: last - 1)).map({ CharacterSet.whitespacesAndNewlines.contains($0) }) == true {
            last -= 1
        }
        // Adjust the break only when the last visible content is marked to stay with its successor.
        guard last > characters.location, storage.attribute(printKeepWithNext, at: last - 1, effectiveRange: nil) != nil else { return }
        let paragraph = string.paragraphRange(for: NSRange(location: last - 1, length: 1))
        let start = layout.glyphIndexForCharacter(at: paragraph.location)
        // Keep a leading heading on the page when moving it would leave the page empty.
        guard start > glyphs.location else { return }
        let line = layout.lineFragmentRect(forGlyphAt: start, effectiveRange: nil)
        container.containerSize.height = max(1, line.minY)
        layout.ensureLayout(for: container)
    }

    // knowsPageRange(range): Paginate using the active print settings and
    // report AppKit's one-based page range.
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        // Report no page range until an active print operation supplies paper settings.
        guard let info = NSPrintOperation.current?.printInfo else { return false }
        paginate(with: info)
        range.pointee = NSRange(location: 1, length: layout.textContainers.count)
        return true
    }

    // rectForPage(page): Locate a page in the print view's vertically stacked
    // page coordinate space.
    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(page - 1) * pageSize.height, width: pageSize.width, height: pageSize.height)
    }

    // draw(dirtyRect): Draw visible paper pages and their laid-out text against
    // a white background.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        // Draw only the page containers that intersect the requested drawing region.
        for (index, container) in layout.textContainers.enumerated() {
            let page = rectForPage(index + 1)
            // Skip pages outside the dirty rectangle.
            guard page.intersects(dirtyRect) else { continue }
            // Clip and transform drawing into this page's printable coordinate
            // space.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: page).addClip()
            let transform = NSAffineTransform()
            transform.translateX(by: 0, yBy: page.minY)
            transform.scale(by: printScale)
            transform.concat()
            let width = page.width / printScale
            let height = page.height / printScale
            // Use a compact, muted header that does not crowd the document
            // body.
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let small: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8.5),
                .foregroundColor: NSColor(calibratedWhite: 0.4, alpha: 1), .paragraphStyle: style.copy()
            ]
            (title as NSString).draw(in: NSRect(x: 0, y: 0, width: width, height: 14), withAttributes: small)
            NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
            NSRect(x: 0, y: 21, width: width, height: 0.5).fill()
            // Draw this page's laid-out glyphs below the header.
            let origin = NSPoint(x: 0, y: headerHeight)
            let glyphs = layout.glyphRange(for: container)
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            // Put the app name and page count at opposite ends of the footer.
            let footer = NSRect(x: 0, y: height - 12, width: width, height: 12)
            ("Langmin" as NSString).draw(in: footer, withAttributes: small)
            style.alignment = .right
            var right = small
            right[.paragraphStyle] = style.copy()
            ("\(index + 1) / \(layout.textContainers.count)" as NSString).draw(in: footer, withAttributes: right)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

}
