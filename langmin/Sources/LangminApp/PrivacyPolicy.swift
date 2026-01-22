import Cocoa

// Allow the in-app privacy panel to close with the standard cancel action.
private final class PrivacyPolicyPanel: NSPanel {
    // cancelOperation(sender): Treat Escape as closing this read-only policy
    // panel.
    override func cancelOperation(_ sender: Any?) { close() }
}

// Read the bundled policy in Langmin, including while the Pro purchase window is modal.
final class PrivacyPolicyController: NSObject, NSTextViewDelegate {
    static let shared = PrivacyPolicyController()
    private var window: NSPanel?
    private var textView: NSTextView!

    // show(): Refresh the bundled policy and bring its reusable in-app panel
    // forward.
    func show() {
        // Create the policy reader only on its first presentation.
        if window == nil { buildWindow() }
        textView.textStorage?.setAttributedString(Self.policyText(
            at: Bundle.main.url(forResource: "PRIVACY", withExtension: "md")
        ))
        textView.scrollToBeginningOfDocument(nil)
        // Center newly opened readers without moving one the user is already reading.
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // buildWindow(): Build a resizable policy reader with a separate scroll
    // area and dismissal button.
    private func buildWindow() {
        let panel = PrivacyPolicyPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = localized("pro_privacy_policy", "Privacy Policy")
        panel.isReleasedWhenClosed = false
        panel.worksWhenModal = true
        panel.hidesOnDeactivate = false
        let content = installNativeContent(in: panel)
        panel.setContentSize(nativeContentSize(NSSize(width: 640, height: 580), in: panel))
        panel.contentMinSize = nativeContentSize(NSSize(width: 420, height: 320), in: panel)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 500))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Keep padding inside the scroll view so overlay scrollers stay in the window-edge gutter.
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        textView.setAccessibilityLabel(localized("pro_privacy_policy", "Privacy Policy"))
        scroll.documentView = textView

        let close = NSButton(title: localized("ok", "OK"), target: self, action: #selector(dismiss(_:)))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        // Use explicit constraints for both the scroll area and its dismissal control.
        for view in [scroll, close] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -14),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        window = panel
    }

    // policyText(url): A missing or unreadable bundled policy still opens this
    // panel, with an explicit online link.
    static func policyText(at url: URL?) -> NSAttributedString {
        do {
            // Treat a missing bundled policy as a load failure with a visible fallback message.
            guard let url else { throw CocoaError(.fileNoSuchFile) }
            let markdown = try String(contentsOf: url, encoding: .utf8)
            // Do not display an empty bundled file as though a policy loaded successfully.
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return attributedPolicy(markdown)
        } catch {
            // Show a readable in-app fallback when the policy cannot be loaded.
            let title = localized("pro_privacy_policy", "Privacy Policy")
            return attributedPolicy("# \(title)\n\n\(error.localizedDescription)\n\n[\(title)](\(privacyPolicyURL.absoluteString))")
        }
    }

    // attributedPolicy(markdown): The bundled policy uses headings and
    // paragraphs. Render inline Markdown without HTML or a web view, preserving
    // emphasis, selectable text and links in both system appearances.
    static func attributedPolicy(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        // Render Markdown blocks with spacing between paragraphs and headings.
        for block in normalized.components(separatedBy: "\n\n") {
            var text = block.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip empty blocks left by adjacent blank lines.
            guard !text.isEmpty else { continue }
            let heading = text.prefix { $0 == "#" }.count
            let isHeading = (1...6).contains(heading) && text.dropFirst(heading).first == " "
            // Remove the heading marker before rendering its text at heading size.
            if isHeading { text = String(text.dropFirst(heading + 1)) }
            text = text.replacingOccurrences(of: "\n", with: " ")
            let size: CGFloat = isHeading ? (heading == 1 ? 24 : heading == 2 ? 18 : 15) : 14
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = isHeading ? 12 : 18
            paragraph.paragraphSpacingBefore = isHeading && result.length > 0 ? 8 : 0
            let parsed = (try? AttributedString(markdown: text, options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            ))) ?? AttributedString(text)
            // Preserve inline emphasis and links within each rendered block.
            for run in parsed.runs {
                let intent = run.inlinePresentationIntent ?? []
                let weight: NSFont.Weight = isHeading || intent.contains(.stronglyEmphasized) ? .semibold : .regular
                var font = intent.contains(.code)
                    ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                    : NSFont.systemFont(ofSize: size, weight: weight)
                // Add italic traits when Markdown marks the text as emphasized.
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
                ]
                // Retain explicit Markdown link destinations on their rendered labels.
                if let link = run.link { attributes[.link] = link }
                result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
            result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
        }
        // Make the policy's plain contact address clickable without replacing explicit Markdown links.
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        // Make bare detected URLs clickable as well as explicit Markdown links.
        for match in detector?.matches(in: result.string, range: NSRange(location: 0, length: result.length)) ?? [] {
            // Add detected links only where Markdown has not already supplied a destination.
            if let url = match.url, result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil {
                result.addAttribute(.link, value: url, range: match.range)
            }
        }
        return result
    }

    // textView(textView, link, charIndex): Only an explicit link click can
    // leave the policy window.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        // Open only the supported web and email link schemes from policy text.
        if let url, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return true
    }

    // dismiss(sender): Close the policy panel from its OK button.
    @objc private func dismiss(_ sender: Any?) { window?.close() }
}
