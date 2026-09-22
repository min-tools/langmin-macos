import Cocoa
import StoreKit

// MARK: - Store

// Load products, handle purchases and cache Pro access.
// Read and update the entitlement only on the main thread.
final class ProStore {
    static let shared = ProStore()
    static let entitlementDidChange = Notification.Name("LangminProEntitlementDidChange")
    static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!
    static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    // Separate completed purchases from pending approval and user cancellation.
    enum PurchaseOutcome {
        // A verified purchase unlocked Pro access.
        case unlocked
        // The purchase is waiting for approval or another store-side step.
        case pending
        // The user cancelled without completing a purchase.
        case cancelled
    }

    // Expose StoreKit-flow errors through a user-readable localized description.
    struct StoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var entitlement: ProEntitlement = .free
    private(set) var yearly: Product?
    private(set) var lifetime: Product?
    private(set) var appTrialStartedAt: Date?
    private(set) var hasResolvedEntitlement = false
    private var updatesTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var entitlementTimer: Timer?
    private var appTrialTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    private static let appTrialStartedAtKey = "LangminAppTrialStartedAt"

    var isPro: Bool {
        // Private local builds can grant access without querying StoreKit.
        if let developerOverride {
            return developerOverride
        }
        return entitlement.isPro
    }

    var isAppTrialActive: Bool {
        guard developerOverride == nil, !entitlement.isPro, let appTrialStartedAt else {
            return false
        }
        return LangminFreeAccessPolicy.isTrialActive(startedAt: appTrialStartedAt)
    }

    var hasFullAccess: Bool { isPro || isAppTrialActive }
    var hasPreparedAppTrial: Bool { developerOverride != nil || appTrialStartedAt != nil }
    var canManageSubscription: Bool { entitlement.kind == .subscription && !entitlement.isFamilyShared }

    // Only the private build input can override verified purchase access.
    var developerOverride: Bool? { LangminEdition.localProAccess }

    // start(): Start the transaction listener once and load the current
    // entitlement.
    func start() {
        // An unlocked local build must not start StoreKit or prompt for an Apple Account.
        guard developerOverride == nil else {
            hasResolvedEntitlement = true
            return
        }
        prepareAppTrial()
        // Install the transaction observer once.
        guard updatesTask == nil else {
            return
        }
        updatesTask = Task { [weak self] in
            // Process StoreKit transaction updates until the observer task is cancelled.
            for await result in Transaction.updates {
                // Finish only verified transactions before refreshing access.
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await self?.refreshEntitlement()
            }
        }
        // Recheck after sleep or an App Store account change while Langmin was
        // inactive.
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }

            // Refresh trial-dependent UI after a long inactive period.
            self.prepareAppTrial()
            NotificationCenter.default.post(name: Self.entitlementDidChange, object: self)
            Task { @MainActor [weak self] in await self?.refreshEntitlement() }
        }
        Task { [weak self] in
            await self?.refreshEntitlement()
        }
    }

    // deinit(): Stop transaction updates, entitlement timers, and activation
    // observation when the store is released.
    deinit {
        updatesTask?.cancel()
        entitlementTimer?.invalidate()
        appTrialTimer?.invalidate()
        // Remove the activation observer when releasing the store.
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    // refreshEntitlement(): Apply verified access before loading optional
    // renewal text, which can require the network.
    @MainActor func refreshEntitlement() async {
        // Private local builds do not need a StoreKit entitlement refresh.
        guard developerOverride == nil else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        var summaries: [ProTransactionSummary] = []
        // Build access state from StoreKit's current entitlements.
        for await result in Transaction.currentEntitlements {
            // Ignore transaction data whose signature was not verified.
            guard case .verified(let transaction) = result else {
                continue
            }
            summaries.append(summary(of: transaction))
        }
        // Discard a refresh result if a newer refresh started while it was awaiting StoreKit.
        guard generation == refreshGeneration else { return }
        let resolvedForFirstTime = !hasResolvedEntitlement
        hasResolvedEntitlement = true
        var evaluated = ProEntitlementLogic.evaluate(summaries)
        // Retain renewal metadata only when the newly evaluated entitlement represents the same access.
        if evaluated.kind == entitlement.kind && evaluated.expirationDate == entitlement.expirationDate
            && evaluated.isFamilyShared == entitlement.isFamilyShared {
            evaluated.willAutoRenew = entitlement.willAutoRenew
        }
        let entitlementChanged = evaluated != entitlement
        applyEntitlement(evaluated)
        // Publish the first resolved free state even when the entitlement value stayed unchanged.
        if resolvedForFirstTime && !entitlementChanged {
            NotificationCenter.default.post(name: Self.entitlementDidChange, object: self)
        }
        scheduleEntitlementRefresh()
        // Look up renewal details only for an active subscription entitlement.
        if evaluated.kind == .subscription {
            evaluated.willAutoRenew = await subscriptionWillAutoRenew(for: evaluated)
            // A slow product request must not restore access after a newer expiry or revocation.
            guard generation == refreshGeneration else { return }
            applyEntitlement(evaluated)
        }
    }

    // applyEntitlement(updated): Publish entitlement changes on the main actor
    // only when the verified state differs.
    @MainActor private func applyEntitlement(_ updated: ProEntitlement) {
        // Notify observers only when the entitlement value changes.
        if updated != entitlement {
            entitlement = updated
            NotificationCenter.default.post(name: Self.entitlementDidChange, object: self)
        }
    }

    // scheduleEntitlementRefresh(): Expiry need not emit a new transaction. Ask
    // StoreKit again rather than revoking access by date alone, because a
    // subscription in Apple's billing grace period still provides Pro.
    private func scheduleEntitlementRefresh() {
        entitlementTimer?.invalidate()
        entitlementTimer = nil
        // Only subscription access needs a timer to revisit expiration and renewal status.
        guard entitlement.kind == .subscription else { return }
        let remaining = entitlement.expirationDate?.timeIntervalSinceNow ?? 60
        let delay = remaining > 0 ? max(1, min(60, remaining)) : 60
        entitlementTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshEntitlement() }
        }
    }

    // beginAppTrial([now]): Start the local trial after its first-launch disclosure is accepted.
    func beginAppTrial(now: Date = Date()) {
        prepareAppTrial(startIfNeeded: true, now: now)
    }

    // prepareAppTrial([startIfNeeded = false], [now]): Restore trial state and optionally start it.
    private func prepareAppTrial(startIfNeeded: Bool = false, now: Date = Date()) {
        // Private builds never create public trial state.
        guard developerOverride == nil else { return }
        let previousStart = appTrialStartedAt
        if let forced = LangminEdition.forcedTrialStartedAt {
            // Private previews must not change the real trial date in preferences.
            appTrialStartedAt = forced
        } else if appTrialStartedAt == nil {
            if let stored = UserDefaults.standard.object(forKey: Self.appTrialStartedAtKey) as? Date {
                appTrialStartedAt = stored
            } else if startIfNeeded {
                appTrialStartedAt = now
                UserDefaults.standard.set(now, forKey: Self.appTrialStartedAtKey)
            }
        }
        if appTrialStartedAt != previousStart {
            NotificationCenter.default.post(name: Self.entitlementDidChange, object: self)
        }
        scheduleAppTrialExpiry(now: now)
    }

    // scheduleAppTrialExpiry([now]): Publish access changes when the local trial reaches its end.
    private func scheduleAppTrialExpiry(now: Date = Date()) {
        appTrialTimer?.invalidate()
        appTrialTimer = nil
        guard let appTrialStartedAt,
              LangminFreeAccessPolicy.isTrialActive(startedAt: appTrialStartedAt, now: now) else {
            return
        }
        let expiry = appTrialStartedAt.addingTimeInterval(LangminFreeAccessPolicy.trialDuration)
        appTrialTimer = Timer.scheduledTimer(
            withTimeInterval: max(1, expiry.timeIntervalSince(now)),
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            NotificationCenter.default.post(name: Self.entitlementDidChange, object: self)
        }
    }

    // subscriptionWillAutoRenew(current): Load the product before reading
    // renewal status. Return nil if it is unavailable.
    private func subscriptionWillAutoRenew(for current: ProEntitlement) async -> Bool? {
        // Load the yearly product before requesting its subscription status if needed.
        if yearly == nil {
            try? await loadProducts()
        }
        // Leave renewal state unknown when StoreKit status is unavailable.
        guard let statuses = try? await yearly?.subscription?.status else {
            return nil
        }
        for status in statuses {
            // StoreKit can return both owned and family subscriptions. Only describe
            // renewal for the verified purchase that currently provides access.
            guard case .verified(let transaction) = status.transaction,
                  transaction.productID == ProProductID.yearly,
                  transaction.revocationDate == nil,
                  transaction.expirationDate == current.expirationDate,
                  (transaction.ownershipType == .familyShared) == current.isFamilyShared,
                  // Trust renewal information only after StoreKit verifies it.
                  case .verified(let info) = status.renewalInfo else { continue }
            return info.willAutoRenew
        }
        return nil
    }

    // summary(transaction): Extract the transaction fields used for entitlement
    // decisions, including version-specific trial metadata.
    private func summary(of transaction: Transaction) -> ProTransactionSummary {
        let introductory: Bool
        // Use the newer introductory-offer metadata on supported macOS versions.
        if #available(macOS 14.2, *) {
            introductory = transaction.offer?.type == .introductory
        } else {
            // Use the earlier offer-type property on older supported versions.
            introductory = transaction.offerType == .introductory
        }
        return ProTransactionSummary(
            productID: transaction.productID,
            purchaseDate: transaction.purchaseDate,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            isFamilyShared: transaction.ownershipType == .familyShared,
            isIntroductoryOffer: introductory
        )
    }

    // loadProducts(): Load the yearly and lifetime products.
    func loadProducts() async throws {
        // Avoid store product requests in a private local build.
        guard developerOverride == nil else { return }
        let products = try await Product.products(for: ProProductID.all)
        let yearly = products.first { $0.id == ProProductID.yearly }
        let lifetime = products.first { $0.id == ProProductID.lifetime }
        // Report product unavailability when neither configured product is returned.
        guard yearly != nil || lifetime != nil else {
            throw StoreError(message: localized(
                "pro_store_unavailable",
                "Pro purchases are unavailable right now. Please try again later."
            ))
        }
        await MainActor.run {
            self.yearly = yearly
            self.lifetime = lifetime
        }
    }

    // purchase(product, window): Update Pro access after purchase. Pending
    // purchases complete through the transaction listener.
    func purchase(_ product: Product, confirmIn window: NSWindow?) async throws -> PurchaseOutcome {
        // Return development access without opening a purchase confirmation.
        if developerOverride == true { return .unlocked }
        let result: Product.PurchaseResult
        // Anchor the system purchase confirmation to its window when the API supports it.
        if #available(macOS 15.2, *), let window {
            result = try await product.purchase(confirmIn: window, options: [])
        } else {
            // Use the standard purchase API on older macOS versions or without a window.
            result = try await product.purchase(options: [])
        }
        // Separate verified success, pending approval, and user cancellation.
        switch result {
        // Validate the returned transaction before treating purchase completion as access.
        case .success(let verification):
            // Do not unlock Pro from an unverified purchase result.
            guard case .verified(let transaction) = verification else {
                throw StoreError(message: localized(
                    "pro_unverified",
                    "The App Store could not verify this purchase."
                ))
            }
            await transaction.finish()
            await refreshEntitlement()
            return .unlocked
        // Preserve the pending outcome without claiming the purchase is complete.
        case .pending:
            return .pending
        // Treat user cancellation as a normal outcome rather than an error.
        case .userCancelled:
            return .cancelled
        // Treat future StoreKit result cases as uncompleted purchases.
        @unknown default:
            return .cancelled
        }
    }

    // restore(): Sync purchases with the App Store and return whether Pro is
    // active.
    func restore() async throws -> Bool {
        // Restore immediately succeeds for a private local build.
        if developerOverride == true { return true }
        try await AppStore.sync()
        await refreshEntitlement()
        return await MainActor.run { isPro }
    }

    // statusText(): The one-line entitlement description shown in Settings and
    // the Pro panel.
    func statusText() -> String {
        // Keep private development access distinct from an App Store purchase.
        if developerOverride == true {
            return LangminEdition.localAccessStatus ?? localized("pro_status_active", "Pro")
        }
        // Describe the independent local trial before purchase entitlement details.
        if isAppTrialActive, let appTrialStartedAt {
            let days = LangminFreeAccessPolicy.trialDaysRemaining(startedAt: appTrialStartedAt)
            return days == 1
                ? localized("pro_app_trial_one_day", "Pro trial · 1 day remaining")
                : String(
                    format: localized("pro_app_trial_days", "Pro trial · %d days remaining"),
                    days
                )
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        // Format the status derived from the verified entitlement and available renewal information.
        switch ProEntitlementLogic.statusKind(for: entitlement) {
        // Show the free state when there is no Pro entitlement.
        case .free:
            return localized("pro_status_free", "Free")
        // Show neutral active access when precise renewal timing is unavailable.
        case .active:
            return localized("pro_status_active", "Pro")
        // Identify lifetime access without suggesting a renewal date.
        case .lifetime:
            return localized("pro_status_lifetime", "Pro · lifetime")
        // Identify family-shared access without claiming the user owns its billing controls.
        case .familyShared:
            return localized("pro_status_family", "Pro · shared with your family")
        // Show the first-payment date for a trial known to renew.
        case .trialRenews(let date):
            return String(format: localized("pro_status_trial_renews", "Pro trial · first payment %@"), formatter.string(from: date))
        // Show the end date for a trial known not to renew.
        case .trialEnds(let date):
            return String(format: localized("pro_status_trial_ends", "Pro trial · ends %@"), formatter.string(from: date))
        // Show the trial's known coverage date without guessing renewal behavior.
        case .trialUntil(let date):
            return String(format: localized("pro_status_trial_until", "Pro trial · until %@"), formatter.string(from: date))
        // Show the renewal date when auto-renewal is verified.
        case .renews(let date):
            return String(format: localized("pro_status_renews", "Pro · renews %@"), formatter.string(from: date))
        // Show the end date when renewal is verified as disabled.
        case .ends(let date):
            return String(format: localized("pro_status_ends", "Pro · ends %@"), formatter.string(from: date))
        // Show the coverage date when renewal status remains unknown.
        case .activeUntil(let date):
            return String(format: localized("pro_status_until", "Pro · until %@"), formatter.string(from: date))
        }
    }
}

