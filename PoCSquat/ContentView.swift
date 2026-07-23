import SwiftUI
import ARKit

struct ContentView: View {
    @StateObject private var arManager = ARSessionManager()

    var body: some View {
        ZStack {
            ARCameraView(session: arManager.arSession)
                .ignoresSafeArea()
                .background(
                    // Capture view size so displayTransform uses the correct aspect ratio
                    GeometryReader { geo in
                        Color.clear.onAppear {
                            arManager.viewportSize = geo.size
                        }
                    }
                )

            if !arManager.jointPositions.isEmpty {
                SkeletonOverlay(
                    points: arManager.jointPositions,
                    displayTransform: arManager.displayTransform
                )
                .ignoresSafeArea()
            }

            VStack {
                if let guide = positioningGuide {
                    PositioningCard(title: guide.title, detail: guide.detail)
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
                        Text("Knee angle: \(Int(arManager.currentKneeAngle))°")
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
                    .padding()
                    .background(.white)
                    .cornerRadius(12)
                    .padding(.bottom, 20)
            }
            .animation(.easeInOut(duration: 0.3), value: arManager.isBodyDetected)
        }
        .onAppear { arManager.start() }
        .onDisappear { arManager.pause() }
    }

    // Convert a joint from camera-image space to normalized display space (0,0 = top-left).
    private func displayPos(_ name: String) -> CGPoint? {
        guard let p = arManager.jointPositions[name] else { return nil }
        return p.applying(arManager.displayTransform)
    }

    private var statusText: String {
        if !arManager.isSupported { return "Body tracking not supported on this device" }
        if arManager.jointPositions.isEmpty { return "Step into frame" }
        if arManager.jointPositions["right_upLeg_joint"] == nil { return "Show your right hip" }
        if arManager.jointPositions["right_leg_joint"]   == nil { return "Show your right knee" }
        if arManager.jointPositions["right_foot_joint"]  == nil { return "Show your right ankle" }
        return "Almost there…"
    }

    private var positioningGuide: (title: String, detail: String)? {
        guard !arManager.isBodyDetected else { return nil }
        guard arManager.isSupported else { return nil }

        let pts = arManager.jointPositions

        // ── 1. No joints at all ──────────────────────────────────────────────
        if pts.isEmpty {
            return ("Set Up",
                    "Prop your phone on a low surface (waist height or lower), rear camera facing you. Step back about 6–10 feet until your full body fits in frame.")
        }

        // ── 2. Distance checks using display-space positions ─────────────────
        let headY       = displayPos("head_joint")?.y
        let rightAnkleY = displayPos("right_foot_joint")?.y
        let leftAnkleY  = displayPos("left_foot_joint")?.y
        let ankleY      = rightAnkleY ?? leftAnkleY

        // Too close: head near top AND feet near bottom simultaneously
        if let hy = headY, let ay = ankleY, hy < 0.08, ay > 0.90 {
            return ("Too Close",
                    "Your whole body is filling the screen. Move back a few steps so there's space above your head and below your feet.")
        }

        // Too far: all joints present but body occupies less than a quarter of the screen height
        if let hy = headY, let ay = ankleY, (ay - hy) < 0.25 {
            return ("Too Far",
                    "You're quite far from the camera. Move a few steps closer so your body fills more of the frame.")
        }

        // ── 3. Horizontal centering ───────────────────────────────────────────
        let xs = [displayPos("right_shoulder_1_joint")?.x,
                  displayPos("left_shoulder_1_joint")?.x,
                  displayPos("right_upLeg_joint")?.x,
                  displayPos("left_upLeg_joint")?.x].compactMap { $0 }
        if !xs.isEmpty {
            let midX = xs.reduce(0, +) / Double(xs.count)
            if midX < 0.30 {
                return ("Off to the Side",
                        "Your body is near the left edge of the frame. Shift sideways to center yourself.")
            } else if midX > 0.70 {
                return ("Off to the Side",
                        "Your body is near the right edge of the frame. Shift sideways to center yourself.")
            }
        }

        // ── 4. Joint visibility — guide from top to bottom ───────────────────
        let hasShoulders  = pts["right_shoulder_1_joint"] != nil || pts["left_shoulder_1_joint"] != nil
        let hasHips       = pts["right_upLeg_joint"]      != nil || pts["left_upLeg_joint"]      != nil
        let hasKnees      = pts["right_leg_joint"]        != nil || pts["left_leg_joint"]        != nil
        let hasAnkles     = pts["right_foot_joint"]       != nil || pts["left_foot_joint"]       != nil
        let hasRightHip   = pts["right_upLeg_joint"]      != nil
        let hasRightKnee  = pts["right_leg_joint"]        != nil
        let hasRightAnkle = pts["right_foot_joint"]       != nil
        let hasLeftHip    = pts["left_upLeg_joint"]       != nil
        let hasLeftKnee   = pts["left_leg_joint"]         != nil

        if !hasShoulders {
            return ("Back Up",
                    "Your upper body isn't visible yet. Keep stepping back until your shoulders appear in frame.")
        }
        if !hasHips {
            return ("Back Up",
                    "Your lower body is cut off. Step back until your hips come into view.")
        }
        if !hasKnees {
            return ("Back Up More",
                    "Your knees aren't visible. Step back until your full leg appears in the frame.")
        }
        if !hasAnkles {
            return ("Back Up Slightly",
                    "Your feet are cut off. Take a small step back so your ankles are visible.")
        }

        // ── 5. Right-side orientation ─────────────────────────────────────────
        // Tracking requires right hip → knee → ankle. If only left-side joints are
        // visible, the person is likely showing their left side to the camera.
        if hasLeftHip, hasLeftKnee, !hasRightHip, !hasRightKnee {
            return ("Turn Around",
                    "Your left side is facing the camera. Turn so your right side faces the camera instead — tracking uses your right hip, knee, and ankle.")
        }
        if !hasRightHip {
            return ("Show Right Hip",
                    "Your right hip isn't detected. Turn slightly so your right side is more visible.")
        }
        if !hasRightKnee {
            return ("Show Right Knee",
                    "Your right knee isn't visible. Angle your body so your right side faces the camera.")
        }
        if !hasRightAnkle {
            return ("Show Right Ankle",
                    "Your right ankle isn't visible. Turn slightly and make sure nothing is blocking your lower right leg.")
        }

        return ("Almost Ready",
                "All key joints are in view. Stand straight and make sure your right hip, knee, and ankle are clearly visible.")
    }
}

// MARK: - Skeleton Overlay

struct SkeletonOverlay: View {
    let points: [String: CGPoint]
    let displayTransform: CGAffineTransform

