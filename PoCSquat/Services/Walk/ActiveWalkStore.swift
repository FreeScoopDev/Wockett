import Foundation
import UIKit
import UserNotifications

/// A walk saved from outside the walk screen, waiting for the app root to
/// show its summary (`ActiveWalkStore.pendingSummary`).
struct ActivitySummaryRequest: Identifiable {
    let id = UUID()
    let session: WalkSession
    let records: [PRType]
    /// The named trail walked, for the summary's questions (memory only).
    var trail: TrailRef?
    /// Checkpoint splits of a guided walk, read before the session stops.
    var splits: [(label: String, elapsed: TimeInterval)] = []
}

@Observable @MainActor
final class ActiveWalkStore {
    static let shared = ActiveWalkStore()

    private(set) var session: NavigationSessionManager?
    private(set) var activeRoute: NavigableRoute?
    private(set) var isStarted: Bool = false
    private(set) var historyStore: WalkHistoryStore?
    private let notifications: NotificationService
    /// Ends the Live Activity when a walk ends. `WalkLiveActivityManager.shared`
    /// in the app; a test passes a fake to count the calls. Starting and
    /// updating it (`restoreIfNeeded`) still go to `.shared` directly.
    private let liveActivity: any WalkLiveActivityEnding
    /// The work `end` leaves running after it returns: ending the Live
    /// Activity, then finishing a saved walk's Health workout. Kept so a test
    /// can await it; nothing in the app waits on it.
    @ObservationIgnored private(set) var endTask: Task<Void, Never>?
    /// Set by `end`: a walk ends once, however many paths try. Cleared when
    /// the session is released.
    @ObservationIgnored private var sessionEnded = false
    /// Whether the app is in front. Read when a guided walk completes with
    /// its screen minimised; a test passes its own answer.
    @ObservationIgnored private let isAppActive: @MainActor () -> Bool

    /// A walk ended from outside the walk screen while the person is in the
    /// app (the mini tile's Save & End, a route completed while minimised):
    /// the app root shows its summary, the same one the walk screen shows,
    /// and clears this when it goes. Never set by the Live Activity's End or
    /// a discard: the walk is in Activity History, one tap from its summary.
    var pendingSummary: ActivitySummaryRequest?

    /// The named trail of the walk `end(.save)` just saved, for the walk
    /// screen's summary questions (memory only). Cleared with the session.
    @ObservationIgnored private(set) var endedTrail: TrailRef?

    /// A save that did not reach the disk, and how to try it again. Set by
    /// `end(.save)` when Walk History's write fails; the walk is then still
    /// in progress, its checkpoint, Live Activity and Health workout intact.
    /// The app root shows "Couldn't save your {noun}" (`SaveFailureAlert`),
    /// or the walk screen does while it is up.
    struct SaveFailure: Equatable {
        /// "walk", "run", "ride", "hike": the alert's title.
        let noun: String
        let releaseSession: Bool
        let presentSummary: Bool
        /// When the walk was first ended: a retry finishes the Health
        /// workout then, not after the time spent at the alert.
        let endedAt: Date
    }
    private(set) var saveFailure: SaveFailure?
    /// Set when a failed save paused the walk, so Keep going resumes it. A
    /// walk the person had paused themselves stays paused.
    @ObservationIgnored private var pausedForSaveFailure = false

    /// `shared` is the app's store; tests build their own with an in-memory
    /// history store. `.shared` defaults are resolved in the body, not as
    /// default arguments, which are evaluated off the main actor.
    init(historyStore: WalkHistoryStore? = nil,
         notifications: NotificationService? = nil,
         liveActivity: (any WalkLiveActivityEnding)? = nil,
         isAppActive: (@MainActor () -> Bool)? = nil) {
        self.historyStore = historyStore
        self.notifications = notifications ?? .shared
        self.liveActivity = liveActivity ?? WalkLiveActivityManager.shared
        self.isAppActive = isAppActive ?? { UIApplication.shared.applicationState == .active }
    }

    func configure(historyStore: WalkHistoryStore) {
        self.historyStore = historyStore
    }

    var isActive: Bool { session != nil }

