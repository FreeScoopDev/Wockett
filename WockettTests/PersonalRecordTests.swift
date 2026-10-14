import Testing
import Foundation
@testable import PoCSquat

struct PersonalRecordTests {

    // MARK: - Helpers

    private func session(
        distance: Double,
        elapsed: TimeInterval,
        activityType: String = "walking",
        petIds: [UUID] = [],
        flagged: Bool = false,
        steps: Int = 0,
        date: Date = Date()
    ) -> WalkSession {
        WalkSession(
            id: UUID(), routeName: "Test", date: date,
            elapsedTime: elapsed, totalDistance: distance,
            waypoints: [], lapCount: 1, isLoop: false,
            activePetIds: petIds, activityType: activityType,
            steps: steps,
            flaggedPossibleVehicle: flagged
        )
    }

    private func isLongest(_ pr: PRType) -> Bool { if case .longestDistance = pr { return true }; return false }
    private func isFastest(_ pr: PRType) -> Bool { if case .fastest = pr { return true }; return false }

    // MARK: - First-ever session

    // A session > 200 m with no prior history earns longestWalk.
    @Test func firstSession_earnsLongestWalk() {
        let s   = session(distance: 500, elapsed: 300)
        let prs = checkNewPRs(newSession: s, against: [])
        #expect(prs.contains (where: isLongest))
    }

    // A session > 500 m with no prior history earns both longestWalk and fastestPace
    // (prevBest pace is ∞ for empty history).
    @Test func firstSession_earnsLongestAndFastestWhenOver500m() {
        let s   = session(distance: 1000, elapsed: 600)
        let prs = checkNewPRs(newSession: s, against: [])
        #expect(prs.count == 2)
        #expect(prs.contains (where: isLongest))
        #expect(prs.contains (where: isFastest))
    }

    // MARK: - Beating a previous record

    // New session longer than previous best → earns longestWalk only
    // (same pace as previous → no fastestPace).
    @Test func beatingDistance_earnsLongestWalkOnly() {
        let prev = session(distance: 3000, elapsed: 1800) // 600 s/km
        let new  = session(distance: 5000, elapsed: 3000) // 600 s/km — same pace, longer
        let prs  = checkNewPRs(newSession: new, against: [prev])
        #expect(prs.count == 1)
        #expect(prs.contains (where: isLongest))
    }

    // New session faster than previous best pace → earns fastestPace only
    // (shorter than previous → no longestWalk).
    @Test func beatingPace_earnsFastestPaceOnly() {
        let prev = session(distance: 5000, elapsed: 3000) // 600 s/km
        let new  = session(distance: 1000, elapsed: 500)  // 500 s/km — faster, shorter
        let prs  = checkNewPRs(newSession: new, against: [prev])
        // new is shorter → no longestWalk
        #expect(prs.contains (where: isFastest))
        #expect(!prs.contains (where: isLongest))
    }

    // MARK: - No improvement

    @Test func nothingBeaten_returnsEmpty() {
        let prev = session(distance: 5000, elapsed: 2400) // 480 s/km, longer
        let new  = session(distance: 3000, elapsed: 1800) // 600 s/km, shorter and slower
        #expect(checkNewPRs(newSession: new, against: [prev]).isEmpty)
    }

    // MARK: - Guard conditions — PR is never awarded

    // Flagged session is never awarded a PR; the guard is inside checkNewPRs itself.
    @Test func flaggedSession_neverEarnsPR() {
        let s = session(distance: 5000, elapsed: 1800, flagged: true)
        #expect(checkNewPRs(newSession: s, against: []).isEmpty)
    }

    // A walk with pets competes like any other (2026-10-13). Since 1.7 the
    // person's own walk carries its pets, and `activePetIds.isEmpty` kept
    // every dog walk from setting a record.
    @Test func walkWithPets_earnsLongestAndFastest() {
        let prev = session(distance: 3000, elapsed: 1800)                  // 600 s/km
        let s = session(distance: 5000, elapsed: 2500, petIds: [UUID(), UUID()]) // 500 s/km
        let prs = checkNewPRs(newSession: s, against: [prev])
        #expect(prs == [.longestDistance(meters: 5000, mode: .walking), .fastest(secsPerKm: 500, mode: .walking)])
        let onePet = session(distance: 5000, elapsed: 2500, petIds: [UUID()])
        #expect(checkNewPRs(newSession: onePet, against: [prev]).count == 2)
    }

    // A pet's credit entry (one pet, no time: indoor's, and every walk's in
    // 1.6) is neither a record nor a walk to beat.
    @Test func petCreditEntry_neverEarnsOrBlocksARecord() {
        let entry = session(distance: 9000, elapsed: 0, petIds: [UUID()])
        #expect(entry.isPetCreditEntry)
        #expect(checkNewPRs(newSession: entry, against: []).isEmpty)
        let walk = session(distance: 5000, elapsed: 2500)
        #expect(checkNewPRs(newSession: walk, against: [entry]).contains(where: isLongest))
        #expect(!session(distance: 5000, elapsed: 2500, petIds: [UUID()]).isPetCreditEntry, "a real walk has time")
    }

    // Session below the 200 m distance threshold earns nothing.
    @Test func sessionBelowMinimumDistance_earnsNothing() {
        let s = session(distance: 150, elapsed: 120)
        #expect(checkNewPRs(newSession: s, against: []).isEmpty)
    }

    // Stationary sessions don't compete for fastestPace even if distance > 500 m.
    @Test func stationarySession_doesNotEarnFastestPace() {
        let s   = session(distance: 1000, elapsed: 300, activityType: "stationary")
        let prs = checkNewPRs(newSession: s, against: [])
        #expect(!prs.contains (where: isFastest))
    }

