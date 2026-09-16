import Foundation

// MARK: - Pro entitlement — the shared half
//
// Compiled into BOTH the app and WocketWidgetExtension, the same way
// `DesignSystem.swift` is, so the widget and Live Activity never re-derive
// entitlement on their own. The app owns the truth (`ProEntitlementStore`,
// app target only: StoreKit + the supporter ledger) and writes a snapshot to
// the shared app group; everything else reads the snapshot.
//
// Nothing here talks to StoreKit. That is deliberate: this file has to compile
// in the widget, and the widget must never open a StoreKit session.

/// The one list of what Pro gates. Every gate in the app names a case here,
/// so the gating table in the monetization spec stays auditable in code —
/// no scattered `if isPro` literals.
enum ProFeature: String, CaseIterable, Codable {
    /// Free keeps `freeSavedRouteLimit`; Pro removes the cap.
    case unlimitedSavedRoutes
    /// Free keeps `freePetProfileLimit`; Pro removes the cap.
    case unlimitedPetProfiles
    case offlineMaps
    /// Depth only. Basic trends and summaries stay free — decided 2026-09-15,
    /// because a user's own week is their own data.
    case advancedAnalytics
    case premiumShareCards
    case routeCollections
    case supporterBadge

    /// Generous on purpose: most people never reach either. The number is the
    /// free tier's promise, so it lives here and nowhere else.
    static let freeSavedRouteLimit = 10
    static let freePetProfileLimit = 3

    /// The free-tier cap this feature lifts, if it is a count-based one.
    var freeLimit: Int? {
        switch self {
        case .unlimitedSavedRoutes: return Self.freeSavedRouteLimit
        case .unlimitedPetProfiles: return Self.freePetProfileLimit
        default: return nil
        }
    }
}

/// The feature flag. While this is `false`, `gate(_:)` allows everything and
/// no limit is enforced — the entitlement layer runs, records, and stays
/// invisible. Flip it with the paywall, once two or three Pro features are
/// genuinely good; never before. Nothing that is free today moves behind Pro.
enum ProGating {
    // `nonisolated`: read as a default argument in `ProEntitlementStore.init`,
    // and default arguments are evaluated in a nonisolated context.
    nonisolated static let isEnabled = false
}

/// How the user came to be Pro. Kept so the UI can say the right thing —
/// "thanks for buying" and "you're a supporter" are different sentences.
enum ProEntitlementSource: String, Codable {
    /// `wockett.pro.lifetime` in the Apple Account's current entitlements.
    case purchase
    /// Tips totalling the supporter threshold — the 1.11 promise.
    case supporter
    case none
}

/// Last-known entitlement, persisted to the app group. This is what "fail
/// open" means in practice: when StoreKit cannot be reached, the app keeps
/// showing whatever it last knew, and a paying customer is never locked out
/// because the network is down.
// `nonisolated`: a plain value read and written from wherever the caller is —
// the app's main actor, the widget's timeline provider. Nothing here needs an
// actor, and opting the type out of the app target's MainActor default keeps
// its members callable from `Codable` and other nonisolated paths.
nonisolated struct ProEntitlementSnapshot: Codable, Equatable {
    var isPro: Bool
    var source: ProEntitlementSource
    var updatedAt: Date

    static let appGroup = "group.com.scoops.wockett"
    static let defaultsKey = "pro.entitlement.snapshot"

    static let unknown = ProEntitlementSnapshot(isPro: false, source: .none, updatedAt: .distantPast)

    /// The shared defaults both targets read. Nil only if the app group is
    /// misconfigured, in which case callers fall back to standard defaults.
    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func load(from defaults: UserDefaults) -> ProEntitlementSnapshot? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(ProEntitlementSnapshot.self, from: data)
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// What the widget asks. Reads the app group; unknown means not Pro.
    static var lastKnown: ProEntitlementSnapshot {
        sharedDefaults.flatMap(load(from:)) ?? .unknown
    }
}
