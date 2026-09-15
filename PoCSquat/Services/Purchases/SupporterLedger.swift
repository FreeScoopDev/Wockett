import Foundation
import Combine

// MARK: - TipLedgerEntry

/// One recorded tip. Stored rather than derived so the supporter total survives
/// anything StoreKit does with consumables afterwards.
struct TipLedgerEntry: Codable, Equatable, Sendable {
    let transactionID: UInt64
    let productID: String
    let date: Date

    var product: TipProduct? { TipProduct.from(productID: productID) }
    var points: Int { product?.supporterPoints ?? 0 }
}

// MARK: - SupporterLedgerStoring
//
// Seam so the ledger's arithmetic can be unit-tested without UserDefaults or a
// live StoreKit session — same pattern as `NotificationCentering`.
protocol SupporterLedgerStoring: AnyObject {
    func loadEntries() -> [TipLedgerEntry]
    func saveEntries(_ entries: [TipLedgerEntry])
}

final class UserDefaultsSupporterLedgerStore: SupporterLedgerStoring {
    private let key = "wkt_supporterLedger_v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadEntries() -> [TipLedgerEntry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([TipLedgerEntry].self, from: data)
        else { return [] }
        return entries
    }

    func saveEntries(_ entries: [TipLedgerEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - SupporterLedger
//
// The durable record of what someone has tipped, and the single place that
// answers "has this person earned Pro?".
//
// Why this exists at all, given StoreKit:
//
//   Consumables are consumed. StoreKit does not put finished consumable
//   transactions in `Transaction.currentEntitlements`, and by default they do not
//   appear in `Transaction.all` either. Apple's guidance is explicit: once you
//   finish a consumable transaction, keeping track of what the user is entitled
//   to is your job.
//
//   Wockett has promised, in the tip jar's own copy, that tipping about ten
//   dollars earns Wockett Pro when it ships in a later version. That promise has
//   to survive a reinstall and a new phone, so it cannot rest on memory alone.
//
// Two mechanisms, deliberately overlapping:
//
//   1. `SKIncludeConsumableInAppPurchaseHistory` is set to YES in Info.plist,
//      which makes finished consumables show up in `Transaction.all`. That
//      history is held against the Apple ID, so it follows the user to a new
//      device or a fresh install at no cost to us — no CloudKit record type, no
//      schema migration on the store that holds walks and pets, and no new
//      entitlement to register on the App ID.
//
//   2. Every purchase is also written here, locally, BEFORE the transaction is
//      finished — which is what Apple recommends and what protects the promise
//      if the Info.plist behaviour ever changes or a history read fails.
//
// The two are reconciled by transaction ID, so a tip counted from both sources
// counts once. Where they disagree, the union wins: never lose a tip someone
// actually paid for.
//
// In 1.12 `ProEntitlementStore` reads `hasEarnedPro` from here. It should not
// re-derive any of this itself.

@MainActor
final class SupporterLedger: ObservableObject {

    static let shared = SupporterLedger()

    /// Points needed to earn Pro. See `TipProduct.supporterPoints` for why this
    /// is expressed in points rather than currency.
    static let proThresholdPoints = 4

    @Published private(set) var entries: [TipLedgerEntry] = []

    private let store: SupporterLedgerStoring

    // Resolved inside the body rather than as a default argument: default
    // arguments are evaluated in a nonisolated context, and the store is
    // MainActor-isolated like everything else in this target.
    init(store: SupporterLedgerStoring? = nil) {
        let store = store ?? UserDefaultsSupporterLedgerStore()
        self.store = store
        self.entries = store.loadEntries().sorted { $0.date < $1.date }
    }

    // MARK: Derived state

    var supporterPoints: Int { entries.reduce(0) { $0 + $1.points } }

    var tipCount: Int { entries.count }

    var hasTipped: Bool { !entries.isEmpty }

    /// True once the user has tipped enough to be owed Wockett Pro.
    var hasEarnedPro: Bool { supporterPoints >= Self.proThresholdPoints }

    /// Points still needed to reach the Pro threshold, or zero once earned.
    /// Drives the "you're partway there" line in the tip jar.
    var pointsToPro: Int { max(0, Self.proThresholdPoints - supporterPoints) }

    var firstTipDate: Date? { entries.first?.date }

    // MARK: Recording

    /// Records a tip. Safe to call repeatedly with the same transaction — the
    /// transaction ID deduplicates, which is what lets the local write and the
    /// StoreKit history reconcile without double counting.
    ///
    /// Returns true when this call actually added something new.
    @discardableResult
    func record(transactionID: UInt64, productID: String, date: Date) -> Bool {
        guard TipProduct.from(productID: productID) != nil else { return false }
        guard !entries.contains(where: { $0.transactionID == transactionID }) else { return false }

        entries.append(TipLedgerEntry(transactionID: transactionID, productID: productID, date: date))
        entries.sort { $0.date < $1.date }
        store.saveEntries(entries)
        return true
    }

    /// Merges a batch read from StoreKit's transaction history into whatever is
    /// already recorded. Returns the number of tips this added.
    @discardableResult
    func merge(_ incoming: [TipLedgerEntry]) -> Int {
        var added = 0
        for entry in incoming {
            if record(transactionID: entry.transactionID, productID: entry.productID, date: entry.date) {
                added += 1
            }
        }
        return added
    }

    // MARK: Revocation

    /// Removes a tip Apple has refunded or otherwise revoked.
    ///
    /// StoreKit reports a refund as the same transaction with `revocationDate`
    /// set — through `Transaction.updates` when it happens, and in
    /// `Transaction.all` on every launch after. Without this, a refunded tip
    /// keeps counting toward Pro forever: someone could tip the large amount,
    /// take the refund, and still be owed Pro when it ships. The promise is
    /// "tip about ten dollars", not "briefly hold about ten dollars".
    ///
    /// Safe to call for a transaction that was never recorded, or already
    /// revoked — both are no-ops. Returns true when something was removed.
    @discardableResult
    func revoke(transactionID: UInt64) -> Bool {
        let before = entries.count
        entries.removeAll { $0.transactionID == transactionID }
        guard entries.count != before else { return false }
        store.saveEntries(entries)
        return true
    }

    #if DEBUG
    /// Dev-seed support only. Never called outside DEBUG.
    func resetForTesting() {
        entries = []
        store.saveEntries(entries)
    }
    #endif
}
