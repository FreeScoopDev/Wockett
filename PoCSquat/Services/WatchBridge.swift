import Foundation
import UIKit
import CoreLocation
import WatchConnectivity

// MARK: - WatchBridge (feat/watch-walk-remote)
//
// The iPhone side of the Apple Watch walk remote. The phone owns every
// session; the watch is a second screen and a remote. This class:
//
// - sends the walk's state (`WatchWalkState`, WatchWalkLink.swift) on every
//   phase change and at most every 5 s while only the distance moves;
// - acts on the watch's commands only through the paths the app already
//   has: Start posts to `WalkIntentInbox` like Siri and Control Center,
//   Pause and Resume do what the Live Activity's toggle does, and Finish is
//   `ActiveWalkStore.end(.save)` like the Live Activity's End;
// - starts only a session that can track. A When In Use app cannot begin
//   location updates from the background (Apple's docs, checked 2026-11-20;
//   specs/Wockett/feat/watch-walk-remote.md, "Background start finding"), and
//   a watch message wakes the phone in the background. So Start works while
//   Wockett is in front, and otherwise replies `needsPhone`: nothing
//   half-starts.
//
// `WCSessionLink` below owns the `WCSession`; the bridge itself never touches
// WatchConnectivity, so a test drives it with a fake sink and its own store.

/// Where the bridge sends state. `WCSessionLink` in the app; a fake in tests.
@MainActor
protocol WatchStateSink: AnyObject {
    func send(_ state: WatchWalkState)
}

/// An indoor walk's numbers. Indoor walks run in `StationaryWalkView`, not
/// through `ActiveWalkStore`, so the screen reports them here. The watch
/// shows their time and distance; they have no pause and finish on the phone.
struct IndoorWalkReading: Equatable {
    var startDate: Date
    var distanceMeters: Double
}

@MainActor
final class WatchBridge {
    static let shared = WatchBridge()

    private let store: ActiveWalkStore
    private let inbox: WalkIntentInbox
    /// Whether a session could track if started now: Wockett in front, and
    /// for an outdoor activity, location not off.
    private let canStart: @MainActor (WatchActivity) -> Bool
    private let isAppActive: @MainActor () -> Bool
    private let usesMiles: () -> Bool
    private let now: () -> Date
    /// How long Start waits for the walk screen to begin the session before
    /// replying. Zero in tests.
    private let startWait: TimeInterval

    weak var sink: (any WatchStateSink)?
    private(set) var throttle = WatchSendThrottle()
    private var link: WCSessionLink?
    private var timer: Timer?

    /// Set by the indoor walk screen while one runs.
    var indoorWalk: IndoorWalkReading?

    init(store: ActiveWalkStore? = nil,
         inbox: WalkIntentInbox? = nil,
         canStart: (@MainActor (WatchActivity) -> Bool)? = nil,
         isAppActive: (@MainActor () -> Bool)? = nil,
         usesMiles: @escaping () -> Bool = { WalkAudioCueService.usesMiles },
         now: @escaping () -> Date = Date.init,
         startWait: TimeInterval = 5) {
        self.store = store ?? .shared
        self.inbox = inbox ?? .shared
        let isActive = isAppActive ?? { UIApplication.shared.applicationState == .active }
        self.isAppActive = isActive
        self.canStart = canStart ?? { mode in Self.canStartNow(mode, appIsActive: isActive()) }
        self.usesMiles = usesMiles
        self.now = now
        self.startWait = startWait
    }

    // MARK: - Launch

