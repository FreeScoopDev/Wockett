import Foundation

// MARK: - Readiness evaluator

/// What readiness is judged from. `RecoveryService` fetches these; the
/// evaluator only decides, so every rule below is testable without HealthKit.
struct ReadinessInputs {
    var sleepHours: Double?       // last night, from the 17:00-12:00 window
    var hrv: Double?              // latest SDNN in ms
    var hrvDate: Date?            // that sample's end date
    var baseline: Double?         // 30-day average SDNN in ms
    /// Days in the 30-day window with an HRV value: the count of the daily
    /// averages `RecoveryService` already fetches (`hrvHistory`), not of
    /// individual samples, so no extra HealthKit query is needed.
    var baselineReadings: Int
}

struct ReadinessResult: Equatable {
    let level: ReadinessLevel
    /// Describes the readings, or says which input is missing. Never an instruction.
    let hint: String
}

enum ReadinessEvaluator {
    /// An HRV reading older than this does not describe today (Joe, 2026-10-30).
    static let hrvFreshness: TimeInterval = 48 * 3600
    /// Days of HRV the baseline needs before it is compared against (Joe, 2026-10-30).
    static let minimumBaselineReadings = 7

    /// Answers only when sleep, a fresh HRV and a baseline on enough days all
    /// exist; one signal alone is `.unknown`. The scores and cut-offs are the
    /// ones readiness has always used.
    static func evaluate(_ inputs: ReadinessInputs, now: Date) -> ReadinessResult {
        // Zero hours means only In Bed or Awake samples: no sleep to score.
        guard let sleep = inputs.sleepHours, sleep > 0 else {
            return ReadinessResult(level: .unknown, hint: "No sleep recorded last night")
        }
        guard let hrv = inputs.hrv, let date = inputs.hrvDate,
              now.timeIntervalSince(date) <= hrvFreshness else {
            return ReadinessResult(level: .unknown, hint: "No HRV in the last 2 days")
        }
        guard inputs.baselineReadings >= minimumBaselineReadings else {
            return ReadinessResult(level: .unknown, hint:
                "Not enough HRV history yet: \(inputs.baselineReadings) of \(minimumBaselineReadings) days")
        }
        guard let baseline = inputs.baseline, baseline > 0 else {
            return ReadinessResult(level: .unknown, hint: "No HRV baseline yet")
        }

        let ratio      = hrv / baseline
        let sleepScore = Self.sleepScore(sleep)
        let hrvScore   = Self.hrvScore(ratio: ratio)
        let avg        = Double(sleepScore + hrvScore) / 2
        let level: ReadinessLevel = avg >= 1.7 ? .push : avg >= 0.8 ? .active : .recover

        let hrvWords = hrvScore == 2 ? "above" : hrvScore == 1 ? "near" : "below"
        return ReadinessResult(level: level, hint:
            "HRV \(hrvWords) your 30-day average; slept \(RecoveryService.formatHours(sleep))")
    }

    /// 0-2: 7 hours or more is 2, 6 or more is 1. The score breakdown uses these too.
    static func sleepScore(_ hours: Double) -> Int { hours >= 7.0 ? 2 : hours >= 6.0 ? 1 : 0 }
    /// 0-2 from HRV / baseline: 1.1 or more is 2, 0.85 or more is 1.
    static func hrvScore(ratio: Double) -> Int { ratio >= 1.1 ? 2 : ratio >= 0.85 ? 1 : 0 }
}
