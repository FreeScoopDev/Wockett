import SwiftUI

// MARK: - W Letter Shape

private struct WLetterShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to:    CGPoint(x: rect.minX,                   y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width*0.25, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX,                   y: rect.minY + rect.height*0.45))
        p.addLine(to: CGPoint(x: rect.minX + rect.width*0.75, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX,                   y: rect.minY))
        return p
    }
}

// MARK: - Wocket Logo View

private struct WocketLogoView: View {
    @State private var trimEnd:    CGFloat       = 0
    @State private var dotScales: [CGFloat]      = [0, 0, 0, 0, 0]

    private let w: CGFloat            = 120
    private let h: CGFloat            = 80
    private let strokeWidth: CGFloat  = 5.5
    private let dotR: CGFloat         = 6
    private let drawDuration: Double  = 1.1

    // Cumulative fractional positions along path at each vertex (see path-length math)
    private let pathFractions: [CGFloat] = [0, 0.307, 0.50, 0.693, 1.0]

    private var vertices: [CGPoint] {
        [
            CGPoint(x: 0,       y: 0),
            CGPoint(x: w*0.25,  y: h),
            CGPoint(x: w*0.5,   y: h*0.45),
            CGPoint(x: w*0.75,  y: h),
            CGPoint(x: w,       y: 0),
        ]
    }

    var body: some View {
        ZStack {
            // Ghost path
            WLetterShape()
                .stroke(
                    Color.earthGreen.opacity(0.14),
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                )

            // Animated drawing stroke
            WLetterShape()
                .trim(from: 0, to: trimEnd)
                .stroke(
                    Color.earthGreen,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                )
                .animation(.linear(duration: drawDuration), value: trimEnd)

            // Waypoint dots — spring in as path reaches each vertex
            ForEach(0..<5, id: \.self) { i in
                Circle()
                    .fill(Color.earthGreen)
                    .frame(width: dotR * 2, height: dotR * 2)
                    .shadow(color: Color.earthGreen.opacity(0.55), radius: 6)
                    .scaleEffect(dotScales[i])
                    .offset(x: vertices[i].x - w / 2,
                            y: vertices[i].y - h / 2)
            }
        }
        .frame(width: w, height: h)
        .onAppear {
            trimEnd = 1

            for (i, fraction) in pathFractions.enumerated() {
                let delaySecs = Double(fraction) * drawDuration
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(delaySecs * 1_000_000_000))
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.5)) {
                        dotScales[i] = 1
                    }
                }
            }
        }
    }
}

// MARK: - Launch Splash View

struct SplashView: View {
    let onDismiss: () -> Void

    @State private var logoOpacity:   Double = 0
    @State private var titleOpacity:  Double = 0
    @State private var titleOffset:   Double = 14
    @State private var tipOpacity:    Double = 0
    @State private var screenOpacity: Double = 1
    @State private var tipIndex:      Int    = Self.dailyTipIndex()

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                WocketLogoView()
                    .opacity(logoOpacity)

                VStack(spacing: 8) {
                    Text("Wockett")
                        .font(.system(size: 46, weight: .black, design: .rounded))
                        .foregroundColor(.earthCream)
                    Text("Walk more. Move better.")
                        .font(.subheadline)
                        .foregroundColor(.earthMuted)
                }
                .opacity(titleOpacity)
                .offset(y: titleOffset)

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
                .opacity(tipOpacity)

                Spacer()
            }
        }
        .opacity(screenOpacity)
        .onAppear { runSequence() }
        .onTapGesture { onDismiss() }
    }

    private func runSequence() {
        // t=0: W logo fades in; stroke draw begins in WocketLogoView.onAppear
        withAnimation(.easeIn(duration: 0.2)) { logoOpacity = 1 }

        // t=1.1s: title springs up when W drawing completes
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                titleOpacity = 1
                titleOffset  = 0
            }
        }

        // t=1.4s: tip card fades in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeIn(duration: 0.35)) { tipOpacity = 1 }
        }

        // t=3.1s: fade out, then dismiss
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_100_000_000)
            withAnimation(.easeOut(duration: 0.3)) { screenOpacity = 0 }
            try? await Task.sleep(nanoseconds: 310_000_000)
            onDismiss()
        }
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