    // Flagged sessions in history are also excluded from the comparison baseline.
    @Test func flaggedPreviousSession_excludedFromBaseline() {
        // Previous session is flagged — should not count as a distance record to beat.
        let prev    = session(distance: 10_000, elapsed: 3000, flagged: true)
        let new     = session(distance: 5000, elapsed: 1800)
        let prs     = checkNewPRs(newSession: new, against: [prev])
        // Without the flagged session in the baseline, 5000 m > prevLongest (0) → earns longestWalk.
        #expect(prs.contains (where: isLongest))
    }

    // MARK: - Records belong to one activity type (2026-10-13)

    // A ride never beats a walk's distance: before, a first ride claimed
    // "Longest Walk" over every walk.
    @Test func recordsCompareOnlyWithTheSameActivity() {
        let walk = session(distance: 3000, elapsed: 1800)
        let ride = session(distance: 10_000, elapsed: 1800, activityType: "cycling")
        let walkAfterRide = checkNewPRs(newSession: session(distance: 4000, elapsed: 2400), against: [walk, ride])
        #expect(walkAfterRide.contains(where: isLongest), "the ride is not a walk to beat")
        let rideAfterLongerWalks = checkNewPRs(newSession: session(distance: 2000, elapsed: 300, activityType: "cycling"),
                                               against: [walk])
        #expect(rideAfterLongerWalks == [.longestDistance(meters: 2000, mode: .cycling),
                                         .fastest(secsPerKm: 150, mode: .cycling)])
    }

    @Test func recordTitlesFollowTheActivity() {
        #expect(PRType.longestDistance(meters: 1, mode: .walking).title == "Longest walk")
        #expect(PRType.longestDistance(meters: 1, mode: .running).title == "Longest run")
        #expect(PRType.longestDistance(meters: 1, mode: .cycling).title == "Longest ride")
        #expect(PRType.fastest(secsPerKm: 1, mode: .running).title == "Fastest pace")
        #expect(PRType.fastest(secsPerKm: 1, mode: .cycling).title == "Fastest ride")
    }

    // MARK: - Indoor: steps and time, never distance or pace

    @Test func indoorWalk_setsMostStepsAndLongestTime_neverDistanceOrPace() {
        let s = session(distance: 3048, elapsed: 1800, activityType: "stationary", steps: 4000)
        #expect(checkNewPRs(newSession: s, against: []) == [.mostSteps(4000), .longestTime(1800)])
    }

    @Test func indoorWalk_belowTheStepBar_setsNothing() {
        let s = session(distance: 200, elapsed: 600, activityType: "stationary",
                        steps: minimumRecordIndoorSteps - 1)
        #expect(checkNewPRs(newSession: s, against: []).isEmpty)
        let atBar = session(distance: 200, elapsed: 600, activityType: "stationary",
                            steps: minimumRecordIndoorSteps)
        #expect(checkNewPRs(newSession: atBar, against: []) == [.mostSteps(minimumRecordIndoorSteps), .longestTime(600)])
    }

    @Test func indoorWalk_beatsOnlyEarlierIndoorWalks() {
        let earlierIndoor = session(distance: 4000, elapsed: 3000, activityType: "stationary", steps: 5000)
        let longWalk = session(distance: 9000, elapsed: 7200, steps: 12_000)
        let s = session(distance: 3048, elapsed: 3600, activityType: "stationary", steps: 4000)
        // Fewer steps than the earlier indoor walk, longer time; the outdoor walk doesn't count.
        #expect(checkNewPRs(newSession: s, against: [earlierIndoor, longWalk]) == [.longestTime(3600)])
    }

    // An indoor walk saves each pet's credit as its own entry first. With the
    // pet on for the whole walk that entry has the same steps, and must not
    // stop the walk setting Most steps.
    @Test func indoorPetCreditEntries_areNotWalksToBeat() {
        let petEntry = session(distance: 4000 * 0.762, elapsed: 0, activityType: "stationary", petIds: [UUID()])
        let s = session(distance: 4000 * 0.762, elapsed: 1800, activityType: "stationary", steps: 4000)
        #expect(checkNewPRs(newSession: s, against: [petEntry]).contains(.mostSteps(4000)))
    }

    // MARK: - From history: the records an activity set at the time

    @Test func historyRecords_compareOnlyWithEarlierActivities() {
        let now = Date()
        let first = session(distance: 3000, elapsed: 1800, date: now.addingTimeInterval(-7200))
        let second = session(distance: 5000, elapsed: 3000, date: now)
        let all = [second, first]
        #expect(ActivitySummaryContent.recordsSet(by: second, in: all).contains(where: isLongest))
        // `first` was the longest when it happened, though `second` beat it later.
        #expect(ActivitySummaryContent.recordsSet(by: first, in: all).contains(where: isLongest))
        let shorterLater = session(distance: 1000, elapsed: 600, date: now.addingTimeInterval(60))
        #expect(!ActivitySummaryContent.recordsSet(by: shorterLater, in: all + [shorterLater]).contains(where: isLongest))
    }

    // The entry an indoor walk saves for a pet is the shape the record rules
    // skip, and none is made for 50 steps or fewer.
    @Test func indoorPetCreditEntries_areRecognisedAsCredit() throws {
        #expect(StationaryWalkManager.petCreditEntry(petId: UUID(), name: "Nala", sinceSteps: 10,
                                                     currentSteps: 60, start: Date()) == nil)
        let entry = try #require(StationaryWalkManager.petCreditEntry(
            petId: UUID(), name: "Nala", sinceSteps: 0, currentSteps: 4000, start: Date()))
        #expect(entry.isPetCreditEntry)
        #expect(entry.routeName == "Nala's Indoor Walk")
        #expect(entry.estimatedSteps == 4000)
    }
}
