import Foundation
import MapKit

// MARK: - Activity summary content
//
// What a finished activity shows, decided in one place by its type: the
// summary (`ActivitySummaryView`), the history notes sheet and the share card
// all read these rules. Pure, so they are tested without a view. Until
// 2026-10-13 each screen chose for itself: rides showed a step count worked
// out from their distance, and an indoor share card showed a pace worked out
// from steps.

/// One figure on a summary.
enum SummaryStat: Equatable {
    case distance
    /// Indoor: steps at the app's 0.762 m stride, labelled as an estimate.
    case estimatedDistance
    case time
    case pace
    case speed
    case steps
    case cadence

    var label: String {
        switch self {
        case .distance:          return "Distance"
        case .estimatedDistance: return "Est. distance"
        case .time:              return "Time"
        case .pace:              return "Pace"
        case .speed:             return "Speed"
        case .steps:             return "Steps"
        case .cadence:           return "Cadence"
        }
    }

    var symbol: WktSymbol {
        switch self {
        case .distance, .estimatedDistance: return .distance
        case .time:                         return .time
        case .pace, .speed:                 return .pace
        case .steps:                        return .steps
        case .cadence:                      return .cadence
        }
    }

    /// `metric` picks km and min/km over miles and min/mi, as every pace does.
    func value(for session: WalkSession,
               metric: Bool = Locale.current.measurementSystem != .us) -> String {
        switch self {
        case .distance, .estimatedDistance:
            return session.distanceText
        case .time:
            return session.timeText
        case .pace, .speed:
            return session.paceOrSpeedText(metric: metric)
        case .steps:
            return session.estimatedSteps.formatted()
        case .cadence:
            guard session.elapsedTime > 0 else { return "—" }
            let perMinute = Double(session.estimatedSteps) / (session.elapsedTime / 60)
            return String(format: "%.0f spm", perMinute)
        }
    }
}

enum ActivitySummaryContent {

    static func mode(of session: WalkSession) -> ActivityMode {
        ActivityMode(rawValue: session.activityType) ?? .walking
    }

    /// A line to draw: two points or more. Indoor walks, manually added Past
    /// Walks and saved untracked walks have none, and get no map at all.
    static func hasRoute(_ session: WalkSession) -> Bool {
        session.waypoints.count >= 2
    }

    /// Whether an activity's steps are worth showing anywhere. A ride's are
    /// only distance / 0.762 m (the pedometer never runs on a ride), so a
    /// 14 km ride would "take" 18,000 steps.
    static func showsSteps(for mode: ActivityMode) -> Bool {
        mode != .cycling
    }

    static func showsSteps(_ session: WalkSession) -> Bool {
        showsSteps(for: mode(of: session))
    }

    /// The pace rule `WalkSession.paceOrSpeedText` already applies.
    private static func hasPace(_ session: WalkSession) -> Bool {
        session.totalDistance > 100 && session.elapsedTime > 0
    }

    /// The summary's tiles. A ride has no steps; indoor has no pace, because
    /// its distance is only steps times a stride.
    static func stats(for session: WalkSession) -> [SummaryStat] {
        switch mode(of: session) {
        case .stationary:
            var stats: [SummaryStat] = [.steps, .time]
            if session.elapsedTime > 0 { stats.append(.cadence) }
            stats.append(.estimatedDistance)
            return stats
        case .cycling:
            return [.distance, .time] + (hasPace(session) ? [.speed] : [])
        case .walking, .running:
            return [.distance, .time] + (hasPace(session) ? [.pace] : []) + [.steps]
        }
    }

    /// The share card's three columns, always three ("—" when a figure is missing).
    static func cardStats(for session: WalkSession) -> [SummaryStat] {
        switch mode(of: session) {
        case .stationary:         return [.steps, .time, .cadence]
        case .cycling:            return [.distance, .time, .speed]
        case .walking, .running:  return [.distance, .time, .pace]
        }
    }

    /// The caption that goes with a shared card, before the App Store link.
    static func shareCaption(for session: WalkSession) -> String {
        switch mode(of: session) {
        case .stationary:
            return "Just walked \(session.estimatedSteps.formatted()) steps indoors in \(session.timeText) on Wockett 🐾"
        case .cycling:
            return "Just rode \(session.distanceText) in \(session.timeText) on Wockett 🐾"
        case .running:
            return "Just ran \(session.distanceText) in \(session.timeText) on Wockett 🐾"
        case .walking:
            return "Just walked \(session.distanceText) in \(session.timeText) on Wockett 🐾"
        }
    }

    /// The records an activity set when it happened: against the activities
    /// of its type dated before it. What a summary opened from history shows.
    static func recordsSet(by session: WalkSession, in history: [WalkSession]) -> [PRType] {
        checkNewPRs(newSession: session, against: history.filter { $0.date < session.date })
    }
}
