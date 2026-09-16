import Combine
import Foundation
import StoreKit

// MARK: - ProEntitlementStore
//
// The single source of truth for "is this user Pro". Everything StoreKit for
// Pro lives here — the same one-owner shape as `TipJarStore` and
// `NotificationService`. Two things make someone Pro, and this is the only
// place that knows both:
//
//   1. `wockett.pro.lifetime` in the Apple Account's current entitlements —
//      the $9.99 one-time unlock (Notion: "Wockett Pro — monetization spec").
//   2. `SupporterLedger.hasEarnedPro` — tips totalling the supporter
//      threshold. That promise shipped in 1.11 and this is where it is kept.
//
// The result is written to the app group as a `ProEntitlementSnapshot` so the
// widget can read it without a StoreKit session, and so the app can fail
// open: when StoreKit is unreachable, the last-known answer stands.
//
// Feature-flagged off (`ProGating.isEnabled`). While off, `gate(_:)` allows
// everything; `isPro` is still computed and recorded, so the tip jar can say
// "you're a supporter" and the day the flag flips nothing needs migrating.

/// The one Pro product. Product IDs are permanent in App Store Connect and
/// carry a `wockett.` prefix rather than the bundle ID (`Scoops.PoCSquat`) —
/// decided 2026-09-15.
enum ProProduct {
    static let lifetime = "wockett.pro.lifetime"
}

@MainActor
final class ProEntitlementStore: ObservableObject {

    static let shared = ProEntitlementStore()

    /// Reads the product IDs the Apple Account currently owns. Returns nil
    /// when StoreKit could not answer — distinct from "owns nothing" — so the
    /// store can fail open. Injectable for tests; the default is StoreKit.
    typealias EntitlementReader = @Sendable () async -> Set<String>?

    @Published private(set) var isPro: Bool
    @Published private(set) var source: ProEntitlementSource
    /// When the answer last changed. Unchanged answers are not re-written.
    @Published private(set) var updatedAt: Date

    private let ledger: SupporterLedger
    private let read: EntitlementReader
    private let defaults: UserDefaults
    private let gatingEnabled: Bool
    private let listensToStoreKit: Bool
    private var updatesTask: Task<Void, Never>?
    private var ledgerSubscription: AnyCancellable?
    private var started = false

    /// Whether StoreKit has ever confirmed the purchase either way. Nil until
    /// the first confirmed read, or forever if StoreKit never vouches.
    private var lastConfirmedPurchase: Bool?

    /// Bumped per `refresh()`. A refresh that started earlier must not apply
    /// its answer over one that finished later — two overlapping reads after
    /// a refund and a tip could otherwise leave the stale one standing.
    private var refreshGeneration = 0

    // `.shared` and the defaults are resolved in the body, not as default
    // arguments — default arguments are evaluated in a nonisolated context.
    init(ledger: SupporterLedger? = nil,
         entitlements: EntitlementReader? = nil,
         defaults: UserDefaults? = nil,
         gatingEnabled: Bool = ProGating.isEnabled,
         listensToStoreKit: Bool = true) {
        self.ledger = ledger ?? .shared
        self.read = entitlements ?? Self.readFromStoreKit
        self.defaults = defaults ?? ProEntitlementSnapshot.sharedDefaults ?? .standard
        self.gatingEnabled = gatingEnabled
        self.listensToStoreKit = listensToStoreKit

        // Fail open from the first instant: whatever was last known is true
        // until StoreKit says otherwise.
        let snapshot = ProEntitlementSnapshot.load(from: self.defaults) ?? .unknown
        isPro = snapshot.isPro
        source = snapshot.source
        updatedAt = snapshot.updatedAt
    }

    // No deinit cancelling `updatesTask` — `deinit` is nonisolated and cannot
    // read a MainActor property under strict checking; the listener holds
    // only a weak reference, and `.shared` lives for the process anyway.

    // MARK: Lifecycle

