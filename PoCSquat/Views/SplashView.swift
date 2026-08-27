import SwiftUI

// MARK: - Splash Color Palette (matches app icon)

private let splashBg    = Color(red: 0.169, green: 0.278, blue: 0.220)   // deep forest green
private let splashPath  = Color(red: 0.929, green: 0.914, blue: 0.875)   // cream
private let splashDot   = Color(red: 0.831, green: 0.294, blue: 0.180)   // orange-red waypoints
private let splashCard  = Color(red: 0.133, green: 0.220, blue: 0.173)   // darker card bg
private let splashTopo  = Color(red: 0.200, green: 0.318, blue: 0.251)   // contour lines

// MARK: - Topographic Contour Lines Background

private struct TopoBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height * 0.44
            // Concentric ellipses at increasing scales — mimics elevation contours
            let rings: [(CGFloat, CGFloat)] = [
                (0.40, 0.20), (0.58, 0.30), (0.76, 0.41),
                (0.95, 0.53), (1.16, 0.65), (1.40, 0.79), (1.68, 0.94),
            ]
            for (sx, sy) in rings {
                let w = size.width * sx, h = size.height * sy
                let rect = CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h)
                var path = Path(); path.addEllipse(in: rect)
                ctx.stroke(path, with: .color(splashTopo), lineWidth: 0.75)
            }
        }
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
        let w = rect.width, h = rect.height
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

private struct WocketLogoView: View {
    @State private var trimEnd:     CGFloat   = 0
    @State private var dotScales: [CGFloat]   = [0, 0]
    @State private var arrowScale:  CGFloat   = 0

    private let w: CGFloat           = 130
    private let h: CGFloat           = 88
    private let strokeWidth: CGFloat = 7
    private let dotR: CGFloat        = 7.5
    private let drawDuration: Double = 1.15

    // Only the two valley vertices get orange dots (matches the icon)
    private let dotFractions: [CGFloat] = [0.307, 0.693]
    private var dotVertices: [CGPoint] {
        [CGPoint(x: w*0.25, y: h), CGPoint(x: w*0.75, y: h)]
    }

    var body: some View {
        ZStack {
            // Ghost path — faint dashed outline
            WLetterShape()
                .stroke(splashPath.opacity(0.16),
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round,
                                           dash: [10, 8]))
                .frame(width: w, height: h)

            // Animated dashed stroke — draws left to right
            WLetterShape()
                .trim(from: 0, to: trimEnd)
                .stroke(splashPath,
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round,
                                           dash: [10, 8]))
                .frame(width: w, height: h)
                .animation(.easeInOut(duration: drawDuration), value: trimEnd)

            // Arrowhead at top-right (springs in when draw completes)
            WArrowheadShape()
                .stroke(splashPath,
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round,
                                           lineJoin: .round))
                .frame(width: w, height: h)
                .scaleEffect(arrowScale, anchor: UnitPoint(x: 1.0, y: 0.0))

            // Orange waypoint dots at the two valley points
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .fill(splashDot)
                    .frame(width: dotR*2, height: dotR*2)
                    .shadow(color: splashDot.opacity(0.7), radius: 7)
                    .scaleEffect(dotScales[i])
                    .offset(x: dotVertices[i].x - w/2,
                            y: dotVertices[i].y - h/2)
            }
        }
        .frame(width: w, height: h)
        .onAppear { startAnimation() }
    }

    private func startAnimation() {
        trimEnd = 1

        // Orange dots spring in as the path reaches each valley vertex
        for (i, fraction) in dotFractions.enumerated() {
            let delay = Double(fraction) * drawDuration
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                withAnimation(.spring(response: 0.28, dampingFraction: 0.48)) {
                    dotScales[i] = 1
                }
            }
        }

        // Arrowhead springs in at end of draw
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(drawDuration * 1_000_000_000))
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) {
                arrowScale = 1
            }
        }
    }
}

// MARK: - Splash View

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
            splashBg.ignoresSafeArea()
            TopoBackground().ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                WocketLogoView()
                    .opacity(logoOpacity)

                VStack(spacing: 8) {
                    Text("Wockett")
                        .font(.system(size: 46, weight: .black, design: .rounded))
                        .foregroundColor(splashPath)
                    Text("Walk more. Move better.")
                        .font(.subheadline)
                        .foregroundColor(splashPath.opacity(0.58))
                }
                .opacity(titleOpacity)
                .offset(y: titleOffset)

                Spacer()

                VStack(spacing: 10) {
                    Image(systemName: "lightbulb.fill")
                        .font(.title3)
                        .foregroundColor(splashDot)
                    Text(tips[tipIndex])
                        .font(.footnote)
                        .foregroundColor(splashPath.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 20)
                .padding(.horizontal)
                .background(splashCard)
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
        withAnimation(.easeIn(duration: 0.2)) { logoOpacity = 1 }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_150_000_000)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                titleOpacity = 1; titleOffset = 0
            }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeIn(duration: 0.35)) { tipOpacity = 1 }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_100_000_000)
            withAnimation(.easeOut(duration: 0.3)) { screenOpacity = 0 }
            try? await Task.sleep(nanoseconds: 310_000_000)
            onDismiss()
        }
    }

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
