import ARKit
import Combine
import SwiftUI

enum SquatPhase { case up, down }

/// Manages the ARKit session for body tracking and squat counting.
/// ARBodyTrackingConfiguration uses the rear camera and requires A12 Bionic or later.
@MainActor
final class ARSessionManager: NSObject, ObservableObject {
    let arSession = ARSession()

    let isSupported = ARBodyTrackingConfiguration.isSupported

    @Published var isBodyDetected = false
    @Published var repCount = 0
    @Published var currentKneeAngle: Double = 180

    /// Joint positions in normalized camera-image coordinates (0,0 = top-left).
    /// Apply `displayTransform` then scale to view size to get screen points.
    @Published var jointPositions: [String: CGPoint] = [:]

    /// Affine transform from normalized image space → normalized display space.
    /// Updated every frame by the ARSession delegate.
    @Published var displayTransform: CGAffineTransform = .identity

    /// Set by ContentView via GeometryReader so displayTransform uses the correct aspect ratio.
    nonisolated(unsafe) var viewportSize: CGSize = CGSize(width: 393, height: 852)

    private var phase: SquatPhase = .up
    private let downThreshold = 100.0
    private let upThreshold = 160.0

    override init() {
        super.init()
        arSession.delegate = self
    }

    func start() {
        guard ARBodyTrackingConfiguration.isSupported else {
            print("ARBodyTrackingConfiguration not supported on this device.")
            return
        }
        let config = ARBodyTrackingConfiguration()
        arSession.run(config)
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

        // Build full joint map for skeleton overlay
        let skeleton = body.skeleton
        var points: [String: CGPoint] = [:]
        for name in skeleton.definition.jointNames {
            if let pos = skeleton.landmark(for: ARSkeleton.JointName(rawValue: name)) {
                points[name] = CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y))
            }
        }

        // Squat tracking uses right leg: upLeg (hip), leg (knee), foot (ankle)
        if let hip   = skeleton.landmark(for: ARSkeleton.JointName(rawValue: "right_upLeg_joint")),
           let knee  = skeleton.landmark(for: ARSkeleton.JointName(rawValue: "right_leg_joint")),
           let ankle = skeleton.landmark(for: ARSkeleton.JointName(rawValue: "right_foot_joint")) {
            let angle = angleBetween(
                a:      CGPoint(x: CGFloat(hip.x),   y: CGFloat(hip.y)),
                vertex: CGPoint(x: CGFloat(knee.x),  y: CGFloat(knee.y)),
                c:      CGPoint(x: CGFloat(ankle.x), y: CGFloat(ankle.y))
            )
            DispatchQueue.main.async {
                self.isBodyDetected = true
                self.jointPositions = points
                self.displayTransform = tx
                self.currentKneeAngle = angle
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
        case .up:   if angle < downThreshold { phase = .down }
        case .down: if angle > upThreshold   { phase = .up; repCount += 1 }
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
