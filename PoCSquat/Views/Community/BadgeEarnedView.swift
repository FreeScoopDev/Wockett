import SwiftUI

// MARK: - Preview

#Preview("Badge Earned") {
    BadgeEarnedView(badge: walkBadges.first!)
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
                    Text("Badge Unlocked!")
                        .wktTechnical(12)
                        .foregroundColor(.earthGreen)
                        .textCase(.uppercase)
                    Text(badge.name)
                        .font(.wktDisplay(34))
                        .foregroundColor(.earthCream)
                    Text(badge.description)
                        .font(.wktBody(14))
                        .foregroundColor(.earthMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                VStack(spacing: 12) {
                    // Share to community feed
                    Button { showShareSheet = true } label: {
                        Label {
                            Text("Share to Community")
                        } icon: {
                            Image(wkt: .communityWave).wktIcon(.row, tint: .white, onFill: true)
                        }
                        .font(.wktHeading(17))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.earthGreenFill)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                    }

                    // Standard iOS share sheet (Messages, social apps, etc.)
                    let shareText = "I just earned the \"\(badge.name)\" badge on Wockett \(badge.emoji) Keep walking!"
                    ShareLink(item: shareText) {
                        Label {
                            Text("Share via Messages / Social")
                        } icon: {
                            Image(wkt: .share).wktIcon(.row, tint: .earthCream)
                        }
                        .font(.wktHeading(14))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.earthCard)
                        .foregroundColor(.earthCream)
                        .cornerRadius(14)
                    }

                    Button("Close") { dismiss() }
                        .font(.wktBody(14))
                        .foregroundColor(.earthMuted)
                        .padding(.bottom, 8)
                }
                .padding(.horizontal, 32)
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
