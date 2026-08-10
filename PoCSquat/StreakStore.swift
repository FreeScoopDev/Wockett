import Foundation

// MARK: - Badge Type

enum WalkBadgeType: Equatable {
    case distance(km: Double)
    case streak(days: Int)
    case earlyBird      // any session started before 8am
    case nightOwl       // any session started after 8pm
    case badgeCount(n: Int) // earn this many other badges
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
            return totalKm(from: sessions) >= km
        case .streak(let days):
            return currentStreak >= days
        case .earlyBird:
            return sessions.contains { Calendar.current.component(.hour, from: $0.date) < 8 }
        case .nightOwl:
            return sessions.contains { Calendar.current.component(.hour, from: $0.date) >= 20 }
        case .badgeCount(let n):
            let others = walkBadges.filter { $0.id != id }
            return others.filter { $0.isEarned(sessions: sessions, currentStreak: currentStreak) }.count >= n
        }
    }

    func progress(sessions: [WalkSession], currentStreak: Int) -> Double {
        switch type {
        case .distance(let km):
            return min(1.0, totalKm(from: sessions) / max(1, km))
        case .streak(let days):
            return min(1.0, Double(currentStreak) / Double(max(1, days)))
        case .earlyBird, .nightOwl:
            return isEarned(sessions: sessions, currentStreak: currentStreak) ? 1.0 : 0.0
        case .badgeCount(let n):
            let others = walkBadges.filter { $0.id != id }
            let earnedCount = others.filter { $0.isEarned(sessions: sessions, currentStreak: currentStreak) }.count
            return min(1.0, Double(earnedCount) / Double(max(1, n)))
        }
    }

    private func totalKm(from sessions: [WalkSession]) -> Double {
        sessions.reduce(0.0) { $0 + $1.totalDistance } / 1000
    }
}

// MARK: - Badge Catalogue

let walkBadges: [WalkBadge] = [
    // Distance milestones
    WalkBadge(id: "first",     name: "First Steps",  description: "Walk your first km",         emoji: "🚶",  type: .distance(km: 1)),
    WalkBadge(id: "warming",   name: "Warming Up",   description: "10 km total walked",         emoji: "🔥",  type: .distance(km: 10)),
    WalkBadge(id: "rolling",   name: "On a Roll",    description: "50 km total walked",         emoji: "⚡️", type: .distance(km: 50)),
    WalkBadge(id: "century",   name: "Century",      description: "100 km total walked",        emoji: "💯",  type: .distance(km: 100)),
    WalkBadge(id: "marathon",  name: "Marathoner",   description: "500 km total walked",        emoji: "🏅",  type: .distance(km: 500)),
    WalkBadge(id: "legend",    name: "Legend",       description: "1,000 km total walked",      emoji: "🌟",  type: .distance(km: 1000)),
    // Streak milestones
    WalkBadge(id: "week1",     name: "Week One",      description: "7-day goal streak",          emoji: "🗓️",  type: .streak(days: 7)),
    WalkBadge(id: "fortnight", name: "Fortnight",     description: "14-day goal streak",         emoji: "🌱",  type: .streak(days: 14)),
    WalkBadge(id: "month1",    name: "Month Strong",  description: "30-day goal streak",         emoji: "📅",  type: .streak(days: 30)),
    WalkBadge(id: "ironwill",  name: "Iron Will",     description: "60-day goal streak",         emoji: "💪",  type: .streak(days: 60)),
    WalkBadge(id: "centurion", name: "Centurion",     description: "100-day goal streak",        emoji: "💎",  type: .streak(days: 100)),
    // Time-of-day
    WalkBadge(id: "earlybird",    name: "Early Bird",    description: "Complete a walk before 8am", emoji: "🌅",  type: .earlyBird),
    WalkBadge(id: "nightowl",     name: "Night Owl",     description: "Complete a walk after 8pm",  emoji: "🌙",  type: .nightOwl),
    // Meta
    WalkBadge(id: "badgehunter",  name: "Badge Hunter",  description: "Earn 5 other badges",        emoji: "🏆",  type: .badgeCount(n: 5)),
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
        // If today hasn't hit the threshold yet, start from yesterday so an
        // in-progress day doesn't break an existing streak.
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
