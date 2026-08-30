import Foundation
import UserNotifications

@Observable @MainActor
final class ActiveWalkStore {
    static let shared = ActiveWalkStore()

    private(set) var session: NavigationSessionManager?
    private(set) var activeRoute: NavigableRoute?
    private(set) var isStarted: Bool = false
    private(set) var historyStore: WalkHistoryStore?

    private init() {}

    func configure(historyStore: WalkHistoryStore) {
        self.historyStore = historyStore
    }

    /// Snapshots the current session into Walk History. Does NOT stop the session or
    /// clear the store — callers are responsible for that ordering. Safe to call with
    /// default args when per-pet distance data isn't available (e.g. from the mini tile).
    @discardableResult
    func buildAndSaveSession(
        petDistances: [UUID: Double] = [:],
        activePetIds: [UUID] = [],
        isCommunityRoute: Bool = false
    ) -> WalkSession? {
        guard let session, let historyStore else { return nil }
        var s = session.completedSession
        s.activePetIds = activePetIds
        s.petDistances = petDistances
        s.isCommunityRoute = isCommunityRoute
        historyStore.add(s)
        BackgroundTaskManager.shared.scheduleCloudKitSync()
        return s
    }

    var isActive: Bool { session != nil }

    /// Saves the active walk and tears down the session in one call.
    /// For exit points that have no access to per-pet distance accrual
    /// (mini tile, Live Activity button) — the walk is saved but pets
    /// won't get distance credit for this session.
    @discardableResult
    func saveAndEndActiveSession() -> WalkSession? {
        guard let session, let route = activeRoute else { return nil }
        let dist           = session.totalDistanceCovered
        let elapsed        = Int(session.elapsedTime)
        let pausedDuration = session.totalPausedDuration
        let capturedSession = session
        let saved          = buildAndSaveSession(isCommunityRoute: route.isCommunityRoute)
        session.stop()
        endSession()
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: (1...12).map { "waterBreak-\($0)" }
        )
        Task {
            await WalkLiveActivityManager.shared.end(distanceCovered: dist, elapsedSeconds: elapsed, pausedDuration: pausedDuration)
            await capturedSession.finishWorkoutSession()
        }
        return saved
    }

    /// Reconstructs the last checkpointed walk if one exists and nothing is
    /// currently active. Returns the restored route on success.
    @discardableResult
    func restoreIfNeeded() -> NavigableRoute? {
        guard session == nil, let snapshot = ActiveWalkSnapshotStore.load() else { return nil }
        let route = snapshot.route.navigableRoute
        let mgr = NavigationSessionManager(route: route)
        mgr.restore(from: snapshot)
        session = mgr
        activeRoute = route
        isStarted = true
        // Start a fresh Live Activity for the restored session and push an immediate
        // state update so the banner shows current distance/elapsed rather than zeros.
        let capturedMgr = mgr
        Task {
            await WalkLiveActivityManager.shared.start(
                routeName: route.name,
                totalDistanceMeters: route.totalDistance,
                activityMode: route.activityMode.rawValue,
                startDate: snapshot.startTime
            )
            await WalkLiveActivityManager.shared.update(
                distanceCovered: capturedMgr.totalDistanceCovered,
                elapsedSeconds: Int(capturedMgr.elapsedTime),
                isPaused: capturedMgr.isPaused,
                paceSecsPerKm: nil,
                pausedDuration: capturedMgr.totalPausedDuration,
                pauseTime: capturedMgr.isPaused ? Date() : nil
            )
        }
        return route
    }

    /// If a checkpoint exists but is too old to offer for resume, convert it
    /// into a Walk History entry and clear the checkpoint. Silent — no PR
    /// fanfare, no completion UI. Must be called after configure(historyStore:).
    func salvageStaleWalkIfNeeded() {
        guard session == nil,
              let historyStore,
              let snapshot = ActiveWalkSnapshotStore.loadAnyAge(),
              Date().timeIntervalSince(snapshot.checkpointDate) > ActiveWalkSnapshotStore.maxSnapshotAge
        else { return }
        defer { ActiveWalkSnapshotStore.clear() }

        // Ignore trivial walks — same 50m threshold used by the Free Walk summary auto-save.
        guard snapshot.totalDistanceCovered >= 50 else { return }

        let route = snapshot.route.navigableRoute
        let path: [WaypointCoord] = route.waypoints.isEmpty
            ? (snapshot.trackPoints ?? [])
            : snapshot.route.waypoints

        let salvaged = WalkSession(
            id: UUID(),
            routeName: snapshot.route.name,
            date: snapshot.startTime,
            elapsedTime: ActiveWalkSnapshotStore.salvagedElapsed(for: snapshot),
            totalDistance: snapshot.totalDistanceCovered,
            waypoints: path,
            lapCount: snapshot.route.lapCount,
            isLoop: snapshot.route.isLoop,
            activityType: snapshot.route.activityMode,
            steps: snapshot.liveSteps,
            customRouteId: snapshot.route.customRouteId
        )
        historyStore.add(salvaged)
    }

    /// Called when the user declines to resume a recovered walk.
    func declineRestore() {
        ActiveWalkSnapshotStore.clear()
    }

    var hasRestorableWalk: Bool {
        session == nil && ActiveWalkSnapshotStore.hasPending
    }

    /// Creates a session for `route` and returns it. Returns nil without side effects if a session is already active.
    @discardableResult
    func beginSession(route: NavigableRoute) -> NavigationSessionManager? {
        guard session == nil else { return nil }
        let mgr = NavigationSessionManager(route: route)
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
    }

    // MARK: - Reopen signal

    /// Set by the mini tile when the user taps "return to walk". Consumed by StepCounterView.
    private(set) var reopenRequested: Bool = false

    func requestReopen() { reopenRequested = true }
    func consumeReopenRequest() { reopenRequested = false }
}
