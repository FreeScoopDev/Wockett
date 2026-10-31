import Foundation
import Testing
@testable import PoCSquat

/// A gait status needs 4 sampled days in the last 7, a trend 3 in each week,
/// and the notes say how many days there were (2026-10-31). Until then one
/// day of data was enough for "On track", "Watch" or "Check in".
@Suite struct GaitSamplingTests {
    /// Snapshots one per day, oldest first, as `GaitHealthService.load()`
    /// makes them; `speeds[i]` is day i's walking speed, nil for no data.
    private func snapshots(_ speeds: [Double?]) -> [GaitDaySnapshot] {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return speeds.enumerated().map { i, speed in
            let day = start.addingTimeInterval(Double(i) * 86_400)
            return GaitDaySnapshot(id: day, date: day, speedMps: speed,
                                   stepLengthCm: nil, doubleSupportPct: nil, asymmetryPct: nil)
        }
    }

    private func sampling(_ speeds: [Double?]) -> GaitSampling {
        GaitSampling(snapshots(speeds), value: { $0.speedMps })
    }

    private let none = [Double?](repeating: nil, count: 7)

    @Test func countsSampledDaysInTheLastSeven() {
        #expect(sampling(none).recent.isEmpty)
        #expect(sampling([nil, nil, nil, nil, nil, nil, 1.2]).recent.count == 1)
        #expect(sampling([1.2, nil, 1.2, nil, 1.2, nil, nil]).recent.count == 3)
        #expect(sampling([1.2, nil, 1.2, nil, 1.2, nil, 1.2]).recent.count == 4)
        #expect(sampling([Double?](repeating: 1.2, count: 7)).recent.count == 7)
    }

    /// The 8th day back belongs to the prior week, not the last 7; nil days count in neither.
    @Test func windowsAreDisjoint() {
        // 14 days: prior week has values on 2 days, last 7 on 5.
        let s = sampling([nil, 1.0, nil, nil, nil, nil, 1.0,
                          1.2, 1.2, nil, 1.2, 1.2, nil, 1.2])
        #expect(s.prior.count == 2)
        #expect(s.recent.count == 5)
        #expect(s.prior == [1.0, 1.0])
        #expect(s.recent == [1.2, 1.2, 1.2, 1.2, 1.2])
    }

    /// Averages only the sampled days: (1.0 + 1.4) / 2, not / 7.
    @Test func averageIgnoresDaysWithoutData() {
        let avg = sampling([nil, nil, 1.0, nil, nil, 1.4, nil]).recentAverage
        #expect(avg.map { abs($0 - 1.2) < 1e-9 } == true)
        #expect(sampling(none).recentAverage == nil)
    }

    @Test func statusNeedsFourDays() {
        #expect(!sampling([1.2, nil, 1.2, nil, 1.2, nil, nil]).showsStatus)
        #expect(sampling([1.2, nil, 1.2, nil, 1.2, nil, 1.2]).showsStatus)
        #expect(!sampling([nil, nil, nil, nil, nil, nil, 1.2]).showsStatus)
    }

    /// What the card, the hero and the Recovery card show: 0.5 m/s (1.8 km/h)
    /// is "Check in" on walking speed, but only once 4 days stand behind it.
    @Test func statusComesOnlyWithFourDays() {
        let speed = GaitMetricConfig.all[0]
        #expect(sampling([0.5, nil, 0.5, nil, 0.5, nil, nil]).status(speed) == nil)
        #expect(sampling([0.5, nil, 0.5, nil, 0.5, nil, 0.5]).status(speed) == .attention)
    }

    @Test func trendNeedsThreeDaysInEachWeek() {
        let threeOfSeven: [Double?] = [1.0, nil, 1.0, nil, 1.0, nil, nil]
        let twoOfSeven: [Double?]   = [1.0, nil, 1.0, nil, nil, nil, nil]
        let threeAt12: [Double?]    = [1.2, nil, 1.2, nil, 1.2, nil, nil]
        let twoAt12: [Double?]      = [1.2, nil, 1.2, nil, nil, nil, nil]
        let oneAt12: [Double?]      = [nil, nil, nil, nil, nil, nil, 1.2]

        #expect(sampling(twoOfSeven + threeAt12).trendPct == nil)
        #expect(sampling(threeOfSeven + twoAt12).trendPct == nil)
        #expect(sampling(threeOfSeven + oneAt12).trendPct == nil)
        #expect(sampling(none + threeAt12).trendPct == nil)

        // 1.2 against 1.0: +20%.
        let pct = sampling(threeOfSeven + threeAt12).trendPct
        #expect(pct.map { abs($0 - 20) < 1e-9 } == true)
    }

    @Test func countSentence() {
        #expect(GaitSampling.daysText(1) == "1 day")
        #expect(GaitSampling.daysText(5) == "5 days")
        #expect(GaitSampling.basedOnText(1, of: 7) == "based on 1 of the last 7 days")
        #expect(GaitSampling.basedOnText(18, of: 30) == "based on 18 of the last 30 days")
        #expect(GaitSampling.basedOnText(0, of: 7) == "no data in the last 7 days")
    }
}
