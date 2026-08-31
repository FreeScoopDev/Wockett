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
        flagged: Bool = false
    ) -> WalkSession {
        WalkSession(
            id: UUID(), routeName: "Test", date: Date(),
            elapsedTime: elapsed, totalDistance: distance,
            waypoints: [], lapCount: 1, isLoop: false,
            activePetIds: petIds, activityType: activityType,
            flaggedPossibleVehicle: flagged
        )
    }

    // MARK: - First-ever session

    // A session > 200 m with no prior history earns longestWalk.
    @Test func firstSession_earnsLongestWalk() {
        let s   = session(distance: 500, elapsed: 300)
        let prs = checkNewPRs(newSession: s, against: [])
        #expect(prs.contains { if case .longestWalk = $0 { return true }; return false })
    }

    // A session > 500 m with no prior history earns both longestWalk and fastestPace
    // (prevBest pace is ∞ for empty history).
    @Test func firstSession_earnsLongestAndFastestWhenOver500m() {
        let s   = session(distance: 1000, elapsed: 600)
        let prs = checkNewPRs(newSession: s, against: [])
        #expect(prs.count == 2)
        #expect(prs.contains { if case .longestWalk = $0 { return true }; return false })
        #expect(prs.contains { if case .fastestPace = $0 { return true }; return false })
    }

    // MARK: - Beating a previous record

    // New session longer than previous best → earns longestWalk only
    // (same pace as previous → no fastestPace).
    @Test func beatingDistance_earnsLongestWalkOnly() {
        let prev = session(distance: 3000, elapsed: 1800) // 600 s/km
        let new  = session(distance: 5000, elapsed: 3000) // 600 s/km — same pace, longer
        let prs  = checkNewPRs(newSession: new, against: [prev])
        #expect(prs.count == 1)
        #expect(prs.contains { if case .longestWalk = $0 { return true }; return false })
    }

    // New session faster than previous best pace → earns fastestPace only
    // (shorter than previous → no longestWalk).
    @Test func beatingPace_earnsFastestPaceOnly() {
        let prev = session(distance: 5000, elapsed: 3000) // 600 s/km
        let new  = session(distance: 1000, elapsed: 500)  // 500 s/km — faster, shorter
        let prs  = checkNewPRs(newSession: new, against: [prev])
        // new is shorter → no longestWalk
        #expect(prs.contains { if case .fastestPace = $0 { return true }; return false })
        #expect(!prs.contains { if case .longestWalk = $0 { return true }; return false })
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

    // Sessions with active pets do not earn PRs.
    @Test func sessionWithPets_neverEarnsPR() {
        let s = session(distance: 5000, elapsed: 1800, petIds: [UUID()])
        #expect(checkNewPRs(newSession: s, against: []).isEmpty)
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
        #expect(!prs.contains { if case .fastestPace = $0 { return true }; return false })
    }

    // Flagged sessions in history are also excluded from the comparison baseline.
    @Test func flaggedPreviousSession_excludedFromBaseline() {
        // Previous session is flagged — should not count as a distance record to beat.
        let prev    = session(distance: 10_000, elapsed: 3000, flagged: true)
        let new     = session(distance: 5000, elapsed: 1800)
        let prs     = checkNewPRs(newSession: new, against: [prev])
        // Without the flagged session in the baseline, 5000 m > prevLongest (0) → earns longestWalk.
        #expect(prs.contains { if case .longestWalk = $0 { return true }; return false })
    }
}
