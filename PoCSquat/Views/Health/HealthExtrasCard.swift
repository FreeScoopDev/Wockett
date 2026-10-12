import SwiftUI

// MARK: - Health Extras Card
//
// In the Recovery card's place on Health while its data has never been asked
// for (`HealthExtrasAccess`). Says what Wockett would read and what for,
// before iOS's sheet lists the same types, so the ask is never a surprise.

struct HealthExtrasCard: View {
    private var access = HealthExtrasAccess.shared
    @State private var isAsking = false

    var body: some View {
        VStack(alignment: .leading, spacing: WktSpacing.cardPadding) {
            HStack(spacing: 12) {
                WktIconBadge(symbol: .sleep, tint: .accentHealth)
                Text("Sleep, readiness and walking health")
                    .font(.wktRowTitle)
                    .foregroundColor(.earthCream)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Wockett can read your sleep, heart rate, heart rate variability, active calories, floors climbed, and walking speed, step length and steadiness from Apple Health to show them here. You choose which in the next screen.")
                .font(.wktLabel)
                .foregroundColor(.earthMuted)
                .fixedSize(horizontal: false, vertical: true)
            WktPrimaryButton(title: "Connect Apple Health", symbol: .openHealth) {
                guard !isAsking else { return }
                isAsking = true
                Task {
                    await access.connect()
                    isAsking = false
                }
            }
            .disabled(isAsking)
        }
        .wktCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("health.extrasCard")
    }
}