// MARK: - Gate

// ensureProAccess(feature, [deadline = nil]): Check Pro access, offering the
// paywall when needed. A successful purchase lets the caller continue. Services
// calls limit the dialog with a deadline.
@discardableResult
func ensureProAccess(_ feature: ProFeature, deadline: DispatchTime? = nil) -> Bool {
    // Allow the feature immediately when the current entitlement already grants Pro.
    if ProStore.shared.hasFullAccess {
        return true
    }
    return ProPaywallController.presentModal(feature: feature, deadline: deadline) == .unlocked
}

// MARK: - Panel

// Show purchases, restore and subscription status. Run modally so a purchase
// can resume the action that opened the paywall.
final class ProPaywallController: NSObject, NSWindowDelegate {
    // Tell a gated caller whether the Pro panel unlocked access or was dismissed.
    enum Outcome {
        // Return unlocked when the panel completes an access-granting action.
        case unlocked
        // Return dismissed when the user leaves without unlocking the feature.
        case dismissed
    }

    // Fit the longest translated feature label beside its icon.
    private static let contentWidth: CGFloat = 500
    private static let sideInset: CGFloat = 28

    private let feature: ProFeature?
    private var window: NSWindow!
    private var content: NSStackView!
    private var outcome: Outcome = .dismissed
    private var isModal = false

