import Foundation

/// Agreement to the Terms of Service before a first community action
/// (2026-10-12 audit, finding 6). Kept on this device only: the date and the
/// version agreed to, in UserDefaults. Nothing is sent anywhere.
enum CommunityTerms {
    /// The Terms version a community action needs. Change it only when the
    /// Terms change in a way everyone should agree to again: every user then
    /// sees the sheet once more, at their next community action. It is the
    /// "Last updated" date of the Terms it stands for.
    static let version = "2026-10-13"

    static let termsURL = URL(string: "https://wockett.app/terms-of-service.html")
    static let privacyURL = URL(string: "https://wockett.app/privacy-policy.html")

    static let acceptedVersionKey = "wkt_termsAcceptedVersion"
    static let acceptedAtKey = "wkt_termsAcceptedAt"

    /// The gate: agreement is needed unless the version agreed to is the current one.
    static func needsAgreement(acceptedVersion: String?, current: String = version) -> Bool {
        acceptedVersion != current
    }

    static func needsAgreement(defaults: UserDefaults) -> Bool {
        needsAgreement(acceptedVersion: defaults.string(forKey: acceptedVersionKey))
    }

    static func recordAgreement(defaults: UserDefaults, now: Date) {
        defaults.set(version, forKey: acceptedVersionKey)
        defaults.set(now, forKey: acceptedAtKey)
    }
}

/// One screen's community action, held while the Terms sheet is up. Each
/// screen with a community action owns one as `@State` and presents
/// `.communityTermsSheet($gate)`, so the sheet shows above whatever sheet
/// the action is in.
struct CommunityTermsGate {
    struct Pending: Identifiable {
        let id = UUID()
        let action: () -> Void
    }

    /// Non-nil while the sheet is showing; the sheet sets it to nil when swiped away.
    var pending: Pending?
    var defaults: UserDefaults = .standard

    /// Runs `action` now if the current Terms are agreed to; otherwise holds
    /// it for `agree()` and shows the sheet.
    mutating func perform(_ action: @escaping () -> Void) {
        if CommunityTerms.needsAgreement(defaults: defaults) {
            pending = Pending(action: action)
        } else {
            action()
        }
    }

    /// Records agreement, closes the sheet and runs the held action, once.
    mutating func agree(now: Date = Date()) {
        CommunityTerms.recordAgreement(defaults: defaults, now: now)
        let held = pending
        pending = nil
        held?.action()
    }

    /// Closes the sheet; the held action is dropped, never run.
    mutating func cancel() {
        pending = nil
    }
}
