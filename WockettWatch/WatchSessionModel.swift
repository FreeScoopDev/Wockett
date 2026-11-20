import Foundation
import Observation
import WatchConnectivity
import WatchKit

/// Owns the Watch's `WCSession`. Holds the latest walk state from the phone
/// (its application context, or a reply) in a `WatchRemoteDisplay`, whose
/// rules live in WatchWalkLink.swift where the app's tests cover them, and
/// sends the person's commands. The watch tracks nothing itself: the phone
/// owns every session.
@Observable @MainActor
final class WatchSessionModel: NSObject {
    private(set) var display = WatchRemoteDisplay()
    private(set) var isReachable = false
    /// A command is on its way; the buttons wait for its reply.
    private(set) var isSending = false
    var selectedActivity: WatchActivity = .walking

    /// How long Start waits for the phone to show a running session.
    private static let startTimeout: Duration = .seconds(12)
    @ObservationIgnored private var startTimeoutTask: Task<Void, Never>?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Ask the phone for its state; called when the app becomes active.
    func requestState() {
        let session = WCSession.default
        isReachable = session.isReachable
        if let context = WatchWire.decode(WatchWalkState.self, from: session.receivedApplicationContext) {
            apply(display.receive(context))
        }
        send(.requestState)
    }

    var controlsEnabled: Bool {
        WatchRemoteDisplay.controlsEnabled(state: display.state, isReachable: isReachable) && !isSending
    }

    func start() {
        display.beginStart()
        send(.start(selectedActivity))
        startTimeoutTask?.cancel()
        startTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.startTimeout)
            guard !Task.isCancelled, let self, self.display.screen == .starting else { return }
            self.display.commandFailed()
        }
    }

    func togglePause() {
        send(display.state?.phase == .paused ? .resume : .pause)
    }

    func finish() {
        send(.finish)
    }

    func dismissSummary() {
        display.dismissSummary()
    }

    // MARK: - Sending

    /// `sendMessage` with a reply, or nothing: a command the phone cannot
    /// get now is dropped, never queued to run later.
    private func send(_ command: WatchCommand) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            isReachable = false
            if command != .requestState { display.commandFailed() }
            return
        }
        if command != .requestState { isSending = true }
        session.sendMessage(WatchWire.encode(command), replyHandler: { message in
            let reply = WatchWire.decode(WatchReply.self, from: message)
            Task { @MainActor in self.received(reply, to: command) }
        }, errorHandler: { _ in
            Task { @MainActor in self.received(nil, to: command) }
        })
    }

    private func received(_ reply: WatchReply?, to command: WatchCommand) {
        if command != .requestState { isSending = false }
        guard let reply else {
            isReachable = WCSession.default.isReachable
            display.commandFailed()
            return
        }
        isReachable = true
        apply(display.receive(reply: reply, to: command))
    }

    // MARK: - Wrist taps

    private func apply(_ taps: [WatchHapticEvent]) {
        guard let tap = taps.last else { return }
        let device = WKInterfaceDevice.current()
        switch tap {
        case .paused:   device.play(.stop)
        case .resumed:  device.play(.start)
        case .finished: device.play(.success)
        case .marker:   device.play(.notification)
        }
    }

    fileprivate func contextArrived(_ state: WatchWalkState) {
        apply(display.receive(state))
    }

    fileprivate func reachabilityChanged(_ reachable: Bool) {
        let cameBack = reachable && !isReachable
        isReachable = reachable
        if cameBack { send(.requestState) }
    }
}

extension WatchSessionModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.requestState() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let state = WatchWire.decode(WatchWalkState.self, from: applicationContext) else { return }
        Task { @MainActor in self.contextArrived(state) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachabilityChanged(reachable) }
    }
}
