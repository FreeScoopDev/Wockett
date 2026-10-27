import Foundation

// MARK: - Recorded days
//
// The Health tab's "Last 30 days" trend and the month calendar's "This month"
// stats both average steps and count goals over a run of days (2026-10-27,
// Slice A3). Neither can tell a day the person did not move from a day with
// no step data: Apple Health returns nothing for both, and does not say
// whether read access was turned off. So both use only the **recorded days**,
// a day up to today with more than 0 steps, and say how many there were
// ("18 of 30 days have steps") instead of showing an average or a "0/0" whose
// denominator nobody can see. A day with 0 or no steps is in neither the
// average nor the goals.

struct RecordedDaysSummary: Equatable {
    /// Days with more than 0 steps.
    let recordedDays: Int
    /// Every day the caller supplied: the denominator of the coverage line.
    let totalDays: Int
    /// Total steps over recorded days / `recordedDays`; nil when none.
    let average: Int?
    /// Recorded days whose steps reached that day's own goal.
    let goalsMet: Int
    /// The most steps on one day; nil when none.
    let best: Int?
    /// Steps over every recorded day.
    let totalSteps: Int

    var isEmpty: Bool { recordedDays == 0 }

    /// One day as the caller sees it. `steps` is nil when the day has no
    /// value at all (no sample, or not loaded).
    struct Day: Equatable {
        let steps: Int?
        let goal: Int
    }

    /// The summary of `days`, which must be today or earlier: the caller
    /// leaves out days still to come.
    nonisolated static func make(days: [Day]) -> RecordedDaysSummary {
        var recorded = 0, total = 0, met = 0
        var best: Int?
        for day in days {
            guard let steps = day.steps, steps > 0 else { continue }
            recorded += 1
            total += steps
            if steps >= day.goal { met += 1 }
            if steps > (best ?? 0) { best = steps }
        }
        return RecordedDaysSummary(recordedDays: recorded, totalDays: days.count,
                                   average: recorded > 0 ? total / recorded : nil,
                                   goalsMet: met, best: best, totalSteps: total)
    }

    /// The dates of `dates` that are today or earlier. Both screens pick
    /// their days with this, so a day still to come is never in a
    /// denominator.
    nonisolated static func pastDates(_ dates: [Date], today: Date, calendar: Calendar) -> [Date] {
        let startOfToday = calendar.startOfDay(for: today)
        return dates.filter { calendar.startOfDay(for: $0) <= startOfToday }
    }

    /// "18 of 30 days have steps".
    nonisolated static func coverageText(recorded: Int, total: Int) -> String {
        "\(recorded) of \(total) \(total == 1 ? "day" : "days") \(recorded == 1 ? "has" : "have") steps"
    }

    var coverageText: String { Self.coverageText(recorded: recordedDays, total: totalDays) }

    // MARK: Empty and unavailable wording
    //
    // Neutral on purpose: HealthKit cannot tell the app that read access was
    // turned off, and a day with no samples is not proof of no movement, so
    // nothing here says access was denied.

    nonisolated static let noHealthData = "No step data for the last 30 days."
    nonisolated static let noHealthDataHint =
        "Wockett reads steps from Apple Health. If you expected data, check Health access in Settings."
    nonisolated static let noAppOnlyData = "No recorded activities in the last 30 days."
    nonisolated static let unavailable = "Step history is unavailable right now."
}

/// What the 30-day trend shows. A failed or impossible Health query
/// (`StepManager.fetchStepCounts` returning nil) reads differently from a
/// query that found nothing.
enum StepHistoryState: Equatable {
    case unavailable
    case empty
    case recorded(RecordedDaysSummary)

    /// `fetched` is the Health query's result: nil when it could not run or
    /// failed, an empty dictionary when it ran and found no samples.
    nonisolated static func make(fetched: [Date: Int]?, summary: RecordedDaysSummary) -> StepHistoryState {
        guard fetched != nil else { return .unavailable }
        return summary.isEmpty ? .empty : .recorded(summary)
    }
}
