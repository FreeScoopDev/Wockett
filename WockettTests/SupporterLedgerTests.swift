import Testing
import Foundation
@testable import PoCSquat

// MARK: - SupporterLedger
//
// These cover the arithmetic behind a promise made in the tip jar's copy: tip
// roughly ten dollars in total and Wockett Pro is yours when it ships. Getting
// this wrong means either charging someone who already paid, or giving Pro away
// to someone who did not — so the threshold cases are pinned explicitly rather
// than left to be reasoned about.

private final class InMemoryLedgerStore: SupporterLedgerStoring {
    var saved: [TipLedgerEntry] = []
    private(set) var saveCount = 0

    init(seed: [TipLedgerEntry] = []) { saved = seed }

    func loadEntries() -> [TipLedgerEntry] { saved }
    func saveEntries(_ entries: [TipLedgerEntry]) {
        saved = entries
        saveCount += 1
    }
}

@MainActor
struct SupporterLedgerTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ id: UInt64, _ product: TipProduct, offset: TimeInterval = 0) -> TipLedgerEntry {
        TipLedgerEntry(
            transactionID: id,
            productID: product.rawValue,
            date: base.addingTimeInterval(offset)
        )
    }

    private func ledger(seed: [TipLedgerEntry] = []) -> (SupporterLedger, InMemoryLedgerStore) {
        let store = InMemoryLedgerStore(seed: seed)
        return (SupporterLedger(store: store), store)
    }

    // MARK: Empty state

    @Test func emptyLedger_hasNoPointsAndNoPro() {
        let (sut, _) = ledger()
        #expect(sut.supporterPoints == 0)
        #expect(sut.tipCount == 0)
        #expect(sut.hasTipped == false)
        #expect(sut.hasEarnedPro == false)
        #expect(sut.pointsToPro == SupporterLedger.proThresholdPoints)
        #expect(sut.firstTipDate == nil)
    }

    // MARK: The threshold — the cases the promise actually turns on

    @Test func singleLargeTip_earnsPro() {
        let (sut, _) = ledger(seed: [entry(1, .large)])
        #expect(sut.supporterPoints == 8)
        #expect(sut.hasEarnedPro)
    }

    /// Two medium tips is $9.98 in the US storefront — a cent under a literal
    /// $9.99 threshold. Points exist so this qualifies, because explaining that
    /// miss to someone who tipped twice would be indefensible.
    @Test func twoMediumTips_earnPro() {
        let (sut, _) = ledger(seed: [entry(1, .medium), entry(2, .medium, offset: 60)])
        #expect(sut.supporterPoints == 4)
        #expect(sut.hasEarnedPro)
    }

    @Test func fourSmallTips_earnPro() {
        let seed = (1...4).map { entry(UInt64($0), .small, offset: Double($0) * 60) }
        let (sut, _) = ledger(seed: seed)
        #expect(sut.supporterPoints == 4)
        #expect(sut.hasEarnedPro)
    }

    @Test func mediumPlusTwoSmall_earnsPro() {
        let (sut, _) = ledger(seed: [entry(1, .medium), entry(2, .small, offset: 60), entry(3, .small, offset: 120)])
        #expect(sut.supporterPoints == 4)
        #expect(sut.hasEarnedPro)
    }

    @Test func singleMediumTip_doesNotEarnPro() {
        let (sut, _) = ledger(seed: [entry(1, .medium)])
        #expect(sut.supporterPoints == 2)
        #expect(sut.hasEarnedPro == false)
        #expect(sut.pointsToPro == 2)
    }

    @Test func singleSmallTip_doesNotEarnPro() {
        let (sut, _) = ledger(seed: [entry(1, .small)])
        #expect(sut.hasEarnedPro == false)
        #expect(sut.pointsToPro == 3)
    }

    // MARK: Deduplication
    //
    // The same transaction arrives twice by design: once written locally before
    // `finish()`, once read back from StoreKit's history on a later launch. It
    // must count once.

    @Test func recordingSameTransactionTwice_countsOnce() {
        let (sut, _) = ledger()
        #expect(sut.record(transactionID: 42, productID: TipProduct.large.rawValue, date: base) == true)
        #expect(sut.record(transactionID: 42, productID: TipProduct.large.rawValue, date: base) == false)
        #expect(sut.tipCount == 1)
        #expect(sut.supporterPoints == 8)
    }

    @Test func mergeIsIdempotent() {
        let (sut, _) = ledger()
        let incoming = [entry(1, .medium), entry(2, .small, offset: 60)]

        #expect(sut.merge(incoming) == 2)
        #expect(sut.merge(incoming) == 0)
        #expect(sut.tipCount == 2)
        #expect(sut.supporterPoints == 3)
    }

    @Test func mergeAddsOnlyWhatIsNew() {
        let (sut, _) = ledger(seed: [entry(1, .medium)])
        let added = sut.merge([entry(1, .medium), entry(2, .large, offset: 60)])
        #expect(added == 1)
        #expect(sut.tipCount == 2)
        #expect(sut.hasEarnedPro)
    }

    // MARK: Revocation
    //
    // A refund is the same transaction re-delivered with `revocationDate` set.
    // The ledger has to forget it, or the Pro promise can be earned by tipping
    // and then taking the money back.

    @Test func revokingTheOnlyLargeTip_losesPro() {
        let (sut, store) = ledger(seed: [entry(1, .large)])
        #expect(sut.hasEarnedPro)

        #expect(sut.revoke(transactionID: 1) == true)
        #expect(sut.hasEarnedPro == false)
        #expect(sut.tipCount == 0)
        #expect(sut.hasTipped == false)
        #expect(store.saved.isEmpty)
        #expect(store.saveCount == 1)
    }

    @Test func revokingOneOfTwoMediumTips_dropsBelowThreshold() {
        let (sut, _) = ledger(seed: [entry(1, .medium), entry(2, .medium, offset: 60)])
        #expect(sut.hasEarnedPro)

        sut.revoke(transactionID: 2)
        #expect(sut.supporterPoints == 2)
        #expect(sut.hasEarnedPro == false)
        #expect(sut.pointsToPro == 2)
        #expect(sut.entries.map(\.transactionID) == [1])
    }

    @Test func revokingUnknownOrAlreadyRevokedTransaction_isANoOp() {
        let (sut, store) = ledger(seed: [entry(1, .small)])

        #expect(sut.revoke(transactionID: 99) == false)
        #expect(sut.revoke(transactionID: 1) == true)
        #expect(sut.revoke(transactionID: 1) == false)
        #expect(sut.tipCount == 0)
        // Only the one revocation that changed something touched the store.
        #expect(store.saveCount == 1)
    }

    /// The reinstall case, with a refund in between: the fresh ledger over the
    /// same store must not resurrect the revoked tip.
    @Test func revocationPersistsThroughTheStore() {
        let (sut, store) = ledger()
        sut.record(transactionID: 1, productID: TipProduct.large.rawValue, date: base)
        sut.revoke(transactionID: 1)

        let reloaded = SupporterLedger(store: store)
        #expect(reloaded.tipCount == 0)
        #expect(reloaded.hasEarnedPro == false)
    }

    // MARK: Unknown products

    /// A product ID that is not a tip must never earn supporter points — this is
    /// what stops a future Pro purchase, or a renamed product, from silently
    /// counting as a tip.
    @Test func unknownProductID_isIgnored() {
        let (sut, _) = ledger()
        #expect(sut.record(transactionID: 7, productID: "wockett.pro.lifetime", date: base) == false)
        #expect(sut.tipCount == 0)
        #expect(sut.supporterPoints == 0)
    }

    // MARK: Persistence

    @Test func recordingPersistsThroughTheStore() {
        let (sut, store) = ledger()
        sut.record(transactionID: 1, productID: TipProduct.large.rawValue, date: base)

        #expect(store.saved.count == 1)
        #expect(store.saveCount == 1)

        // A fresh ledger over the same store sees the tip — the reinstall case.
        let reloaded = SupporterLedger(store: store)
        #expect(reloaded.hasEarnedPro)
        #expect(reloaded.tipCount == 1)
    }

    @Test func entriesAreOrderedOldestFirst() {
        let (sut, _) = ledger()
        sut.record(transactionID: 2, productID: TipProduct.small.rawValue, date: base.addingTimeInterval(600))
        sut.record(transactionID: 1, productID: TipProduct.small.rawValue, date: base)

        #expect(sut.firstTipDate == base)
        #expect(sut.entries.map(\.transactionID) == [1, 2])
    }

    // MARK: Product table

    @Test func everyTipProductCarriesPoints() {
        for product in TipProduct.allCases {
            #expect(product.supporterPoints > 0)
        }
    }

    /// Guards the weighting itself. If a tier's price changes, this test should
    /// be updated deliberately rather than discovered by a user who expected Pro.
    @Test func pointWeightsAreAsDocumented() {
        #expect(TipProduct.small.supporterPoints == 1)
        #expect(TipProduct.medium.supporterPoints == 2)
        #expect(TipProduct.large.supporterPoints == 8)
        #expect(SupporterLedger.proThresholdPoints == 4)
    }

    @Test func productIDsDoNotInheritThePrototypeBundleID() {
        // Product IDs are permanent. This pins them so a later refactor cannot
        // quietly reintroduce the PoCSquat prototype name.
        #expect(TipProduct.small.rawValue == "wockett.tip.small")
        #expect(TipProduct.medium.rawValue == "wockett.tip.medium")
        #expect(TipProduct.large.rawValue == "wockett.tip.large")
        for product in TipProduct.allCases {
            #expect(product.rawValue.contains("PoCSquat") == false)
        }
    }
}
