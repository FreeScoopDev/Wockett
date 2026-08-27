import Testing
import Foundation
@testable import PoCSquat

struct StreakStoreTests {

    // MARK: - Helpers

    private func date(daysAgo: Int = 0, hour: Int = 10) -> Date {
        let cal  = Calendar.current
        let base = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: Date())) ?? Date()
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
    }

    private func session(
        distance: Double = 2_000,
        activityType: String = "walking",
        daysAgo: Int = 0,
        hour: Int = 10,
        activePetIds: [UUID] = [],
        notes: String = "",
        isCommunityRoute: Bool = false
    ) -> WalkSession {
        WalkSession(
            id: UUID(), routeName: "Test", date: date(daysAgo: daysAgo, hour: hour),
            elapsedTime: 1_800, totalDistance: distance,
            waypoints: [], lapCount: 1, isLoop: false,
            activePetIds: activePetIds, activityType: activityType,
            notes: notes, isCommunityRoute: isCommunityRoute
        )
    }

    private func badge(_ type: WalkBadgeType) -> WalkBadge {
        WalkBadge(id: "test", name: "Test", description: "", emoji: "⭐", type: type)
    }

    // MARK: - Distance (walking-only)

    @Test func distanceBadge_earned_whenWalkingMeetsThreshold() {
        let b = badge(.distance(km: 5))
        #expect(b.isEarned(sessions: [session(distance: 5_100)], currentStreak: 0))
    }

    @Test func distanceBadge_notEarned_belowThreshold() {
        let b = badge(.distance(km: 10))
        #expect(!b.isEarned(sessions: [session(distance: 5_000)], currentStreak: 0))
    }

    @Test func distanceBadge_excludesCyclingSessions() {
        let b = badge(.distance(km: 5))
        // 5 km of cycling + 0 walking → walking distance badge not earned
        let s = session(distance: 5_100, activityType: "cycling")
        #expect(!b.isEarned(sessions: [s], currentStreak: 0))
    }

    // MARK: - Rides

    @Test func rideBadge_earnedFromCyclingDistanceOnly() {
        let b = badge(.rideKm(km: 5))
        let s = session(distance: 5_100, activityType: "cycling")
        #expect(b.isEarned(sessions: [s], currentStreak: 0))
    }

    @Test func rideBadge_notEarned_fromWalkingSessions() {
        let b = badge(.rideKm(km: 5))
        let s = session(distance: 5_100, activityType: "walking")
        #expect(!b.isEarned(sessions: [s], currentStreak: 0))
    }

    // MARK: - Ride streak

    @Test func rideStreak_earnedForConsecutiveCyclingDays() {
        let b = badge(.rideStreak(days: 2))
        let sessions = [
            session(distance: 5_000, activityType: "cycling", daysAgo: 0),
            session(distance: 5_000, activityType: "cycling", daysAgo: 1),
        ]
        #expect(b.isEarned(sessions: sessions, currentStreak: 0))
    }

    @Test func rideStreak_brokenByGapDay() {
        let b = badge(.rideStreak(days: 2))
        let sessions = [
            session(distance: 5_000, activityType: "cycling", daysAgo: 0),
            session(distance: 5_000, activityType: "cycling", daysAgo: 3), // gap
        ]
        #expect(!b.isEarned(sessions: sessions, currentStreak: 0))
    }

    // MARK: - Cross-train

    @Test func crossTrainDay_earnedWithBothActivitiesOnSameDay() {
        let b = badge(.crossTrainDay)
        let sessions = [
            session(distance: 2_000, activityType: "walking"),
            session(distance: 2_000, activityType: "cycling"),
        ]
        #expect(b.isEarned(sessions: sessions, currentStreak: 0))
    }

    @Test func crossTrainDay_notEarned_withWalkingOnly() {
        let b = badge(.crossTrainDay)
        let sessions = [session(distance: 2_000), session(distance: 2_000)]
        #expect(!b.isEarned(sessions: sessions, currentStreak: 0))
    }

    // MARK: - Pets

    @Test func petWalkBadge_earnedAfterEnoughSessionsWithPet() {
        let b = badge(.petWalks(n: 2))
        let petId = UUID()
        let sessions = [
            session(activePetIds: [petId]),
            session(activePetIds: [petId]),
        ]
        #expect(b.isEarned(sessions: sessions, currentStreak: 0))
    }

    @Test func multiPetWalkBadge_requiresTwoPetsInOneSession() {
        let b = badge(.multiPetWalk)
        let oneAtATime = [session(activePetIds: [UUID()])]
        let twoAtOnce  = [session(activePetIds: [UUID(), UUID()])]
        #expect(!b.isEarned(sessions: oneAtATime, currentStreak: 0))
        #expect(b.isEarned(sessions: twoAtOnce, currentStreak: 0))
    }

    // MARK: - Explorer

    @Test func communityRoutesBadge_countsOnlyCommunityRouteSessions() {
        let b = badge(.communityRoutesCompleted(n: 2))
        let sessions = [
            session(isCommunityRoute: true),
            session(isCommunityRoute: false),
            session(isCommunityRoute: true),
        ]
        #expect(b.isEarned(sessions: sessions, currentStreak: 0))
    }

    // MARK: - Consistency / Collection

    @Test func indoorWalkBadge_countsStationarySessions() {
        let b = badge(.indoorWalks(n: 2))
        let sessions = [
            session(activityType: "stationary"),
            session(activityType: "stationary"),
        ]
        #expect(b.isEarned(sessions: sessions, currentStreak: 0))
    }

    @Test func walkNotesBadge_ignoresSessionsWithoutNotes() {
        let b = badge(.walkNotesAdded(n: 2))
        let sessions = [
            session(notes: "Sunny morning"),
            session(notes: ""),           // no note — should not count
            session(notes: "Felt great"),
        ]
        #expect(b.isEarned(sessions: sessions, currentStreak: 0))
    }

    // MARK: - Time-of-day

    @Test func earlyBirdBadge_earnedForPreEightAmSession() {
        let b = badge(.earlyBird)
        #expect(b.isEarned(sessions: [session(hour: 7)], currentStreak: 0))
    }

    @Test func earlyBirdBadge_notEarned_forLaterSession() {
        let b = badge(.earlyBird)
        #expect(!b.isEarned(sessions: [session(hour: 9)], currentStreak: 0))
    }

    // MARK: - Streak

    @Test func streakBadge_progressScalesWithCurrentStreak() {
        let b = badge(.streak(days: 10))
        #expect(b.progress(sessions: [], currentStreak: 5) == 0.5)
    }

    @Test func streakBadge_progressClampedAtOne() {
        let b = badge(.streak(days: 7))
        #expect(b.progress(sessions: [], currentStreak: 30) == 1.0)
    }

    // MARK: - Edge cases

    @Test func progress_isZero_forAllSessionDerivedBadges_withNoSessions() {
        let sessionDerived: [WalkBadgeType] = [
            .distance(km: 1), .rideKm(km: 1), .petWalks(n: 1),
            .indoorWalks(n: 1), .walkNotesAdded(n: 1),
            .communityRoutesCompleted(n: 1), .rideStreak(days: 1),
        ]
        for type in sessionDerived {
            let b = badge(type)
            #expect(b.progress(sessions: [], currentStreak: 0) == 0.0,
                    "Expected zero progress for \(type) with no sessions")
        }
    }

    @Test func distanceBadge_progress_accumulatesAcrossMultipleSessions() {
        let b = badge(.distance(km: 10))
        let sessions = [session(distance: 5_000), session(distance: 5_000)]
        #expect(b.progress(sessions: sessions, currentStreak: 0) == 1.0)
    }
}
