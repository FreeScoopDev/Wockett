import Foundation

// MARK: - Badge Model

struct WalkBadge: Identifiable {
    let id: String
    let name: String
    let description: String
    let emoji: String
    let requiredKm: Double
}

let walkBadges: [WalkBadge] = [
    WalkBadge(id: "first",    name: "First Steps",  description: "Walk your first km",    emoji: "🚶",  requiredKm: 1),
    WalkBadge(id: "warming",  name: "Warming Up",   description: "10 km total walked",    emoji: "🔥",  requiredKm: 10),
    WalkBadge(id: "rolling",  name: "On a Roll",    description: "50 km total walked",    emoji: "⚡️", requiredKm: 50),
    WalkBadge(id: "century",  name: "Century",      description: "100 km total walked",   emoji: "💯",  requiredKm: 100),
    WalkBadge(id: "marathon", name: "Marathoner",   description: "500 km total walked",   emoji: "🏅",  requiredKm: 500),
    WalkBadge(id: "legend",   name: "Legend",       description: "1,000 km total walked", emoji: "🌟",  requiredKm: 1000),
]

// MARK: - Streak Store

@Observable
final class StreakStore {
    static let shared = StreakStore()

    var currentStreak: Int = 0
    var appleADayStreak: Int = 0
    var longestStreak: Int = 0

    private let longestKey = "wkt_longestStreak_v1"

    private init() {
        longestStreak = UserDefaults.standard.integer(forKey: longestKey)
    }

    func refresh(sessions: [WalkSession], todaySteps: Int, dailyGoal: Int) {
        currentStreak   = compute(sessions: sessions, todaySteps: todaySteps, threshold: dailyGoal)
        appleADayStreak = compute(sessions: sessions, todaySteps: todaySteps, threshold: 10_000)
        if currentStreak > longestStreak {
            longestStreak = currentStreak
            UserDefaults.standard.set(longestStreak, forKey: longestKey)
        }
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
        var count = 0
        var day = today
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
