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
    /// The latest report when Core Motion was confident about it, else nil.
    /// A session's auto-resume watches this.
    private(set) var confidentActivity: DetectedActivity?

    private let motionManager = CMMotionActivityManager()
    private var suggestionDismissedAt: Date?
    private let suggestionCooldown: TimeInterval = 3600  // don't re-suggest within 1 hour

    private init() {}

    /// Launch and returning to the foreground: starts only if the user already
    /// allowed Motion & Fitness. Starting updates is what shows iOS's prompt, and
    /// a prompt at launch for a Home banner was one of three a new user saw in
    /// the first seconds. A walk asks instead (`startDetection()`), where the
    /// vehicle check and auto-resume are what motion is for.
    func startDetectionIfAuthorized() {
        Task {
            guard await Self.authorizationStatus() == .authorized else { return }
            startDetection()
        }
    }

    /// Starts updates, asking for Motion & Fitness if it has never been asked.
    /// Call it only where the user has just started something that uses it.
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

    /// Settings' untracked-walk nudge: the background check reads Core Motion
    /// history and cannot prompt there, so turning the nudge on is the moment
    /// to ask. A one-minute history query shows the prompt if it has never
    /// been shown, and does nothing visible otherwise.
    func requestAccessIfNeverAsked() async {
        guard CMMotionActivityManager.isActivityAvailable(),
              await Self.authorizationStatus() == .notDetermined else { return }
        let now = Date()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            motionManager.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: .main) { _, _ in
                cont.resume()
            }
        }
    }

    /// `@concurrent` so the read runs off the main thread: it is a synchronous
    /// call to the system, like the CoreLocation and HealthKit reads that
    /// stalled the main thread on 2026-09-28.
    @concurrent
    private nonisolated static func authorizationStatus() async -> CMAuthorizationStatus {
        CMMotionActivityManager.authorizationStatus()
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
        confidentActivity = activity.confidence == .high ? detectedActivity : nil

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
