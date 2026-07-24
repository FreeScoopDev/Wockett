import SwiftUI
import ARKit

// MARK: - Workout Session View

struct WorkoutSessionView: View {
    let config: WorkoutConfig
    @StateObject private var arManager: ARSessionManager

    init(config: WorkoutConfig) {
        self.config = config
        _arManager = StateObject(wrappedValue: ARSessionManager(config: config))
    }

    var body: some View {
        ZStack {
            ARCameraView(session: arManager.arSession)
                .ignoresSafeArea()
                .background(
                    GeometryReader { geo in
                        Color.clear.onAppear { arManager.viewportSize = geo.size }
                    }
                )

            if !arManager.jointPositions.isEmpty {
                SkeletonOverlay(
                    points: arManager.jointPositions,
                    displayTransform: arManager.displayTransform,
                    highlightJoints: [config.primaryJoint, config.vertexJoint, config.secondaryJoint],
                    highlightColor: config.color
                )
                .ignoresSafeArea()
            }

            VStack {
                if let guide = positioningGuide {
                    PositioningCard(title: guide.title, detail: guide.detail, color: config.color)
                        .padding(.top, 60)
                        .padding(.horizontal)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()

                VStack(spacing: 8) {
                    Text("\(arManager.repCount)")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    if arManager.isBodyDetected {
                        HStack(spacing: 6) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text("Tracking").foregroundColor(.green)
                        }
                        Text("\(config.vertexName.capitalized) angle: \(Int(arManager.currentAngle))°")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    } else {
                        Text(statusText).foregroundColor(.yellow)
                    }
                }
                .padding()
                .background(.black.opacity(0.5))
                .cornerRadius(16)
                .padding(.bottom, 40)

                Button("Reset") { arManager.reset() }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(.white)
                    .cornerRadius(12)
                    .padding(.bottom, 20)
            }
            .animation(.easeInOut(duration: 0.3), value: arManager.isBodyDetected)
        }
        .navigationTitle(config.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear  { arManager.start() }
        .onDisappear { arManager.pause() }
    }

    // MARK: - Guidance helpers

    private func displayPos(_ name: String) -> CGPoint? {
        guard let p = arManager.jointPositions[name] else { return nil }
        return p.applying(arManager.displayTransform)
    }

    private var statusText: String {
        if !arManager.isSupported { return "Body tracking not supported on this device" }
        if arManager.jointPositions.isEmpty { return "Step into frame" }
        for (joint, _, _) in config.guidanceJoints {
            if arManager.jointPositions[joint] == nil {
                return "Show your \(joint.replacingOccurrences(of: "_joint", with: "").replacingOccurrences(of: "_", with: " "))"
            }
        }
        return "Almost there…"
    }

    private var positioningGuide: (title: String, detail: String)? {
        guard !arManager.isBodyDetected, arManager.isSupported else { return nil }
        let pts = arManager.jointPositions

        // ── No joints at all ────────────────────────────────────────────────
        if pts.isEmpty {
            return ("Set Up", config.setupInstructions)
        }

        // ── Distance / framing checks (display-space Y coords) ───────────────
        let headY       = displayPos("head_joint")?.y
        let rightAnkleY = displayPos("right_foot_joint")?.y
        let leftAnkleY  = displayPos("left_foot_joint")?.y
        let ankleY      = rightAnkleY ?? leftAnkleY

        if let hy = headY, let ay = ankleY {
            if hy < 0.08 && ay > 0.90 {
                return ("Too Close",
                        "Your whole body is filling the screen. Move back a few steps so there's space above and below.")
            }
            if (ay - hy) < 0.25 {
                return ("Too Far",
                        "You're quite far from the camera. Move a few steps closer so your body fills more of the frame.")
            }
        }

        // ── Horizontal centering ─────────────────────────────────────────────
        let xs = [displayPos("right_shoulder_1_joint")?.x,
                  displayPos("left_shoulder_1_joint")?.x,
                  displayPos("right_upLeg_joint")?.x,
                  displayPos("left_upLeg_joint")?.x].compactMap { $0 }
        if !xs.isEmpty {
            let midX = xs.reduce(0, +) / Double(xs.count)
            if midX < 0.30 {
                return ("Off to the Side", "Your body is near the left edge. Shift sideways to center yourself.")
            } else if midX > 0.70 {
                return ("Off to the Side", "Your body is near the right edge. Shift sideways to center yourself.")
            }
        }

        // ── Workout-specific joint visibility chain ───────────────────────────
        for (joint, title, detail) in config.guidanceJoints {
            if pts[joint] == nil { return (title, detail) }
        }

        // All defined joints visible but angle tracking still not locked
        return ("Adjust Angle",
                "All joints are visible. Make sure your \(config.vertexName) is clearly in frame and try standing sideways.")
    }
}

// MARK: - Skeleton Overlay

struct SkeletonOverlay: View {
    let points: [String: CGPoint]
    let displayTransform: CGAffineTransform
    let highlightJoints: Set<String>
    let highlightColor: Color

    private let connections: [(String, String)] = [
        ("head_joint",             "neck_1_joint"),
        ("neck_1_joint",           "right_shoulder_1_joint"),
        ("neck_1_joint",           "left_shoulder_1_joint"),
        ("right_shoulder_1_joint", "right_arm_joint"),
        ("right_arm_joint",        "right_forearm_joint"),
        ("right_forearm_joint",    "right_hand_joint"),
        ("left_shoulder_1_joint",  "left_arm_joint"),
        ("left_arm_joint",         "left_forearm_joint"),
        ("neck_1_joint",           "hips_joint"),
        ("hips_joint",             "right_upLeg_joint"),
        ("hips_joint",             "left_upLeg_joint"),
        ("right_upLeg_joint",      "right_leg_joint"),
        ("right_leg_joint",        "right_foot_joint"),
        ("left_upLeg_joint",       "left_leg_joint"),
        ("left_leg_joint",         "left_foot_joint"),
    ]

    var body: some View {
        Canvas { context, size in
            for (from, to) in connections {
                guard let a = points[from], let b = points[to] else { continue }
                var path = Path()
                path.move(to: screen(a, size))
                path.addLine(to: screen(b, size))
                let isHighlighted = highlightJoints.contains(from) || highlightJoints.contains(to)
                context.stroke(path,
                               with: .color(isHighlighted ? highlightColor.opacity(0.95) : .green.opacity(0.7)),
                               lineWidth: isHighlighted ? 4 : 2.5)
            }
            for (name, pt) in points {
                let s = screen(pt, size)
                if highlightJoints.contains(name) {
                    context.fill(Path(ellipseIn:   CGRect(x: s.x-9, y: s.y-9, width: 18, height: 18)), with: .color(highlightColor))
                    context.stroke(Path(ellipseIn: CGRect(x: s.x-9, y: s.y-9, width: 18, height: 18)), with: .color(.white), lineWidth: 2)
                } else {
                    context.fill(Path(ellipseIn: CGRect(x: s.x-5, y: s.y-5, width: 10, height: 10)), with: .color(.white.opacity(0.7)))
                }
            }
        }
    }

    private func screen(_ imagePoint: CGPoint, _ size: CGSize) -> CGPoint {
        let d = imagePoint.applying(displayTransform)
        return CGPoint(x: d.x * size.width, y: d.y * size.height)
    }
}

// MARK: - Positioning Card

struct PositioningCard: View {
    let title: String
    let detail: String
    var color: Color = .white

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .background(.black.opacity(0.65))
        .cornerRadius(14)
    }
}
