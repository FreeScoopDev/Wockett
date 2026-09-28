import Testing
import Foundation
@testable import PoCSquat

struct AutoResumeTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - The rule

    @Test func walkingFor30Seconds_resumesAWalk() {
        var watch = AutoResumeWatch(mode: .walking, pausedAt: t0)
        #expect(watch.observe(.walking, at: t0.addingTimeInterval(60)) == .keepWatching)
        #expect(watch.observe(.walking, at: t0.addingTimeInterval(85)) == .keepWatching)
        #expect(watch.observe(.walking, at: t0.addingTimeInterval(90)) == .resume)
    }

    @Test func aStopInBetween_restartsTheCount() {
        var watch = AutoResumeWatch(mode: .walking, pausedAt: t0)
        _ = watch.observe(.walking, at: t0.addingTimeInterval(60))
        _ = watch.observe(.stationary, at: t0.addingTimeInterval(80))
        #expect(watch.observe(.walking, at: t0.addingTimeInterval(95)) == .keepWatching)
        #expect(watch.observe(.walking, at: t0.addingTimeInterval(124)) == .keepWatching)
        #expect(watch.observe(.walking, at: t0.addingTimeInterval(125)) == .resume)
    }

    @Test func lowConfidence_doesNotCount() {
        var watch = AutoResumeWatch(mode: .walking, pausedAt: t0)
        _ = watch.observe(.walking, at: t0.addingTimeInterval(60))
        _ = watch.observe(nil, at: t0.addingTimeInterval(70))
        #expect(watch.observe(.walking, at: t0.addingTimeInterval(95)) == .keepWatching)
    }

    @Test func aRide_needsCycling_notWalking() {
        var ride = AutoResumeWatch(mode: .cycling, pausedAt: t0)
        _ = ride.observe(.walking, at: t0.addingTimeInterval(60))
        #expect(ride.observe(.walking, at: t0.addingTimeInterval(120)) == .keepWatching)

        var riding = AutoResumeWatch(mode: .cycling, pausedAt: t0)
        _ = riding.observe(.cycling, at: t0.addingTimeInterval(60))
        #expect(riding.observe(.cycling, at: t0.addingTimeInterval(90)) == .resume)
    }

    @Test func aRun_resumesOnAJogOrAWalk() {
        var run = AutoResumeWatch(mode: .running, pausedAt: t0)
        _ = run.observe(.running, at: t0.addingTimeInterval(60))
        #expect(run.observe(.walking, at: t0.addingTimeInterval(90)) == .resume)
    }

    @Test func after30Minutes_givesUp() {
        var watch = AutoResumeWatch(mode: .walking, pausedAt: t0)
        #expect(watch.observe(.stationary, at: t0.addingTimeInterval(29 * 60)) == .keepWatching)
        #expect(watch.observe(.stationary, at: t0.addingTimeInterval(30 * 60)) == .giveUp)
    }

    // MARK: - The session

    private func walk() -> NavigableRoute {
        NavigableRoute(name: "Free Walk", waypoints: [], lapCount: 1, isLoop: false, totalDistance: 0)
    }

    @Test @MainActor func session_resumesAndClearsTheBreakPrompt() {
        let mgr = NavigationSessionManager(route: walk())
        mgr.showBreakPrompt = true
        mgr.autoPause(at: t0)
        #expect(mgr.isPaused)
        #expect(mgr.autoPausedForInactivity)

        mgr.autoResumeTick(confident: .walking, at: t0.addingTimeInterval(10))
        #expect(mgr.isPaused)
        mgr.autoResumeTick(confident: .walking, at: t0.addingTimeInterval(40))
        #expect(!mgr.isPaused)
        #expect(!mgr.autoPausedForInactivity)
        #expect(!mgr.showBreakPrompt)
        mgr.stop()
    }

    @Test @MainActor func session_afterGivingUp_staysPaused() {
        let mgr = NavigationSessionManager(route: walk())
        mgr.autoPause(at: t0)
        mgr.autoResumeTick(confident: .stationary, at: t0.addingTimeInterval(31 * 60))
        mgr.autoResumeTick(confident: .walking, at: t0.addingTimeInterval(32 * 60))
        mgr.autoResumeTick(confident: .walking, at: t0.addingTimeInterval(33 * 60))
        #expect(mgr.isPaused)
        mgr.stop()
    }

    @Test @MainActor func manualPause_isNeverAutoResumed() {
        let mgr = NavigationSessionManager(route: walk())
        mgr.pause()
        mgr.autoResumeTick(confident: .walking, at: t0)
        mgr.autoResumeTick(confident: .walking, at: t0.addingTimeInterval(60))
        #expect(mgr.isPaused)
        mgr.stop()
    }
}
