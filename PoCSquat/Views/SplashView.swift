import SwiftUI

// The launch splash (2026-10-06 redesign). It sits on the app's own
// background, `earthBg`, so the hand-off is one surface from end to end: the
// launch screen iOS shows first (`LaunchBackground`, the same colour) → this →
// Home. The forest-green splash it replaces was a hard cut on both sides.

// MARK: - Topographic Contour Lines Background

private struct TopoBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height * 0.40
            // Concentric ellipses at increasing scales — mimics elevation contours
            let rings: [(CGFloat, CGFloat)] = [
                (0.40, 0.20), (0.58, 0.30), (0.76, 0.41),
                (0.95, 0.53), (1.16, 0.65), (1.40, 0.79), (1.68, 0.94),
            ]
            for (sx, sy) in rings {
                let w = size.width * sx, h = size.height * sy
                let rect = CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h)
                var path = Path(); path.addEllipse(in: rect)
                ctx.stroke(path, with: .color(.earthTrack), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - W Letter Shape

private struct WLetterShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        // s controls how much of each segment is used for the rounded corner transition
        let s: CGFloat = 0.40

        let p0 = CGPoint(x: 0,      y: 0)        // top-left tip
        let p1 = CGPoint(x: w*0.25, y: h)         // valley 1
        let p2 = CGPoint(x: w*0.50, y: h*0.38)   // center peak
        let p3 = CGPoint(x: w*0.75, y: h)         // valley 2
        let p4 = CGPoint(x: w,      y: 0)         // top-right tip

        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }

        var path = Path()
        path.move(to: p0)
        path.addLine(to: lerp(p0, p1, 1 - s))
        path.addQuadCurve(to: lerp(p1, p2, s), control: p1)
        path.addLine(to: lerp(p1, p2, 1 - s))
        path.addQuadCurve(to: lerp(p2, p3, s), control: p2)
        path.addLine(to: lerp(p2, p3, 1 - s))
        path.addQuadCurve(to: lerp(p3, p4, s), control: p3)
        path.addLine(to: p4)
        return path
    }
}

// MARK: - Arrowhead at TR endpoint

private struct WArrowheadShape: Shape {
    // Open V-arrowhead at the W's top-right tip, pointing in the direction of the last stroke.
    // Direction from BR=(0.75w, h) to TR=(w, 0) — normalized for canvas proportions.
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        // Precomputed for w=130, h=88; direction ≈ (0.347, -0.938), perp ≈ (0.938, 0.347)
        let dX: CGFloat = 0.347, dY: CGFloat = -0.938
        let pX: CGFloat = 0.938, pY: CGFloat =  0.347
        let len = w * 0.115
        let wid = w * 0.062

        let tip = CGPoint(x: w, y: 0)
        let w1  = CGPoint(x: tip.x - len*dX + wid*pX, y: tip.y - len*dY + wid*pY)
        let w2  = CGPoint(x: tip.x - len*dX - wid*pX, y: tip.y - len*dY - wid*pY)

        var p = Path()
        p.move(to: w1)
        p.addLine(to: tip)
        p.addLine(to: w2)
        return p
    }
}

// MARK: - Wocket Logo View

/// The dashed W drawing itself. One eased `progress` drives everything: the
/// line, a pen dot at its tip, the two waypoints as the line reaches them and
/// the arrowhead at the end. The first version ran four separate timers, and
/// the trim revealed the dashed line a whole dash at a time, so the front
/// jumped; the pen dot moves continuously and hides that.
private struct WocketLogoView: View {
    /// False under Reduce Motion: the logo appears already drawn.
    let animates: Bool
    @State private var progress: CGFloat = 0

    var body: some View {
        WocketLogoDrawing(progress: progress)
            .frame(width: WocketLogoDrawing.size.width, height: WocketLogoDrawing.size.height)
            .onAppear {
                guard animates else { progress = 1; return }
                // Gentle start, long soft landing.
                withAnimation(.timingCurve(0.45, 0, 0.15, 1, duration: 1.5)) { progress = 1 }
            }
            .accessibilityHidden(true)
    }
}

