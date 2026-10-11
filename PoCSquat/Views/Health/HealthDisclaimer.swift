import SwiftUI

/// The one-line footnote under health screens (Scoops Dev LLC liability
/// review, 2026-10-11): always shown, never dismissed, read by VoiceOver as
/// ordinary text. One component, so the Health hub and every gait detail
/// screen say the same words.
struct HealthDisclaimer: View {
    static let text = "For general information, not medical advice. Wockett isn't a medical device."

    var body: some View {
        Text(Self.text)
            .font(.wktLabel)
            .foregroundColor(.earthMuted)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("health.disclaimer")
    }
}