    /// Called once at launch. Does nothing where WatchConnectivity is not
    /// supported (iPad) and under tests, which inject a sink instead.
    func activate() {
        guard link == nil, WCSession.isSupported(), !AppModelContainer.isRunningUnderTests else { return }
        let link = WCSessionLink(bridge: self)
        self.link = link
        sink = link
        link.activate()
        // A local check once a second; what it sends is throttled.
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in WatchBridge.shared.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - State

    /// The walk as the watch should show it now.
    func currentState() -> WatchWalkState {
        let miles = usesMiles()
        if let session = store.session {
            let mode = Self.watchActivity(for: store.activeRoute?.activityMode ?? session.route.activityMode)
            let distance = session.totalDistanceCovered
            let elapsed = session.elapsedTime
            var state = WatchWalkState(mode: mode, phase: .running, usesMiles: miles)
            state.startDate = session.startTime
            state.distanceMeters = distance
            guard store.isWalkInProgress else {
                state.phase = .ended
                state.summary = WatchWalkSummary(distanceMeters: distance, movingSeconds: elapsed)
                return state
            }
            state.phase = session.isPaused ? .paused : .running
            state.pausedDuration = session.totalPausedDuration
            state.pausedAt = session.isPaused ? now() : nil
            if mode.showsSpeed {
                // As the walk screen's ride speed: from 50 m and 5 s.
                state.averageSpeedMetersPerSecond = distance > 50 && elapsed > 5 ? distance / elapsed : nil
            } else {
                state.averagePaceSecsPerKm = session.averagePaceSecsPerKm
                state.currentPaceSecsPerKm = session.currentPaceSecsPerKm
            }
            return state
        }
        if let indoor = indoorWalk {
            var state = WatchWalkState(mode: .stationary, phase: .running, usesMiles: miles)
            state.startDate = indoor.startDate
            state.distanceMeters = indoor.distanceMeters > 0 ? indoor.distanceMeters : nil
            state.controllable = false
            return state
        }
        return .idle(usesMiles: miles)
    }

    /// Sends the state if the throttle allows. The 1 s timer calls this, and
    /// every command does after acting.
    func refresh() {
        let state = currentState()
        let time = now()
        guard throttle.decide(state, now: time) == .sendNow else { return }
        sink?.send(state)
        throttle.didSend(state, at: time)
    }

    // MARK: - Commands

    func handle(_ command: WatchCommand) async -> WatchReply {
        defer { refresh() }
        switch command {
        case .requestState:
            return .state(currentState())

        case .start(let activity):
            // A session already running is shown, never replaced.
            if store.isWalkInProgress || indoorWalk != nil { return .state(currentState()) }
            guard canStart(activity) else { return .needsPhone }
            inbox.post(WalkIntentRequest(mode: Self.mode(for: activity)))
            await waitForStart()
            return .state(currentState())

        case .pause, .resume:
            guard let session = store.session, store.isWalkInProgress else {
                return indoorWalk != nil ? .needsPhone : .noActiveSession
            }
            // As ToggleWalkPauseLiveActivityIntent, but never toggles the
            // wrong way: a Pause that arrives already paused does nothing.
            let wantsPause = command == .pause
            if wantsPause, !session.isPaused { session.pause(); session.pushLiveActivityState() }
            if !wantsPause, session.isPaused { session.resume(); session.pushLiveActivityState() }
            return .state(currentState())

        case .finish:
            guard store.isWalkInProgress else {
                return indoorWalk != nil ? .needsPhone : .noActiveSession
            }
            // As the Live Activity's End, plus the phone's own summary when
            // someone is looking at the phone (a guided walk completing while
            // minimised does the same).
            guard let saved = store.end(.save, presentSummary: isAppActive()) else {
                // The save failed: the walk is still on, paused, and the
                // phone is asking what to do.
                return .state(currentState())
            }
            var state = WatchWalkState(mode: Self.watchActivity(for: ActivityMode(rawValue: saved.activityType) ?? .walking),
                                       phase: .ended, usesMiles: usesMiles())
            state.startDate = saved.date
            state.distanceMeters = saved.totalDistance
            state.summary = WatchWalkSummary(distanceMeters: saved.totalDistance, movingSeconds: saved.elapsedTime)
            return .state(state)
        }
    }

    /// Start posts the request; the walk screen begins the session a moment
    /// later. Waits a little for that, so the reply carries the running walk.
    private func waitForStart() async {
        let deadline = now().addingTimeInterval(startWait)
        while now() < deadline, !store.isWalkInProgress, indoorWalk == nil {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: - Mapping

    static func mode(for activity: WatchActivity) -> ActivityMode {
        switch activity {
        case .walking:    return .walking
        case .running:    return .running
        case .cycling:    return .cycling
        case .stationary: return .stationary
        }
    }

    static func watchActivity(for mode: ActivityMode) -> WatchActivity {
        switch mode {
        case .walking:    return .walking
        case .running:    return .running
        case .cycling:    return .cycling
        case .stationary: return .stationary
        }
    }

    /// A session tracks only if it starts with Wockett in front (Apple's docs:
    /// no starting location from the background with When In Use). An
    /// outdoor activity also needs location not to be off; an indoor walk
    /// counts steps.
    static func canStartNow(_ activity: WatchActivity, appIsActive: Bool,
                            authorization: () -> CLAuthorizationStatus = { CLLocationManager().authorizationStatus }) -> Bool {
        guard appIsActive else { return false }
        guard activity != .stationary else { return true }
        switch authorization() {
        case .denied, .restricted: return false
        default: return true
        }
    }
}

// MARK: - WCSessionLink

/// Owns the iPhone's `WCSession`. Commands arrive with a reply handler and
/// are answered at once; nothing is queued (no `transferUserInfo`).
final class WCSessionLink: NSObject, WCSessionDelegate, WatchStateSink {
    private weak var bridge: WatchBridge?

    init(bridge: WatchBridge) {
        self.bridge = bridge
    }

    func activate() {
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func send(_ state: WatchWalkState) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext(WatchWire.encode(state))
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.bridge?.refreshAfterActivation() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The person switched watches: activate again for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard let command = WatchWire.decode(WatchCommand.self, from: message) else {
            replyHandler([:])
            return
        }
        let reply = UncheckedReply(handler: replyHandler)
        Task { @MainActor in
            let answer = await self.bridge?.handle(command) ?? .noActiveSession
            reply.handler(WatchWire.encode(answer))
        }
    }

    /// The reply handler crosses to the main actor and back; WatchConnectivity
    /// allows calling it from any thread.
    private struct UncheckedReply: @unchecked Sendable {
        let handler: ([String: Any]) -> Void
    }
}

extension WatchBridge {
    /// A newly activated session sends the current state whatever was last
    /// sent before, so a watch paired mid-walk gets it.
    fileprivate func refreshAfterActivation() {
        throttle = WatchSendThrottle()
        refresh()
    }
}
