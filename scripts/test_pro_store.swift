import Cocoa

// langminPreferencesStore(): Only the StoreKit boundary is simulated; the
// compiled ProStore methods are the app's source.
func langminPreferencesStore() -> UserDefaults { fatalError("Unexpected preferences access") }
// localized(key, fallback): Resolve labels through the fixture’s controlled
// localization.
func localized(_ key: String, _ fallback: String) -> String { fallback }
let appName = "Langmin"
// Represent verified and rejected transaction results without StoreKit.
enum VerificationResult<T> { case verified(T), unverified }
// Supply the transaction fields used by the production entitlement reducer.
struct Transaction {
    // Distinguish owned purchases from Family Sharing access.
    enum Ownership { case purchased, familyShared }
    // Distinguish introductory access from regular purchases.
    enum OfferType { case introductory, regular }
    // Attach offer information to a fixture transaction.
    struct Offer { var type: OfferType }
    var productID: String
    var purchaseDate = Date()
    var expirationDate: Date?
    var revocationDate: Date?
    var ownershipType = Ownership.purchased
    var offer: Offer?
    var offerType: OfferType? { offer?.type }
    static var fixtures: [VerificationResult<Transaction>] = []
    static var entitlementReads = 0, updateReads = 0
    // Stream a snapshot of the configured entitlements and count reads.
    static var currentEntitlements: AsyncStream<VerificationResult<Transaction>> {
        entitlementReads += 1
        let snapshot = fixtures
        return AsyncStream { continuation in
            snapshot.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
    // Count transaction-listener requests without producing live updates.
    static var updates: AsyncStream<VerificationResult<Transaction>> {
        updateReads += 1
        return AsyncStream { $0.finish() }
    }
    // finish(): Keep this production dependency inactive in the isolated
    // fixture.
    func finish() async {}
}
// Supply the signed app transaction used to anchor production trials.
struct AppTransaction {
    // Distinguish production receipts from Xcode, TestFlight, and review sandboxes.
    enum Environment { case production, sandbox }
    var originalPurchaseDate: Date
    var bundleID = LangminEdition.bundleIdentifier
    var environment = Environment.production
    static var fixture: VerificationResult<AppTransaction> = .unverified
    static var reads = 0
    // shared: Return the configured signed-app result without contacting Apple.
    static var shared: VerificationResult<AppTransaction> {
        get async throws {
            reads += 1
            return fixture
        }
    }
}
// Simulate products, renewal status, and purchase calls without contacting the store.
struct Product {
    // Supply renewal and eligibility information for subscription fixtures.
    struct SubscriptionInfo {
        // Control the renewal wording associated with a verified subscription.
        struct RenewalInfo { var willAutoRenew = true }
        // Pair a transaction with the renewal information used to describe it.
        struct Status {
            var transaction: VerificationResult<Transaction>
            var renewalInfo = VerificationResult.verified(RenewalInfo())
        }
        static var statuses: [Status]?
        var status: [Status] {
            get async throws {
                Self.statuses ?? Transaction.fixtures.map { Status(transaction: $0) }
            }
        }
        var isEligibleForIntroOffer: Bool { get async { false } }
    }
    // Represent the outcomes handled by the production purchase path.
    enum PurchaseResult { case success(VerificationResult<Transaction>), pending, userCancelled }
    var id: String
    var subscription: SubscriptionInfo? { id == ProProductID.yearly ? SubscriptionInfo() : nil }
    static var blockProducts = false
    static var productRequests = 0, purchaseRequests = 0
    static var pendingProducts: CheckedContinuation<Void, Never>?
    // products(ids): Return fixture products, optionally suspending lookup to
    // test stale responses.
    static func products(for ids: [String]) async throws -> [Product] {
        productRequests += 1
        // Hold this lookup until the test explicitly resumes its continuation.
        if blockProducts { await withCheckedContinuation { pendingProducts = $0 } }
        return ids.map { Product(id: $0) }
    }
    // purchase(options): Count a purchase request and return cancellation
    // without charging anything.
    func purchase(options: Set<String>) async throws -> PurchaseResult {
        Self.purchaseRequests += 1
        return .userCancelled
    }
    // purchase(confirmIn, options): Simulate the window-based purchase API with
    // the same cancelled outcome.
    func purchase(confirmIn: NSWindow, options: Set<String>) async throws -> PurchaseResult {
        Self.purchaseRequests += 1
        return .userCancelled
    }
}
// Record restore requests without contacting the App Store.
enum AppStore {
    static var syncRequests = 0
    // sync(): Count each requested store synchronization.
    static func sync() async throws { syncRequests += 1 }
}

// Run the production store logic against simulated transactions and products.
@main struct Tests {
    // main(): Exercise verified access and renewal races in both public builds.
    @MainActor static func main() async throws {
        var count = 0
        // check(valid, message): Report failed fixture expectations with their
        // case names.
        func check(_ valid: Bool, _ message: String) throws {
            // Stop this fixture when its named expectation does not hold.
            guard valid else { throw NSError(domain: message, code: 1) }
            count += 1
        }
        // until(condition): Wait for asynchronous state changes with a bounded
        // fixture deadline.
        func until(_ condition: () -> Bool) async throws {
            let limit = Date().addingTimeInterval(5)
            // Yield to pending tasks until the condition is met or the deadline expires.
            while !condition(), Date() < limit { try await Task.sleep(nanoseconds: 5_000_000) }
            try check(condition(), "Asynchronous fixture settled")
        }
        let store = ProStore()
        // Public source and App Store builds must both start without Pro access.
        try check(store.developerOverride == nil, "Public builds have no local override")
        UserDefaults.standard.removeObject(forKey: ProStore.appTrialStartedAtKey)
        UserDefaults.standard.removeObject(forKey: ProStore.appTrialDisclosureAcceptedKey)
        defer {
            UserDefaults.standard.removeObject(forKey: ProStore.appTrialStartedAtKey)
            UserDefaults.standard.removeObject(forKey: ProStore.appTrialDisclosureAcceptedKey)
        }
        let disclosedStart = Date(timeIntervalSince1970: 1_800_000_000)
        #if LANGMIN_APP_STORE
        // A production build ignores a resettable local date when signed app data is unavailable.
        UserDefaults.standard.set(disclosedStart, forKey: ProStore.appTrialStartedAtKey)
        AppTransaction.fixture = .unverified
        store.prepareLocalAppTrial(startIfNeeded: true, now: disclosedStart)
        await store.refreshEntitlement()
        try check(store.appTrialStartedAt == nil, "A failed signed lookup never restores local trial state")
        try check(
            store.hasResolvedAppTrial && store.hasPreparedAppTrial,
            "A failed signed lookup resolves the App Store build as Free"
        )

        // Apple's original acquisition date remains authoritative after disclosure.
        let acquisition = disclosedStart.addingTimeInterval(-10 * 86_400)
        AppTransaction.fixture = .verified(AppTransaction(originalPurchaseDate: acquisition))
        store.beginAppTrial(now: disclosedStart)
        try await until { store.appTrialStartedAt == acquisition }
        store.beginAppTrial(now: disclosedStart.addingTimeInterval(60))
        try await until { AppTransaction.reads >= 3 }
        try check(store.appTrialStartedAt == acquisition, "Repeated acceptance preserves the signed acquisition date")
        #else
        store.prepareLocalAppTrial(now: disclosedStart)
        try check(store.appTrialStartedAt == nil, "Store startup does not begin the trial before disclosure")
        try check(!store.hasPreparedAppTrial, "A source build waits for the trial disclosure")
        store.beginAppTrial(now: disclosedStart)
        try check(store.appTrialStartedAt == disclosedStart, "Accepting the disclosure begins the local trial")
        try check(store.hasPreparedAppTrial, "Starting the source trial resolves its access state")
        store.beginAppTrial(now: disclosedStart.addingTimeInterval(60))
        try check(store.appTrialStartedAt == disclosedStart, "Repeated acceptance preserves the local trial date")
        await store.refreshEntitlement()
        #endif
        try check(store.hasResolvedEntitlement, "The first StoreKit lookup resolves launch UI")
        try check(!store.isPro && store.entitlementTimer == nil, "Free accounts have no expiry timer")

        // A slow renewal-label lookup cannot delay the entitlement or restore stale access later.
        Transaction.fixtures = [.verified(Transaction(productID: ProProductID.yearly, expirationDate: Date().addingTimeInterval(3600)))]
        Product.blockProducts = true
        let first = Task { @MainActor in await store.refreshEntitlement() }
        try await until { Product.pendingProducts != nil }
        try check(store.isPro, "Verified access applies before product loading completes")
        try check(store.entitlementTimer != nil, "Expiry refresh is scheduled while product loading is pending")
        Transaction.fixtures = []
        await store.refreshEntitlement()
        try check(!store.isPro, "Expiry applies without waiting for older product lookup")
        Product.blockProducts = false
        Product.pendingProducts?.resume()
        Product.pendingProducts = nil
        await first.value
        try check(!store.isPro && store.entitlementTimer == nil, "A late renewal response cannot restore expired Pro")

        // StoreKit, rather than a wall-clock comparison, decides billing grace access.
        Transaction.fixtures = [.verified(Transaction(productID: ProProductID.yearly, expirationDate: Date().addingTimeInterval(-60)))]
        await store.refreshEntitlement()
        try check(store.isPro, "An entitlement in billing grace still grants Pro")
        try check(store.statusText() == "Pro", "Billing grace does not show a past renewal date as an upcoming payment")
        try check((55...60).contains(store.entitlementTimer!.fireDate.timeIntervalSinceNow), "Grace period is rechecked without a tight retry loop")
        let timer = store.entitlementTimer!
        Transaction.fixtures = []
        timer.fire()
        try await until { !store.isPro }
        try check(store.entitlementTimer == nil, "Timer detects expiry without a transaction update")

        // Restoration grants the same access as purchase, including lifetime and Family Sharing.
        var lifetime = Transaction(productID: ProProductID.lifetime)
        lifetime.ownershipType = .familyShared
        Transaction.fixtures = [.verified(lifetime)]
        let restored = try await store.restore()
        try check(restored && store.entitlement.isFamilyShared, "Restore recognizes a shared lifetime purchase")
        try check(store.entitlementTimer == nil, "Lifetime access needs no subscription expiry timer")
        lifetime.revocationDate = Date()
        Transaction.fixtures = [.verified(lifetime), .unverified]
        await store.refreshEntitlement()
        try check(!store.isPro, "Revoked and unverified purchases do not provide access")

        // Repeated refreshes do not publish duplicate access changes just to reload renewal text.
        Transaction.fixtures = [.verified(Transaction(productID: ProProductID.yearly, expirationDate: Date().addingTimeInterval(3600)))]
        await store.refreshEntitlement()
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: ProStore.entitlementDidChange, object: nil, queue: .main) { _ in notifications += 1 }
        // Remove the temporary observer when the fixture completes.
        defer { NotificationCenter.default.removeObserver(observer) }
        await store.refreshEntitlement()
        try check(notifications == 0, "Unchanged renewal status does not churn sync observers")
        try check((0...60).contains(store.entitlementTimer!.fireDate.timeIntervalSinceNow), "An open app rechecks subscription access at least every minute")

        // A family or expired status can precede the owned subscription in StoreKit's response.
        let owned = Transaction(productID: ProProductID.yearly, expirationDate: Date().addingTimeInterval(7200))
        var shared = owned
        shared.ownershipType = .familyShared
        var expired = owned
        expired.expirationDate = Date().addingTimeInterval(-3600)
        Transaction.fixtures = [.verified(shared), .verified(owned)]
        Product.SubscriptionInfo.statuses = [
            .init(transaction: .verified(shared)),
            .init(transaction: .verified(expired)),
            .init(transaction: .verified(owned), renewalInfo: .verified(.init(willAutoRenew: false)))
        ]
        await store.refreshEntitlement()
        try check(!store.entitlement.isFamilyShared, "An owned purchase takes priority over shared access")
        try check(store.entitlement.willAutoRenew == false, "Renewal wording uses the matching owned purchase")

        // Unverified or unrelated status data cannot claim that the selected purchase will renew.
        Product.SubscriptionInfo.statuses = [
            .init(transaction: .unverified),
            .init(transaction: .verified(shared)),
            .init(transaction: .verified(owned), renewalInfo: .unverified)
        ]
        await store.refreshEntitlement()
        try check(store.entitlement.willAutoRenew == nil, "Missing verified renewal information uses neutral wording")

        Transaction.fixtures = [.verified(shared)]
        Product.SubscriptionInfo.statuses = [.init(transaction: .verified(shared))]
        await store.refreshEntitlement()
        try check(store.entitlement.isFamilyShared && store.entitlement.willAutoRenew == true, "Shared access matches its own verified status")
        print("\(count) Pro store checks passed")
    }
}
