import Cocoa

// Public builds show this recoverable notice only after the independent trial has ended.
final class SourcePurchaseFooter: NSView {
    static let visibleHeight: CGFloat = 58
    private static let dismissedKey = "LangminDidDismissExpiredTrialBanner"
    private static var previewDismissed = false

    var onVisibilityChange: ((Bool) -> Void)?
    private let topBorder = NSView()
    private let dismissButton = NSButton()
    private let restoreButton = NSButton()
    private let purchaseButton = NSButton()
    private var heightConstraint: NSLayoutConstraint!
    private var restoring = false

    // shouldBeVisible: Match window sizing to the footer's persisted and current access state.
    static var shouldBeVisible: Bool {
        let store = ProStore.shared
        let dismissed = LangminEdition.isExpiredTrialPreview
            ? previewDismissed
            : UserDefaults.standard.bool(forKey: dismissedKey)
        return store.hasPreparedAppTrial && !store.hasFullAccess && !dismissed
    }

    // init(frame): Explain the expired trial and offer dismissal, purchase, or restore.
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true

        // Keep the explanation readable while long translations can truncate.
        let title = NSTextField(labelWithString: localized("source_build_title", "Trial ended"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        let message = NSTextField(labelWithString: localized(
            "source_build_support",
            "Apple Intelligence stays free, while other Pro features require purchase."
        ))
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, message])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolTip = title.stringValue + "\n" + message.stringValue

        // Give all actions the same subdued native button style.
        dismissButton.title = localized("source_build_dismiss", "Dismiss")
        dismissButton.action = #selector(dismissBanner)
        restoreButton.title = localized("pro_restore_purchases", "Restore Purchases")
        restoreButton.action = #selector(restorePurchases)
        purchaseButton.title = localized("source_build_purchase", "Purchase")
        purchaseButton.action = #selector(openPurchase)
        for button in [dismissButton, restoreButton, purchaseButton] {
            button.target = self
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        let actions = NSStackView(views: [dismissButton, restoreButton, purchaseButton])
        actions.spacing = 10
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.distribution = .fill
        actions.setHuggingPriority(.required, for: .horizontal)

        // A zero-height footer releases its space during the trial, after purchase, or after dismissal.
        topBorder.wantsLayer = true
        for view in [text, actions, topBorder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.visibleHeight)
        NSLayoutConstraint.activate([
            heightConstraint,
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            text.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -14),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1)
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateAccess),
            name: ProStore.entitlementDidChange,
            object: nil
        )
        updateAccess()
        updateColors()
    }

    // init?(coder): This footer is created in code, never decoded from a nib.
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // deinit(): Stop receiving purchase updates when the launcher is released.
    deinit { NotificationCenter.default.removeObserver(self) }

    // updateAccess(): Collapse the banner while full access applies or after dismissal.
    @objc private func updateAccess() {
        let visible = Self.shouldBeVisible
        isHidden = !visible
        heightConstraint.constant = visible ? Self.visibleHeight : 0
        onVisibilityChange?(visible)
    }

    // viewDidChangeEffectiveAppearance(): Resolve the amber tint in the new appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    // updateColors(): Match the restrained amber purchase banner used by the other apps.
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.16).cgColor
            topBorder.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.48).cgColor
        }
    }

    // dismissBanner(): Remember that this user does not want the optional Pro reminder.
    @objc private func dismissBanner() {
        if LangminEdition.isExpiredTrialPreview {
            // Keep preview dismissal in memory so public preferences stay untouched.
            Self.previewDismissed = true
        } else {
            UserDefaults.standard.set(true, forKey: Self.dismissedKey)
        }
        updateAccess()
    }

    // openPurchase(): Offer yearly and lifetime purchase choices.
    @objc private func openPurchase() {
        // Ignore a queued click while a restore is pending.
        guard !restoring else { return }
        _ = ProPaywallController.presentModal(feature: nil)
        updateAccess()
    }

    // restorePurchases(): Restore verified access without allowing competing requests.
    @objc private func restorePurchases() {
        // Prevent double clicks from starting multiple account prompts.
        guard !restoring else { return }
        restoring = true
        dismissButton.isEnabled = false
        restoreButton.isEnabled = false
        purchaseButton.isEnabled = false
        Task { @MainActor in
            // Re-enable every action even when restoration fails or finds nothing.
            defer {
                restoring = false
                dismissButton.isEnabled = true
                restoreButton.isEnabled = true
                purchaseButton.isEnabled = true
                updateAccess()
            }
            do {
                // Keep the banner visible and explain when no purchase was found.
                let restored = try await ProStore.shared.restore()
                if !restored { presentNothingToRestoreAlert() }
            } catch {
                // Report the StoreKit error without changing the user's access.
                presentProAlert(
                    title: localized("pro_restore_purchases", "Restore Purchases"),
                    body: error.localizedDescription,
                    style: .warning
                )
            }
        }
    }
}