    private var loadingRow: NSStackView!
    private var spinner: NSProgressIndicator!
    private var errorLabel: NSTextField!
    private var retryButton: NSButton!
    private var statusLabel: NSTextField!
    private var statusDetailLabel: NSTextField!
    private var manageButton: NSButton!
    private var yearlyButton: NSButton!
    private var yearlyCaption: NSTextField!
    private var lifetimeButton: NSButton!
    private var familyCaption: NSTextField!
    private var termsLabel: NSTextField!
    private var linksRow: NSStackView!
    private var restoreButton: NSButton!
    private var closeButton: NSButton!

    // presentModal(feature, [deadline = nil]): Create and run a
    // feature-specific Pro panel with an optional caller deadline.
    static func presentModal(feature: ProFeature?, deadline: DispatchTime? = nil) -> Outcome {
        let controller = ProPaywallController(feature: feature)
        return controller.runModal(deadline: deadline)
    }

    // init(feature): Build a Pro panel around the feature that requested
    // access.
    private init(feature: ProFeature?) {
        self.feature = feature
        super.init()
        buildWindow()
    }

    // MARK: Modal session

    // runModal(deadline): Close the panel when a Services request reaches its
    // deadline.
    private func runModal(deadline: DispatchTime?) -> Outcome {
        NSApp.activate(ignoringOtherApps: true)
        // Size to the first state before centering so the panel opens in place.
        beginLoading()
        window.center()

        var timeoutWorkItem: DispatchWorkItem?
        // Bound a modal panel by the service request's deadline when one was supplied.
        if let deadline {
            let workItem = DispatchWorkItem { [weak self] in
                // Ignore an expired deadline callback after the panel has already ended.
                guard let self, self.isModal else {
                    return
                }
                self.window.orderOut(nil)
                NSApp.abortModal()
            }
            timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: deadline, execute: workItem)
        }

