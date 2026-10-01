import SwiftUI

// MARK: - Preview

#Preview("Badge Earned") {
    // Plain `if let` rather than a lint-suppression comment. The suppression was
    // honoured by SwiftLint on macOS and not by the same version on the Linux CI
    // runner (2026-09-09). Code that needs no exemption can't lose one to a
    // platform difference. (Don't name the directive here either — SwiftLint
    // parses that token inside ordinary comment text and flags it as malformed.)
    if let badge = walkBadges.first {
        BadgeEarnedView(badge: badge)
    }
}

struct BadgeEarnedView: View {
    let badge: WalkBadge
    @Environment(\.dismiss) private var dismiss

    @State private var scale:        CGFloat = 0.3
    @State private var opacity:      Double  = 0
    @State private var glowRadius:   CGFloat = 0
    @State private var showShareSheet = false

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()

                Text(badge.emoji)
                    .font(.system(size: 96))
                    .scaleEffect(scale)
                    .shadow(color: Color.earthGreen.opacity(0.5), radius: glowRadius)
                    .padding(.bottom, 32)

                VStack(spacing: 10) {
                    Text("Badge unlocked")
                        .font(.wktLabel)
                        .foregroundColor(.earthGreen)
                    Text(badge.name)
                        .font(.wktMetric)
                        .foregroundColor(.earthCream)
                        .multilineTextAlignment(.center)
                    Text(badge.description)
                        .font(.wktBodyText)
                        .foregroundColor(.earthMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                VStack(spacing: 12) {
                    // Share to community feed
                    WktPrimaryButton(title: "Share to Community", symbol: .communityWave) {
                        showShareSheet = true
                    }

                    // Standard iOS share sheet (Messages, social apps, etc.)
                    let shareText = "I just earned the \"\(badge.name)\" badge on Wockett \(badge.emoji) Keep walking!"
                    ShareLink(item: shareText) {
                        WktSecondaryLabel(title: "Share via Messages / Social", symbol: .share)
                    }
                    .buttonStyle(BounceButtonStyle(scale: 0.98))

                    Button("Close") { dismiss() }
                        .font(.wktBodyText)
                        .foregroundColor(.earthMuted)
                        .padding(.bottom, 8)
                }
                .padding(.horizontal, WktSpacing.screen)
                .padding(.bottom, 32)
            }
            .opacity(opacity)
        }
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) {
                scale   = 1.0
                opacity = 1.0
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                glowRadius = 24
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareAchievementSheet(badge: badge) {}
        }
    }
}
