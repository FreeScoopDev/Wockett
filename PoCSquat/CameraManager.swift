import ARKit
import Combine
import SwiftUI

// MARK: - Workout Configuration

struct WorkoutConfig: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let color: Color
    let description: String

    // The three joints forming the angle to measure (A → vertex → C)
    let primaryJoint: String    // proximal side (hip / shoulder)
    let vertexJoint: String     // the bend point  (knee / elbow)
    let secondaryJoint: String  // distal side     (ankle / wrist)

    let downThreshold: Double   // angle below this = "down" rep position
    let upThreshold: Double     // angle above this = "up" / start position

    // Friendly name for the tracked bend (used in status messages)
    let vertexName: String

    // Ordered guidance steps: check each joint; show the first message whose joint is absent
    let guidanceJoints: [(joint: String, title: String, detail: String)]

    // Shown on the home card and as the initial setup card
    let setupInstructions: String

    static func == (lhs: WorkoutConfig, rhs: WorkoutConfig) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: Built-in workouts

    static let squats = WorkoutConfig(
        id: "squats",
        name: "Squats",
        icon: "figure.strengthtraining.traditional",
        color: .cyan,
        description: "Measure right knee angle\nto count squat reps",
        primaryJoint:   "right_upLeg_joint",
        vertexJoint:    "right_leg_joint",
        secondaryJoint: "right_foot_joint",
        downThreshold: 100,
        upThreshold:   160,
        vertexName: "right knee",
        guidanceJoints: [
            ("right_shoulder_1_joint", "Back Up",          "Step back until your shoulders are visible."),
            ("right_upLeg_joint",      "Back Up",          "Step back until your right hip is in frame."),
            ("right_leg_joint",        "Back Up More",     "Step back until your right knee is fully visible."),
            ("right_foot_joint",       "Almost There",     "Step back slightly so your right ankle is in frame."),
        ],
        setupInstructions: "Prop your phone at waist height, rear camera facing you, about 6–10 feet away. Stand so your right side is visible."
    )

    static let pushups = WorkoutConfig(
        id: "pushups",
        name: "Push-ups",
        icon: "figure.strengthtraining.functional",
        color: .orange,
        description: "Measure right elbow angle\nto count push-up reps",
        primaryJoint:   "right_arm_joint",
        vertexJoint:    "right_forearm_joint",
        secondaryJoint: "right_hand_joint",
        downThreshold:  90,
        upThreshold:   155,
        vertexName: "right elbow",
        guidanceJoints: [
            ("right_shoulder_1_joint", "Adjust Camera",  "Your upper body isn't visible. Make sure your right side faces the camera."),
            ("right_arm_joint",        "Show Shoulder",  "Your right shoulder isn't detected. Reposition so your right arm is visible."),
            ("right_forearm_joint",    "Show Elbow",     "Your right elbow isn't visible. Make sure your full arm is in frame."),
            ("right_hand_joint",       "Show Wrist",     "Your right wrist isn't visible. Extend your arm so the full length is in frame."),
        ],
        setupInstructions: "Place your phone on the floor to your right side, rear camera facing you. Get into push-up position so your whole body is visible in profile."
    )
}

// MARK: - AR Session Manager

@MainActor
final class ARSessionManager: NSObject, ObservableObject {
    let arSession = ARSession()
    let config: WorkoutConfig

    let isSupported = ARBodyTrackingConfiguration.isSupported

    @Published var isBodyDetected = false
    @Published var repCount = 0
    @Published var currentAngle: Double = 180
    @Published var jointPositions: [String: CGPoint] = [:]
    @Published var displayTransform: CGAffineTransform = .identity

    nonisolated(unsafe) var viewportSize: CGSize = CGSize(width: 393, height: 852)

    private var phase: SquatPhase = .up

    init(config: WorkoutConfig) {
        self.config = config
        super.init()
        arSession.delegate = self
    }

    func start() {
        guard ARBodyTrackingConfiguration.isSupported else {
            print("ARBodyTrackingConfiguration not supported on this device.")
            return
        }
        let cfg = ARBodyTrackingConfiguration()
        arSession.run(cfg)
    }

    func pause() { arSession.pause() }

    func reset() { repCount = 0; phase = .up }
}

// MARK: - ARSessionDelegate

extension ARSessionManager: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let tx = frame.displayTransform(for: .portrait, viewportSize: viewportSize)

        guard let body = frame.detectedBody else {
            DispatchQueue.main.async {
                self.isBodyDetected = false
                self.jointPositions = [:]
                self.displayTransform = tx
            }
            return
        }

        let skeleton = body.skeleton
        var points: [String: CGPoint] = [:]
        for name in skeleton.definition.jointNames {
            if let pos = skeleton.landmark(for: ARSkeleton.JointName(rawValue: name)) {
                points[name] = CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y))
            }
        }

        let pJoint = ARSkeleton.JointName(rawValue: config.primaryJoint)
        let vJoint = ARSkeleton.JointName(rawValue: config.vertexJoint)
        let sJoint = ARSkeleton.JointName(rawValue: config.secondaryJoint)

        if let p = skeleton.landmark(for: pJoint),
           let v = skeleton.landmark(for: vJoint),
           let s = skeleton.landmark(for: sJoint) {
            let angle = angleBetween(
                a:      CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)),
                vertex: CGPoint(x: CGFloat(v.x), y: CGFloat(v.y)),
                c:      CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))
            )
            DispatchQueue.main.async {
                self.isBodyDetected = true
                self.jointPositions = points
                self.displayTransform = tx
                self.currentAngle = angle
                self.updateRepState(angle: angle)
            }
        } else {
            DispatchQueue.main.async {
                self.isBodyDetected = false
                self.jointPositions = points
                self.displayTransform = tx
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        print("ARSession failed: \(error.localizedDescription)")
    }
}

// MARK: - Private helpers

private extension ARSessionManager {
    func updateRepState(angle: Double) {
        switch phase {
        case .up:   if angle < config.downThreshold { phase = .down }
        case .down: if angle > config.upThreshold   { phase = .up; repCount += 1 }
        }
    }

    nonisolated func angleBetween(a: CGPoint, vertex: CGPoint, c: CGPoint) -> Double {
        let v1 = CGVector(dx: a.x - vertex.x, dy: a.y - vertex.y)
        let v2 = CGVector(dx: c.x - vertex.x, dy: c.y - vertex.y)
        let dot  = v1.dx * v2.dx + v1.dy * v2.dy
        let mag1 = sqrt(v1.dx * v1.dx + v1.dy * v1.dy)
        let mag2 = sqrt(v2.dx * v2.dx + v2.dy * v2.dy)
        guard mag1 > 0, mag2 > 0 else { return 180 }
        return Double(acos(max(-1.0, min(1.0, dot / (mag1 * mag2))))) * 180 / .pi
    }
}

// Used by ARSessionManager — defined here to avoid a separate file
enum SquatPhase { case up, down }
