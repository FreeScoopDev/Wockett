import SwiftUI

/// How many days of gait data stand behind a number, and whether that is
/// enough for a status or a trend. Pure, so the counting rule is tested.
///
/// `GaitHealthService.load()` makes one snapshot per calendar day, oldest
/// first and today last, with nil on a day Health has no value. So the last
/// 7 snapshots are the last 7 calendar days, and the 7 before them the week
/// before. Until 2026-10-31 one sampled day was enough for "On track",
/// "Watch" or "Check in", and one day in each week for a trend.
struct GaitSampling {
    static let minDaysForStatus = 4
    static let minDaysForTrend  = 3

    /// The values of the last 7 days and of the 7 before, days without one left out.
    let recent: [Double]
    let prior: [Double]

    init(_ snapshots: [GaitDaySnapshot], value: (GaitDaySnapshot) -> Double?) {
        recent = snapshots.suffix(7).compactMap(value)
        prior  = snapshots.dropLast(7).suffix(7).compactMap(value)
    }

    var recentAverage: Double? { Self.average(recent) }

    /// A status needs at least 4 of the last 7 days.
    var showsStatus: Bool { recent.count >= Self.minDaysForStatus }

    /// The 7-day average's status, or nil with fewer than 4 days. Every gait
    /// status on screen comes from here, so none can skip the day count.
    func status(_ config: GaitMetricConfig) -> GaitStatus? {
        guard showsStatus, let avg = recentAverage else { return nil }
        return config.statusOf(avg)
    }

    /// A chart dot's or day bar's colour: that day's status colour only when
    /// the 7-day status shows; otherwise `earthMuted`, because the "On track"
    /// green would still give a verdict, just a kind one.
    func dayColor(_ value: Double, _ config: GaitMetricConfig) -> Color {
        showsStatus ? config.statusOf(value).color : .earthMuted
    }

    /// The change against the week before, only with 3 days in each week.
    var trendPct: Double? {
        guard recent.count >= Self.minDaysForTrend, prior.count >= Self.minDaysForTrend,
              let cur = Self.average(recent), let prev = Self.average(prior), prev > 0 else { return nil }
        return (cur - prev) / prev * 100
    }

    static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// "1 day", "5 days".
    static func daysText(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }

    /// "based on 5 of the last 7 days", or "no data in the last 7 days".
    static func basedOnText(_ count: Int, of window: Int) -> String {
        count == 0 ? "no data in the last \(window) days" : "based on \(count) of the last \(window) days"
    }
}
