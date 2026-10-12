import Foundation

/// The invitation a challenge is shared with: what it asks, where to get the
/// app, and where to find the challenge once there. Plain text, because the
/// system share sheet sends it to Messages, Mail and social apps alike.
enum ChallengeShareMessage {
    static let appStoreURL = "https://apps.apple.com/app/id6794364736"

    /// `isMine` says "my" challenge for the one who created it, "the" for anyone
    /// else sharing it. `locale` picks mi or km and the number grouping, the
    /// same rule the detail screen uses; tests pass a fixed one.
    static func text(for challenge: WalkChallenge, isMine: Bool, locale: Locale = .current) -> String {
        let days = challenge.durationDays
        return """
        Join \(isMine ? "my" : "the") "\(challenge.title)" challenge on Wockett: \
        \(goal(for: challenge, locale: locale)) in \(days) day\(days == 1 ? "" : "s").

        Get Wockett: \(appStoreURL)
        Then open Community → Challenges to join.
        """
    }

    /// The goal in plain words, in the challenge's own activity: a run
    /// challenge says run, a ride says ride.
    static func goal(for challenge: WalkChallenge, locale: Locale) -> String {
        switch challenge.goalType {
        case .steps:
            return "\(challenge.goalSteps.formatted(.number.locale(locale))) steps"
        case .distance:
            let distance = challengeFormattedDistance(challenge.goalDistanceMeters, locale: locale)
            switch challenge.activityFilter {
            case "running": return "run \(distance)"
            case "walking": return "walk \(distance)"
            case "cycling": return "bike \(distance)"
            default:        return "cover \(distance)"
            }
        case .pace:
            let count = challenge.goalSessionCount
            let noun: String
            switch challenge.activityFilter {
            case "running": noun = "run"
            case "walking": noun = "walk"
            case "cycling": noun = "ride"
            default:        noun = "session"
            }
            let pace = challengeFormattedPace(challenge.goalPaceSecsPerKm, locale: locale)
            return "\(count) \(noun)\(count == 1 ? "" : "s") at \(pace) pace or faster"
        }
    }
}
