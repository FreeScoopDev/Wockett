import Testing
import Foundation
@testable import PoCSquat

/// The shared Watch message types (WatchWalkLink.swift, compiled into the app
/// and the Watch app): they survive the wire, the watch's numbers read
/// right, and the watch's screen and wrist taps follow the phone's state.
struct WatchWalkLinkTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) -> T? {
        WatchWire.decode(T.self, from: WatchWire.encode(value))
    }

    private func state(_ phase: WatchWalkPhase, mode: WatchActivity = .walking, distance: Double? = nil,
                       start: Date? = Date(timeIntervalSince1970: 1_000), miles: Bool = false) -> WatchWalkState {
        var state = WatchWalkState(mode: mode, phase: phase, usesMiles: miles)
        state.startDate = phase == .idle ? nil : start
        state.distanceMeters = distance
        if phase == .ended { state.summary = WatchWalkSummary(distanceMeters: distance ?? 0, movingSeconds: 600) }
        return state
    }

    // MARK: - Wire

    static let commands: [WatchCommand] = WatchActivity.allCases.map { .start($0) }
        + [.pause, .resume, .finish, .requestState]

    @Test(arguments: commands)
    func everyCommand_roundTrips(command: WatchCommand) {
        #expect(roundTrip(command) == command)
    }

    @Test func everyCommandKind_isCovered() {
        #expect(Self.commands.count == WatchActivity.allCases.count + 4)
    }

    @Test(arguments: WatchWalkPhase.allCases)
    func everyPhase_roundTripsInAFullState(phase: WatchWalkPhase) {
        var full = state(phase, mode: .cycling, distance: 1234.5, miles: true)
        full.pausedDuration = 42
        full.pausedAt = Date(timeIntervalSince1970: 2_000)
        full.currentPaceSecsPerKm = 400
        full.averagePaceSecsPerKm = 410
        full.averageSpeedMetersPerSecond = 4.2
        full.controllable = false
        full.noun = "hike"
        full.title = "Hike"
        #expect(roundTrip(full) == full)
    }

    @Test func everyReply_roundTrips() {
        for reply in [WatchReply.state(state(.running, distance: 10)), .needsPhone, .noActiveSession, .notStarted] {
            #expect(roundTrip(reply) == reply)
        }
    }

    @Test func aMessageWithoutTheKey_decodesToNothing() {
        #expect(WatchWire.decode(WatchCommand.self, from: ["other": Data()]) == nil)
        #expect(WatchWire.decode(WatchCommand.self, from: [:]) == nil)
    }

    // MARK: - Numbers

    @Test func distance_inTheUsersUnit() {
        #expect(WatchWalkFormat.distance(1609.344, usesMiles: true) == "1.00 mi")
        #expect(WatchWalkFormat.distance(2010, usesMiles: false) == "2.01 km")
        #expect(WatchWalkFormat.distance(-5, usesMiles: false) == "0.00 km")
    }

    @Test func pace_andSpeed_inTheUsersUnit() {
        #expect(WatchWalkFormat.pace(secsPerKm: 343, usesMiles: false) == "5:43 /km")
        #expect(WatchWalkFormat.pace(secsPerKm: 343, usesMiles: true) == "9:12 /mi")
        #expect(WatchWalkFormat.pace(secsPerKm: nil, usesMiles: true) == "--:--")
        #expect(WatchWalkFormat.speed(metersPerSecond: 5, usesMiles: false) == "18.0 km/h")
        #expect(WatchWalkFormat.speed(metersPerSecond: 5, usesMiles: true) == "11.2 mph")
        #expect(WatchWalkFormat.speed(metersPerSecond: nil, usesMiles: true) == "--")
        #expect(WatchWalkFormat.duration(2527) == "42:07")
        #expect(WatchWalkFormat.duration(3727) == "1:02:07")
    }

    @Test func nouns_neverSayWalkForARunOrRide() {
        #expect(WatchActivity.running.noun == "run")
        #expect(WatchActivity.cycling.noun == "ride")
        #expect(WatchActivity.running.title == "Run")
        #expect(WatchActivity.stationary.title == "Indoor walk")
        #expect(WatchActivity.cycling.showsSpeed && !WatchActivity.cycling.showsPace)
        #expect(WatchActivity.running.showsPace && !WatchActivity.running.showsSpeed)
        #expect(!WatchActivity.stationary.showsPace && !WatchActivity.stationary.showsSpeed)
    }

    // MARK: - Wrist taps

    @Test func taps_onPauseResumeFinish() {
        #expect(WatchHaptics.events(from: state(.running), to: state(.paused)) == [.paused])
        #expect(WatchHaptics.events(from: state(.paused), to: state(.running)) == [.resumed])
        #expect(WatchHaptics.events(from: state(.running), to: state(.ended)) == [.finished])
        // Ended on the phone with no summary (Live Activity End, mini tile).
        #expect(WatchHaptics.events(from: state(.running), to: state(.idle)) == [.finished])
        #expect(WatchHaptics.events(from: state(.paused), to: state(.idle)) == [.finished])
        #expect(WatchHaptics.events(from: nil, to: state(.paused)).isEmpty, "opening the app mid-walk taps nothing")
        #expect(WatchHaptics.events(from: state(.idle), to: state(.running)).isEmpty)
    }

    @Test func taps_oncePerMileOrKilometre() {
        #expect(WatchHaptics.events(from: state(.running, distance: 990), to: state(.running, distance: 1010))
                == [.marker(1)])
        #expect(WatchHaptics.events(from: state(.running, distance: 1010), to: state(.running, distance: 1500))
                .isEmpty)
        #expect(WatchHaptics.events(from: state(.running, distance: 1500, miles: true),
                                    to: state(.running, distance: 1700, miles: true)) == [.marker(1)])
        #expect(WatchHaptics.events(from: state(.running, distance: 1500, miles: true),
                                    to: state(.running, distance: 1600, miles: true)).isEmpty)
        // A new walk's first fix is not a marker passed.
        #expect(WatchHaptics.events(from: state(.running, distance: 990),
                                    to: state(.running, distance: 1010, start: Date(timeIntervalSince1970: 5)))
                .isEmpty)
    }

    // MARK: - The watch's screen

    @Test func runningState_showsTheLiveScreen() {
        var display = WatchRemoteDisplay()
        #expect(display.screen == .idle)
        _ = display.receive(state(.running))
        #expect(display.screen == .live)
        _ = display.receive(state(.paused))
        #expect(display.screen == .live)
    }

    @Test func endedAfterRunning_showsTheSummary_untilDone() {
        var display = WatchRemoteDisplay()
        _ = display.receive(state(.running))
        let taps = display.receive(state(.ended, distance: 800))
        #expect(taps == [.finished])
        #expect(display.screen == .summary)
        _ = display.receive(state(.idle))
        #expect(display.screen == .summary, "the phone going idle does not take the summary away")
        display.dismissSummary()
        #expect(display.screen == .idle)
    }

    @Test func anOldEndedContext_atLaunch_isNotShownAsASummary() {
        var display = WatchRemoteDisplay()
        _ = display.receive(state(.ended, distance: 800))
        #expect(display.screen == .idle)
    }

    @Test func finishReply_showsTheSummary_evenWithoutTheRunningState() {
        var display = WatchRemoteDisplay()
        let taps = display.receive(reply: .state(state(.ended, distance: 800)), to: .finish)
        #expect(taps == [.finished])
        #expect(display.screen == .summary)
        #expect(display.summary?.summary?.distanceMeters == 800)
    }

    /// A watch Finish arrives twice: the idle context and Finish's own reply,
    /// in either order. One tap, not two.
    @Test func watchFinish_tapsOnce_whicheverMessageArrivesFirst() {
        var contextFirst = WatchRemoteDisplay()
        _ = contextFirst.receive(state(.running))
        let a = contextFirst.receive(state(.idle))
        let b = contextFirst.receive(reply: .state(state(.ended, distance: 800)), to: .finish)
        #expect((a + b).filter { $0 == .finished }.count == 1)
        #expect(contextFirst.screen == .summary)

        var replyFirst = WatchRemoteDisplay()
        _ = replyFirst.receive(state(.running))
        let c = replyFirst.receive(reply: .state(state(.ended, distance: 800)), to: .finish)
        let d = replyFirst.receive(state(.idle))
        #expect((c + d).filter { $0 == .finished }.count == 1)
    }

    /// The phone relaunched mid-walk (idle), then the same walk was resumed
    /// (same start date): its real finish still taps.
    @Test func aResumedWalk_tapsFinishedAtItsRealFinish() {
        var display = WatchRemoteDisplay()
        _ = display.receive(state(.running))
        _ = display.receive(state(.idle))
        _ = display.receive(state(.running))
        let taps = display.receive(state(.idle))
        #expect(taps == [.finished])
    }

    /// The next walk still gets its own finish tap.
    @Test func aLaterWalk_tapsFinishedAgain() {
        var display = WatchRemoteDisplay()
        _ = display.receive(state(.running))
        _ = display.receive(state(.idle))
        _ = display.receive(state(.running, start: Date(timeIntervalSince1970: 9_000)))
        let taps = display.receive(state(.idle))
        #expect(taps == [.finished])
    }

    @Test func start_showsProgress_thenTheLiveScreen_orTheOpenYourPhoneNote() {
        var display = WatchRemoteDisplay()
        display.beginStart()
        #expect(display.screen == .starting)
        _ = display.receive(reply: .state(state(.idle)), to: .start(.running))
        #expect(display.screen == .starting, "the phone is still opening the walk screen")
        _ = display.receive(state(.running, mode: .running))
        #expect(display.screen == .live)

        var refused = WatchRemoteDisplay()
        refused.beginStart()
        _ = refused.receive(reply: .needsPhone, to: .start(.walking))
        #expect(refused.screen == .idle)
        #expect(refused.needsPhone)

        var dropped = WatchRemoteDisplay()
        dropped.beginStart()
        dropped.commandFailed()
        #expect(dropped.screen == .idle)
    }

    @Test func notStarted_leavesStarting_withANote_clearedByTheNextStart() {
        var display = WatchRemoteDisplay()
        display.beginStart()
        _ = display.receive(reply: .notStarted, to: .start(.walking))
        #expect(display.screen == .idle)
        #expect(display.notStarted)
        display.beginStart()
        #expect(!display.notStarted)
        _ = display.receive(state(.running))
        #expect(display.screen == .live)
    }

    @Test func noActiveSession_goesBackToIdle() {
        var display = WatchRemoteDisplay()
        _ = display.receive(state(.running))
        _ = display.receive(reply: .noActiveSession, to: .pause)
        #expect(display.screen == .idle)
    }

    @Test func controls_needTheIPhone_andAWalkTheWatchMayControl() {
        let running = state(.running)
        #expect(WatchRemoteDisplay.controlsEnabled(state: running, isReachable: true))
        #expect(!WatchRemoteDisplay.controlsEnabled(state: running, isReachable: false))
        var indoor = state(.running, mode: .stationary)
        indoor.controllable = false
        #expect(!WatchRemoteDisplay.controlsEnabled(state: indoor, isReachable: true))
    }
}
