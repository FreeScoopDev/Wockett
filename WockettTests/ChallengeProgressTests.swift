import Testing
import CloudKit
@testable import PoCSquat

// WalkChallenge.localProgressValue(from:) is a pure function on the model struct —
// no CloudKit network traffic occurs in these tests. We construct CKRecord objects
// in memory solely to satisfy the existing designated initializer.

struct ChallengeProgressTests {

    // MARK: - Helpers

    private func makeChallenge(
        goalType: ChallengeGoalType,
        activityFilter: String? = nil,
        goalSteps: Int = 10_000,
        goalDistanceMeters: Double = 10_000,
        goalPaceSecsPerKm: Double = 360,
        goalSessionCount: Int = 3,
        startDate: Date = Date().addingTimeInterval(-86400 * 3),
        endDate: Date = Date().addingTimeInterval(86400 * 3)
    ) -> WalkChallenge? {
        let record = CKRecord(recordType: "Challenge")
        record["title"]               = "Test Challenge"
        record["startDate"]           = startDate as CKRecordValue
        record["endDate"]             = endDate   as CKRecordValue
        record["goalType"]            = goalType.rawValue as CKRecordValue
        record["goalSteps"]           = goalSteps          as CKRecordValue
        record["goalDistanceMeters"]  = goalDistanceMeters as CKRecordValue
        record["goalPaceSecsPerKm"]   = goalPaceSecsPerKm  as CKRecordValue
        record["goalSessionCount"]    = goalSessionCount    as CKRecordValue
        if let filter = activityFilter {
            record["activityFilter"]  = filter as CKRecordValue
        }
        return WalkChallenge(record: record)
    }

    private func session(
        distance: Double,
        elapsed: TimeInterval,
        activityType: String = "walking",
        flagged: Bool = false,
        date: Date = Date(),
        steps: Int = 0
    ) -> WalkSession {
        WalkSession(
            id: UUID(), routeName: "Test", date: date,
            elapsedTime: elapsed, totalDistance: distance,
            waypoints: [], lapCount: 1, isLoop: false,
            activityType: activityType, steps: steps,
            flaggedPossibleVehicle: flagged
        )
    }

    // MARK: - Distance goal

    @Test func distanceGoal_accumulatesMatchingSessions() throws {
        let challenge = try #require(makeChallenge(goalType: .distance, goalDistanceMeters: 10_000))
        let sessions  = [
            session(distance: 3000, elapsed: 1200),
            session(distance: 4000, elapsed: 1600),
        ]
        #expect(challenge.localProgressValue(from: sessions) == 7000)
    }

    @Test func distanceGoal_excludesFlaggedSessions() throws {
        let challenge = try #require(makeChallenge(goalType: .distance))
        let sessions  = [
            session(distance: 5000, elapsed: 2000, flagged: true),
            session(distance: 2000, elapsed: 800),
        ]
        #expect(challenge.localProgressValue(from: sessions) == 2000)
    }

    @Test func distanceGoal_activityFilterExcludesMismatch() throws {
        let challenge = try #require(makeChallenge(goalType: .distance, activityFilter: "running"))
        let sessions  = [
            session(distance: 4000, elapsed: 1600, activityType: "cycling"),
            session(distance: 2000, elapsed: 800,  activityType: "running"),
        ]
        #expect(challenge.localProgressValue(from: sessions) == 2000)
    }

    @Test func distanceGoal_nilFilterAcceptsAllActivityTypes() throws {
        let challenge = try #require(makeChallenge(goalType: .distance, activityFilter: nil))
        let sessions  = [
            session(distance: 3000, elapsed: 1200, activityType: "walking"),
            session(distance: 2000, elapsed: 800,  activityType: "cycling"),
        ]
        #expect(challenge.localProgressValue(from: sessions) == 5000)
    }

    // MARK: - Pace goal

    // goalPaceSecsPerKm: 360 (6:00/km); sessions under that threshold qualify.
    @Test func paceGoal_countsQualifyingSessions() throws {
        let challenge = try #require(makeChallenge(goalType: .pace, goalPaceSecsPerKm: 360, goalSessionCount: 3))
        let sessions  = [
            session(distance: 1000, elapsed: 300), // 300 s/km < 360 → qualifies
            session(distance: 1000, elapsed: 400), // 400 s/km ≥ 360 → does not qualify
            session(distance: 1000, elapsed: 350), // 350 s/km < 360 → qualifies
        ]
        #expect(challenge.localProgressValue(from: sessions) == 2)
    }

    @Test func paceGoal_flaggedSessionsContributeNothing() throws {
        let challenge = try #require(makeChallenge(goalType: .pace, goalPaceSecsPerKm: 360))
        let sessions  = [
            session(distance: 1000, elapsed: 300, flagged: true), // flagged → excluded
            session(distance: 1000, elapsed: 300),                 // qualifies
        ]
        #expect(challenge.localProgressValue(from: sessions) == 1)
    }

