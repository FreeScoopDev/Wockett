import Testing
import CloudKit
@testable import PoCSquat

// ChallengeShareMessage is pure: a challenge built from an in-memory CKRecord,
// and a fixed locale so mi/km and the number grouping don't follow the
// simulator's settings.

struct ChallengeShareMessageTests {

    private let us = Locale(identifier: "en_US")      // miles
    private let canada = Locale(identifier: "en_CA")  // kilometres

    private func makeChallenge(
        title: String = "Weekend Runfest",
        goalType: ChallengeGoalType,
        activityFilter: String? = nil,
        goalSteps: Int = 50_000,
        goalDistanceMeters: Double = 10_000,
        goalPaceSecsPerKm: Double = 480,
        goalSessionCount: Int = 3,
        days: Int = 7
    ) throws -> WalkChallenge {
        // June: no daylight-saving change inside the window in any time zone,
        // so durationDays is exactly `days` wherever the test runs.
        let start = Date(timeIntervalSince1970: 1_780_315_200) // 2026-06-01 12:00 UTC
        let record = CKRecord(recordType: "Challenge")
        record["title"]              = title as CKRecordValue
        record["startDate"]          = start as CKRecordValue
        record["endDate"]            = start.addingTimeInterval(Double(days) * 86_400) as CKRecordValue
        record["goalType"]           = goalType.rawValue as CKRecordValue
        record["goalSteps"]          = goalSteps as CKRecordValue
        record["goalDistanceMeters"] = goalDistanceMeters as CKRecordValue
        record["goalPaceSecsPerKm"]  = goalPaceSecsPerKm as CKRecordValue
        record["goalSessionCount"]   = goalSessionCount as CKRecordValue
        if let activityFilter { record["activityFilter"] = activityFilter as CKRecordValue }
        return try #require(WalkChallenge(record: record))
    }

    // MARK: - Whole message

    @Test func stepsMessage_hasTitleGoalDurationLinkAndWhereToJoin() throws {
        let challenge = try makeChallenge(goalType: .steps)
        let text = ChallengeShareMessage.text(for: challenge, isMine: true, locale: us)
        #expect(text == """
        Join my "Weekend Runfest" challenge on Wockett: 50,000 steps in 7 days.

        Get Wockett: https://apps.apple.com/app/id6794364736
        Then open Community → Challenges to join.
        """)
    }

    @Test func someoneElsesChallenge_isTheNotMy() throws {
        let challenge = try makeChallenge(goalType: .steps)
        let text = ChallengeShareMessage.text(for: challenge, isMine: false, locale: us)
        #expect(text.hasPrefix("Join the \"Weekend Runfest\" challenge on Wockett: "))
    }

    @Test func oneDayChallenge_isSingular() throws {
        let challenge = try makeChallenge(goalType: .steps, goalSteps: 10_000, days: 1)
        let text = ChallengeShareMessage.text(for: challenge, isMine: true, locale: us)
        #expect(text.contains(": 10,000 steps in 1 day."))
    }

    // MARK: - Distance

    @Test func distance_inMiles_saysTheActivity() throws {
        // 32,187 m = 20.0 mi
        let run = try makeChallenge(goalType: .distance, activityFilter: "running", goalDistanceMeters: 32_187)
        #expect(ChallengeShareMessage.goal(for: run, locale: us) == "run 20 mi")
        let ride = try makeChallenge(goalType: .distance, activityFilter: "cycling", goalDistanceMeters: 32_187)
        #expect(ChallengeShareMessage.goal(for: ride, locale: us) == "bike 20 mi")
    }

    @Test func distance_inKilometres() throws {
        let walk = try makeChallenge(goalType: .distance, activityFilter: "walking", goalDistanceMeters: 10_000)
        #expect(ChallengeShareMessage.goal(for: walk, locale: canada) == "walk 10 km")
        let any = try makeChallenge(goalType: .distance, goalDistanceMeters: 5_000)
        #expect(ChallengeShareMessage.goal(for: any, locale: canada) == "cover 5.0 km")
    }

    @Test func distanceMessage_endsWithDuration() throws {
        let run = try makeChallenge(goalType: .distance, activityFilter: "running", goalDistanceMeters: 10_000, days: 14)
        let text = ChallengeShareMessage.text(for: run, isMine: true, locale: canada)
        #expect(text.contains("challenge on Wockett: run 10 km in 14 days."))
    }

    // MARK: - Pace

    @Test func pace_countsSessionsInTheActivity_inKilometres() throws {
        let runs = try makeChallenge(goalType: .pace, activityFilter: "running", goalPaceSecsPerKm: 480, goalSessionCount: 3)
        #expect(ChallengeShareMessage.goal(for: runs, locale: canada) == "3 runs at 8:00/km pace or faster")
    }

    @Test func pace_inMiles() throws {
        // 480 s/km × 1.60934 = 772 s/mi = 12:52/mi
        let runs = try makeChallenge(goalType: .pace, activityFilter: "running", goalPaceSecsPerKm: 480, goalSessionCount: 5)
        #expect(ChallengeShareMessage.goal(for: runs, locale: us) == "5 runs at 12:52/mi pace or faster")
    }

    @Test func pace_singularAndOtherActivities() throws {
        let oneRide = try makeChallenge(goalType: .pace, activityFilter: "cycling", goalPaceSecsPerKm: 300, goalSessionCount: 1)
        #expect(ChallengeShareMessage.goal(for: oneRide, locale: canada) == "1 ride at 5:00/km pace or faster")
        let walks = try makeChallenge(goalType: .pace, activityFilter: "walking", goalPaceSecsPerKm: 600, goalSessionCount: 7)
        #expect(ChallengeShareMessage.goal(for: walks, locale: canada) == "7 walks at 10:00/km pace or faster")
        let any = try makeChallenge(goalType: .pace, goalPaceSecsPerKm: 420, goalSessionCount: 10)
        #expect(ChallengeShareMessage.goal(for: any, locale: canada) == "10 sessions at 7:00/km pace or faster")
    }
}