        isModal = true
        NSApp.runModal(for: window)
        isModal = false
        timeoutWorkItem?.cancel()
        // Hide a still-visible panel after its modal loop returns.
        if window.isVisible {
            window.orderOut(nil)
        }
        return outcome
    }

    // finish(result): Record the modal outcome before closing the Pro window.
    private func finish(_ result: Outcome) {
        outcome = result
        window.close()
    }

    // windowWillClose(notification): Stop the modal session whether the close
    // button or finish() closes the window.
    func windowWillClose(_ notification: Notification) {
        // Stop modal processing only while this controller owns an active modal loop.
        guard isModal else {
            return
        }
        NSApp.stopModal(withCode: outcome == .unlocked ? .OK : .cancel)
    }

    // MARK: Layout

    // buildWindow(): Build the purchase panel, feature list, and action
    // controls.
    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth + 2 * Self.sideInset, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(format: localized("pro_title", "%@ Pro"), appName)
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        let title = NSTextField(labelWithString: String(format: localized("pro_title", "%@ Pro"), appName))
        title.font = NSFont.systemFont(ofSize: 22, weight: .bold)

        let headline = wrappingLabel(reasonText(), size: 13, color: .secondaryLabelColor)

        let features = NSStackView(views: [
            featureRow(symbol: "cloud", text: localized(
                "pro_feature_cloud",
                "OpenAI, Anthropic, Gemini, Grok, DeepSeek, and custom endpoints"
            )),
            featureRow(symbol: "magnifyingglass", text: localized(
                "pro_feature_research",
                "Web research for current facts and sources"
            )),
            featureRow(symbol: "folder", text: localized("pro_feature_folders", "Library folders")),
            featureRow(symbol: "icloud", text: localized("pro_feature_icloud", "iCloud Library sync")),
            featureRow(symbol: "waveform", text: localized("pro_feature_voices", "OpenAI and Grok voices")),
            featureRow(symbol: "waveform.badge.mic", text: "OpenAI audio transcription")
        ])
        features.orientation = .vertical
        features.alignment = .leading
        features.spacing = 8

        let freeNote = wrappingLabel(
            localized("pro_free_note", "Apple Intelligence, Apple voices, and the Library stay free."),
            size: 12,
            color: .secondaryLabelColor
        )

        // Show only the rows needed for the current loading, error, purchase or Pro state.
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        let progressLabel = plainLabel(localized("pro_loading", "Contacting the App Store…"), size: 12, color: .secondaryLabelColor)
        loadingRow = NSStackView(views: [spinner, progressLabel])
        loadingRow.orientation = .horizontal
        loadingRow.spacing = 8

        errorLabel = wrappingLabel("", size: 12, color: .systemRed)
        retryButton = NSButton(title: localized("retry", "Retry"), target: self, action: #selector(retryLoading(_:)))
        retryButton.bezelStyle = .rounded

        statusLabel = wrappingLabel("", size: 13, color: .labelColor)
        statusDetailLabel = wrappingLabel("", size: 12, color: .secondaryLabelColor)
        manageButton = NSButton(
            title: localized("pro_manage_subscription", "Manage Subscription…"),
            target: self,
            action: #selector(manageSubscription(_:))
        )
        manageButton.bezelStyle = .rounded

        yearlyButton = NSButton(title: "", target: self, action: #selector(buyYearly(_:)))
        yearlyButton.bezelStyle = .rounded
        yearlyButton.controlSize = .large
        yearlyButton.keyEquivalent = "\r"
        yearlyCaption = wrappingLabel("", size: 11, color: .secondaryLabelColor)

        lifetimeButton = NSButton(title: "", target: self, action: #selector(buyLifetime(_:)))
        lifetimeButton.bezelStyle = .rounded
        lifetimeButton.controlSize = .large
        familyCaption = wrappingLabel(
            localized("pro_family_caption", "Family Sharing included."),
            size: 11,
            color: .secondaryLabelColor
        )

        termsLabel = wrappingLabel("", size: 11, color: .tertiaryLabelColor)
        linksRow = NSStackView(views: [
            linkButton(localized("pro_terms_of_use", "Terms of Use"), size: 11, action: #selector(openTerms(_:))),
            linkButton(localized("pro_privacy_policy", "Privacy Policy"), size: 11, action: #selector(openPrivacy(_:)))
        ])
        linksRow.orientation = .horizontal
        linksRow.spacing = 16

        let purchaseStack = NSStackView(views: [
            loadingRow, errorLabel, retryButton, statusLabel, statusDetailLabel, manageButton,
            yearlyButton, yearlyCaption, lifetimeButton, familyCaption, termsLabel, linksRow
        ])
        purchaseStack.orientation = .vertical
        purchaseStack.alignment = .leading
        purchaseStack.spacing = 8
        purchaseStack.setCustomSpacing(2, after: statusLabel)
        purchaseStack.setCustomSpacing(14, after: yearlyCaption)
        purchaseStack.setCustomSpacing(14, after: familyCaption)
        purchaseStack.setCustomSpacing(4, after: termsLabel)
        // Apply consistent layout constraints to yearly and lifetime purchase buttons.
        for button in [yearlyButton!, lifetimeButton!] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalTo: purchaseStack.widthAnchor).isActive = true
        }

        restoreButton = linkButton(localized("pro_restore_purchases", "Restore Purchases"), size: 12, action: #selector(restorePurchases(_:)))
        closeButton = NSButton(title: localized("not_now", "Not Now"), target: self, action: #selector(dismiss(_:)))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        // Keep the native-sized close button pinned to the content edge even when Restore is hidden.
        let footer = NSView()
        // Align restore and close actions in the panel footer.
        for button in [restoreButton!, closeButton!] {
            button.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(button)
        }
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            closeButton.topAnchor.constraint(equalTo: footer.topAnchor),
            closeButton.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            restoreButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            restoreButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            restoreButton.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12)
        ])

        content = NSStackView(views: [title, headline, features, freeNote, purchaseStack, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.setCustomSpacing(6, after: title)
        content.setCustomSpacing(18, after: freeNote)
        content.setCustomSpacing(18, after: purchaseStack)
        content.edgeInsets = NSEdgeInsets(top: 22, left: Self.sideInset, bottom: 24, right: Self.sideInset)
        content.translatesAutoresizingMaskIntoConstraints = false
        // Constrain the purchase content and footer within the same panel margins.
        for view in [purchaseStack, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        }

        // Install the shared window background and content area below the title bar.
        let contentView = installNativeContent(in: window)
        contentView.addSubview(content)
        // Pin the top and sides; fit the window height to the visible rows.
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.contentWidth + 2 * Self.sideInset)
        ])
    }

    // fitWindow(animate): Resize to the visible rows while keeping the top edge
    // fixed.
    private func fitWindow(animate: Bool) {
        content.layoutSubtreeIfNeeded()
        let size = nativeContentSize(content.fittingSize, in: window)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let current = window.frame
        frame.origin = NSPoint(x: current.minX, y: current.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }

    // reasonText(): Explain which requested feature needs Pro, or show the
    // general introduction.
    private func reasonText() -> String {
        // Explain the feature that caused the Pro panel to open.
        switch feature {
        // Explain that remote text models require Pro access.
        case .cloudModels:
            return String(format: localized("pro_reason_cloud", "Cloud models are part of %@ Pro."), appName)
        // Explain that Library folder management requires Pro access.
        case .libraryFolders:
            return String(format: localized("pro_reason_folders", "Library folders are part of %@ Pro."), appName)
        // Explain that cross-device Library sync requires Pro access.
        case .librarySync:
            return String(format: localized("pro_reason_icloud", "iCloud Library sync is part of %@ Pro."), appName)
        // Explain that remote narration voices require Pro access.
        case .cloudVoices:
            return String(format: localized("pro_reason_voices", "OpenAI and Grok voices are part of %@ Pro."), appName)
        // Explain the purchase requirement before a recording can be uploaded.
        case .cloudTranscription:
            return "OpenAI audio transcription is part of \(appName) Pro. Apple transcription stays free."
        // Use a general introduction when no particular feature requested the panel.
        case nil:
            return String(format: localized("pro_reason_general", "Get more with %@ Pro."), appName)
        }
    }

    // featureRow(symbol, text): Align a Pro feature's symbol and description in
    // a compact row.
    private func featureRow(symbol: String, text: String) -> NSView {
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        image.contentTintColor = .controlAccentColor
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let label = wrappingLabel(text, size: 13, color: .labelColor, maxWidth: Self.contentWidth - 28)
        let row = NSStackView(views: [image, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    // plainLabel(text, size, color): Create a nonwrapping Pro-panel label with
    // the requested size and color.
    private func plainLabel(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size)
        label.textColor = color
        return label
    }

    // wrappingLabel(text, size, color, [maxWidth]): Create wrapping Pro-panel
    // text with its required typography and layout width.
    private func wrappingLabel(
        _ text: String,
        size: CGFloat,
        color: NSColor,
        maxWidth: CGFloat = ProPaywallController.contentWidth
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: size)
        label.textColor = color
        label.preferredMaxLayoutWidth = maxWidth
        return label
    }

    // linkButton(title, size, action): Create a borderless, link-styled button
    // for the panel's supporting actions.
    private func linkButton(_ title: String, size: CGFloat, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.linkColor,
            .font: NSFont.systemFont(ofSize: size)
        ])
        return button
    }

    // MARK: States

    // beginLoading(): Load products and refresh the panel after checking
    // purchase status.
    private func beginLoading() {
        // Show current Pro status instead of purchase choices for an already entitled user.
        if ProStore.shared.isPro {
            showProStatus()
            return
        }
        showLoading()
        Task { @MainActor [weak self] in
            // Load product information before showing prices or purchase actions.
            do {
                try await ProStore.shared.loadProducts()
                self?.showProducts()
            } catch {
                // Show product-loading failures in the recoverable error view.
                self?.showError(error.localizedDescription)
            }
        }
    }

    // setRows([loading = false], [error = false], [products = false], [status =
    // false]): Show the requested panel sections and keep spinner activity
    // consistent with loading state.
    private func setRows(loading: Bool = false, error: Bool = false, products: Bool = false, status: Bool = false) {
        loadingRow.isHidden = !loading
        // Animate the loading indicator while the loading row is active.
        if loading {
            spinner.startAnimation(nil)
        } else {
            // Stop the indicator when leaving the loading state.
            spinner.stopAnimation(nil)
        }
        errorLabel.isHidden = !error
        retryButton.isHidden = !error
        statusLabel.isHidden = !status
        statusDetailLabel.isHidden = !status
        manageButton.isHidden = !status
        // Show purchase details together so hidden products do not leave orphaned captions or links.
        for view in [yearlyButton, yearlyCaption, lifetimeButton, familyCaption, termsLabel, linksRow] as [NSView] {
            view.isHidden = !products
        }
        fitWindow(animate: true)
    }

    // showLoading(): Switch the panel to its product-loading state.
    private func showLoading() {
        setRows(loading: true)
    }

    // showError(message): Show a recoverable store error using the panel's
    // error row.
    private func showError(_ message: String) {
        errorLabel.stringValue = message
        setRows(error: true)
    }

    // showProducts(): Offer yearly and lifetime plans without starting another trial.
    private func showProducts() {
        let store = ProStore.shared
        let terms = localized(
            "pro_terms",
            "Payment goes to your Apple Account. A subscription renews automatically each year unless it is cancelled in your App Store settings at least a day before the period ends."
        )
        // Populate yearly pricing only when StoreKit returned the yearly product.
        if let yearly = store.yearly {
            yearlyButton.title = String(
                format: localized("pro_yearly_button", "Subscribe for %@ a year"),
                yearly.displayPrice
            )
            yearlyCaption.stringValue = localized(
                "pro_yearly_caption",
                "Renews automatically each year · cancel anytime"
            )
        }
        // Populate lifetime pricing only when StoreKit returned the lifetime product.
        if let lifetime = store.lifetime {
            lifetimeButton.title = String(format: localized("pro_lifetime_button", "Buy once for %@"), lifetime.displayPrice)
        }
        termsLabel.stringValue = terms
        setRows(products: true)
        yearlyButton.isHidden = store.yearly == nil
        yearlyCaption.isHidden = store.yearly == nil
        lifetimeButton.isHidden = store.lifetime == nil
        familyCaption.isHidden = !((store.yearly?.isFamilyShareable ?? false) || (store.lifetime?.isFamilyShareable ?? false))
        setBusy(false)
        fitWindow(animate: true)
    }

    // showProStatus(): Show Pro status and subscription management for an owned
    // subscription.
    private func showProStatus() {
        let store = ProStore.shared
        statusLabel.stringValue = String(format: localized("pro_you_have", "You have %@ Pro."), appName)
        statusDetailLabel.stringValue = store.statusText()
        setRows(status: true)
        manageButton.isHidden = !(store.entitlement.kind == .subscription && !store.entitlement.isFamilyShared)
        restoreButton.isHidden = true
        closeButton.title = localized("ok", "OK")
        // Make OK the primary action once Pro is unlocked, while retaining Escape to dismiss.
        window.defaultButtonCell = closeButton.cell as? NSButtonCell
        fitWindow(animate: true)
    }

    // setBusy(busy): Disable competing purchase actions while an operation is
    // running.
    private func setBusy(_ busy: Bool) {
        // Prevent competing clicks during purchase or restore operations.
        for button in [yearlyButton, lifetimeButton, retryButton, restoreButton, closeButton] as [NSButton] {
            button.isEnabled = !busy
        }
        // Let the caller choose the spinner's visibility when idle.
        if busy {
            loadingRow.isHidden = false
            spinner.startAnimation(nil)
        } else {
            // Stop the busy indicator when an operation finishes.
            spinner.stopAnimation(nil)
        }
        fitWindow(animate: true)
    }

    // MARK: Actions

    // retryLoading(sender): Restart product loading after a recoverable
    // failure.
    @objc private func retryLoading(_ sender: Any?) {
        beginLoading()
    }

    // buyYearly(sender): Start the yearly purchase only after its StoreKit
    // product has loaded.
    @objc private func buyYearly(_ sender: Any?) {
        // Ignore a yearly purchase action before its product has loaded.
        guard let product = ProStore.shared.yearly else {
            return
        }
        purchase(product)
    }

    // buyLifetime(sender): Start the lifetime purchase only after its StoreKit
    // product has loaded.
    @objc private func buyLifetime(_ sender: Any?) {
        // Ignore a lifetime purchase action before its product has loaded.
        guard let product = ProStore.shared.lifetime else {
            return
        }
        purchase(product)
    }

    // purchase(product): Run a purchase on the main actor and reflect its
    // unlocked, pending, cancelled, or failed outcome.
    private func purchase(_ product: Product) {
        setBusy(true)
        Task { @MainActor [weak self] in
            // Stop the purchase UI task if its controller was released.
            guard let self else {
                return
            }
            do {
                // Update the panel according to the purchase's actual outcome.
                switch try await ProStore.shared.purchase(product, confirmIn: self.window) {
                // Close with unlocked access after verified purchase completion.
                case .unlocked:
                    self.finish(.unlocked)
                // Explain the pending purchase without claiming access was granted.
                case .pending:
                    presentProAlert(
                        title: localized("pro_pending_title", "Purchase pending"),
                        body: String(format: localized(
                            "pro_pending_body",
                            "This purchase is still pending. %@ Pro unlocks when the App Store confirms it."
                        ), appName)
                    )
                    self.finish(.dismissed)
                // Restore enabled controls after the user cancels the system purchase sheet.
                case .cancelled:
                    self.setBusy(false)
                    self.loadingRow.isHidden = true
                    self.fitWindow(animate: true)
                }
            } catch {
                // Restore controls and report a failed purchase.
                self.setBusy(false)
                self.loadingRow.isHidden = true
                self.errorLabel.stringValue = String(
                    format: localized("pro_purchase_failed", "The purchase didn't complete: %@"),
                    error.localizedDescription
                )
                self.errorLabel.isHidden = false
                self.fitWindow(animate: true)
            }
        }
    }

    // restorePurchases(sender): Restore purchases and report whether verified
    // Pro access was recovered.
    @objc private func restorePurchases(_ sender: Any?) {
        setBusy(true)
        Task { @MainActor [weak self] in
            // Stop the restore UI task if its controller was released.
            guard let self else {
                return
            }
            do {
                // Close with unlocked access when verified restoration succeeds.
                if try await ProStore.shared.restore() {
                    self.finish(.unlocked)
                } else {
                    // Restore controls and explain that no purchase was found.
                    self.setBusy(false)
                    self.loadingRow.isHidden = true
                    self.fitWindow(animate: true)
                    presentNothingToRestoreAlert()
                }
            } catch {
                // Restore controls and report a failed restoration attempt.
                self.setBusy(false)
                self.loadingRow.isHidden = true
                self.errorLabel.stringValue = error.localizedDescription
                self.errorLabel.isHidden = false
                self.fitWindow(animate: true)
            }
        }
    }

    // manageSubscription(sender): Open Apple's subscription-management page
    // from the Pro panel.
    @objc private func manageSubscription(_ sender: Any?) {
        NSWorkspace.shared.open(ProStore.manageSubscriptionsURL)
    }

    // openTerms(sender): Open the terms of use from the Pro panel.
    @objc private func openTerms(_ sender: Any?) {
        NSWorkspace.shared.open(ProStore.termsOfUseURL)
    }

    // openPrivacy(sender): Open the bundled privacy policy in Langmin's own
    // panel.
    @objc private func openPrivacy(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showPrivacyPolicy(nil)
    }

    // dismiss(sender): Close the Pro panel with a dismissed outcome.
    @objc private func dismiss(_ sender: Any?) {
        finish(.dismissed)
    }
}
