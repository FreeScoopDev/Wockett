import Foundation

// MARK: - Insights
//
// Weekly and monthly trends from the walks, runs and rides recorded in
// Wockett (2026-10-09, the first piece of the Premium bundle Joe approved:
// Insights + Personalisation + route preferences + supporter badge).
//
// What is free and what is Pro follows `ProFeature.advancedAnalytics`: "Depth
// only. Basic trends and summaries stay free" (decided 2026-09-15). The
// period's totals, its day-by-day chart and the comparison with last
// week/month are free; the longer trend, activity mix, weekly pattern and
// per-pet totals are the depth.
//
// The source is the session history only, never HealthKit's all-day steps:
// Insights is about the activities the person recorded, it works in app-only
// tracking mode and on the simulator, and its numbers match Activity History.
// Steps are `estimatedSteps` (the pedometer count, or distance / 0.762 m for
// sessions from before 1.7), so the screen calls them estimated.
//
// Every function takes `now` and a `Calendar`, so weeks follow the person's
// locale (Sunday in the US, Monday elsewhere) and tests fix both: CI runs in
// UTC, and CommunityHubSummaryTests already lost a day to that.

enum InsightsPeriod: String, CaseIterable, Hashable {
    case week, month

    var component: Calendar.Component { self == .week ? .weekOfYear : .month }
    /// "week", "month", for "vs last week".
    var noun: String { rawValue }
}

struct InsightsTotals: Equatable {
    var sessions = 0
    var distanceMeters: Double = 0
    var duration: TimeInterval = 0
    var steps = 0
    var activeDays = 0
    var distanceByActivity: [ActivityMode: Double] = [:]
}

/// One bar: a day of the period, or a whole week or month in a trend.
struct InsightsBucket: Identifiable, Equatable {
    let start: Date
    let distanceMeters: Double
    var id: Date { start }
}

enum InsightsTimeOfDay: String, CaseIterable {
    case morning, afternoon, evening, night

    /// Morning 5–11, afternoon 11–17, evening 17–21, night 21–5.
    init(hour: Int) {
        switch hour {
        case 5..<11:  self = .morning
        case 11..<17: self = .afternoon
        case 17..<21: self = .evening
        default:      self = .night
        }
    }

    var title: String { rawValue.capitalized }
}

struct InsightsPetTotals: Identifiable, Equatable {
    let pet: PetProfile
    let distanceMeters: Double
    let sessions: Int
    var id: UUID { pet.id }
    /// Pets carry no pedometer: estimated from distance, as everywhere else.
    var estimatedSteps: Int { Int(distanceMeters / 0.762) }
}

enum InsightsSummary {

    /// Sessions that count. A session flagged as possibly driving, that the
    /// person did not confirm, is left out, as it is for badges.
    nonisolated static func counted(_ sessions: [WalkSession]) -> [WalkSession] {
        sessions.filter { !$0.flaggedPossibleVehicle }
    }