    /// A walk is being recorded: a session exists and has not been ended.
    /// False on the summary, where the stopped session is still held
    /// (`releaseSession: false`). The trail questions never show while true.
    var isWalkInProgress: Bool { session != nil && !sessionEnded }

    // MARK: - Ending a walk

    enum EndOutcome { case save, discard }

    /// The one way a walk ends, whoever ends it: the walk screen's Finish and
    /// Discard, the break prompt, the driving banner, route completion, the
    /// mini tile and the Live Activity. Until 2026-09-28 seven places
    /// re-implemented this, and each left something out: free walks never
    /// finished their Health workout, the mini tile and Live Activity saved no
    /// pet credit, the driving banner ended the Live Activity twice.
    ///
    /// Save: the walk goes to Walk History with every pet's credit and its
    /// Health workout is finished. Discard: the Health workout is thrown away.
    /// Either way tracking stops, the checkpoint is deleted, water-break
    /// reminders are cancelled and the Live Activity ends.
    ///
    /// `releaseSession: false` keeps the stopped session for the walk
    /// screen's summary; the screen calls `endSession()` when it goes away.
    /// `presentSummary` asks the app root to show the saved walk's summary
    /// (`pendingSummary`), for a path with no walk screen to show it.
    ///
    /// Returns the saved walk; nil for a discard, a walk already ended, or a
    /// save that failed. A failed save ends nothing: the walk stays in
    /// progress with its checkpoint, Live Activity and Health workout, is
    /// paused while the person decides, and `saveFailure` is set for the
    /// alert. With no Walk History to save to, it counts as failed: until
    /// 2026-10-27 that saved nothing and still ended the walk.
    @discardableResult
    func end(_ outcome: EndOutcome, releaseSession: Bool = true,
             presentSummary: Bool = false) -> WalkSession? {
        end(outcome, releaseSession: releaseSession, presentSummary: presentSummary, endedAt: Date())
    }

    private func end(_ outcome: EndOutcome, releaseSession: Bool, presentSummary: Bool,
                     endedAt: Date) -> WalkSession? {
        guard let session, let route = activeRoute, !sessionEnded else { return nil }
        // Set before the save, so nothing the save sets off can end the walk
        // a second time; a failed save sets it back.
        sessionEnded = true
        let distance = session.totalDistanceCovered
        let elapsed  = Int(session.elapsedTime)
        let paused   = session.totalPausedDuration
        var saved: WalkSession?
        switch outcome {
        case .save:
            let previous = historyStore?.sessions ?? []
            var walk = session.completedSession
            let pets = session.petDistances
            walk.activePetIds = Array(pets.keys)
            walk.petDistances = pets
            walk.isCommunityRoute = route.isCommunityRoute
            guard let historyStore, historyStore.add(walk) else {
                sessionEnded = false
                saveFailed(session: session, noun: route.wording.noun, releaseSession: releaseSession,
                           presentSummary: presentSummary, endedAt: endedAt)
                return nil
            }
            endedTrail = route.trail
            BackgroundTaskManager.shared.scheduleCloudKitSync()
            saved = walk
            if presentSummary {
                pendingSummary = ActivitySummaryRequest(
                    session: walk, records: checkNewPRs(newSession: walk, against: previous),
                    trail: route.trail, splits: session.splitTimes)
            }
        case .discard:
            session.discardWorkoutSession()
        }
        saveFailure = nil
        pausedForSaveFailure = false
        session.stop()
        notifications.cancelWaterBreaks()
        let liveActivity = self.liveActivity
        endTask = Task {
            await liveActivity.end(distanceCovered: distance, elapsedSeconds: elapsed, pausedDuration: paused)
            if outcome == .save { await session.finishWorkoutSession(endedAt: endedAt) }
        }
        if releaseSession { endSession() }
        return saved
    }

    /// The walk stays as it is, paused while the alert is up so the time
    /// spent there is not added to it.
    private func saveFailed(session: NavigationSessionManager, noun: String, releaseSession: Bool,
                            presentSummary: Bool, endedAt: Date) {
        if !session.isPaused, !session.isCompleted {
            session.pause()
            session.pushLiveActivityState()
            pausedForSaveFailure = true
        }
        saveFailure = SaveFailure(noun: noun, releaseSession: releaseSession,
                                  presentSummary: presentSummary, endedAt: endedAt)
    }

