import SwiftUI

// MARK: - Launch Splash View

struct SplashView: View {
    let onDismiss: () -> Void

    @State private var opacity = 0.0
    @State private var tipIndex: Int = Self.dailyTipIndex()

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 8) {
                    Text("Wockett")
                        .font(.system(size: 46, weight: .black, design: .rounded))
                        .foregroundColor(.earthCream)
                    Text("Walk more. Move better.")
                        .font(.subheadline)
                        .foregroundColor(.earthMuted)
                }

                Spacer()

                VStack(spacing: 10) {
                    Image(systemName: "lightbulb.fill")
                        .font(.title3)
                        .foregroundColor(.earthOrange)
                    Text(tips[tipIndex])
                        .font(.footnote)
                        .foregroundColor(.earthMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 20)
                .padding(.horizontal)
                .background(Color.earthCard)
                .cornerRadius(16)
                .padding(.horizontal, 24)

                Spacer()

                ProgressView()
                    .tint(.earthMuted)
                    .padding(.bottom, 48)
            }
        }
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeIn(duration: 0.35)) { opacity = 1 }
            Task {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                withAnimation(.easeOut(duration: 0.3)) { opacity = 0 }
                try? await Task.sleep(nanoseconds: 300_000_000)
                onDismiss()
            }
        }
        .onTapGesture { onDismiss() }
    }

    // Seed by calendar day so the tip changes daily but is stable within a day
    private static func dailyTipIndex() -> Int {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        return day % tips.count
    }
}

// MARK: - Daily Tips

private let tips: [String] = [
    "You can create custom tags for your weekly schedule. Be weird!",
    "Walking 10 minutes after a meal can lower blood sugar more than a 45-minute walk later.",
    "Try a new direction each time you use Recommend — your neighbourhood has more to offer.",
    "Bring a pet along. Dogs that walk regularly live longer, and so do their humans.",
    "A 20-minute walk can boost your mood for up to 12 hours.",
    "Use waypoints in custom routes to plan coffee stops, scenic detours, or hill climbs.",
    "Shorter, more frequent walks beat one long walk for sustained energy levels.",
    "Tap the calendar icon to see your step history over any month.",
    "Free Walk mode is great for hiking or exploring somewhere new without a planned route.",
    "Walking backwards up a hill burns significantly more calories — and yes, people will stare.",
    "Post a route to the community board so others can discover your favourite loop.",
    "Swipe left or right on the week bar to browse your step history.",
    "Bookmark a recommended route to save it for later without walking it now.",
    "Early morning walks are linked to better sleep quality that same night.",
    "The best walk is the one you actually take.",
    "Route colour on the map matches the card in the list — select one to zoom in.",
    "Split times on custom routes are recorded at each waypoint you set.",
    "Add water break reminders in Settings to stay hydrated on longer routes.",
    "Your pet earns credit for every walk they join — even mid-walk toggles count.",
    "Challenge yourself: pick the hardest route in the list once a week.",
    "Walking in nature reduces cortisol levels measurably within 20 minutes.",
    "Use Explore to find interesting landmarks, parks, or cafés near you.",
    "You can log a past walk manually from your Walk History if you forgot your phone.",
    "The Elevation profile shows on a selected route — look for the ↑ ↓ numbers on route cards.",
    "Every step you don't take is a step you can take tomorrow. No pressure.",
]
