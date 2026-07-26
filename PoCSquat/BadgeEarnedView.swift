import SwiftUI

struct BadgeEarnedView: View {
    let badge: WalkBadge
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 0.3
    @State private var opacity: Double = 0
    @State private var glowRadius: CGFloat = 0

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
                        .font(.caption.bold())
                        .foregroundColor(.earthGreen)
                        .textCase(.uppercase)
                        .tracking(2)
                    Text(badge.name)
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundColor(.earthCream)
                    Text(badge.description)
                        .font(.subheadline)
                        .foregroundColor(.earthMuted)
                }

                Spacer()

                VStack(spacing: 12) {
                    let shareText = "I just earned the \"\(badge.name)\" badge on Wockett \(badge.emoji) Keep walking!"
                    ShareLink(item: shareText) {
                        Label("Share Achievement", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.earthGreen)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }

                    Button("Close") { dismiss() }
                        .font(.subheadline)
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
                scale = 1.0
                opacity = 1.0
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                glowRadius = 24
            }
        }
    }
}