    /// Try again: the failed save once more, as it was first asked for.
    /// Returns the saved walk, or nil with `saveFailure` set again.
    @discardableResult
    func retrySave() -> WalkSession? {
        guard let failure = saveFailure else { return nil }
        saveFailure = nil
        return end(.save, releaseSession: failure.releaseSession,
                   presentSummary: failure.presentSummary, endedAt: failure.endedAt)
    }

    /// Keep going: the walk carries on, unsaved, as if Finish had not been
    /// pressed. Resumes it only if the failed save paused it.
    func keepGoingAfterSaveFailure() {
        saveFailure = nil
        guard pausedForSaveFailure else { return }
        pausedForSaveFailure = false
        guard let session, session.isPaused else { return }
        session.resume()
        session.pushLiveActivityState()
    }

    /// Reconstructs the last checkpointed walk if one exists and nothing is
    /// currently active. Returns the restored route on success.
    @discardableResult
    func restoreIfNeeded() -> NavigableRoute? {
        guard session == nil, let snapshot = ActiveWalkSnapshotStore.load() else { return nil }
        let route = snapshot.route.navigableRoute
        let mgr = NavigationSessionManager(route: route)
        mgr.onRouteChanged = { [weak self] in self?.activeRoute = $0 }
        mgr.onCompleted = { [weak self] in self?.sessionDidComplete() }
        mgr.restore(from: snapshot)
        session = mgr
        activeRoute = route
        isStarted = true
        // Start a fresh Live Activity for the restored session and push an immediate
        // state update so the banner shows current distance/elapsed rather than zeros.
        let capturedMgr = mgr
        Task {
            await WalkLiveActivityManager.shared.start(
                route: route,
                totalDistanceMeters: capturedMgr.liveActivityTotalMeters,
                startDate: snapshot.startTime
            )
            await WalkLiveActivityManager.shared.update(capturedMgr.liveActivityState)
        }
        return route
    }

    /// If a checkpoint exists but is too old to offer for resume, convert it
    /// into a Walk History entry and clear the checkpoint. Silent — no PR
    /// fanfare, no completion UI. Must be called after configure(historyStore:).
    func salvageStaleWalkIfNeeded() {
        guard session == nil,
              let historyStore,
              let snapshot = ActiveWalkSnapshotStore.loadAnyAge()
        else { return }
        // A finished guided walk the app died before saving is saved now,
        // whatever its age or length: the person reached the end.
        let completed = snapshot.isCompleted == true
        guard completed || Date().timeIntervalSince(snapshot.checkpointDate) > ActiveWalkSnapshotStore.maxSnapshotAge
        else { return }

        // Ignore trivial walks — same 50m threshold used by the Free Walk summary auto-save.
        guard completed || snapshot.totalDistanceCovered >= 50 else {
            ActiveWalkSnapshotStore.clear()
            return
        }

        // The checkpoint is the only copy: it goes only once the walk is on
        // disk. A failed save leaves it for the next launch to try again
        // (it is never offered for resume: too old, or completed).
        if historyStore.add(Self.salvagedSession(from: snapshot)) {
            ActiveWalkSnapshotStore.clear()
        }
    }

    /// The history entry a stale or completed checkpoint becomes. Pure, so a
    /// test can check what is saved (splits included) without the real
    /// checkpoint file, which other tests use in parallel.
    static func salvagedSession(from snapshot: ActiveWalkSnapshot) -> WalkSession {
        let path = salvagedWaypoints(for: snapshot)
        let elapsed = ActiveWalkSnapshotStore.salvagedElapsed(for: snapshot)
        return WalkSession(
            id: UUID(),
            routeName: snapshot.route.name,
            date: snapshot.startTime,
            elapsedTime: elapsed,
            totalDistance: snapshot.totalDistanceCovered,
            waypoints: path,
            lapCount: snapshot.route.lapCount,
            isLoop: snapshot.route.isLoop,
            activityType: snapshot.route.activityMode,
            steps: snapshot.liveSteps,
            customRouteId: snapshot.route.customRouteId,
            unitSplits: salvagedSplits(for: snapshot, elapsed: elapsed),
            elevation: salvagedElevation(for: snapshot),
            isHike: snapshot.route.isHike ?? false
        )
    }

