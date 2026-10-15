import Foundation
import StoreKit

// App identity is the same for local builds and App Store releases.
enum LangminEdition {
    static let bundleIdentifier = "tools.min.langmin"
    static let urlScheme = "langmin"

    #if LANGMIN_APP_STORE
    // Production App Store builds use the signed app acquisition date.
    static let isAppStoreBuild = true
    #else
    // Source and private builds retain the disclosed local trial.
    static let isAppStoreBuild = false
    #endif

    // A private build input may supply local access. Public builds verify purchases.
    #if LANGMIN_LOCAL_BUILD && LANGMIN_APP_STORE
    #error("Local access must not be included in an App Store build.")
    #elseif LANGMIN_LOCAL_BUILD && LANGMIN_EXPIRED_TRIAL_BUILD
    // Preview the public post-trial state without granting local Pro access.
    static let localProAccess: Bool? = nil
    static let localAccessStatus: String? = nil
    static let forcedTrialStartedAt: Date? = LangminLocalAccess.expiredTrialStartedAt
    static let isExpiredTrialPreview = true
    #elseif LANGMIN_LOCAL_BUILD
    static let localProAccess: Bool? = LangminLocalAccess.isPro
    static let localAccessStatus: String? = LangminLocalAccess.status
    static let forcedTrialStartedAt: Date? = nil
    static let isExpiredTrialPreview = false
    #else
    // Neither Debug nor Release grants Pro without a verified entitlement.
    static let localProAccess: Bool? = nil
    static let localAccessStatus: String? = nil
    static let forcedTrialStartedAt: Date? = nil
    static let isExpiredTrialPreview = false
    #endif
}

// Check whether the App Store storefront allows the built-in OpenAI
// integrations. Local builds allow OpenAI unless compiled as the China preview.
enum OpenAIAvailability {
    private static let lock = NSLock()
    private static var resolvedValue = !LangminEdition.isAppStoreBuild

    // isAvailable: Read the launch-time storefront decision from any request
    // path without introducing actor requirements into transport code.
    static var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolvedValue
    }

    // setResolvedValue(available): Update the shared result from synchronous
    // lock code after the asynchronous StoreKit lookup finishes.
    private static func setResolvedValue(_ available: Bool) {
        lock.lock()
        resolvedValue = available
        lock.unlock()
    }

    // resolveAtLaunch(): Read the storefront once before provider-dependent UI
    // is built. The preview flag supplies the China decision without changing
    // the developer's App Store account.
    static func resolveAtLaunch() async {
        let available: Bool
        #if LANGMIN_CHINA_PREVIEW
        // Force the restricted interface for local visual inspection.
        available = false
        #else
        // App Store builds use the customer's current storefront.
        if LangminEdition.isAppStoreBuild {
            let storefront = await Storefront.current
            available = storefront?.countryCode != "CHN"
        } else {
            // Developer and unlocked builds keep every provider available.
            available = true
        }
        #endif

        setResolvedValue(available)
    }

    // requireAvailable(): Reject an OpenAI request when the launch-time
    // storefront decision excludes that provider.
    static func requireAvailable() throws {
        // Fail before callers read credentials or create network requests.
        guard isAvailable else {
            throw NSError(
                domain: "tools.min.langmin.openai-availability",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI is unavailable in the China mainland storefront."]
            )
        }
    }
}