private struct WocketLogoDrawing: View, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    static let size = CGSize(width: 130, height: 88)
    private static let rect = CGRect(origin: .zero, size: size)
    private static let strokeWidth: CGFloat = 7
    private static let dash = StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round, dash: [10, 8])

    /// The two valley vertices, where the icon has its orange waypoints.
    private static let valleys = [CGPoint(x: size.width * 0.25, y: size.height),
                                  CGPoint(x: size.width * 0.75, y: size.height)]

    /// How far along the line each valley is, measured on the real path so a
    /// waypoint lands exactly as the pen passes it.
    private static let valleyProgress: [CGFloat] = {
        let path = WLetterShape().path(in: rect)
        let steps = 400
        return valleys.map { valley in
            var best: (t: CGFloat, d: CGFloat) = (0, .infinity)
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let p = path.trimmedPath(from: 0, to: max(t, 0.0001)).currentPoint ?? .zero
                let d = hypot(p.x - valley.x, p.y - valley.y)
                if d < best.d { best = (t, d) }
            }
            return best.t
        }
    }()

    var body: some View {
        let path = WLetterShape().path(in: Self.rect)
        let pen = path.trimmedPath(from: 0, to: max(progress, 0.0001)).currentPoint ?? .zero

        ZStack(alignment: .topLeading) {
            // The whole route, faintly, so the eye knows where the line is going.
            path.stroke(Color.earthTrack, style: Self.dash)

            path.trimmedPath(from: 0, to: progress)
                .stroke(Color.earthGreen, style: Self.dash)

            WArrowheadShape()
                .stroke(Color.earthGreen, style: StrokeStyle(lineWidth: Self.strokeWidth, lineCap: .round, lineJoin: .round))
                .scaleEffect(Self.settle(Self.phase(progress, from: 0.9, length: 0.1)),
                             anchor: UnitPoint(x: 1, y: 0))

            // The pen: fades in as it starts and out as the arrowhead takes over.
            Circle()
                .fill(Color.earthGreen)
                .frame(width: 10, height: 10)
                .position(pen)
                .opacity(Self.phase(progress, from: 0, length: 0.04) * (1 - Self.phase(progress, from: 0.9, length: 0.08)))

            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .fill(Color.earthOrange)
                    .frame(width: 15, height: 15)
                    .scaleEffect(Self.settle(Self.phase(progress, from: Self.valleyProgress[i] - 0.02, length: 0.14)))
                    .position(Self.valleys[i])
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    /// 0 before `from`, 1 after `from + length`, linear in between.
    private static func phase(_ p: CGFloat, from: CGFloat, length: CGFloat) -> CGFloat {
        min(1, max(0, (p - from) / length))
    }

    /// Ease out with a small overshoot (about 6%), so a dot settles into place
    /// rather than popping. Driven by `progress`, so it stays in step with the line.
    private static func settle(_ x: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.2, c3 = c1 + 1
        let u = x - 1
        return x <= 0 ? 0 : 1 + c3 * u * u * u + c1 * u * u
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
            Color.earthBg.ignoresSafeArea()
            TopoBackground().ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                WocketLogoView(animates: !reduceMotion)

                VStack(spacing: 6) {
                    Text("Wockett")
                        .font(.wktHeading(40))
                        .foregroundColor(.earthCream)
                    Text("Walk more. Move better.")
                        .font(.wktBodyText)
                        .foregroundColor(.earthMuted)
                }
                .opacity(titleShown ? 1 : 0)
                .offset(y: titleShown || reduceMotion ? 0 : 12)
                .accessibilityElement(children: .combine)

                Spacer()

                HStack(alignment: .top, spacing: 12) {
                    WktIconBadge(symbol: .tip)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tip of the day")
                            .font(.wktLabel)
                            .foregroundColor(.earthMuted)
                        Text(tips[tipIndex])
                            .font(.wktBodyText)
                            .foregroundColor(.earthCream)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .wktCard()
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
