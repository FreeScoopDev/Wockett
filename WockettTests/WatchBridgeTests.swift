import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import PoCSquat

/// The iPhone side of the Watch walk remote: each watch command reaches the
/// store through the app's existing paths, state goes out throttled, and a
/// Start that could not track is refused. Each test builds its own store,
/// inbox and fake sink; nothing touches WatchConnectivity.
@MainActor
struct WatchBridgeTests {

    final class FakeSink: WatchStateSink {
        var sent: [WatchWalkState] = []
        func send(_ state: WatchWalkState) { sent.append(state) }
    }

    final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    struct Rig {
        let bridge: WatchBridge
        let store: ActiveWalkStore
        let inbox: WalkIntentInbox
        let history: WalkHistoryStore
        let sink: FakeSink
        let clock: Clock
    }

    private func rig(canStart: Bool = true, usesMiles: Bool = false) throws -> Rig {
        let config = ModelConfiguration(schema: AppModelContainer.schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppModelContainer.schema, configurations: config)
        let history = WalkHistoryStore(context: ModelContext(container))
        let store = ActiveWalkStore(historyStore: history, isAppActive: { false })
        let suite = "wkt.tests.watch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let inbox = WalkIntentInbox(store: defaults)
        let clock = Clock()
        let bridge = WatchBridge(store: store, inbox: inbox, canStart: { _ in canStart },
                                 isAppActive: { false }, usesMiles: { usesMiles },
                                 now: { clock.now }, startWait: 0)
        let sink = FakeSink()
        bridge.sink = sink
        return Rig(bridge: bridge, store: store, inbox: inbox, history: history, sink: sink, clock: clock)
    }

    /// A free session as the walk screen begins one, without its sensors.
    @discardableResult
    private func beginFree(_ rig: Rig, mode: ActivityMode = .walking) throws -> NavigationSessionManager {
        let stub = NavigableRoute(name: "Free", waypoints: [], lapCount: 1, isLoop: false, totalDistance: 0,
                                  isCustomRoute: true, isCommunityRoute: false, activityMode: mode, customRouteId: nil)
        let session = try #require(rig.store.beginSession(route: stub))
        session.writesSnapshots = false
        rig.store.markStarted()
        return session
    }

    private func phase(_ reply: WatchReply) -> WatchWalkPhase? {
        if case .state(let state) = reply { return state.phase }
        return nil
    }

    // MARK: - Commands

    @Test func pauseAndResume_actOnTheSession_andReplyWithItsState() async throws {
        let rig = try rig()
        let session = try beginFree(rig)

        #expect(phase(await rig.bridge.handle(.pause)) == .paused)
        #expect(session.isPaused)
        // A second Pause never toggles it back.
        #expect(phase(await rig.bridge.handle(.pause)) == .paused)
        #expect(session.isPaused)

        #expect(phase(await rig.bridge.handle(.resume)) == .running)
        #expect(!session.isPaused)
        #expect(phase(await rig.bridge.handle(.resume)) == .running)
        #expect(!session.isPaused)
    }

    @Test func finish_savesThroughTheStore_andRepliesWithTheSummary() async throws {
        let rig = try rig()
        let session = try beginFree(rig, mode: .running)
        session.totalDistanceCovered = 2_400
        session.elapsedTime = 900

        let reply = await rig.bridge.handle(.finish)

        #expect(rig.history.sessions.count == 1, "saved once, through ActiveWalkStore.end(.save)")
        #expect(rig.store.session == nil)
        guard case .state(let state) = reply else { Issue.record("expected a state, got \(reply)"); return }
        #expect(state.phase == .ended)
        #expect(state.mode == .running)
        #expect(state.summary == WatchWalkSummary(distanceMeters: 2_400, movingSeconds: 900))
        // Finish again: nothing left to end.
        #expect(await rig.bridge.handle(.finish) == .noActiveSession)
        #expect(rig.history.sessions.count == 1)
    }

    @Test func pauseResumeFinish_withNothingRunning_sayNoActiveSession() async throws {
        let rig = try rig()
        #expect(await rig.bridge.handle(.pause) == .noActiveSession)
        #expect(await rig.bridge.handle(.resume) == .noActiveSession)
        #expect(await rig.bridge.handle(.finish) == .noActiveSession)
        #expect(rig.history.sessions.isEmpty)
    }

    @Test func requestState_repliesWithTheCurrentState() async throws {
        let rig = try rig()
        #expect(phase(await rig.bridge.handle(.requestState)) == .idle)
        try beginFree(rig)
        #expect(phase(await rig.bridge.handle(.requestState)) == .running)
    }

    @Test(arguments: WatchActivity.allCases)
    func start_postsTheSameRequestSiriDoes(activity: WatchActivity) async throws {
        let rig = try rig(canStart: true)
        _ = await rig.bridge.handle(.start(activity))
        #expect(rig.inbox.pending == WalkIntentRequest(mode: WatchBridge.mode(for: activity)))
        #expect(rig.inbox.pending?.mode.rawValue == activity.rawValue)
    }

    @Test func start_thatCannotTrack_isRefused_andStartsNothing() async throws {
        let rig = try rig(canStart: false)
        #expect(await rig.bridge.handle(.start(.walking)) == .needsPhone)
        #expect(rig.inbox.pending == nil)
        #expect(rig.store.session == nil)
    }

