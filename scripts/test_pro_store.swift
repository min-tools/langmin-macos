import Cocoa

// Keep trial state in memory so repeat launches can be tested without changing preferences.
final class TrialPreferences {
    static let shared = TrialPreferences()
    var values: [String: Any] = [:]
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

// The real footer's visibility is tested; purchase and restore dialogs stay inactive.
enum ProPaywallController {
    static func presentModal(feature: String?) -> Bool { false }
}
func presentNothingToRestoreAlert() {}
func presentProAlert(title: String, body: String, style: NSAlert.Style) {}

// Capture diagnostic messages without writing the test's fixtures to system logs.
struct Logger {
    private static let lock = NSLock()
    private static var recorded: [String] = []
    // Snapshot or reset captured messages while storefront tasks may be logging.
    static var messages: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            recorded = newValue
        }
    }
    init(subsystem: String, category: String) {}
    // Serialize appends as OSLog does for concurrent production calls.
    func notice(_ message: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        Self.recorded.append(message)
    }
}
// Simulate an available or missing storefront without accessing an Apple account.
struct Storefront {
    var countryCode: String
    var id: String
    static var fixture: Storefront? = Storefront(countryCode: "SRB", id: "fixture")
    static var current: Storefront? { get async { fixture } }
}
// Preserve Swift-wrapped causes independently of NSError's underlying error key.
enum StoreKitError: Error {
    case networkError(URLError), systemError(Error), unknown
}

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
    static var suspend = false
    static var pending: CheckedContinuation<Void, Never>?
    // shared: Return the configured signed-app result without contacting Apple.
    static var shared: VerificationResult<AppTransaction> {
        get async throws {
            reads += 1
            // Hold the signed lookup open to inspect the banner during setup completion.
            if suspend { await withCheckedContinuation { pending = $0 } }
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
    static var returnedIDs: [String]?
    static var requestError: Error?
    static var requestedIDs: [String] = []
    static var blockProducts = false
    static var productRequests = 0, purchaseRequests = 0
    static var pendingProducts: CheckedContinuation<Void, Never>?
    // products(ids): Return fixture products, optionally suspending lookup to
    // test stale responses.
    static func products(for ids: [String]) async throws -> [Product] {
        productRequests += 1
        requestedIDs = ids
        // Hold this lookup until the test explicitly resumes its continuation.
        if blockProducts { await withCheckedContinuation { pendingProducts = $0 } }
        if let requestError { throw requestError }
        return (returnedIDs ?? ids).map { Product(id: $0) }
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
        UserDefaults.standard.removeObject(forKey: ProStore.appTrialStartedAtKey)
        UserDefaults.standard.removeObject(forKey: ProStore.appTrialDisclosureAcceptedKey)
        let store = ProStore.shared
        // Public source and App Store builds must both start without Pro access.
        try check(store.developerOverride == nil, "Public builds have no local override")
        defer {
            UserDefaults.standard.removeObject(forKey: ProStore.appTrialStartedAtKey)
            UserDefaults.standard.removeObject(forKey: ProStore.appTrialDisclosureAcceptedKey)
        }
        let disclosedStart = Date(timeIntervalSince1970: 1_800_000_000)
        #if LANGMIN_APP_STORE
        // A completed sandbox lookup must not announce expiry while setup is still open.
        AppTransaction.fixture = .verified(AppTransaction(originalPurchaseDate: .distantPast, environment: .sandbox))
        await store.refreshEntitlement()
        try check(store.appTrialStartedAt == nil && !store.hasPreparedAppTrial,
                  "Sandbox startup waits for setup acceptance")
        try check(!SourcePurchaseFooter.shouldBeVisible, "The real footer stays hidden during setup")

        // Hold the next lookup open after setup closes; the banner must remain hidden.
        AppTransaction.suspend = true
        store.beginAppTrial(now: disclosedStart)
        try await until { AppTransaction.pending != nil }
        try check(!SourcePurchaseFooter.shouldBeVisible, "The real footer waits for the post-setup lookup")
        AppTransaction.suspend = false
        AppTransaction.pending?.resume()
        AppTransaction.pending = nil
        try await until { !store.isTrialWelcomePending }
        try check(store.appTrialStartedAt == disclosedStart && store.isAppTrialActive,
                  "Accepting setup starts the sandbox trial once")
        try check(!SourcePurchaseFooter.shouldBeVisible, "The real footer stays hidden during the trial")

        // Restore the fresh-install scenario for a failed signed lookup.
        store.appTrialStartedAt = nil
        store.isTrialWelcomePending = true
        // A production build ignores a resettable local date when signed app data is unavailable.
        UserDefaults.standard.set(disclosedStart, forKey: ProStore.appTrialStartedAtKey)
        AppTransaction.fixture = .unverified
        store.prepareLocalAppTrial(startIfNeeded: true, now: disclosedStart)
        await store.refreshEntitlement()
        try check(store.appTrialStartedAt == nil, "A failed signed lookup never restores local trial state")
        try check(
            store.hasResolvedAppTrial && !store.hasPreparedAppTrial && !SourcePurchaseFooter.shouldBeVisible,
            "A failed signed lookup does not announce expiry before setup finishes"
        )
        store.beginAppTrial(now: disclosedStart)
        try await until { !store.isTrialWelcomePending }
        try check(store.hasPreparedAppTrial && SourcePurchaseFooter.shouldBeVisible,
                  "Finished setup with failed verification retains the Free tier")

        // Apple's original acquisition date remains authoritative after disclosure.
        let acquisition = disclosedStart.addingTimeInterval(-10 * 86_400)
        AppTransaction.fixture = .verified(AppTransaction(originalPurchaseDate: acquisition))
        store.beginAppTrial(now: disclosedStart)
        try await until { store.appTrialStartedAt == acquisition }
        let readsBeforeRepeat = AppTransaction.reads
        store.beginAppTrial(now: disclosedStart.addingTimeInterval(60))
        try await until { AppTransaction.reads > readsBeforeRepeat }
        try check(store.appTrialStartedAt == acquisition, "Repeated acceptance preserves the signed acquisition date")

        // Returning users no longer see setup; their expired sandbox date must still limit access.
        let expiredDate = Date().addingTimeInterval(-31 * 86_400)
        UserDefaults.standard.set(expiredDate, forKey: ProStore.appTrialStartedAtKey)
        AppTransaction.fixture = .verified(AppTransaction(originalPurchaseDate: .distantPast, environment: .sandbox))
        let returning = ProStore()
        await returning.refreshEntitlement()
        try check(!returning.isTrialWelcomePending && returning.hasPreparedAppTrial && !returning.hasFullAccess,
                  "Returning users resolve expired access without reopening setup")
        store.appTrialStartedAt = expiredDate
        try check(SourcePurchaseFooter.shouldBeVisible, "The real footer appears after actual expiry")
        store.appTrialStartedAt = acquisition
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
        // An active local trial still loads both purchasable products without granting paid access.
        Transaction.fixtures = []
        await store.refreshEntitlement()
        let catalogStore = ProStore()
        UserDefaults.standard.removeObject(forKey: ProStore.appTrialStartedAtKey)
        UserDefaults.standard.removeObject(forKey: ProStore.appTrialDisclosureAcceptedKey)
        AppTransaction.fixture = .verified(AppTransaction(originalPurchaseDate: Date(), environment: .sandbox))
        catalogStore.beginAppTrial()
        await catalogStore.refreshEntitlement()
        Logger.messages = []
        try await catalogStore.loadProducts()
        try check(Product.requestedIDs == ProProductID.all, "Request both exact catalog identifiers")
        try check(catalogStore.yearly?.id == ProProductID.yearly && catalogStore.lifetime?.id == ProProductID.lifetime, "Both returned plans are purchasable during a trial")
        try check(catalogStore.isAppTrialActive && !catalogStore.isPro, "Product lookup does not convert a trial into paid access")
        try await until { Logger.messages.contains { $0.contains("products.storefront") && $0.contains("country=SRB") } }
        try check(Logger.messages.contains { $0.contains("products.request") && $0.contains("version=") && $0.contains("build=") }, "Requests include release metadata")
        try check(Logger.messages.contains { $0.contains("products.response") && $0.contains("count=2") && $0.contains("elapsed_ms=") }, "Successful catalog requests include count and timing")

        // Missing one product must preserve the available purchase option and clear the stale one.
        Product.returnedIDs = [ProProductID.yearly]
        try await catalogStore.loadProducts()
        try check(catalogStore.yearly != nil && catalogStore.lifetime == nil, "Yearly-only responses remain usable")
        try check(Logger.messages.contains { $0.contains("missing=\(ProProductID.lifetime)") }, "Partial responses identify the missing lifetime product")
        Product.returnedIDs = [ProProductID.lifetime]
        try await catalogStore.loadProducts()
        try check(catalogStore.yearly == nil && catalogStore.lifetime != nil, "Lifetime-only responses remain usable")

        // Empty and unrelated responses must fail without manufacturing products or paid access.
        for ids in [[], ["unrelated.product"]] {
            Product.returnedIDs = ids
            let emptyStore = ProStore()
            do {
                try await emptyStore.loadProducts()
                try check(false, "A response without either configured product must fail")
            } catch let error as ProStore.StoreError {
                try check(error.message.contains("purchases are unavailable"), "Unavailable products retain the recoverable message")
            }
            try check(emptyStore.yearly == nil && emptyStore.lifetime == nil && !emptyStore.isPro, "Unavailable catalog never grants access")
        }
        try check(Logger.messages.contains { $0.contains("products.response") && $0.contains("count=0") && $0.contains("missing=\(ProProductID.all.joined(separator: ","))") }, "Empty responses are distinguishable from request errors")

        // Preserve original failures, but exclude descriptions, URLs, and userInfo from logs.
        Logger.messages = []
        let underlying = NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [NSLocalizedDescriptionKey: "private-account-secret"])
        Product.requestError = NSError(domain: "ASDErrorDomain", code: 500, userInfo: [NSUnderlyingErrorKey: underlying, "receipt": "private-receipt-secret"])
        do {
            try await catalogStore.loadProducts()
            try check(false, "Network failure must be propagated")
        } catch {
            try check((error as NSError).domain == "ASDErrorDomain" && (error as NSError).code == 500, "Diagnostics preserve the original error")
        }
        try check(Logger.messages.contains { $0.contains("products.failed") && $0.contains("ASDErrorDomain:500 -> NSURLErrorDomain:-1009") }, "Underlying network codes survive diagnostic logging")
        try check(!Logger.messages.joined().contains("private-"), "Diagnostic logs exclude arbitrary error payloads")
        try check(ProStoreDiagnostics.errorCodes(StoreKitError.networkError(URLError(.timedOut))).contains("NSURLErrorDomain:-1001"), "Swift StoreKit errors retain their wrapped network code")
        try check(ProStoreDiagnostics.errorCodes(StoreKitError.systemError(underlying)).contains("NSURLErrorDomain:-1009"), "Swift system errors retain their wrapped cause")

        // A missing storefront and a previously failed request must not prevent a fresh retry.
        Product.requestError = nil
        Product.returnedIDs = nil
        Storefront.fixture = nil
        Logger.messages = []
        try await catalogStore.loadProducts()
        try check(catalogStore.yearly != nil && catalogStore.lifetime != nil, "Retry recovers both plans after catalog failure")
        try await until { Logger.messages.contains { $0.contains("products.storefront") && $0.contains("country=unknown") } }
        try check(!catalogStore.isPro, "Successful retry still requires a verified purchase for paid access")
        let emptyRestore = try await catalogStore.restore()
        try check(!emptyRestore, "Restore correctly reports no purchase for an unpurchased trial")
        print("\(count) Pro store checks passed")
    }
}
