import SwiftUI

// MARK: - Wockett mark
//
// The W from the app icon (2026-10-08), traced from the 1024 px icon so the
// splash and any artwork draw the same mark: a cream road with a dashed centre
// line, straight strokes joined by round corners, two orange waypoints sitting
// on the road, and a rounded arrowhead. Measured: road 100 px wide with a 3 px
// edge; corner radii 57 / 48 / 62; waypoints r 26 on the centre line. The
// splash's earlier W (a thin dashed line with sharp corners and the dots hung
// below the valleys) did not match the icon.

enum WockettMarkGeometry {
    static let canvas: CGFloat = 1024
    static let roadWidth: CGFloat = 100
    static let edgeWidth: CGFloat = 3
    static let dashWidth: CGFloat = 4
    static let dash: [CGFloat] = [30, 20]
    static let waypointRadius: CGFloat = 26
    static let waypoints = [CGPoint(x: 181, y: 462), CGPoint(x: 705, y: 748)]

    private static let start = CGPoint(x: 122, y: 262)
    private static let corners = [CGPoint(x: 305, y: 888), CGPoint(x: 497, y: 276), CGPoint(x: 689, y: 895)]
    private static let radii: [CGFloat] = [57, 48, 62]
    private static let end = CGPoint(x: 862, y: 345)

    /// The road's centre line, from the top-left tip to the base of the arrowhead.
    static func road(scale s: CGFloat) -> Path {
        let t = CGAffineTransform(scaleX: s, y: s)
        let p = CGMutablePath()
        p.move(to: start, transform: t)
        let points = corners + [end]
        for i in 0..<corners.count {
            p.addArc(tangent1End: points[i], tangent2End: points[i + 1], radius: radii[i], transform: t)
        }
        p.addLine(to: end, transform: t)
        return Path(p)
    }

    /// The arrowhead: a triangle with 34 px rounded corners.
    static func head(scale s: CGFloat) -> Path {
        let t = CGAffineTransform(scaleX: s, y: s)
        let tip = CGPoint(x: 935, y: 192), left = CGPoint(x: 706, y: 300), right = CGPoint(x: 978, y: 410)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2), transform: t)
        p.addArc(tangent1End: right, tangent2End: tip, radius: 34, transform: t)
        p.addArc(tangent1End: tip, tangent2End: left, radius: 34, transform: t)
        p.addArc(tangent1End: left, tangent2End: right, radius: 34, transform: t)
        p.closeSubpath()
        return Path(p)
    }

    /// How far along the road each waypoint is, measured on the path itself so
    /// a waypoint appears exactly as the drawing reaches it.
    static let waypointProgress: [CGFloat] = {
        let path = road(scale: 1)
        return waypoints.map { w in
            var best: (t: CGFloat, d: CGFloat) = (0, .infinity)
            for i in 0...500 {
                let t = CGFloat(i) / 500
                let p = path.trimmedPath(from: 0, to: max(t, 0.0001)).currentPoint ?? .zero
                let d = hypot(p.x - w.x, p.y - w.y)
                if d < best.d { best = (t, d) }
            }
            return best.t
        }
    }()
}

