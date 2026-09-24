import Foundation

// Product IDs must match App Store Connect. Configure Family Sharing there, but not a StoreKit trial.
enum ProProductID {
    static let yearly = "tools.min.langmin.pro.yearly"
    static let lifetime = "tools.min.langmin.pro.lifetime"
    static let all = [yearly, lifetime]
}

// The app grants 30 days of full access without starting a subscription.
enum LangminFreeAccessPolicy {
    static let trialLengthDays = 30
    static let trialDuration = TimeInterval(trialLengthDays * 24 * 60 * 60)

    // authoritativeTrialStartDate(appStoreOriginalPurchaseDate,
    // localStartedAt, usesAppStoreDate): Never fall back to resettable local
    // state when a production App Store build requires Apple's signed date.
    static func authoritativeTrialStartDate(
        appStoreOriginalPurchaseDate: Date?,
        localStartedAt: Date?,
        usesAppStoreDate: Bool
    ) -> Date? {
        usesAppStoreDate ? appStoreOriginalPurchaseDate : localStartedAt
    }

    // isTrialActive(startedAt, [now]): Return whether the full-access period remains active.
    static func isTrialActive(startedAt: Date, now: Date = Date()) -> Bool {
        now < startedAt.addingTimeInterval(trialDuration)
    }

    // trialDaysRemaining(startedAt, [now]): Round a partial remaining day up for status text.
    static func trialDaysRemaining(startedAt: Date, now: Date = Date()) -> Int {
        let seconds = startedAt.addingTimeInterval(trialDuration).timeIntervalSince(now)
        return max(0, Int(ceil(seconds / (24 * 60 * 60))))
    }
}

// Transaction fields needed to evaluate Pro access without StoreKit in unit tests.
struct ProTransactionSummary: Equatable {
    var productID: String
    var purchaseDate: Date
    var expirationDate: Date?
    var revocationDate: Date?
    var isFamilyShared: Bool
    var isIntroductoryOffer: Bool
}

// The evaluated Pro state every gate consults and Settings displays.
struct ProEntitlement: Equatable {
    // Represent no access, lifetime access, and subscription access without StoreKit dependencies.
    enum Kind: Equatable {
        // Represent the absence of verified Pro access.
        case none
        // Represent a verified lifetime purchase.
        case lifetime
        // Represent a verified subscription entitlement.
        case subscription
    }

    var kind: Kind = .none
    var expirationDate: Date?
    var isTrial = false
    var isFamilyShared = false
    // Subscriptions only; nil until the renewal status has been fetched.
    var willAutoRenew: Bool?

    var isPro: Bool { kind != .none }

    static let free = ProEntitlement()
}

// How Settings and the Pro panel describe the entitlement in one line.
enum ProStatusKind: Equatable {
    // Display no Pro access.
    case free
    // Display active access without asserting a renewal date.
    case active
    // Display a personally owned lifetime purchase.
    case lifetime
    // Display access shared by a family member.
    case familyShared
    // Display a trial with verified future renewal.
    case trialRenews(Date)
    // Display a trial with verified cancellation of renewal.
    case trialEnds(Date)
    // Display trial coverage when renewal state is unknown.
    case trialUntil(Date)
    // Display a paid subscription known to renew.
    case renews(Date)
    // Display a paid subscription known to end without renewal.
    case ends(Date)
    // Display paid coverage without guessing renewal state.
    case activeUntil(Date)
}

// Evaluate verified transaction summaries and derive accurate entitlement status labels.
enum ProEntitlementLogic {
    // evaluate(transactions): Trust StoreKit's current-entitlement list for
    // expiry and grace periods. Ignore revoked and unknown products. Prefer
    // lifetime, then owned purchases, then later expiry.
    static func evaluate(_ transactions: [ProTransactionSummary]) -> ProEntitlement {
        let live = transactions.filter {
            $0.revocationDate == nil && ProProductID.all.contains($0.productID)
        }
        // Prefer lifetime access over subscription access when both are currently entitled.
        if let lifetime = preferred(live.filter { $0.productID == ProProductID.lifetime }) {
            return ProEntitlement(kind: .lifetime, isFamilyShared: lifetime.isFamilyShared)
        }
        // Return free access when no supported subscription or lifetime entitlement remains.
        // Fall back to free access when no live yearly subscription remains.
        guard let subscription = preferred(live.filter { $0.productID == ProProductID.yearly }) else {
            return .free
        }
        return ProEntitlement(
            kind: .subscription,
            expirationDate: subscription.expirationDate,
            isTrial: subscription.isIntroductoryOffer,
            isFamilyShared: subscription.isFamilyShared
        )
    }

    // preferred(candidates): Owned before family-shared, then the one that
    // lasts longest.
    private static func preferred(_ candidates: [ProTransactionSummary]) -> ProTransactionSummary? {
        candidates.max { first, second in
            // Prefer a personally owned purchase over family-shared access of the same kind.
            if first.isFamilyShared != second.isFamilyShared {
                return first.isFamilyShared
            }
            return (first.expirationDate ?? .distantFuture) < (second.expirationDate ?? .distantFuture)
        }
    }

    // statusKind(entitlement, [now = Date()]): Use renewal status to
    // distinguish a trial's first payment from its end date. Use neutral
    // wording while renewal status is unknown; apply the same rule to paid
    // plans.
    static func statusKind(for entitlement: ProEntitlement, now: Date = Date()) -> ProStatusKind {
        // Choose the broad status from the verified access kind first.
        switch entitlement.kind {
        // No entitlement produces a free status.
        case .none:
            return .free
        // Distinguish family-shared lifetime access from a personally owned purchase.
        case .lifetime:
            return entitlement.isFamilyShared ? .familyShared : .lifetime
        // Subscription wording depends on ownership, dates, and known renewal state.
        case .subscription:
            // Avoid exposing billing claims for a subscription owned by a family member.
            if entitlement.isFamilyShared {
                return .familyShared
            }
            // StoreKit can keep access active during billing grace. A past expiry
            // is not a future renewal or end date, so keep the status neutral.
            guard let date = entitlement.expirationDate, date > now else {
                return .active
            }
            // Combine trial status with verified, disabled, or unknown auto-renewal.
            switch (entitlement.isTrial, entitlement.willAutoRenew) {
            // The trial is known to convert to a paid subscription on its coverage date.
            case (true, .some(true)):
                return .trialRenews(date)
            // The trial is known to end without renewal.
            case (true, .some(false)):
                return .trialEnds(date)
            // The trial's coverage date is known but its renewal state is not.
            case (true, .none):
                return .trialUntil(date)
            // The paid subscription is known to renew.
            case (false, .some(true)):
                return .renews(date)
            // The paid subscription is known not to renew.
            case (false, .some(false)):
                return .ends(date)
            // Show only the known paid-coverage date when renewal state is unavailable.
            case (false, .none):
                return .activeUntil(date)
            }
        }
    }
}
