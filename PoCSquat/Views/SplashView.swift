import SwiftUI

// The launch splash (2026-10-08). It is the app icon come to life: the icon's
// forest green with contour lines, and its W drawing itself: the cream road and
// its dashes along the line, the orange waypoints settling onto the road as the
// drawing reaches them, the arrowhead last. The launch screen iOS shows first
// (`LaunchBackground`) is the same green, so the hand-off is seamless; the
// splash then fades into Home. The 2026-10-06 version sat on the app's own
// background with a thin dashed W that did not match the icon.

// MARK: - Mark animation

private struct SplashMark: View {
    /// False under Reduce Motion: the mark appears already drawn.
    let animates: Bool
    @State private var progress: CGFloat = 0

    var body: some View {
        WockettMarkView(progress: progress)
            .frame(width: 190, height: 190)
            .onAppear {
                guard animates else { progress = 1; return }
                // Gentle start, long soft landing.
                withAnimation(.timingCurve(0.45, 0, 0.15, 1, duration: 1.5)) { progress = 1 }
            }
    }
}

// MARK: - Splash View

struct SplashView: View {
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var titleShown = false
    @State private var tipShown = false
    @State private var screenOpacity: Double = 1
    @State private var tipIndex: Int = Self.dailyTipIndex()

    var body: some View {
        ZStack {
            Color.brandForest.ignoresSafeArea()
            ContourLinesView(color: .brandContour.opacity(0.75)).ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                SplashMark(animates: !reduceMotion)

                VStack(spacing: 6) {
                    Text("Wockett")
                        .font(.wktHeading(40))
                        .foregroundColor(.brandRoad)
                    Text("Walk more. Move better.")
                        .font(.wktBodyText)
                        .foregroundColor(.brandRoad.opacity(0.7))
                }
                .opacity(titleShown ? 1 : 0)
                .offset(y: titleShown || reduceMotion ? 0 : 12)
                .accessibilityElement(children: .combine)

                Spacer()

                HStack(alignment: .top, spacing: 12) {
                    WktIconBadge(symbol: .tip, tint: .brandWaypoint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tip of the day")
                            .font(.wktLabel)
                            .foregroundColor(.brandRoad.opacity(0.65))
                        Text(tips[tipIndex])
                            .font(.wktBodyText)
                            .foregroundColor(.brandRoad)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // The card's shape, in the splash's palette: a lighter green
                // panel with a cream hairline, so it reads on the dark field.
                .padding(WktSpacing.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .wktCardBackground(fill: Color.brandRoad.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.brandRoad.opacity(0.12), lineWidth: 1))
                .accessibilityElement(children: .combine)
                .padding(.horizontal, WktSpacing.screen)
                .padding(.bottom, WktSpacing.betweenSections)
                .opacity(tipShown ? 1 : 0)
                .offset(y: tipShown || reduceMotion ? 0 : 10)
            }
        }
        .opacity(screenOpacity)
        .onAppear { runSequence() }
        .onTapGesture { onDismiss() }
    }

    private func runSequence() {
        // The title lands as the line reaches its last valley; the tip just after.
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(1.1)) { titleShown = true }
        withAnimation(.easeOut(duration: 0.45).delay(1.35)) { tipShown = true }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.2))
            withAnimation(.easeOut(duration: 0.35)) { screenOpacity = 0 }
            try? await Task.sleep(for: .seconds(0.36))
            onDismiss()
        }
    }

    private static func dailyTipIndex() -> Int {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        return day % tips.count
    }
}

// MARK: - Daily Tips

// Refreshed 2026-10-06. Every tip that names a screen or control was checked
// against the app that day; when one is renamed or moved, fix the tip with it.
private let tips: [String] = [
    "Say \"Hey Siri, start a walk with Wockett\" to start without opening the app.",
    "Add Start Walk to Control Center to begin a walk from anywhere.",
    "Stopped at a crossing? Wockett pauses, then picks up again by itself when you move.",
    "Turn on voice cues under More during a walk to hear how far you've gone.",
    "Turn on water breaks under More during a walk for a reminder to drink.",
    "Bring your pet along. Add them mid-walk and they get credit for every step they join.",
    "Trail too far to walk to? Open it in Routes → Trails for walking or cycling directions.",
    "Swipe the week strip in Health to look back at earlier weeks.",
    "Forgot your phone? Log a past walk from Health → Activity History.",
    "Change your daily step goal in Settings → Tracking → Daily step goal.",
    "Make your own activity tags for the weekly schedule. Be weird.",
    "Share a saved route to Community so others can find your favorite loop.",
    "Nearby places in Routes finds parks, cafés and landmarks to walk to.",
    "Add the Wockett widget to your Home Screen to see today's steps at a glance.",
    "Try a new direction each time. Your neighborhood has more to offer.",
    "A 10-minute walk after a meal can help steady your blood sugar.",
    "Short walks add up. Three 10-minute walks still count.",
    "Time among trees is linked to lower stress, even in 20 minutes.",
    "Dogs that walk every day tend to be healthier, and so do their people.",
    "A morning walk gets you daylight early, which helps set your body clock.",
    "Walking backwards uphill works different muscles. People will stare.",
    "The best walk is the one you actually take.",
    "Every step you don't take today is one you can take tomorrow. No pressure.",
]