    /// The splits a salvaged walk or run keeps: the whole units in its
    /// checkpoint and the part-unit after them. None for a ride, an indoor
    /// walk, or a checkpoint from before splits existed.
    static func salvagedSplits(for snapshot: ActiveWalkSnapshot, elapsed: TimeInterval) -> UnitSplits? {
        guard let saved = snapshot.unitSplits,
              ActivityMode(rawValue: snapshot.route.activityMode)?.hasPaceAndSplits == true else { return nil }
        return SplitTracker(restoring: saved, unitMeters: saved.unitMeters,
                            elapsed: elapsed, distance: snapshot.totalDistanceCovered)
            .finished(elapsed: elapsed, distance: snapshot.totalDistanceCovered)
    }

    /// The climb a salvaged activity keeps: its checkpoint's, as it stood.
    /// None for an indoor walk (it has no GPS) or an older checkpoint.
    static func salvagedElevation(for snapshot: ActiveWalkSnapshot) -> ElevationTotals? {
        guard ActivityMode(rawValue: snapshot.route.activityMode)?.recordsElevation == true else { return nil }
        return snapshot.elevation
    }

    /// The points a salvaged walk keeps: the breadcrumbs of a free walk, and
    /// for a guided one what Walk History keeps for its route.
    static func salvagedWaypoints(for snapshot: ActiveWalkSnapshot) -> [WaypointCoord] {
        let route = snapshot.route.navigableRoute
        return route.waypoints.isEmpty
            ? (snapshot.trackPoints ?? [])
            : route.historyWaypoints.map { WaypointCoord($0) }
    }

    /// A guided walk reached its end. With the walk screen up, the screen
    /// ends it and shows the summary. Without it, minimised to the mini tile,
    /// nothing else would, so it ends here, pet credit included.
    func sessionDidComplete() {
        guard let session, !session.isSessionScreenVisible else { return }
        // Its summary only when the person is in the app to see it; a walk
        // completed in a pocket is in Activity History.
        end(.save, presentSummary: isAppActive())
    }

    /// Called when the user declines to resume a recovered walk.
    func declineRestore() {
        ActiveWalkSnapshotStore.clear()
    }

    var hasRestorableWalk: Bool {
        session == nil && ActiveWalkSnapshotStore.hasPending
    }

    /// Creates a session for `route` and returns it. Returns nil without side effects if a session is already active.
    /// Every guided walk starts here, so this is where a recorded walk saved as
    /// a route becomes a line to follow rather than hundreds of MKDirections legs.
    @discardableResult
    func beginSession(route: NavigableRoute) -> NavigationSessionManager? {
        guard session == nil else { return nil }
        let route = route.followingRecordedLine()
        let mgr = NavigationSessionManager(route: route)
        mgr.onRouteChanged = { [weak self] in self?.activeRoute = $0 }
        mgr.onCompleted = { [weak self] in self?.sessionDidComplete() }
        session = mgr
        activeRoute = route
        isStarted = false
        return mgr
    }

    func markStarted() {
        isStarted = true
    }

    func endSession() {
        session = nil
        activeRoute = nil
        isStarted = false
        sessionEnded = false
        endedTrail = nil
        // A walk ended another way (Live Activity) takes its question with it.
        endConfirmationRequested = false
        saveFailure = nil
        pausedForSaveFailure = false
    }

    // MARK: - Reopen signal

    /// Set by the mini tile when the user taps "return to walk". Consumed by StepCounterView.
    private(set) var reopenRequested: Bool = false

    func requestReopen() { reopenRequested = true }
    func consumeReopenRequest() { reopenRequested = false }

    /// Set by the mini tile's End; the app root asks Save or Discard
    /// (`MiniTileEndConfirmation`), because iOS 26.5 never presents a dialog
    /// attached inside `tabViewBottomAccessory`.
    var endConfirmationRequested = false
}