/// The mark, drawn to `progress` (0 = nothing, 1 = complete). Animate
/// `progress` and every part stays in step: the road and its dashes draw
/// along the line, each waypoint settles onto the road as the drawing reaches
/// it, and the arrowhead lands at the end.
struct WockettMarkView: View, Animatable {
    var progress: CGFloat = 1
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / WockettMarkGeometry.canvas
            let road = WockettMarkGeometry.road(scale: s)
            let drawn = road.trimmedPath(from: 0, to: progress)
            let headIn = Self.settle(Self.phase(progress, from: 0.9, length: 0.1))
            ZStack(alignment: .topLeading) {
                // Edge, then the cream road over it, so the edge shows 3 px each side.
                drawn.stroke(Color.brandContour, style: StrokeStyle(lineWidth: (WockettMarkGeometry.roadWidth + WockettMarkGeometry.edgeWidth * 2) * s,
                                                                    lineCap: .round, lineJoin: .round))
                WockettMarkGeometry.head(scale: s)
                    .stroke(Color.brandContour, lineWidth: WockettMarkGeometry.edgeWidth * 2 * s)
                    .scaleEffect(headIn, anchor: Self.headAnchor)
                drawn.stroke(Color.brandRoad, style: StrokeStyle(lineWidth: WockettMarkGeometry.roadWidth * s, lineCap: .round, lineJoin: .round))
                WockettMarkGeometry.head(scale: s)
                    .fill(Color.brandRoad)
                    .scaleEffect(headIn, anchor: Self.headAnchor)
                drawn.stroke(Color.brandDash, style: StrokeStyle(lineWidth: WockettMarkGeometry.dashWidth * s,
                                                                 dash: WockettMarkGeometry.dash.map { $0 * s }))
                ForEach(0..<WockettMarkGeometry.waypoints.count, id: \.self) { i in
                    let w = WockettMarkGeometry.waypoints[i], r = WockettMarkGeometry.waypointRadius * s
                    Circle()
                        .fill(Color.brandWaypoint)
                        .frame(width: r * 2, height: r * 2)
                        .scaleEffect(Self.settle(Self.phase(progress, from: WockettMarkGeometry.waypointProgress[i] - 0.01, length: 0.08)))
                        .position(x: w.x * s, y: w.y * s)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// The arrowhead grows out of the end of the road.
    private static let headAnchor = UnitPoint(x: 862 / WockettMarkGeometry.canvas, y: 345 / WockettMarkGeometry.canvas)

    private static func phase(_ p: CGFloat, from: CGFloat, length: CGFloat) -> CGFloat {
        min(1, max(0, (p - from) / length))
    }

    /// Ease out with a small overshoot, so a waypoint settles rather than pops.
    private static func settle(_ x: CGFloat) -> CGFloat {
        guard x > 0 else { return 0 }
        let c1: CGFloat = 1.2, c3 = c1 + 1, u = x - 1
        return 1 + c3 * u * u * u + c1 * u * u
    }
}

// MARK: - Contour lines

/// Organic contour lines like the icon's: iso-lines of a smooth terrain made
/// from a few slow waves, traced with marching squares. Deterministic, so the
/// splash looks the same every launch.
struct ContourLinesView: View {
    var color: Color = .brandContour
    var lineWidth: CGFloat = 1
    /// Terrain units across the view's width: higher is busier.
    var scale: Double = 3.4
    var levels: Int = 16

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            for (a, b) in ContourTerrain.shared.segments(width: size.width, height: size.height,
                                                        scale: scale, levels: levels, cell: 5) {
                path.move(to: a); path.addLine(to: b)
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

struct ContourTerrain {
    static let shared = ContourTerrain(seed: 7)

    private struct Wave { let kx, ky, phase, amp: Double }
    private let waves: [Wave]

    init(seed: UInt64) {
        var s = seed
        func rnd() -> Double {
            s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(s >> 11) / Double(1 << 53)
        }
        waves = (0..<9).map { i in
            let f = 0.6 + Double(i) * 0.35, a = rnd() * 2 * .pi
            return Wave(kx: cos(a) * f, ky: sin(a) * f, phase: rnd() * 2 * .pi, amp: 1 / (1 + Double(i) * 0.45))
        }
    }

    func height(_ x: Double, _ y: Double) -> Double {
        var h = 0.0
        for w in waves { h += w.amp * sin(w.kx * x + w.ky * y + w.phase) }
        // A slow warp keeps the lines from reading as sine stripes.
        return h + 0.6 * sin(1.3 * sin(0.7 * x) + 0.9 * y)
    }

    func segments(width: Double, height: Double, scale: Double, levels: Int, cell: Double) -> [(CGPoint, CGPoint)] {
        guard width > 0, height > 0 else { return [] }
        let nx = Int(width / cell) + 2, ny = Int(height / cell) + 2
        var g = [Double](repeating: 0, count: nx * ny)
        var lo = Double.infinity, hi = -Double.infinity
        for j in 0..<ny {
            for i in 0..<nx {
                let v = self.height(Double(i) * cell / width * scale, Double(j) * cell / width * scale)
                g[j * nx + i] = v; lo = min(lo, v); hi = max(hi, v)
            }
        }
        var out: [(CGPoint, CGPoint)] = []
        for l in 1...levels {
            let t = lo + (hi - lo) * Double(l) / Double(levels + 1)
            for j in 0..<(ny - 1) {
                for i in 0..<(nx - 1) {
                    let a = g[j * nx + i], b = g[j * nx + i + 1], c = g[(j + 1) * nx + i + 1], d = g[(j + 1) * nx + i]
                    var pts: [CGPoint] = []
                    func edge(_ v1: Double, _ v2: Double, _ p1: (Double, Double), _ p2: (Double, Double)) {
                        guard (v1 < t) != (v2 < t) else { return }
                        let f = (t - v1) / (v2 - v1)
                        pts.append(CGPoint(x: (p1.0 + (p2.0 - p1.0) * f) * cell, y: (p1.1 + (p2.1 - p1.1) * f) * cell))
                    }
                    let x = Double(i), y = Double(j)
                    edge(a, b, (x, y), (x + 1, y)); edge(b, c, (x + 1, y), (x + 1, y + 1))
                    edge(c, d, (x + 1, y + 1), (x, y + 1)); edge(d, a, (x, y + 1), (x, y))
                    if pts.count == 2 {
                        out.append((pts[0], pts[1]))
                    } else if pts.count == 4 {
                        out.append((pts[0], pts[1])); out.append((pts[2], pts[3]))
                    }
                }
            }
        }
        return out
    }
}
