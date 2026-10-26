import Testing
import CloudKit
@testable import PoCSquat

/// Distance challenge text (2026-10-12): the "13 mi" option is 20,921 m, which
/// is 12.9997 mi, and truncating it showed the goal as "12 mi". Goals round to
/// the nearest; progress rounds down so it never reads as finished early.
@Suite struct ChallengeDistanceFormatTests {
    private let us = Locale(identifier: "en_US")
    private let metric = Locale(identifier: "en_GB")

    private func distanceChallenge(goalMeters: Double) -> WalkChallenge? {
        let record = CKRecord(recordType: "Challenge")
        record["title"]              = "Test Challenge" as CKRecordValue
        record["startDate"]          = Date().addingTimeInterval(-86400) as CKRecordValue
        record["endDate"]            = Date().addingTimeInterval(86400) as CKRecordValue
        record["goalType"]           = ChallengeGoalType.distance.rawValue as CKRecordValue
        record["goalDistanceMeters"] = goalMeters as CKRecordValue
        return WalkChallenge(record: record)
    }

    @Test("Formatters survive values no record should carry", arguments: [1e30, -1e30, Double.nan, Double.infinity])
    func hostileValues(value: Double) {
        _ = challengeFormattedDistance(value, locale: us)
        _ = challengeFormattedDistance(value, locale: metric)
        _ = challengeFormattedPace(value, locale: us)
        _ = challengeFormattedPace(value, locale: metric)
    }

    @Test func thirteenMileOptionReadsThirteen() {
        #expect(challengeFormattedDistance(20_921, locale: us) == "13 mi")
    }

    @Test func everyCreateSheetOptionMatchesItsLabel() {
        // The Create Challenge sheet's options (ChallengeView.distanceOptions).
        #expect(challengeFormattedDistance(4_828, locale: us) == "3.0 mi")
        #expect(challengeFormattedDistance(9_656, locale: us) == "6.0 mi")
        #expect(challengeFormattedDistance(41_843, locale: us) == "26 mi")
        #expect(challengeFormattedDistance(99_779, locale: us) == "62 mi")
        #expect(challengeFormattedDistance(5_000, locale: metric) == "5.0 km")
        #expect(challengeFormattedDistance(10_000, locale: metric) == "10 km")
        #expect(challengeFormattedDistance(100_000, locale: metric) == "100 km")
    }

    @Test func justUnderTenReadsAsWholeTen() {
        // 9.96 mi: "%.1f" alone gave "10.0 mi" next to whole-number "10 mi".
        #expect(challengeFormattedDistance(16_029, locale: us) == "10 mi")
    }

    @Test func progressRoundsDownUntilTheGoalIsReached() throws {
        let challenge = try #require(distanceChallenge(goalMeters: 20_921))
        // 12.6 mi of 13: rounding to the nearest would read "13 mi / 13 mi".
        #expect(challenge.formattedDistanceProgress(20_278, locale: us) == "12 mi")
        // 9.96 mi stays below ten.
        #expect(challenge.formattedDistanceProgress(16_029, locale: us) == "9.9 mi")
        // Reaching the goal reads as the goal, not 12.9997 rounded down to 12.
        #expect(challenge.formattedDistanceProgress(20_921, locale: us) == "13 mi")
        // Past the goal, the real distance (20.0 mi), not the goal.
        #expect(challenge.formattedDistanceProgress(32_187, locale: us) == "20 mi")
    }
}