    // Joint name pairs for skeleton lines (from ARKit's body hierarchy)
    private let connections: [(String, String)] = [
        ("head_joint",             "neck_1_joint"),
        ("neck_1_joint",           "right_shoulder_1_joint"),
        ("neck_1_joint",           "left_shoulder_1_joint"),
        ("right_shoulder_1_joint", "right_arm_joint"),
        ("right_arm_joint",        "right_forearm_joint"),
        ("left_shoulder_1_joint",  "left_arm_joint"),
        ("left_arm_joint",         "left_forearm_joint"),
        // Spine approximation: neck to hips
        ("neck_1_joint",           "hips_joint"),
        ("hips_joint",             "right_upLeg_joint"),
        ("hips_joint",             "left_upLeg_joint"),
        // Right leg
        ("right_upLeg_joint",      "right_leg_joint"),
        ("right_leg_joint",        "right_foot_joint"),
        // Left leg
        ("left_upLeg_joint",       "left_leg_joint"),
        ("left_leg_joint",         "left_foot_joint"),
    ]

    private let squatJoints: Set<String> = [
        "right_upLeg_joint", "right_leg_joint", "right_foot_joint"
    ]

    var body: some View {
        Canvas { context, size in
            for (from, to) in connections {
                guard let a = points[from], let b = points[to] else { continue }
                var path = Path()
                path.move(to: screen(a, size))
                path.addLine(to: screen(b, size))
                context.stroke(path, with: .color(.green.opacity(0.9)), lineWidth: 3)
            }
            for (name, pt) in points {
                let s = screen(pt, size)
                if squatJoints.contains(name) {
                    context.fill(Path(ellipseIn:   CGRect(x: s.x-9, y: s.y-9, width: 18, height: 18)), with: .color(.cyan))
                    context.stroke(Path(ellipseIn: CGRect(x: s.x-9, y: s.y-9, width: 18, height: 18)), with: .color(.white), lineWidth: 2)
                } else {
                    context.fill(Path(ellipseIn: CGRect(x: s.x-5, y: s.y-5, width: 10, height: 10)), with: .color(.yellow))
                }
            }
        }
    }

    private func screen(_ imagePoint: CGPoint, _ size: CGSize) -> CGPoint {
        // displayTransform converts normalized camera-image coords → normalized display coords
        let d = imagePoint.applying(displayTransform)
        return CGPoint(x: d.x * size.width, y: d.y * size.height)
    }
}

// MARK: - Positioning Card

struct PositioningCard: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundColor(.white)
            Text(detail).font(.subheadline).foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(.black.opacity(0.6))
        .cornerRadius(14)
    }
}