    @Test func paceGoal_cyclingSessionDoesNotContributeToRunChallenge() throws {
        let challenge = try #require(makeChallenge(goalType: .pace, activityFilter: "running", goalPaceSecsPerKm: 360))
        let sessions  = [
            session(distance: 1000, elapsed: 300, activityType: "cycling"), // wrong type
            session(distance: 1000, elapsed: 300, activityType: "running"), // qualifies
        ]
        #expect(challenge.localProgressValue(from: sessions) == 1)
    }

    // MARK: - Steps goal (regression)

    // Steps challenges count walks recorded in Wockett, never Apple Health: the
    // total is public (2026-10-12 audit, finding 2). Until 1.16 this returned 0
    // and the screens asked HealthKit instead.
    @Test func stepsGoal_countsRecordedSteps() throws {
        let challenge = try #require(makeChallenge(goalType: .steps, goalSteps: 10_000))
        let sessions  = [
            session(distance: 5000, elapsed: 1800, steps: 6_400),
            session(distance: 1000, elapsed: 900, activityType: "running", steps: 900),
        ]
        #expect(challenge.localProgressValue(from: sessions) == 7_300)
    }

    // A walk from before 1.7 has no pedometer count: distance / 0.762 m, as everywhere else.
    @Test func stepsGoal_estimatesOldWalksFromDistance() throws {
        let challenge = try #require(makeChallenge(goalType: .steps))
        #expect(challenge.localProgressValue(from: [session(distance: 762, elapsed: 600)]) == 1_000)
    }

    // A bike has no steps; the distance estimate would turn 20 km into 26,246.
    @Test func stepsGoal_neverCountsRides() throws {
        let challenge = try #require(makeChallenge(goalType: .steps))
        let sessions  = [
            session(distance: 20_000, elapsed: 3600, activityType: "cycling"),
            session(distance: 5_000, elapsed: 900, activityType: "cycling", steps: 300),
            session(distance: 1_000, elapsed: 600, steps: 1_200),
        ]
        #expect(challenge.localProgressValue(from: sessions) == 1_200)
    }

    @Test func stepsGoal_skipsVehicleAndOutOfWindow() throws {
        let challenge = try #require(makeChallenge(goalType: .steps,
                                                   startDate: Date().addingTimeInterval(-86400),
                                                   endDate: Date().addingTimeInterval(86400)))
        let sessions  = [
            session(distance: 1000, elapsed: 600, steps: 1_500),
            session(distance: 1000, elapsed: 600, flagged: true, steps: 2_000),
            session(distance: 1000, elapsed: 600, date: Date().addingTimeInterval(-86400 * 2), steps: 4_000),
        ]
        #expect(challenge.localProgressValue(from: sessions) == 1_500)
    }

    // The create sheet hides the Activity picker for steps but used to publish a
    // leftover choice; a stray filter must not change a step total (critic, 2026-10-13).
    @Test func stepsGoal_ignoresActivityFilter() throws {
        let challenge = try #require(makeChallenge(goalType: .steps, activityFilter: "cycling"))
        let sessions  = [
            session(distance: 1000, elapsed: 600, steps: 1_300),
            session(distance: 1000, elapsed: 300, activityType: "running", steps: 900),
            session(distance: 9000, elapsed: 1800, activityType: "cycling"),
        ]
        #expect(challenge.localProgressValue(from: sessions) == 2_200)
    }

    @Test func syncFootnoteNamesTheSource() {
        for type in [ChallengeGoalType.steps, .distance, .pace] {
            let text = ChallengeSyncCopy.footnote(for: type)
            #expect(text.contains("recorded in Wockett"))
            #expect(text.contains("not Apple Health"))
            #expect(text.contains("public leaderboard"))
        }
    }

    // MARK: - Progress cap

    @Test func distanceProgress_neverExceeds100Percent() throws {
        let challenge = try #require(makeChallenge(goalType: .distance, goalDistanceMeters: 5000))
        let sessions  = [session(distance: 20_000, elapsed: 5000)]
        let value     = challenge.localProgressValue(from: sessions)
        let progress  = challenge.progress(for: value)
        #expect(progress <= 1.0)
    }

    @Test func paceProgress_neverExceeds100Percent() throws {
        let challenge = try #require(makeChallenge(goalType: .pace, goalPaceSecsPerKm: 360, goalSessionCount: 2))
        // 5 qualifying sessions against a goal of 2
        let sessions  = (0..<5).map { _ in session(distance: 1000, elapsed: 300) }
        let value     = challenge.localProgressValue(from: sessions)
        let progress  = challenge.progress(for: value)
        #expect(progress <= 1.0)
    }
}
