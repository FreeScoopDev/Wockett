import CoreMotion
import SwiftUI

// MARK: - ActivityDetectionService
//
// Uses CMMotionActivityManager to detect when the user starts walking or cycling.
// Publishes a `detectedActivity` that the home screen can use to show a
// "Looks like you're walking — want to track it?" prompt.

@MainActor
@Observable
final class ActivityDetectionService {
    static let shared = ActivityDetectionService()

    enum DetectedActivity: Equatable {
        case unknown
        case walking
        case cycling
        case running
        case stationary
    }

    var detectedActivity: DetectedActivity = .unknown
    var showWalkSuggestion: Bool = false
    var isAutomotiveHighConfidence: Bool = false

    private let motionManager = CMMotionActivityManager()
    private var suggestionDismissedAt: Date?
    private let suggestionCooldown: TimeInterval = 3600  // don't re-suggest within 1 hour

    private init() {}

    func startDetection() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity, let self else { return }
            Task { @MainActor [weak self] in
                self?.handleActivity(activity)
            }
        }
    }

    func stopDetection() {
        motionManager.stopActivityUpdates()
    }

    func dismissSuggestion() {
        showWalkSuggestion = false
        suggestionDismissedAt = Date()
    }

    // MARK: - Private

    private func handleActivity(_ activity: CMMotionActivity) {
        if activity.walking {
            detectedActivity = .walking
        } else if activity.cycling {
            detectedActivity = .cycling
        } else if activity.running {
            detectedActivity = .running
        } else if activity.stationary {
            detectedActivity = .stationary
        } else {
            detectedActivity = .unknown
        }

        isAutomotiveHighConfidence = activity.automotive && activity.confidence == .high

        // Only suggest tracking if: user is walking/cycling, high confidence,
        // and not within the cooldown window
        guard activity.confidence == .high,
              (activity.walking || activity.cycling || activity.running) else { return }

        if let dismissed = suggestionDismissedAt,
           Date().timeIntervalSince(dismissed) < suggestionCooldown { return }

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            showWalkSuggestion = true
        }
    }
}
