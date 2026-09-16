import SwiftUI
import StoreKit

// MARK: - TipJarView
//
// One screen, no dark patterns. The monetization plan's stated goal is to cover
// the app's running costs and make the project feel like a real endeavour — not
// to maximise revenue — and the copy here is written to match that. No urgency,
// no guilt, no pre-selected tier, and a plain statement that tipping buys
// nothing the free app withholds.
//
// The one promise this screen makes is that tips are remembered, and it is a
// real commitment: see `SupporterLedger` for how it is kept across reinstalls
// and devices. The wording is deliberately conditional ("if Wockett ever adds
// paid features") and names no product, price or date. Consumable tips that buy
// a durable entitlement read to App Review as a non-consumable sold through
// consumable SKUs, and copy about an unreleased product is "coming soon"
// content under guideline 2.3.1 — either is a rejection on a screen that is
// otherwise exactly the kind of tip jar Apple allows. No currency appears here
// for the same reason it does not appear in `TipProduct`: prices are
// per-storefront.

struct TipJarView: View {

    @StateObject private var store = TipJarStore.shared
    @StateObject private var ledger = SupporterLedger.shared

    @State private var banner: String?
    @State private var showThanks = false
    @State private var restoring = false

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()

            List {
                introSection

                switch store.loadState {
                case .idle, .loading:
                    loadingSection
                case .unavailable(let message):
                    unavailableSection(message)
                case .loaded:
                    tiersSection
                }

                if ledger.hasTipped { supporterStatusSection }

                smallPrintSection
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Support Wockett")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadProducts() }
        .alert("Thank you", isPresented: $showThanks) {
            Button("You're welcome") { }
        } message: {
            Text(thanksMessage)
        }
        .alert(
            "Tip jar",
            isPresented: Binding(get: { banner != nil }, set: { if !$0 { banner = nil } })
        ) {
            Button("OK") { banner = nil }
        } message: {
            Text(banner ?? "")
        }
    }

    // MARK: Sections

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Wockett is made by one person.")
                    .font(.headline)
                    .foregroundColor(.earthCream)
                Text("Tipping is entirely optional and unlocks nothing that's currently free — every feature you use today stays exactly as it is. It just helps cover what the app costs to run.")
                    .font(.subheadline)
                    .foregroundColor(.earthMuted)
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.earthCard)
        }
    }

    private var loadingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading…").foregroundColor(.earthMuted)
            }
            .listRowBackground(Color.earthCard)
        }
    }

    private func unavailableSection(_ message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(message).foregroundColor(.earthCream)
                Text("Nothing's wrong with the app — you can carry on as normal. Try again later.")
                    .font(.caption)
                    .foregroundColor(.earthMuted)
                Button("Try again") { Task { await store.loadProducts() } }
                    .foregroundColor(.earthGreen)
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.earthCard)
        }
    }

    private var tiersSection: some View {
        Section {
            ForEach(TipProduct.ordered) { tip in
                Button {
                    Task { await buy(tip) }
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(wkt: .supportHeart).wktIcon(.row, tint: .earthGreen)
                            .accessibilityHidden(true) // decorative; the button already reads title, blurb, price

                        VStack(alignment: .leading, spacing: 2) {
                            Text(tip.title)
                                .foregroundColor(.earthCream)
                            Text(tip.blurb)
                                .font(.caption)
                                .foregroundColor(.earthMuted)
                        }

                        Spacer()

                        if store.purchasing == tip {
                            ProgressView()
                        } else {
                            // Always StoreKit's own localised price — never a
                            // hardcoded figure, which would be wrong in every
                            // storefront outside the US.
                            // fixedSize + layoutPriority: at accessibility text
                            // sizes the wrapping blurb would otherwise take the
                            // width and squeeze "$19.99" — which has no break
                            // point — down to an ellipsis. The blurb wraps to
                            // another line instead.
                            Text(store.displayPrice(for: tip) ?? "—")
                                .font(.body.monospacedDigit())
                                .foregroundColor(.earthGreen)
                                .fixedSize()
                                .layoutPriority(1)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .disabled(store.purchasing != nil)
                .listRowBackground(Color.earthCard)
            }
        } header: {
            Text("Tip jar")
        } footer: {
            Text("Tips are remembered. If Wockett ever adds paid features, supporters who've tipped roughly the Big Supporter amount in total will get them at no charge.")
                .font(.caption)
                .foregroundColor(.earthMuted)
        }
    }

    private var supporterStatusSection: some View {
        Section("Your support") {
            VStack(alignment: .leading, spacing: 8) {
                Text(ledger.tipCount == 1 ? "You've tipped once." : "You've tipped \(ledger.tipCount) times.")
                    .foregroundColor(.earthCream)

                // No "one more tip and…" nudge in the not-yet case. The status
                // card reports; it does not sell.
                if ledger.hasEarnedPro {
                    Label {
                        Text("You're a supporter. Any future paid features are yours at no charge.")
                            .font(.subheadline)
                    } icon: {
                        Image(wkt: .supportHeart).wktIcon(.row, tint: .earthGreen)
                    }
                    .foregroundColor(.earthGreen)
                }

                Text("Thank you. Genuinely.")
                    .font(.caption)
                    .foregroundColor(.earthMuted)
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.earthCard)
        }
    }

    private var smallPrintSection: some View {
        Section {
            // Guideline 3.1.1 expects a visible way to restore. Reconciliation
            // also runs at every launch, so this is belt-and-braces — but a
            // reviewer looking for the button should find one.
            Button {
                Task { await restore() }
            } label: {
                HStack {
                    Text("Restore tips")
                        .foregroundColor(.earthGreen)
                    Spacer()
                    if restoring { ProgressView() }
                }
            }
            .disabled(restoring)
            .listRowBackground(Color.earthCard)

            Text("Tips are one-off payments handled by Apple. They aren't refundable through Wockett — contact Apple Support for that.")
                .font(.caption)
                .foregroundColor(.earthMuted)
                .listRowBackground(Color.earthCard)
        }
    }

    // MARK: Actions

    private func buy(_ tip: TipProduct) async {
        switch await store.purchase(tip) {
        case .purchased:
            showThanks = true
        case .cancelled:
            break
        case .pending:
            banner = "That purchase needs approval before it goes through."
        case .failed(let message):
            banner = message
        }
    }

    private func restore() async {
        restoring = true
        defer { restoring = false }
        let before = ledger.tipCount
        await store.restore()
        let added = ledger.tipCount - before
        banner = added > 0
            ? (added == 1 ? "Found 1 tip that wasn't recorded here. Thank you." : "Found \(added) tips that weren't recorded here. Thank you.")
            : (ledger.hasTipped ? "Your tips are all accounted for." : "No tips found for this Apple Account.")
    }

    private var thanksMessage: String {
        ledger.hasEarnedPro
            ? "You're a supporter now. Any future paid features are yours at no charge, on any device signed in to the same Apple Account."
            : "That genuinely helps keep Wockett running."
    }
}
