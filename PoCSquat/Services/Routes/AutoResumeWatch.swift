import Foundation

// MARK: - Auto-Resume Watch
//
// After an auto-pause, decides when the person is clearly moving again.
// Core Motion reports an activity only when it changes, so "walking for 30
// seconds" means the latest confident report has been the session's kind of
// motion since at least 30 seconds ago, checked on a timer.
//
// The watch has a deadline because it costs battery: the session keeps
// low-power location running while it watches, which is the only thing that
// keeps iOS from suspending Wockett, and a suspended app hears nothing from
// Core Motion. After the deadline the walk pauses fully, as a manual pause does.

struct AutoResumeWatch {
    static let movingNeeded: TimeInterval = 30
    static let window: TimeInterval = 30 * 60

    enum Decision: Equatable { case keepWatching, resume, giveUp }

    let mode: ActivityMode
    let pausedAt: Date
    private var movingSince: Date?

    init(mode: ActivityMode, pausedAt: Date) {
        self.mode = mode
        self.pausedAt = pausedAt
    }

    /// `confident` is Core Motion's latest high-confidence activity, or nil
    /// when the latest report was low or medium confidence.
    mutating func observe(_ confident: ActivityDetectionService.DetectedActivity?,
                          at now: Date) -> Decision {
        if counts(confident) {
            let since = movingSince ?? now
            movingSince = since
            if now.timeIntervalSince(since) >= Self.movingNeeded { return .resume }
        } else {
            movingSince = nil
        }
        return now.timeIntervalSince(pausedAt) >= Self.window ? .giveUp : .keepWatching
    }

    /// On foot for a walk or a run (a jog counts for a walk and a brisk walk
    /// for a run); only cycling for a ride, so pushing a bike doesn't resume it.
    private func counts(_ activity: ActivityDetectionService.DetectedActivity?) -> Bool {
        switch (mode, activity) {
        case (.walking, .walking), (.walking, .running),
             (.running, .walking), (.running, .running),
             (.cycling, .cycling):
            return true
        default:
            return false
        }
    }
}
