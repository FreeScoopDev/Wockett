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
// The one promise this screen makes is the Pro one, and it is a real commitment:
// see `SupporterLedger` for how it is kept across reinstalls and devices.

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
                            Text(store.displayPrice(for: tip) ?? "—")
                                .font(.body.monospacedDigit())
                                .foregroundColor(.earthGreen)
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
            Text("Tip about ten dollars in total — in one go or across several tips — and Wockett Pro is yours free when it arrives in a future update. Pro is a one-time purchase; there's no subscription, now or later.")
                .font(.caption)
                .foregroundColor(.earthMuted)
        }
    }

    private var supporterStatusSection: some View {
        Section("Your support") {
            VStack(alignment: .leading, spacing: 8) {
                Text(ledger.tipCount == 1 ? "You've tipped once." : "You've tipped \(ledger.tipCount) times.")
                    .foregroundColor(.earthCream)

                if ledger.hasEarnedPro {
                    Label {
                        Text("Wockett Pro is yours when it ships.")
                            .font(.subheadline)
                    } icon: {
                        Image(wkt: .supportHeart).wktIcon(.row, tint: .earthGreen)
                    }
                    .foregroundColor(.earthGreen)
                } else {
                    Text("Another tip or two and Pro will be yours when it ships.")
                        .font(.subheadline)
                        .foregroundColor(.earthMuted)
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

    private var thanksMessage: String {
        ledger.hasEarnedPro
            ? "That's Wockett Pro secured for you — it'll unlock automatically when Pro ships, on any device signed in to the same Apple Account."
            : "That genuinely helps keep Wockett running."
    }
}
