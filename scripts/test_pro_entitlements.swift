import Foundation

// expect(actual, expected, name): Compare entitlement decisions with their
// expected value and case name.
private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    // Stop on the first entitlement or status mismatch.
    guard actual == expected else {
        fputs("FAIL \(name)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
}

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let nextMonth = now.addingTimeInterval(30 * 86_400)
private let nextYear = now.addingTimeInterval(365 * 86_400)

// transaction(productID, [expires = nil], [revoked = false], [family = false],
// [intro = false]): Construct a transaction snapshot with explicit ownership
// and validity fields.
private func transaction(
    _ productID: String,
    expires: Date? = nil,
    revoked: Bool = false,
    family: Bool = false,
    intro: Bool = false
) -> ProTransactionSummary {
    ProTransactionSummary(
        productID: productID,
        purchaseDate: now,
        expirationDate: expires,
        revocationDate: revoked ? now : nil,
        isFamilyShared: family,
        isIntroductoryOffer: intro
    )
}

// subscription([expires = nextYear], [trial = false], [family = false], [renews
// = nil]): Construct a yearly subscription fixture around the fixed test clock.
private func subscription(
    expires: Date? = nextYear,
    trial: Bool = false,
    family: Bool = false,
    renews: Bool? = nil
) -> ProEntitlement {
    ProEntitlement(
        kind: .subscription,
        expirationDate: expires,
        isTrial: trial,
        isFamilyShared: family,
        willAutoRenew: renews
    )
}

@main
// Run entitlement selection and status-label rules without StoreKit access.
private struct ProEntitlementTests {
    // main(): Exercise purchase evaluation separately from status presentation.
    static func main() {
        accessPolicyTests()
        evaluationTests()
        statusTests()
        print("ProEntitlementLogic: all tests passed")
    }

    // accessPolicyTests(): Check the independent first-launch trial boundary.
    static func accessPolicyTests() {
        expect(
            LangminFreeAccessPolicy.isTrialActive(
                startedAt: now,
                now: now.addingTimeInterval(29 * 86_400)
            ),
            true,
            "the local trial remains active through day 29"
        )
        expect(
            LangminFreeAccessPolicy.isTrialActive(
                startedAt: now,
                now: now.addingTimeInterval(30 * 86_400)
            ),
            false,
            "the local trial expires at 30 days"
        )
        expect(
            LangminFreeAccessPolicy.trialDaysRemaining(startedAt: now, now: now),
            30,
            "a new local trial reports 30 days"
        )
        let localStart = now.addingTimeInterval(86_400)
        expect(
            LangminFreeAccessPolicy.authoritativeTrialStartDate(
                appStoreOriginalPurchaseDate: now,
                localStartedAt: localStart,
                usesAppStoreDate: true
            ),
            now,
            "the signed App Store date overrides local state"
        )
        expect(
            LangminFreeAccessPolicy.authoritativeTrialStartDate(
                appStoreOriginalPurchaseDate: nil,
                localStartedAt: localStart,
                usesAppStoreDate: true
            ),
            nil,
            "a missing signed date never falls back to local state"
        )
        expect(
            LangminFreeAccessPolicy.authoritativeTrialStartDate(
                appStoreOriginalPurchaseDate: nil,
                localStartedAt: localStart,
                usesAppStoreDate: false
            ),
            localStart,
            "source builds retain their local trial date"
        )
    }

    // evaluationTests(): Check which verified transaction grants access across
    // expiry and ownership cases.
    static func evaluationTests() {
        expect(ProEntitlementLogic.evaluate([]), .free, "no transactions is free")
        expect(
            ProEntitlementLogic.evaluate([transaction("com.example.other")]),
            .free,
            "a foreign product id is ignored"
        )
        expect(
            ProEntitlementLogic.evaluate([transaction(ProProductID.lifetime)]),
            ProEntitlement(kind: .lifetime),
            "lifetime unlocks without an expiration"
        )
        expect(
            ProEntitlementLogic.evaluate([transaction(ProProductID.lifetime, revoked: true)]),
            .free,
            "a revoked lifetime is free"
        )
        expect(
            ProEntitlementLogic.evaluate([transaction(ProProductID.yearly, expires: nextMonth, intro: true)]),
            subscription(expires: nextMonth, trial: true),
            "an introductory-offer subscription is a trial"
        )
        expect(
            ProEntitlementLogic.evaluate([
                transaction(ProProductID.yearly, expires: nextYear),
                transaction(ProProductID.lifetime)
            ]).kind,
            .lifetime,
            "lifetime beats a subscription"
        )
        expect(
            ProEntitlementLogic.evaluate([transaction(ProProductID.lifetime, family: true)]).isFamilyShared,
            true,
            "a family-shared lifetime is flagged"
        )
        expect(
            ProEntitlementLogic.evaluate([
                transaction(ProProductID.yearly, expires: nextYear, family: true),
                transaction(ProProductID.yearly, expires: nextMonth)
            ]),
            subscription(expires: nextMonth),
            "an owned subscription beats a family-shared one even when shorter"
        )
        expect(
            ProEntitlementLogic.evaluate([
                transaction(ProProductID.yearly, expires: nextMonth),
                transaction(ProProductID.yearly, expires: nextYear)
            ]).expirationDate,
            nextYear,
            "among equals the latest expiration wins"
        )
        expect(
            ProEntitlementLogic.evaluate([
                transaction(ProProductID.lifetime, family: true),
                transaction(ProProductID.lifetime)
            ]).isFamilyShared,
            false,
            "an owned lifetime beats a family-shared one"
        )
        expect(
            ProEntitlementLogic.evaluate([transaction(ProProductID.yearly, expires: nextYear)]).willAutoRenew,
            nil,
            "renewal status is unknown until fetched"
        )
    }

    // status(entitlement): Evaluate status against the fixture's fixed time.
    static func status(for entitlement: ProEntitlement) -> ProStatusKind {
        ProEntitlementLogic.statusKind(for: entitlement, now: now)
    }

    // statusTests(): Check trial, renewal, lifetime, and unknown-status
    // presentation.
    static func statusTests() {
        expect(status(for: .free), .free, "free status")
        expect(status(for: ProEntitlement(kind: .lifetime)), .lifetime, "lifetime status")
        expect(
            status(for: ProEntitlement(kind: .lifetime, isFamilyShared: true)),
            .familyShared,
            "family-shared lifetime status"
        )
        expect(
            status(for: subscription(family: true, renews: true)),
            .familyShared,
            "family-shared subscription hides renewal details"
        )
        expect(
            status(for: subscription(expires: nextMonth, trial: true, renews: true)),
            .trialRenews(nextMonth),
            "renewing trial announces the first payment"
        )
        expect(
            status(for: subscription(expires: nextMonth, trial: true, renews: false)),
            .trialEnds(nextMonth),
            "cancelled trial ends"
        )
        expect(
            status(for: subscription(expires: nextMonth, trial: true)),
            .trialUntil(nextMonth),
            "trial with unknown renewal is neutral"
        )
        expect(
            status(for: subscription(renews: true)),
            .renews(nextYear),
            "renewing subscription"
        )
        expect(
            status(for: subscription(renews: false)),
            .ends(nextYear),
            "cancelled subscription ends"
        )
        expect(
            status(for: subscription()),
            .activeUntil(nextYear),
            "subscription with unknown renewal is neutral"
        )
        expect(
            status(for: subscription(expires: now.addingTimeInterval(-60), renews: true)),
            .active,
            "billing grace does not announce a renewal date in the past"
        )
        expect(
            status(for: subscription(expires: now, trial: true, renews: false)),
            .active,
            "access retained by StoreKit does not claim the trial will end in the past"
        )
        expect(
            status(for: subscription(expires: nil)),
            .active,
            "subscription without an expiration is simply active"
        )
    }
}
