import Testing
import Foundation
import StoreKit
@testable import PoCSquat

// MARK: - TipJarStore product loading
//
// StoreKit's `Product` cannot be constructed in a test, so these drive the
// loader with a fake fetcher that returns nothing or throws. An empty result
// takes the same "fewer than three" path a partial one does, which is the
// path that showed "$2.99 / — / —" on 2026-09-15. What is under test is the
// retry policy and the state the store settles on — not StoreKit.

private final class InMemoryLedgerStore: SupporterLedgerStoring {
    var saved: [TipLedgerEntry] = []
    func loadEntries() -> [TipLedgerEntry] { saved }
    func saveEntries(_ entries: [TipLedgerEntry]) { saved = entries }
}

/// Collects the ID lists each fetch asked for. An actor rather than a captured
/// var, because the fetcher closure is `@Sendable`.
private actor Recorder {
    var seen: [[String]] = []
    func record(_ ids: [String]) { seen.append(ids) }
}

@MainActor
struct TipJarStoreTests {

    private func makeStore(fetch: @escaping TipJarStore.ProductFetcher) -> TipJarStore {
        TipJarStore(ledger: SupporterLedger(store: InMemoryLedgerStore()), fetch: fetch)
    }

    /// A short (empty) answer is asked again, `partialLoadRetries` more times,
    /// before the store gives up and reports the jar unavailable.
    @Test func shortResult_isRetriedBeforeReportingUnavailable() async {
        let sut = makeStore { _ in [] }
        await sut.loadProducts()

        // Pinned, not derived from the constant: with retries set to zero this
        // must go red, or it guards nothing.
        #expect(TipJarStore.partialLoadRetries == 2)
        #expect(sut.fetchCount == 3)
        #expect(sut.products.isEmpty)
        #expect(sut.hasAllProducts == false)
        #expect(sut.loadState == .unavailable("The tip jar isn't available right now."))
    }

    /// A thrown error is not retried — that is a different failure (no network,
    /// StoreKit down) with a different message, and hammering it helps nobody.
    @Test func thrownError_isNotRetried_andReportsUnreachable() async {
        let sut = makeStore { _ in throw URLError(.notConnectedToInternet) }
        await sut.loadProducts()

        #expect(sut.fetchCount == 1)
        #expect(sut.loadState == .unavailable("Couldn't reach the App Store."))
    }

    /// Every fetch asks for exactly the three tip IDs, in tier order.
    @Test func fetchAsksForAllThreeTipIDs() async {
        let recorder = Recorder()
        let sut = makeStore { ids in await recorder.record(ids); return [] }
        await sut.loadProducts()

        let seen = await recorder.seen
        #expect(seen.count == 3)
        for ids in seen {
            #expect(ids == ["wockett.tip.small", "wockett.tip.medium", "wockett.tip.large"])
        }
    }

    /// The retry pause grows, so a slow store is given more room on the second
    /// try, and the whole thing stays comfortably under two seconds.
    @Test func retryDelaysGrowAndStayShort() {
        #expect(TipJarStore.retryDelay(attempt: 1) == .milliseconds(500))
        #expect(TipJarStore.retryDelay(attempt: 2) == .milliseconds(1000))
        // Whole retry budget stays well inside what a person will wait on a spinner.
        #expect(TipJarStore.retryDelay(attempt: 1) + TipJarStore.retryDelay(attempt: 2) <= .seconds(2))
    }

    /// Before anything loads there are no prices and no products, and the
    /// display price for every tier is nil — the view shows "—" and disables
    /// purchase, never a hardcoded figure.
    @Test func displayPriceIsNilUntilLoaded() {
        let sut = makeStore { _ in [] }
        for tip in TipProduct.allCases {
            #expect(sut.displayPrice(for: tip) == nil)
        }
        #expect(sut.loadState == .idle)
    }
}
