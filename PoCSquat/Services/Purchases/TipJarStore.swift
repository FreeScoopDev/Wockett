import Foundation
import Combine
import StoreKit

// MARK: - TipJarStore
//
// Everything StoreKit, for the tip jar. One owner, the same way
// `NotificationService` owns notifications.
//
// Scope note: this deliberately knows nothing about Pro. Tips are consumables
// with no entitlement attached; the only lasting consequence of a tip is the row
// it writes to `SupporterLedger`. When Pro arrives in 1.12,
// `ProEntitlementStore` reads that ledger — it does not reach in here.
//
// Failure posture is fail-open throughout. A tip jar that cannot reach the App
// Store should say so quietly and leave the rest of the app alone; it must never
// block a walk, and it must never discard a tip that was actually paid for.

@MainActor
final class TipJarStore: ObservableObject {

    static let shared = TipJarStore()

    // MARK: State

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case unavailable(String)
    }

    enum PurchaseOutcome: Equatable {
        case purchased(TipProduct)
        case cancelled
        /// Ask to Buy, or a payment method awaiting action. The transaction may
        /// arrive later through the updates listener.
        case pending
        case failed(String)
    }

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var products: [TipProduct: Product] = [:]
    /// Set while a purchase is in flight so the UI can disable the tier buttons.
    @Published private(set) var purchasing: TipProduct?

    private let ledger: SupporterLedger
    private var updatesTask: Task<Void, Never>?

    // `.shared` is resolved in the body, not as a default argument, for the
    // same reason as `SupporterLedger.init`: default arguments are nonisolated.
    init(ledger: SupporterLedger? = nil) {
        self.ledger = ledger ?? .shared
    }

    // No deinit cancelling `updatesTask`: `deinit` is nonisolated, so reading a
    // MainActor-isolated stored property from it is an error under the strict
    // concurrency checking this project enables. It would also be pointless —
    // this is a process-lifetime singleton, and the listener holds only a weak
    // reference to self.

    // MARK: Lifecycle

    /// Call once, at app launch.
    ///
    /// The updates listener has to start before any `purchase` call and stay alive
    /// for the whole process, otherwise a transaction that completes outside the
    /// purchase call — Ask to Buy approval, an interrupted purchase, a tip made on
    /// another device — is never seen and never recorded.
    func start() {
        guard updatesTask == nil else { return }

        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.handle(result)
            }
        }

        Task { await loadProducts() }
        Task { await reconcileWithStoreKitHistory() }
    }

    // MARK: Products

    func loadProducts() async {
        loadState = .loading
        do {
            let fetched = try await Product.products(for: TipProduct.allCases.map(\.rawValue))

            var byTier: [TipProduct: Product] = [:]
            for product in fetched {
                if let tier = TipProduct.from(productID: product.id) { byTier[tier] = product }
            }
            products = byTier

            // An empty result is not an error from StoreKit's point of view, but it
            // is always a misconfiguration from ours: the products do not exist in
            // App Store Connect, are not in the Paid Applications Agreement's
            // territory, or the agreement itself is not active. Say so rather than
            // showing an empty screen.
            loadState = byTier.isEmpty
                ? .unavailable("The tip jar isn't available right now.")
                : .loaded
        } catch {
            loadState = .unavailable("Couldn't reach the App Store.")
        }
    }

    /// Localised, storefront-correct price for a tier. Nil until products load.
    func displayPrice(for tip: TipProduct) -> String? {
        products[tip]?.displayPrice
    }

    // MARK: Purchasing

    func purchase(_ tip: TipProduct) async -> PurchaseOutcome {
        guard let product = products[tip] else {
            return .failed("That tip isn't available right now.")
        }

        purchasing = tip
        defer { purchasing = nil }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                await handle(verification)
                return .purchased(tip)

            case .userCancelled:
                return .cancelled

            case .pending:
                return .pending

            @unknown default:
                // A future case. Treat as pending rather than failed: the updates
                // listener is what actually records the tip, so if it does land we
                // still get it, and telling the user it failed would be a lie.
                return .pending
            }
        } catch {
            return .failed("The purchase didn't go through.")
        }
    }

    // MARK: Transaction handling

    /// Records a transaction, then finishes it.
    ///
    /// Order matters and is not stylistic: once `finish()` is called the
    /// consumable is consumed, so the ledger write has to happen first or the tip
    /// can be lost between the two.
    ///
    /// A refund arrives through the same path: StoreKit re-delivers the
    /// transaction with `revocationDate` set. That has to *remove* the tip from
    /// the ledger, not re-record it — see `SupporterLedger.revoke`.
    private func handle(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            if TipProduct.from(productID: transaction.productID) != nil {
                if transaction.revocationDate != nil {
                    ledger.revoke(transactionID: transaction.id)
                } else {
                    ledger.record(
                        transactionID: transaction.id,
                        productID: transaction.productID,
                        date: transaction.purchaseDate
                    )
                }
            }
            await transaction.finish()

        case .unverified(let transaction, _):
            // Failed StoreKit's own signature check. Do not credit it — but do
            // finish it, or it is replayed on every launch forever.
            await transaction.finish()
        }
    }

    // MARK: History reconciliation

    /// Rebuilds the ledger from StoreKit's own transaction history.
    ///
    /// This is what makes the Pro-for-tippers promise survive a reinstall or a new
    /// phone: the history is held against the Apple ID, not the device. It works
    /// only because `SKIncludeConsumableInAppPurchaseHistory` is YES in
    /// Info.plist — without that key, finished consumables are absent from
    /// `Transaction.all` and this loop silently finds nothing.
    ///
    /// Merging is by transaction ID, so running it alongside the local writes in
    /// `handle` cannot double-count.
    ///
    /// Refunded tips appear in the same history with `revocationDate` set. They
    /// are removed from the ledger rather than merged, so a refund the app never
    /// saw live — because it happened while Wockett was not running, or on
    /// another device — is still honoured on the next launch.
    func reconcileWithStoreKitHistory() async {
        var found: [TipLedgerEntry] = []
        var revoked: [UInt64] = []

        for await result in Transaction.all {
            guard case .verified(let transaction) = result,
                  TipProduct.from(productID: transaction.productID) != nil
            else { continue }

            if transaction.revocationDate != nil {
                revoked.append(transaction.id)
            } else {
                found.append(
                    TipLedgerEntry(
                        transactionID: transaction.id,
                        productID: transaction.productID,
                        date: transaction.purchaseDate
                    )
                )
            }
        }

        ledger.merge(found)
        for id in revoked { ledger.revoke(transactionID: id) }
    }
}
