import Testing
import Foundation
@testable import PoCSquat

/// Readiness answers only when it has last night's sleep, an HRV reading from
/// the last 48 hours and a baseline on at least 7 days (fix/readiness-freshness,
/// Joe 2026-10-30). Every expectation here is worked out by hand from the
/// score table (sleep >= 7 h is 2, >= 6 is 1; HRV / baseline >= 1.1 is 2,
/// >= 0.85 is 1; average >= 1.7 Push, >= 0.8 Active, else Recover), not
/// computed with the code under test.
@MainActor
struct ReadinessEvaluatorTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600

    /// Good sleep, HRV 10% over a 100 ms baseline on 30 days, measured 8 hours ago: Push.
    private func inputs(sleep: Double? = 8, hrv: Double? = 110, hrvAge: TimeInterval? = 8 * 3600,
                        baseline: Double? = 100, readings: Int = 30) -> ReadinessInputs {
        ReadinessInputs(sleepHours: sleep, hrv: hrv, hrvDate: hrvAge.map { now.addingTimeInterval(-$0) },
                        baseline: baseline, baselineReadings: readings)
    }

    private func level(_ i: ReadinessInputs) -> ReadinessLevel {
        ReadinessEvaluator.evaluate(i, now: now).level
    }

    // MARK: One input alone

    @Test func sleepOnlyIsUnknown() {
        let r = ReadinessEvaluator.evaluate(inputs(hrv: nil, hrvAge: nil), now: now)
        #expect(r.level == .unknown)
        #expect(r.hint == "No HRV in the last 2 days")
    }

    @Test func hrvOnlyIsUnknown() {
        let r = ReadinessEvaluator.evaluate(inputs(sleep: nil), now: now)
        #expect(r.level == .unknown)
        #expect(r.hint == "No sleep recorded last night")
    }

    // MARK: HRV freshness

    @Test func hrvJustUnder48HoursCounts() {
        #expect(level(inputs(hrvAge: 47 * hour + 59 * 60)) == .push)
    }

    @Test func hrvAtExactly48HoursCounts() {
        #expect(level(inputs(hrvAge: 48 * hour)) == .push)
    }

    @Test func hrvOver48HoursIsUnknown() {
        let r = ReadinessEvaluator.evaluate(inputs(hrvAge: 48 * hour + 60), now: now)
        #expect(r.level == .unknown)
        #expect(r.hint == "No HRV in the last 2 days")
    }

    @Test func hrvWithoutADateIsUnknown() {
        #expect(level(inputs(hrvAge: nil)) == .unknown)
    }

    // MARK: Baseline

    @Test func sixBaselineReadingsIsUnknown() {
        let r = ReadinessEvaluator.evaluate(inputs(readings: 6), now: now)
        #expect(r.level == .unknown)
        #expect(r.hint == "Not enough HRV history yet: 6 of 7 days")
    }

    @Test func sevenBaselineReadingsCounts() {
        #expect(level(inputs(readings: 7)) == .push)
    }

    @Test func zeroBaselineIsUnknown() {
        #expect(level(inputs(baseline: 0)) == .unknown)
    }

    @Test func missingBaselineIsUnknown() {
        let r = ReadinessEvaluator.evaluate(inputs(baseline: nil), now: now)
        #expect(r.level == .unknown)
        #expect(r.hint == "No HRV baseline yet")
    }

    // MARK: Score table (same levels as before the change)

    /// (sleep hours, HRV in ms against a 100 ms baseline, expected level)
    static let table: [(Double, Double, ReadinessLevel)] = [
        (7.0, 110, .push),    (7.0, 85, .active),  (7.0, 84, .active),
        (6.0, 110, .active),  (6.0, 85, .active),  (6.0, 84, .recover),
        (5.9, 110, .active),  (5.9, 85, .recover), (5.9, 84, .recover)
    ]

    @Test(arguments: 0..<9)
    func scoreTable(row: Int) {
        let (sleep, hrv, expected) = Self.table[row]
        #expect(level(inputs(sleep: sleep, hrv: hrv)) == expected, "sleep \(sleep) h, HRV \(hrv) ms")
    }

    // MARK: Copy

    @Test func pushHintDescribesTheReadings() {
        #expect(ReadinessEvaluator.evaluate(inputs(sleep: 7.0), now: now).hint
                == "HRV above your 30-day average; slept 7h 0m")
        #expect(ReadinessEvaluator.evaluate(inputs(sleep: 6.5, hrv: 85), now: now).hint
                == "HRV near your 30-day average; slept 6h 30m")
        #expect(ReadinessEvaluator.evaluate(inputs(sleep: 5.0, hrv: 84), now: now).hint
                == "HRV below your 30-day average; slept 5h 0m")
    }

    @Test func noHintIsAnInstruction() {
        var all = Self.table.map { inputs(sleep: $0.0, hrv: $0.1) }
        all += [inputs(sleep: nil), inputs(hrv: nil, hrvAge: nil), inputs(hrvAge: 72 * hour),
                inputs(readings: 3), inputs(baseline: nil)]
        for i in all {
            let hint = ReadinessEvaluator.evaluate(i, now: now).hint.lowercased()
            for word in ["push", "harder", "recommended", "should", "try"] {
                #expect(!hint.contains(word), "\"\(hint)\" contains \"\(word)\"")
            }
        }
    }
}
