import Foundation
import WidgetKit

// MARK: - Badge Type

enum WalkBadgeType: Equatable {
    // Existing
    case distance(km: Double)
    case streak(days: Int)
    case earlyBird
    case nightOwl
    case badgeCount(n: Int)
    // Rides
    case rideKm(km: Double)
    case rideStreak(days: Int)
    case crossTrainDay
    // Pets
    case petWalks(n: Int)
    case multiPetWalk
    // Explorer
    case communityRoutesCompleted(n: Int)
    case routesBookmarked(n: Int)
    case customRouteCreated
    case customRouteShared
    // Consistency
    case indoorWalks(n: Int)
    // Collection & Journaling
    case walkNotesAdded(n: Int)
    case manualEntries(n: Int)
    case wockettsGiven(n: Int)
    case wockettsReceived(n: Int)
    // Social
    case challengeShared
}

// MARK: - Badge Model

struct WalkBadge: Identifiable {
    let id: String
    let name: String
    let description: String
    let emoji: String
    let type: WalkBadgeType

    func isEarned(sessions: [WalkSession], currentStreak: Int) -> Bool {
        switch type {
        case .distance(let km):
            return totalWalkKm(from: sessions) >= km
        case .streak(let days):
            return currentStreak >= days
        case .earlyBird:
            return sessions.contains { Calendar.current.component(.hour, from: $0.date) < 8 }
        case .nightOwl:
            return sessions.contains { Calendar.current.component(.hour, from: $0.date) >= 20 }
        case .badgeCount(let n):
            let others = walkBadges.filter { $0.id != id }
            return others.filter { $0.isEarned(sessions: sessions, currentStreak: currentStreak) }.count >= n
        case .rideKm(let km):
            return totalRideKm(from: sessions) >= km
        case .rideStreak(let days):
            return rideStreak(from: sessions) >= days
        case .crossTrainDay:
            return hasCrossTrainDay(in: sessions)
        case .petWalks(let n):
            return sessions.filter { !$0.activePetIds.isEmpty }.count >= n
        case .multiPetWalk:
            return sessions.contains { $0.activePetIds.count >= 2 }
        case .communityRoutesCompleted(let n):
            return sessions.filter { $0.isCommunityRoute }.count >= n
        case .routesBookmarked(let n):
            return UserDefaults.standard.integer(forKey: "wkt_routesBookmarked_count") >= n
        case .customRouteCreated:
            return UserDefaults.standard.bool(forKey: "wkt_customRouteCreated")
        case .customRouteShared:
            return UserDefaults.standard.bool(forKey: "wkt_customRouteShared")
        case .indoorWalks(let n):
            return sessions.filter { $0.activityType == ActivityMode.stationary.rawValue }.count >= n
        case .walkNotesAdded(let n):
            return sessions.filter { !$0.notes.isEmpty }.count >= n
        case .manualEntries(let n):
            return UserDefaults.standard.integer(forKey: "wkt_manualEntries_count") >= n
        case .wockettsGiven(let n):
            return (UserDefaults.standard.stringArray(forKey: "communityVotedRoutes") ?? []).count >= n
        case .wockettsReceived(let n):
            return UserDefaults.standard.integer(forKey: "wkt_wocketts_received") >= n
        case .challengeShared:
            return UserDefaults.standard.bool(forKey: "wkt_challengeShared")
        }
    }

    func progress(sessions: [WalkSession], currentStreak: Int) -> Double {
        switch type {
        case .distance(let km):
            return min(1.0, totalWalkKm(from: sessions) / max(1, km))
        case .streak(let days):
            return min(1.0, Double(currentStreak) / Double(max(1, days)))
        case .earlyBird, .nightOwl, .crossTrainDay, .multiPetWalk,
             .customRouteCreated, .customRouteShared, .challengeShared:
            return isEarned(sessions: sessions, currentStreak: currentStreak) ? 1.0 : 0.0
        case .badgeCount(let n):
            let others = walkBadges.filter { $0.id != id }
            let count = others.filter { $0.isEarned(sessions: sessions, currentStreak: currentStreak) }.count
            return min(1.0, Double(count) / Double(max(1, n)))
        case .rideKm(let km):
            return min(1.0, totalRideKm(from: sessions) / max(1, km))
        case .rideStreak(let days):
            return min(1.0, Double(rideStreak(from: sessions)) / Double(max(1, days)))
        case .petWalks(let n):
            return min(1.0, Double(sessions.filter { !$0.activePetIds.isEmpty }.count) / Double(max(1, n)))
        case .communityRoutesCompleted(let n):
            return min(1.0, Double(sessions.filter { $0.isCommunityRoute }.count) / Double(max(1, n)))
        case .routesBookmarked(let n):
            return min(1.0, Double(UserDefaults.standard.integer(forKey: "wkt_routesBookmarked_count")) / Double(max(1, n)))
        case .indoorWalks(let n):
            return min(1.0, Double(sessions.filter { $0.activityType == ActivityMode.stationary.rawValue }.count) / Double(max(1, n)))
        case .walkNotesAdded(let n):
            return min(1.0, Double(sessions.filter { !$0.notes.isEmpty }.count) / Double(max(1, n)))
        case .manualEntries(let n):
            return min(1.0, Double(UserDefaults.standard.integer(forKey: "wkt_manualEntries_count")) / Double(max(1, n)))
        case .wockettsGiven(let n):
            let count = (UserDefaults.standard.stringArray(forKey: "communityVotedRoutes") ?? []).count
            return min(1.0, Double(count) / Double(max(1, n)))
        case .wockettsReceived(let n):
            return min(1.0, Double(UserDefaults.standard.integer(forKey: "wkt_wocketts_received")) / Double(max(1, n)))
        }
    }

