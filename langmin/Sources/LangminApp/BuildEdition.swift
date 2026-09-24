import Foundation

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
