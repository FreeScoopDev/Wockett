import CoreLocation
import Foundation

// MARK: - What the Community hub shows
//
// The hub became a dashboard on 2026-09-26 (option "A+" of the Community tab
// mockups Joe chose): a You card, your challenge with your rank and the
// person just ahead, the next badge, your crew's week, the latest community
// posts, the top community routes by wocketts, and official trails nearby.
// The decisions it makes about that data live here, as plain functions, so
// they are tested without CloudKit, HealthKit or a view.

enum CommunityHubSummary {

    // MARK: Badges

    struct BadgeProgress {
        let badge: WalkBadge
        let progress: Double
    }

    /// Sessions badges are judged on: a walk flagged as possibly driven does
    /// not count. The Badges screen already did this and the hub did not, so
    /// the two could show different "badges earned" counts.
    static func badgeSessions(_ sessions: [WalkSession]) -> [WalkSession] {
        sessions.filter { !$0.flaggedPossibleVehicle }
    }

    static func earnedCount(_ badges: [WalkBadge], sessions: [WalkSession], currentStreak: Int) -> Int {
        let clean = badgeSessions(sessions)
        return badges.filter { $0.isEarned(sessions: clean, currentStreak: currentStreak) }.count
    }

    /// Unearned badges closest to done, most progress first; `limit` of them.
    /// Badges with no progress yet come after any with some, in catalogue order.
    static func nextBadges(_ badges: [WalkBadge], sessions: [WalkSession], currentStreak: Int,
                           limit: Int = 3) -> [BadgeProgress] {
        let clean = badgeSessions(sessions)
        let open = badges.enumerated().compactMap { index, badge -> (Int, BadgeProgress)? in
            guard !badge.isEarned(sessions: clean, currentStreak: currentStreak) else { return nil }
            return (index, BadgeProgress(badge: badge, progress: badge.progress(sessions: clean, currentStreak: currentStreak)))
        }
        return open
            .sorted { $0.1.progress != $1.1.progress ? $0.1.progress > $1.1.progress : $0.0 < $1.0 }
            .prefix(limit)
            .map(\.1)
    }

    // MARK: Challenge standing

    struct Standing: Equatable {
        /// 1-based place among everyone on the leaderboard, you included.
        let rank: Int
        let total: Int
        /// The person one place above you, and how far you are behind them.
        let aheadName: String?
        let gapToAhead: Int?
    }

    /// Your place in a challenge from its leaderboard and your live progress,
    /// which can be ahead of what the leaderboard last stored for you.
    static func standing(leaderboard: [(name: String, value: Int, isYou: Bool)], yourValue: Int) -> Standing {
        let others = leaderboard.filter { !$0.isYou }
        let ahead = others.filter { $0.value > yourValue }.sorted { $0.value < $1.value }
        let rank = ahead.count + 1
        let closest = ahead.first
        return Standing(rank: rank, total: others.count + 1,
                        aheadName: closest?.name, gapToAhead: closest.map { $0.value - yourValue })
    }

    /// The friendly push under your challenge: roughly how long a walk takes
    /// you past the person ahead. Nil when there is no one ahead.
    static func nudge(goal: ChallengeGoalType, gap: Int?, aheadName: String?, rank: Int, activity: String?) -> String? {
        guard let gap, gap >= 0, let aheadName else { return nil }
        let place = rank - 1
        switch goal {
        case .steps:
            // ~100 steps a minute at an easy walk.
            return "A \(walkMinutes(Double(gap + 1) / 100))-minute walk puts you past \(aheadName) into #\(place)."
        case .distance:
            // ~80 m a minute at an easy walk.
            return "A \(walkMinutes(Double(gap + 1) / 80))-minute walk puts you past \(aheadName) into #\(place)."
        case .pace:
            let noun = activity == "running" ? "run" : "session"
            let needed = gap + 1
            return "\(needed) more qualifying \(noun)\(needed == 1 ? "" : "s") puts you past \(aheadName) into #\(place)."
        }
    }

    /// Minutes rounded up to 5, at least 5: "a 40-minute walk", never "a 37".
    static func walkMinutes(_ minutes: Double) -> Int {
        max(5, Int((minutes / 5).rounded(.up)) * 5)
    }

    // MARK: Crew

    struct CrewWeek: Identifiable {
        let id: UUID
        let name: String
        let walks: Int
        let meters: Double
        /// Metres walked on each of the last 7 days, oldest first, today last.
        let daily: [Double]
    }

    /// Each pet's last 7 days (today and the 6 before it), in `pets` order.
    static func crewWeek(pets: [(id: UUID, name: String)], sessions: [WalkSession],
                         now: Date = Date(), calendar: Calendar = .current) -> [CrewWeek] {
        let today = calendar.startOfDay(for: now)
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0 - 6, to: today) }
        guard let first = days.first else { return [] }
        let week = sessions.filter { $0.date >= first && $0.date <= now }
        return pets.map { pet in
            let theirs = week.filter { PetStore.participated(pet.id, in: $0) }
            let daily = days.map { day in
                theirs.filter { calendar.isDate($0.date, inSameDayAs: day) }
                    .reduce(0) { $0 + PetStore.walkedMeters(pet.id, in: $1) }
            }
            return CrewWeek(id: pet.id, name: pet.name, walks: theirs.count,
                            meters: daily.reduce(0, +), daily: daily)
        }
    }

    /// Walks in the last 7 days that two or more of your pets were on.
    static func walksTogether(petIDs: [UUID], sessions: [WalkSession], now: Date = Date(),
                              calendar: Calendar = .current) -> Int {
        guard petIDs.count >= 2,
              let first = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) else { return 0 }
        return sessions.filter { session in
            session.date >= first && session.date <= now
                && petIDs.filter { PetStore.participated($0, in: session) }.count >= 2
        }.count
    }

    // MARK: Routes

    /// A route starting this close counts as near you: a short drive.
    static let nearbyRouteMeters = 40_000.0   // 25 mi

    /// Community routes ranked by wocketts, those starting near you first
    /// (Joe, 2026-09-26: the plain top list opened on routes 168 mi away).
    /// Routes further off, or all of them when your location is unknown,
    /// follow in the same order, so the row is never empty for being remote.
    static func topRoutes(_ routes: [SharedRoute], near location: CLLocation? = nil,
                          limit: Int = 5) -> [SharedRoute] {
        let ranked = routes.sorted {
            $0.wocketts != $1.wocketts ? $0.wocketts > $1.wocketts : $0.createdAt > $1.createdAt
        }
        let nearby = ranked.filter {
            (distanceToStart(of: $0, from: location) ?? .infinity) <= nearbyRouteMeters
        }
        let rest = ranked.filter { route in !nearby.contains { $0.id == route.id } }
        return Array((nearby + rest).prefix(limit))
    }

    /// Metres from `location` to a route's start, or nil without either.
    static func distanceToStart(of route: SharedRoute, from location: CLLocation?) -> Double? {
        guard let location, let start = route.waypoints.first else { return nil }
        return location.distance(from: CLLocation(latitude: start.latitude, longitude: start.longitude))
    }

    // MARK: Names

    /// "SwiftFern" → "SF"; "nala" → "NA". For the round avatars.
    static func initials(_ name: String) -> String {
        let capitals = name.filter(\.isUppercase)
        if capitals.count >= 2 { return String(capitals.prefix(2)) }
        return String(name.prefix(2)).uppercased()
    }
}
