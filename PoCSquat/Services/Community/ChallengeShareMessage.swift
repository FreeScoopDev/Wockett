import Foundation

/// The invitation a challenge is shared with: what it asks, where to get the
/// app, and where to find the challenge once there. Plain text, because the
/// system share sheet sends it to Messages, Mail and social apps alike.
enum ChallengeShareMessage {
    /// Says "my" challenge to the one who created it (`moderation.isMine`), "the"
    /// to anyone else sharing it. `locale` picks mi or km and the number
    /// grouping, the same rule the detail screen uses; tests pass fixed ones.
    static func text(for challenge: WalkChallenge,
                     moderation: CommunityModerationStore = .shared,
                     locale: Locale = .current) -> String {
        let isMine = moderation.isMine(challenge.author)
        let days = challenge.durationDays
        return """
        Join \(isMine ? "my" : "the") "\(challenge.title)" challenge on Wockett: \
        \(goal(for: challenge, locale: locale)) in \(days) day\(days == 1 ? "" : "s").

        Get Wockett: \(AppStoreLink.page)
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
            // The activity's own noun (run, walk, ride); "session" when any counts.
            let noun = challenge.activityFilter.flatMap(ActivityMode.init(rawValue:))?.noun ?? "session"
            let pace = challengeFormattedPace(challenge.goalPaceSecsPerKm, locale: locale)
            return "\(count) \(noun)\(count == 1 ? "" : "s") at \(pace) pace or faster"
        }
    }
}