    // MARK: - Private helpers

    private func totalWalkKm(from sessions: [WalkSession]) -> Double {
        sessions
            .filter { $0.activityType != ActivityMode.cycling.rawValue }
            .reduce(0.0) { $0 + $1.totalDistance } / 1000
    }

    private func totalRideKm(from sessions: [WalkSession]) -> Double {
        sessions
            .filter { $0.activityType == ActivityMode.cycling.rawValue }
            .reduce(0.0) { $0 + $1.totalDistance } / 1000
    }

    private func rideStreak(from sessions: [WalkSession]) -> Int {
        let cal = Calendar.current
        let rideDays = Set(sessions
            .filter { $0.activityType == ActivityMode.cycling.rawValue }
            .map { cal.startOfDay(for: $0.date) })
        let today = cal.startOfDay(for: Date())
        // Count back from today; if today has no ride, try starting from yesterday
        for start in [today, cal.date(byAdding: .day, value: -1, to: today)].compactMap({ $0 }) {
            guard rideDays.contains(start) else { continue }
            var count = 0
            var day = start
            while rideDays.contains(day) {
                count += 1
                guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
                day = prev
            }
            return count
        }
        return 0
    }

    private func hasCrossTrainDay(in sessions: [WalkSession]) -> Bool {
        let cal = Calendar.current
        var walkDays = Set<Date>()
        var rideDays = Set<Date>()
        for s in sessions {
            let day = cal.startOfDay(for: s.date)
            if s.activityType == ActivityMode.cycling.rawValue { rideDays.insert(day) }
            else { walkDays.insert(day) }
        }
        return !walkDays.isDisjoint(with: rideDays)
    }
}

// MARK: - Badge Catalogue

let walkBadges: [WalkBadge] = [
    // Distance — walking only
    WalkBadge(id: "first",     name: "First Steps",   description: "Walk your first km",          emoji: "🚶",   type: .distance(km: 1)),
    WalkBadge(id: "warming",   name: "Warming Up",    description: "10 km total walked",          emoji: "🔥",   type: .distance(km: 10)),
    WalkBadge(id: "rolling",   name: "On a Roll",     description: "50 km total walked",          emoji: "⚡️",  type: .distance(km: 50)),
    WalkBadge(id: "century",   name: "Century Walk",  description: "100 km total walked",         emoji: "💯",   type: .distance(km: 100)),
    WalkBadge(id: "marathon",  name: "Marathoner",    description: "500 km total walked",         emoji: "🏅",   type: .distance(km: 500)),
    WalkBadge(id: "legend",    name: "Legend",        description: "1,000 km total walked",       emoji: "🌟",   type: .distance(km: 1000)),
    // Streaks
    WalkBadge(id: "week1",     name: "Week One",      description: "7-day goal streak",           emoji: "🗓️",   type: .streak(days: 7)),
    WalkBadge(id: "fortnight", name: "Fortnight",     description: "14-day goal streak",          emoji: "🌱",   type: .streak(days: 14)),
    WalkBadge(id: "month1",    name: "Month Strong",  description: "30-day goal streak",          emoji: "📅",   type: .streak(days: 30)),
    WalkBadge(id: "ironwill",  name: "Iron Will",     description: "60-day goal streak",          emoji: "💪",   type: .streak(days: 60)),
    WalkBadge(id: "centurion", name: "Centurion",     description: "100-day goal streak",         emoji: "💎",   type: .streak(days: 100)),
    // Time-of-day
    WalkBadge(id: "earlybird", name: "Early Bird",    description: "Complete a walk before 8am",  emoji: "🌅",   type: .earlyBird),
    WalkBadge(id: "nightowl",  name: "Night Owl",     description: "Complete a walk after 8pm",   emoji: "🌙",   type: .nightOwl),
    // Meta
    WalkBadge(id: "badgehunter", name: "Badge Hunter", description: "Earn 5 other badges",        emoji: "🏆",   type: .badgeCount(n: 5)),
    // Rides
    WalkBadge(id: "firstride",    name: "Two Wheels",        description: "Complete your first bike ride",  emoji: "🚴",   type: .rideKm(km: 1)),
    WalkBadge(id: "centuryride",  name: "Century Ride",      description: "100 km total cycled",            emoji: "🚵",   type: .rideKm(km: 100)),
    WalkBadge(id: "pedalpower",   name: "Pedal Power",       description: "500 km total cycled",            emoji: "⚙️",   type: .rideKm(km: 500)),
    WalkBadge(id: "crosstrain",   name: "Cross Trainer",     description: "Walk and ride on the same day",  emoji: "🔄",   type: .crossTrainDay),
    WalkBadge(id: "roadwarrior",  name: "Road Warrior",      description: "7-day cycling streak",           emoji: "🛣️",   type: .rideStreak(days: 7)),
    // Pets
    WalkBadge(id: "firstwalkies", name: "First Walkies",     description: "Complete a walk with a pet",     emoji: "🐶",   type: .petWalks(n: 1)),
    WalkBadge(id: "packleader",   name: "Pack Leader",       description: "Walk with 2+ pets at once",      emoji: "🐕‍🦺",  type: .multiPetWalk),
    WalkBadge(id: "pawprints",    name: "Paw Prints",        description: "Log 25 walks with a pet",        emoji: "🐾",   type: .petWalks(n: 25)),
    // Explorer
    WalkBadge(id: "cartographer",     name: "Cartographer",       description: "Build your first custom route",    emoji: "✏️",   type: .customRouteCreated),
    WalkBadge(id: "communitybuilder", name: "Community Builder",  description: "Share a route with the community", emoji: "🌐",   type: .customRouteShared),
    WalkBadge(id: "trailblazer",      name: "Trailblazer",        description: "Complete 5 community routes",      emoji: "🧭",   type: .communityRoutesCompleted(n: 5)),
    WalkBadge(id: "routescout",       name: "Route Scout",        description: "Bookmark 10 routes",               emoji: "🔖",   type: .routesBookmarked(n: 10)),
    // Consistency
    WalkBadge(id: "indoorally",  name: "Rain Check",     description: "Log 5 indoor walks",                emoji: "🏠",   type: .indoorWalks(n: 5)),
    // Collection & Journaling
    WalkBadge(id: "notetaker",    name: "Note Taker",    description: "Add notes to 10 walks",              emoji: "📝",   type: .walkNotesAdded(n: 10)),
    WalkBadge(id: "historian",    name: "Historian",     description: "Log a past walk manually",            emoji: "🕰️",   type: .manualEntries(n: 1)),
    WalkBadge(id: "firstwockett", name: "Wockett Giver", description: "Give a Wockett to a community route", emoji: "🎁",  type: .wockettsGiven(n: 1)),
    // Social
    WalkBadge(id: "challengeaccepted", name: "Challenge Accepted", description: "Challenge a friend to beat your streak", emoji: "🤝", type: .challengeShared),
]