    /// The calendar week or month containing `now`.
    nonisolated static func interval(_ period: InsightsPeriod, containing now: Date,
                                     calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: period.component, for: now) ?? DateInterval(start: now, duration: 0)
    }

    /// Totals for sessions that started inside `interval`. A session is
    /// counted on the day it started, as in Activity History.
    nonisolated static func totals(_ sessions: [WalkSession], in interval: DateInterval,
                                   calendar: Calendar) -> InsightsTotals {
        var t = InsightsTotals()
        var days = Set<Date>()
        for s in counted(sessions) where s.date >= interval.start && s.date < interval.end {
            t.sessions += 1
            t.distanceMeters += s.totalDistance
            t.duration += s.elapsedTime
            t.steps += s.estimatedSteps
            days.insert(calendar.startOfDay(for: s.date))
            let mode = ActivityMode(rawValue: s.activityType) ?? .walking
            t.distanceByActivity[mode, default: 0] += s.totalDistance
        }
        t.activeDays = days.count
        return t
    }

    /// This period so far, and the same stretch of the one before: Wednesday
    /// noon is compared with last Wednesday noon, not with all of last week,
    /// so a week in progress is not always "down".
    nonisolated static func comparison(_ sessions: [WalkSession], period: InsightsPeriod, now: Date,
                                       calendar: Calendar) -> (current: InsightsTotals, previous: InsightsTotals) {
        let current = interval(period, containing: now, calendar: calendar)
        let elapsed = now.timeIntervalSince(current.start)
        guard let previousStart = calendar.date(byAdding: period.component, value: -1, to: current.start) else {
            return (totals(sessions, in: DateInterval(start: current.start, end: now), calendar: calendar),
                    InsightsTotals())
        }
        let previousEnd = min(previousStart.addingTimeInterval(elapsed), current.start)
        return (totals(sessions, in: DateInterval(start: current.start, end: now), calendar: calendar),
                totals(sessions, in: DateInterval(start: previousStart, end: previousEnd), calendar: calendar))
    }

    /// The change as a fraction (0.25 = up 25%), or nil when there is nothing
    /// to compare with: "up ∞%" after an empty week says nothing.
    nonisolated static func change(current: Double, previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous
    }

    /// One bucket per day of the period containing `now`, future days included
    /// (at zero) so the chart always shows the whole week or month.
    nonisolated static func dailyBuckets(_ sessions: [WalkSession], period: InsightsPeriod, now: Date,
                                         calendar: Calendar) -> [InsightsBucket] {
        let range = interval(period, containing: now, calendar: calendar)
        var byDay: [Date: Double] = [:]
        for s in counted(sessions) where range.contains(s.date) {
            byDay[calendar.startOfDay(for: s.date), default: 0] += s.totalDistance
        }
        var buckets: [InsightsBucket] = []
        var day = calendar.startOfDay(for: range.start)
        while day < range.end {
            buckets.append(InsightsBucket(start: day, distanceMeters: byDay[day] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return buckets
    }

    /// The last `count` whole periods ending with the current one, oldest first.
    nonisolated static func trend(_ sessions: [WalkSession], period: InsightsPeriod, now: Date,
                                  calendar: Calendar, count: Int) -> [InsightsBucket] {
        let current = interval(period, containing: now, calendar: calendar)
        return (0..<count).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: period.component, value: -back, to: current.start) else {
                return nil
            }
            let range = interval(period, containing: start, calendar: calendar)
            return InsightsBucket(start: range.start,
                                  distanceMeters: totals(sessions, in: range, calendar: calendar).distanceMeters)
        }
    }

    /// Average distance on each weekday (1 = Sunday … 7 = Saturday, as
    /// `Calendar` numbers them) over the whole weeks before this one: the last
    /// `weeks`, or fewer if the history is shorter. Dividing three weeks of
    /// walks by eight read "Saturday, 1.3 mi on average" on the 2026-10-09
    /// simulator check, a third of the truth for anyone who started recently.
    /// Empty until there is one whole past week.
    nonisolated static func weekdayAverages(_ sessions: [WalkSession], now: Date, calendar: Calendar,
                                            weeks: Int = 8) -> [Int: Double] {
        let thisWeek = interval(.week, containing: now, calendar: calendar)
        let counted = counted(sessions).filter { $0.date < thisWeek.start }
        guard let earliest = counted.map(\.date).min() else { return [:] }
        let firstWeek = interval(.week, containing: earliest, calendar: calendar).start
        let available = calendar.dateComponents([.weekOfYear], from: firstWeek, to: thisWeek.start).weekOfYear ?? 0
        let span = min(weeks, available)
        guard span > 0, let start = calendar.date(byAdding: .weekOfYear, value: -span, to: thisWeek.start) else {
            return [:]
        }
        var sums: [Int: Double] = [:]
        for s in counted where s.date >= start {
            sums[calendar.component(.weekday, from: s.date), default: 0] += s.totalDistance
        }
        return sums.mapValues { $0 / Double(span) }
    }

    /// How many sessions started in each part of the day, inside `interval`.
    nonisolated static func timeOfDay(_ sessions: [WalkSession], in interval: DateInterval,
                                      calendar: Calendar) -> [InsightsTimeOfDay: Int] {
        var counts: [InsightsTimeOfDay: Int] = [:]
        for s in counted(sessions) where s.date >= interval.start && s.date < interval.end {
            counts[InsightsTimeOfDay(hour: calendar.component(.hour, from: s.date)), default: 0] += 1
        }
        return counts
    }

    /// Each pet's distance and walks inside `interval`, most walked first;
    /// pets with none are left out.
    nonisolated static func pets(_ sessions: [WalkSession], pets: [PetProfile],
                                 in interval: DateInterval) -> [InsightsPetTotals] {
        let inRange = counted(sessions).filter { $0.date >= interval.start && $0.date < interval.end }
        return pets.compactMap { pet in
            let walked = inRange.filter { PetStore.participated(pet.id, in: $0) }
            let meters = walked.reduce(0) { $0 + PetStore.walkedMeters(pet.id, in: $1) }
            return walked.isEmpty ? nil : InsightsPetTotals(pet: pet, distanceMeters: meters, sessions: walked.count)
        }
        .sorted { $0.distanceMeters > $1.distanceMeters }
    }
}
