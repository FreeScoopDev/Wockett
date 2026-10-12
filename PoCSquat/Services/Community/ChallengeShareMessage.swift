import Foundation

/// The invitation a challenge is shared with: what it asks, and its link,
/// which opens the challenge in Wockett or, without the app, a page with a
/// Get Wockett button (ChallengeLink). Plain text, because the system share
/// sheet sends it to Messages, Mail and social apps alike.
enum ChallengeShareMessage {
    /// Says "my" challenge to the one who created it (`moderation.isMine`), "the"
    /// to anyone else sharing it. `locale` picks mi or km and the number
    /// grouping, the same rule the detail screen uses; tests pass fixed ones.
    static func text(for challenge: WalkChallenge,
                     moderation: CommunityModerationStore = .shared,
                     locale: Locale = .current) -> String {
        let isMine = moderation.isMine(challenge.author)
        let days = challenge.durationDays
        let invitation = """
        Join \(isMine ? "my" : "the") "\(challenge.title)" challenge on Wockett: \
        \(goal(for: challenge, locale: locale)) in \(days) day\(days == 1 ? "" : "s").
        """
        // The link on a line of its own, with nothing after it: Messages would
        // fold trailing punctuation into the link.
        if let link = ChallengeLink.url(for: challenge.id.recordName) {
            return "\(invitation)\n\n\(link.absoluteString)"
        }
        // A record name no link can carry (none so far): Step 1's directions.
        return """
        \(invitation)

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