// MARK: - Streak Store

@Observable
final class StreakStore {
    static let shared = StreakStore()

    var currentStreak: Int = 0
    var appleADayStreak: Int = 0
    var longestStreak: Int = 0

    private let longestKey    = "wkt_longestStreak_v1"
    private let seenBadgesKey = "wkt_seenBadges_v1"

    init() {
        longestStreak = UserDefaults.standard.integer(forKey: longestKey)
    }

    /// Recomputes streaks and returns a newly unlocked badge if one was just earned.
    @discardableResult
    func refresh(sessions: [WalkSession], todaySteps: Int, dailyGoal: Int) -> WalkBadge? {
        currentStreak   = compute(sessions: sessions, todaySteps: todaySteps, threshold: dailyGoal)
        appleADayStreak = compute(sessions: sessions, todaySteps: todaySteps, threshold: 10_000)
        if currentStreak > longestStreak {
            longestStreak = currentStreak
            UserDefaults.standard.set(longestStreak, forKey: longestKey)
        }
        UserDefaults(suiteName: "group.com.scoops.wockett")?.set(currentStreak, forKey: "wkt_widget_streak")
        return checkNewBadge(sessions: sessions)
    }

    private func checkNewBadge(sessions: [WalkSession]) -> WalkBadge? {
        let prevSeen  = Set(UserDefaults.standard.stringArray(forKey: seenBadgesKey) ?? [])
        let nowEarned = walkBadges.filter { $0.isEarned(sessions: sessions, currentStreak: currentStreak) }
        let newOnes   = nowEarned.filter { !prevSeen.contains($0.id) }
        UserDefaults.standard.set(Array(prevSeen.union(Set(nowEarned.map(\.id)))), forKey: seenBadgesKey)
        return newOnes.first
    }

    private func compute(sessions: [WalkSession], todaySteps: Int, threshold: Int) -> Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var stepsByDay: [Date: Int] = [:]
        for s in sessions {
            let day = cal.startOfDay(for: s.date)
            stepsByDay[day, default: 0] += s.estimatedSteps
        }
        stepsByDay[today] = todaySteps
        var startDay = today
        if todaySteps < threshold, let yesterday = cal.date(byAdding: .day, value: -1, to: today) {
            startDay = yesterday
        }
        var count = 0
        var day = startDay
        while (stepsByDay[day] ?? 0) >= threshold {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }

    func totalKm(from sessions: [WalkSession]) -> Double {
        sessions.reduce(0.0) { $0 + $1.totalDistance } / 1000
    }
}