    /// Call once, at app launch. Refreshes now, then keeps listening: a Pro
    /// purchase made on another device, or a refund, arrives through
    /// `Transaction.updates`; a tip that crosses the supporter threshold
    /// arrives through the ledger.
    func start() {
        guard !started else { return }
        started = true

        if listensToStoreKit {
            updatesTask = Task { [weak self] in
                for await result in Transaction.updates {
                    guard let self else { return }
                    await self.handle(result)
                }
            }
        }

        // `record()` mutates `entries` twice per tip (append, then sort) and
        // the launch reconcile records every historical tip, so this fires in
        // bursts. Debounce to one refresh per burst; the refresh reads the
        // ledger's settled state, not the value at emit time.
        ledgerSubscription = ledger.$entries
            .dropFirst()
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.refresh() }
            }

        Task { await refresh() }
    }

    /// A transaction from `Transaction.updates`. Only the Pro product matters
    /// here; tips are `TipJarStore`'s. Each store finishes its own product —
    /// `finish()` on an already-finished transaction is a no-op, so the two
    /// stores can safely both see the same sequence. An unfinished transaction
    /// is redelivered on every launch, and an unverified one must be finished
    /// too or it replays forever.
    private func handle(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction) where transaction.productID == ProProduct.lifetime:
            await transaction.finish()
            await refresh()
        case .unverified(let transaction, _) where transaction.productID == ProProduct.lifetime:
            await transaction.finish()
        default:
            break
        }
    }

    /// Re-reads StoreKit and the ledger and records the answer. Safe to call
    /// often; the restore path calls it after `AppStore.sync()`.
    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let answer = await read()
        guard generation == refreshGeneration else { return }

        if let owned = answer {
            lastConfirmedPurchase = owned.contains(ProProduct.lifetime)
        }
        // StoreKit could not vouch and never has: keep the snapshot's view of
        // the purchase. That is the fail-open rule, stated once. "Could not
        // vouch" is narrower than "unreachable" — see `readFromStoreKit`.
        let purchased = lastConfirmedPurchase ?? (source == .purchase && isPro)
        let supporter = ledger.hasEarnedPro

        let newSource: ProEntitlementSource = purchased ? .purchase : (supporter ? .supporter : .none)
        apply(isPro: purchased || supporter, source: newSource)
    }

    private func apply(isPro pro: Bool, source src: ProEntitlementSource) {
        // Skip the write when nothing changed: the launch reconcile can call
        // this several times, and the app group is shared with the widget.
        if pro == isPro, src == source, ProEntitlementSnapshot.load(from: defaults) != nil { return }
        let now = Date()
        isPro = pro
        source = src
        updatedAt = now
        ProEntitlementSnapshot(isPro: pro, source: src, updatedAt: now).save(to: defaults)
    }

    // MARK: Gating

    /// Whether `feature` is available to this user. Always true while the
    /// flag is off — the layer records entitlement without enforcing it.
    func gate(_ feature: ProFeature) -> Bool {
        !gatingEnabled || isPro
    }

    /// For count-based features: may the user add one more, given they have
    /// `count` already? Always true while the flag is off, or for features
    /// that have no free limit.
    func canAddAnother(_ feature: ProFeature, current count: Int) -> Bool {
        guard gatingEnabled, !isPro, let limit = feature.freeLimit else { return true }
        return count < limit
    }

    // MARK: StoreKit

    /// Current entitlements from StoreKit 2.
    ///
    /// What "no answer" means here, precisely: StoreKit 2 serves
    /// `currentEntitlements` from its on-device cache, so being offline does
    /// not empty it — an empty *verified* walk is a confirmed "owns nothing"
    /// (a refund, a different Apple Account) and is returned as such. What
    /// StoreKit cannot do is vouch for a transaction whose signature it could
    /// not verify — clock skew is the usual cause — and an `.unverified` result
    /// for the Pro product is exactly the case where "not owned" would be a
    /// guess. That returns nil, and `refresh()` keeps the last confirmed
    /// answer. A revoked transaction (refund) is not an entitlement; StoreKit
    /// leaves those out already and the check is belt-and-braces.
    private static let readFromStoreKit: EntitlementReader = {
        var owned = Set<String>()
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction) where transaction.revocationDate == nil:
                owned.insert(transaction.productID)
            case .unverified(let transaction, _) where transaction.productID == ProProduct.lifetime:
                return nil
            default:
                continue
            }
        }
        return owned
    }
}
