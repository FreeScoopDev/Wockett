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
// The screen makes no promise about future paid features. Until 2026-10-08 it
// said supporters who tipped the Big Supporter amount would get any future paid
// features free; Joe dropped that on 2026-10-06 when premium features became a
// real plan (no one had tipped, so no one is owed it). Tips buy nothing: copy
// that ties a consumable to a durable benefit reads to App Review as a
// non-consumable sold through consumable SKUs. `SupporterLedger` still records
// tips. No currency appears here for the same reason it does not appear in
// `TipProduct`: prices are per-storefront.

struct TipJarView: View {

    @StateObject private var store = TipJarStore.shared
    @StateObject private var ledger = SupporterLedger.shared

    @State private var banner: String?
    @State private var showThanks = false

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
            .font(.wktRowTitle)
        }
        .navigationTitle("Support Wockett")
        .navigationBarTitleDisplayMode(.inline)
        // Fetch on appear only while something is still missing: with all three
        // prices known there is nothing to gain and a spinner flash to lose.
        .task { if !store.hasAllProducts { await store.loadProducts() } }
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
                    .font(.wktRowTitle)
                    .foregroundColor(.earthCream)
                Text("Tipping is entirely optional and unlocks nothing that's currently free — every feature you use today stays exactly as it is. It just helps cover what the app costs to run.")
                    .font(.wktBodyText)
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
                    .font(.wktLabel)
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
                                .font(.wktLabel)
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
                                .font(.wktRowTitle.monospacedDigit())
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
            WktListHeader(title: "Tip jar")
        } footer: {
            Text("Every tip goes toward what Wockett costs to run. Thank you.")
                .font(.wktLabel)
                .foregroundColor(.earthMuted)
        }
    }

    private var supporterStatusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(ledger.tipCount == 1 ? "You've tipped once." : "You've tipped \(ledger.tipCount) times.")
                    .foregroundColor(.earthCream)

                Text("Thank you. Genuinely.")
                    .font(.wktLabel)
                    .foregroundColor(.earthMuted)
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.earthCard)
        } header: { WktListHeader(title: "Your support") }
    }

    private var smallPrintSection: some View {
        Section {
            // No "Restore tips" button. App Review rejected 1.14 (build 182,
            // 2026-10-08, guideline 3.1.1) because it called AppStore.sync(),
            // which asks for the Apple Account password, and consumables cannot
            // be restored that way. Tips are still remembered: the ledger is
            // rebuilt from StoreKit's own history at every launch
            // (`reconcileWithStoreKitHistory`), which needs no sign-in.
            Text("Tips are one-off payments handled by Apple. They aren't refundable through Wockett — contact Apple Support for that.")
                .font(.wktLabel)
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

    private var thanksMessage: String { "That genuinely helps keep Wockett running." }
}
