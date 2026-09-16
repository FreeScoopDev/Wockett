import Testing
import Foundation
@testable import PoCSquat

// MARK: - ProEntitlementStore
//
// The one place that decides "is this user Pro". Two inputs — a StoreKit
// purchase and the supporter ledger — one persisted answer, and a fail-open
// rule when StoreKit cannot be reached. The flag is off in 1.12, so the
// gating tests drive it explicitly through the initialiser.

private final class InMemoryLedgerStore: SupporterLedgerStoring {
    var saved: [TipLedgerEntry] = []
    init(seed: [TipLedgerEntry] = []) { saved = seed }
    func loadEntries() -> [TipLedgerEntry] { saved }
    func saveEntries(_ entries: [TipLedgerEntry]) { saved = entries }
}

/// A StoreKit stand-in whose answer the test controls. `owned == nil` means
/// "StoreKit did not answer", which is not the same as "owns nothing".
private final class FakeEntitlements: @unchecked Sendable {
    var owned: Set<String>?
    var reads = 0
    init(_ owned: Set<String>?) { self.owned = owned }
    var reader: ProEntitlementStore.EntitlementReader {
        { [self] in
            reads += 1
            return owned
        }
    }
}

@MainActor
struct ProEntitlementStoreTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func freshDefaults() -> UserDefaults {
        let suite = "ProEntitlementStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func ledger(points: Int) -> SupporterLedger {
        // `large` is 8 points; the threshold is 4. Build the requested total
        // from smalls (1 point each) so any value is reachable.
        let entries = (0..<points).map { i in
            TipLedgerEntry(transactionID: UInt64(1_000 + i), productID: TipProduct.small.rawValue,
                           date: base.addingTimeInterval(Double(i)))
        }
        return SupporterLedger(store: InMemoryLedgerStore(seed: entries))
    }

    private func make(owned: Set<String>?, points: Int = 0, gating: Bool = false,
                      defaults: UserDefaults? = nil) -> (ProEntitlementStore, FakeEntitlements, UserDefaults) {
        let fake = FakeEntitlements(owned)
        let d = defaults ?? freshDefaults()
        let store = ProEntitlementStore(ledger: ledger(points: points), entitlements: fake.reader,
                                        defaults: d, gatingEnabled: gating, listensToStoreKit: false)
        return (store, fake, d)
    }

    /// Lets the debounced ledger subscription (50 ms) and the Task hop settle.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(250))
    }

    // MARK: Sources of Pro

    @Test("Nothing owned, no tips: not Pro")
    func nobody() async {
        let (store, _, _) = make(owned: [])
        await store.refresh()
        #expect(!store.isPro)
        #expect(store.source == .none)
    }

    @Test("Owning wockett.pro.lifetime makes the user Pro by purchase")
    func purchase() async {
        let (store, _, _) = make(owned: [ProProduct.lifetime])
        await store.refresh()
        #expect(store.isPro)
        #expect(store.source == .purchase)
    }

    @Test("Owning only tip products does not make the user Pro")
    func tipsAreNotEntitlements() async {
        let (store, _, _) = make(owned: [TipProduct.large.rawValue, TipProduct.small.rawValue])
        await store.refresh()
        #expect(!store.isPro)
    }

    @Test("Reaching the supporter threshold makes the user Pro by the 1.11 promise")
    func supporter() async {
        let (store, _, _) = make(owned: [], points: SupporterLedger.proThresholdPoints)
        await store.refresh()
        #expect(store.isPro)
        #expect(store.source == .supporter)
    }

    @Test("One point short of the threshold is not Pro")
    func almostSupporter() async {
        let (store, _, _) = make(owned: [], points: SupporterLedger.proThresholdPoints - 1)
        await store.refresh()
        #expect(!store.isPro)
    }

    @Test("Purchase wins over supporter as the reported source")
    func purchaseOutranksSupporter() async {
        let (store, _, _) = make(owned: [ProProduct.lifetime], points: SupporterLedger.proThresholdPoints)
        await store.refresh()
        #expect(store.source == .purchase)
    }

    // MARK: Persistence and fail-open

    @Test("The answer is written to defaults as a snapshot")
    func persists() async {
        let (store, _, defaults) = make(owned: [ProProduct.lifetime])
        await store.refresh()
        let snapshot = ProEntitlementSnapshot.load(from: defaults)
        #expect(snapshot?.isPro == true)
        #expect(snapshot?.source == .purchase)
    }

    @Test("A new store starts from the last-known snapshot before StoreKit answers")
    func startsFromSnapshot() {
        let defaults = freshDefaults()
        ProEntitlementSnapshot(isPro: true, source: .purchase, updatedAt: base).save(to: defaults)
        let (store, fake, _) = make(owned: [], defaults: defaults)
        #expect(store.isPro, "before any refresh")
        #expect(store.source == .purchase)
        #expect(fake.reads == 0)
    }

    @Test("StoreKit unreachable keeps a paying customer Pro (fail open)")
    func failOpen() async {
        let defaults = freshDefaults()
        ProEntitlementSnapshot(isPro: true, source: .purchase, updatedAt: base).save(to: defaults)
        let (store, fake, _) = make(owned: nil, defaults: defaults)
        await store.refresh()
        #expect(fake.reads == 1)
        #expect(store.isPro)
        #expect(store.source == .purchase)
    }

    @Test("StoreKit unreachable with nothing known stays not Pro — fail open is not fail yes")
    func failOpenNeverInvents() async {
        let (store, _, _) = make(owned: nil)
        await store.refresh()
        #expect(!store.isPro)
    }

    @Test("A refund seen by StoreKit removes Pro; a later outage does not restore it")
    func refundThenOutage() async {
        let defaults = freshDefaults()
        ProEntitlementSnapshot(isPro: true, source: .purchase, updatedAt: base).save(to: defaults)
        let (store, fake, _) = make(owned: [], defaults: defaults)
        await store.refresh()
        #expect(!store.isPro, "StoreKit answered: nothing owned")
        fake.owned = nil
        await store.refresh()
        #expect(!store.isPro, "the last confirmed answer was 'not owned'")
    }

    // MARK: Reacting to the ledger (start)

    @Test("A tip that crosses the supporter threshold makes the user Pro without a restart")
    func ledgerCrossingThresholdIsNoticed() async {
        let fake = FakeEntitlements([])
        let ledger = SupporterLedger(store: InMemoryLedgerStore())
        let store = ProEntitlementStore(ledger: ledger, entitlements: fake.reader,
                                        defaults: freshDefaults(), gatingEnabled: false, listensToStoreKit: false)
        store.start()
        await settle()
        #expect(!store.isPro)

        for i in 0..<SupporterLedger.proThresholdPoints {
            ledger.record(transactionID: UInt64(i + 1), productID: TipProduct.small.rawValue,
                          date: base.addingTimeInterval(Double(i)))
        }
        await settle()
        #expect(store.isPro)
        #expect(store.source == .supporter)
    }

    @Test("A burst of ledger writes costs one refresh, not one per write")
    func ledgerBurstIsDebounced() async {
        let fake = FakeEntitlements([])
        let ledger = SupporterLedger(store: InMemoryLedgerStore())
        let store = ProEntitlementStore(ledger: ledger, entitlements: fake.reader,
                                        defaults: freshDefaults(), gatingEnabled: false, listensToStoreKit: false)
        store.start()
        await settle()
        let afterStart = fake.reads
        #expect(afterStart == 1)

        // record() mutates `entries` twice per call, so four tips are eight
        // emissions. Without the debounce this is eight reads.
        for i in 0..<4 {
            ledger.record(transactionID: UInt64(100 + i), productID: TipProduct.small.rawValue,
                          date: base.addingTimeInterval(Double(i)))
        }
        await settle()
        #expect(fake.reads == afterStart + 1)
    }

    @Test("start() is idempotent")
    func startTwice() async {
        let (store, fake, _) = make(owned: [])
        store.start()
        store.start()
        await settle()
        #expect(fake.reads == 1)
    }

    @Test("An unchanged answer is not re-written to the app group")
    func unchangedAnswerNotRewritten() async {
        let (store, _, defaults) = make(owned: [ProProduct.lifetime])
        await store.refresh()
        let first = ProEntitlementSnapshot.load(from: defaults)
        try? await Task.sleep(for: .milliseconds(20))
        await store.refresh()
        #expect(ProEntitlementSnapshot.load(from: defaults) == first, "same answer, same bytes, same timestamp")
    }

    // MARK: Gating

    @Test("Flag off: every gate opens and no limit applies, Pro or not")
    func flagOff() async {
        let (store, _, _) = make(owned: [], gating: false)
        await store.refresh()
        #expect(!store.isPro)
        for feature in ProFeature.allCases { #expect(store.gate(feature)) }
        #expect(store.canAddAnother(.unlimitedSavedRoutes, current: 1_000))
        #expect(store.canAddAnother(.unlimitedPetProfiles, current: 1_000))
    }

    @Test("Flag on, not Pro: gates close and free limits apply")
    func flagOnFree() async {
        let (store, _, _) = make(owned: [], gating: true)
        await store.refresh()
        for feature in ProFeature.allCases { #expect(!store.gate(feature)) }
        #expect(store.canAddAnother(.unlimitedSavedRoutes, current: ProFeature.freeSavedRouteLimit - 1))
        #expect(!store.canAddAnother(.unlimitedSavedRoutes, current: ProFeature.freeSavedRouteLimit))
        #expect(store.canAddAnother(.unlimitedPetProfiles, current: ProFeature.freePetProfileLimit - 1))
        #expect(!store.canAddAnother(.unlimitedPetProfiles, current: ProFeature.freePetProfileLimit))
        // A feature with no count has nothing to cap.
        #expect(store.canAddAnother(.offlineMaps, current: 1_000))
    }

    @Test("Flag on, Pro: gates open and limits lift")
    func flagOnPro() async {
        let (store, _, _) = make(owned: [ProProduct.lifetime], gating: true)
        await store.refresh()
        for feature in ProFeature.allCases { #expect(store.gate(feature)) }
        #expect(store.canAddAnother(.unlimitedSavedRoutes, current: 1_000))
    }

    @Test("The shipped flag is off, and the free limits are the spec's numbers")
    func shippedConstants() {
        #expect(!ProGating.isEnabled, "1.12 ships the entitlement layer dormant")
        #expect(ProFeature.freeSavedRouteLimit == 10)
        #expect(ProFeature.freePetProfileLimit == 3)
        #expect(ProProduct.lifetime == "wockett.pro.lifetime")
    }

    // MARK: Snapshot (the widget's half)

    @Test("Snapshot round-trips through defaults, and unknown means not Pro")
    func snapshotRoundTrip() {
        let defaults = freshDefaults()
        #expect(ProEntitlementSnapshot.load(from: defaults) == nil)
        let s = ProEntitlementSnapshot(isPro: true, source: .supporter, updatedAt: base)
        s.save(to: defaults)
        #expect(ProEntitlementSnapshot.load(from: defaults) == s)
        #expect(!ProEntitlementSnapshot.unknown.isPro)
    }
}
