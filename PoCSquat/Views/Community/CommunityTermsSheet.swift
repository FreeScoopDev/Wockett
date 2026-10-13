import SwiftUI

/// Shown once before a first community action (`CommunityTermsGate`): what
/// becomes public, links to the Terms and the Privacy Policy, and Agree.
struct CommunityTermsSheet: View {
    let onAgree: () -> Void
    let onCancel: () -> Void
    @Environment(\.openURL) private var openURL

    private let points: [(WktSymbol, String)] = [
        (.communityFill, "What you share is public. Everyone using Wockett can see your routes, posts, challenges and challenge progress, with your community name."),
        (.home, "A shared route can show where you start and finish. Think before sharing one that begins at home."),
        (.blockUser, "No abusive, unlawful or private content. We may remove content, or suspend community features, without notice.")
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                        VStack(alignment: .leading, spacing: WktSpacing.betweenCards) {
                            ForEach(points, id: \.1) { symbol, text in
                                HStack(alignment: .top, spacing: WktSpacing.betweenCards) {
                                    Image(wkt: symbol).wktIcon(.row, tint: .earthGreen)
                                        .frame(width: 28)
                                        .accessibilityHidden(true)
                                    Text(text)
                                        .font(.wktBodyText)
                                        .foregroundColor(.earthCream)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .wktCard()

                        VStack(alignment: .leading, spacing: 0) {
                            link("Terms of Service", url: CommunityTerms.termsURL)
                            link("Privacy Policy", url: CommunityTerms.privacyURL)
                        }

                        Text("Tapping Agree accepts the Terms of Service, including the licence that lets Wockett show what you share.")
                            .font(.wktLabel)
                            .foregroundColor(.earthMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        WktPrimaryButton(title: "Agree", symbol: .success, action: onAgree)
                            .accessibilityIdentifier("terms.agree")
                    }
                    .padding(.horizontal, WktSpacing.screen)
                    .padding(.vertical, WktSpacing.cardPadding)
                }
            }
            .navigationTitle("Before you share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).foregroundColor(.earthMuted)
                        .accessibilityIdentifier("terms.cancel")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terms.sheet")
    }

    private func link(_ title: String, url: URL?) -> some View {
        Button {
            if let url { openURL(url) }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.wktBodyText)
                Image(wkt: .openExternal).wktIcon(.inline, tint: .earthGreen)
            }
            .foregroundColor(.earthGreen)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Presents the Terms sheet while `gate` holds an action.
    func communityTermsSheet(_ gate: Binding<CommunityTermsGate>) -> some View {
        sheet(item: gate.pending) { _ in
            CommunityTermsSheet(onAgree: { gate.wrappedValue.agree() },
                                onCancel: { gate.wrappedValue.cancel() })
        }
    }
}