    @Test func start_whileAWalkRuns_showsIt_andPostsNothing() async throws {
        let rig = try rig(canStart: true)
        try beginFree(rig, mode: .cycling)
        let reply = await rig.bridge.handle(.start(.running))
        guard case .state(let state) = reply else { Issue.record("expected a state"); return }
        #expect(state.mode == .cycling)
        #expect(state.phase == .running)
        #expect(rig.inbox.pending == nil)
    }

    @Test func canStartNow_onlyInFront_andOutdoorsOnlyWithLocation() {
        #expect(!WatchBridge.canStartNow(.walking, appIsActive: false, authorization: { .authorizedWhenInUse }))
        #expect(!WatchBridge.canStartNow(.stationary, appIsActive: false, authorization: { .authorizedWhenInUse }))
        #expect(WatchBridge.canStartNow(.walking, appIsActive: true, authorization: { .authorizedWhenInUse }))
        #expect(!WatchBridge.canStartNow(.cycling, appIsActive: true, authorization: { .denied }))
        #expect(!WatchBridge.canStartNow(.running, appIsActive: true, authorization: { .restricted }))
        #expect(WatchBridge.canStartNow(.stationary, appIsActive: true, authorization: { .denied }))
    }

    // MARK: - State

    @Test func rideSendsSpeed_walkAndRunSendPace() throws {
        let ride = try rig()
        let rideSession = try beginFree(ride, mode: .cycling)
        rideSession.totalDistanceCovered = 1_000
        rideSession.elapsedTime = 200
        let rideState = ride.bridge.currentState()
        #expect(rideState.mode == .cycling)
        #expect(rideState.averageSpeedMetersPerSecond == 5)
        #expect(rideState.averagePaceSecsPerKm == nil)

        let run = try rig()
        let runSession = try beginFree(run, mode: .running)
        runSession.totalDistanceCovered = 1_000
        runSession.elapsedTime = 300
        let runState = run.bridge.currentState()
        #expect(runState.mode == .running)
        #expect(runState.averagePaceSecsPerKm == 300)
        #expect(runState.averageSpeedMetersPerSecond == nil)
    }

    @Test func sendsTheUnitPreference() throws {
        #expect(try rig(usesMiles: true).bridge.currentState().usesMiles)
        #expect(try !rig(usesMiles: false).bridge.currentState().usesMiles)
    }

    @Test func indoorWalk_isShown_butCannotBeControlledFromTheWatch() async throws {
        let rig = try rig()
        rig.bridge.indoorWalk = IndoorWalkReading(startDate: rig.clock.now, distanceMeters: 300)
        let state = rig.bridge.currentState()
        #expect(state.mode == .stationary)
        #expect(state.phase == .running)
        #expect(state.distanceMeters == 300)
        #expect(!state.controllable)
        #expect(await rig.bridge.handle(.pause) == .needsPhone)
        #expect(await rig.bridge.handle(.finish) == .needsPhone)
        #expect(rig.history.sessions.isEmpty)
    }

    // MARK: - Throttle

    @Test func distanceOnlyUpdates_areThrottledToFiveSeconds_phaseChangesAreNot() throws {
        let rig = try rig()
        let session = try beginFree(rig)
        rig.bridge.refresh()
        #expect(rig.sink.sent.count == 1)

        session.totalDistanceCovered = 20
        rig.clock.now += 1
        rig.bridge.refresh()
        #expect(rig.sink.sent.count == 1, "distance alone, 1 s after the last send")

        rig.clock.now += 4
        rig.bridge.refresh()
        #expect(rig.sink.sent.count == 2, "5 s on, the new distance goes")
        #expect(rig.sink.sent.last?.distanceMeters == 20)

        rig.clock.now += 1
        session.pause()
        rig.bridge.refresh()
        #expect(rig.sink.sent.count == 3, "a pause goes at once")
        #expect(rig.sink.sent.last?.phase == .paused)

        rig.clock.now += 1
        rig.bridge.refresh()
        #expect(rig.sink.sent.count == 3, "nothing changed")
    }

    @Test func throttle_decisions() {
        let t0 = Date(timeIntervalSince1970: 0)
        var running = WatchWalkState(mode: .walking, phase: .running, usesMiles: false)
        running.distanceMeters = 10
        var throttle = WatchSendThrottle()
        #expect(throttle.decide(running, now: t0) == .sendNow)
        throttle.didSend(running, at: t0)

        var moved = running
        moved.distanceMeters = 10.6
        #expect(throttle.decide(moved, now: t0 + 2) == .skip, "under a metre is not a change")
        moved.distanceMeters = 14
        #expect(throttle.decide(moved, now: t0 + 2) == .sendAt(t0 + 5))
        #expect(throttle.decide(moved, now: t0 + 5) == .sendNow)

        var paused = running
        paused.phase = .paused
        #expect(throttle.decide(paused, now: t0 + 1) == .sendNow)
    }

    // MARK: - Mapping and launch

    @Test func everyActivityMapsBothWays_withTheSameRawValue() {
        for activity in WatchActivity.allCases {
            let mode = WatchBridge.mode(for: activity)
            #expect(mode.rawValue == activity.rawValue)
            #expect(WatchBridge.watchActivity(for: mode) == activity)
            #expect(activity.noun == mode.noun || mode == .stationary)
        }
    }

    @Test func activate_underTests_leavesWatchConnectivityAlone() throws {
        let rig = try rig()
        rig.bridge.sink = nil
        rig.bridge.activate()
        #expect(rig.bridge.sink == nil)
    }
}
