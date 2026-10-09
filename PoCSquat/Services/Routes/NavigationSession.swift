import SwiftUI
import MapKit
import CoreLocation
import CoreMotion
import UserNotifications
import UIKit
import HealthKit

// MARK: - Checkpoint Circle Overlay

/// The dashed line from someone who has left a trail back to it.
final class OffTrailLine: MKPolyline {}

final class NavCheckpointCircle: MKCircle {
    var isFinish = false
}

// MARK: - Stop Tracker
//
// Shared helper that drives both the 15-second stop-count tally and the
// configurable break prompt. Feed `tick()` once per second; it manages its
// own internal time-keeping so the caller needs no extra state.

struct StopTracker {
    private(set) var stopCount: Int = 0

    private var stoppedSince:     Date? = nil
    private var stopCountRecorded       = false
    private var breakPromptFired        = false

    let stopCountThreshold: TimeInterval = 15   // seconds before counting a stop
    let breakThreshold: TimeInterval            // configurable; default 180 s

    enum Event { case showBreakPrompt }

    init(breakThresholdSeconds: TimeInterval) {
        self.breakThreshold = breakThresholdSeconds
    }

    // Call once per second. Returns an event if one fires; nil otherwise.
    mutating func tick(isMoving: Bool, now: Date = Date()) -> Event? {
        guard !isMoving else {
            stoppedSince      = nil
            stopCountRecorded = false
            breakPromptFired  = false
            return nil
        }
        let stoppedAt = stoppedSince ?? now
        stoppedSince = stoppedAt
        let elapsed = now.timeIntervalSince(stoppedAt)

        if elapsed >= breakThreshold && !breakPromptFired {
            breakPromptFired = true
            return .showBreakPrompt
        }
        if elapsed >= stopCountThreshold && !stopCountRecorded {
            stopCountRecorded = true
            stopCount += 1
        }
        return nil
    }

    // Call when the user dismisses the break prompt to restart fresh tracking.
    mutating func reset() {
        stoppedSince      = nil
        stopCountRecorded = false
        breakPromptFired  = false
    }
}

// MARK: - Driving Detector
//
// Flags likely vehicle use via two independent triggers:
// 1. Speed above the mode ceiling or automotive-high CoreMotion confidence
//    sustained continuously for ~25 seconds.
// 2. A second separate detection episode (catches stop-and-go driving that a
//    single sustained window would miss).
//
// Feed tick() once per second; returns .drivingSuspected when triggered.

struct DrivingDetector {
    private var episodeStart: Date? = nil
    private var episodeCount: Int = 0
    private let sustainedThreshold: TimeInterval = 25
    private let minEpisodeDuration: TimeInterval = 4   // sub-4 s blips are noise

    let speedCeiling: Double  // m/s; set from ActivityMode.drivingSpeedCeiling

    init(speedCeiling: Double) { self.speedCeiling = speedCeiling }

    enum Event { case drivingSuspected }

    mutating func tick(speed: Double, isAutomotiveHigh: Bool, now: Date = Date()) -> Event? {
        let overThreshold = (speed >= 0 && speed > speedCeiling) || isAutomotiveHigh
        if overThreshold {
            let episodeBegan = episodeStart ?? now
            episodeStart = episodeBegan
            let elapsed = now.timeIntervalSince(episodeBegan)
            if episodeCount >= 1 { return .drivingSuspected }          // second episode
            if elapsed >= sustainedThreshold { return .drivingSuspected } // sustained first
        } else if let start = episodeStart {
            if now.timeIntervalSince(start) >= minEpisodeDuration { episodeCount += 1 }
            episodeStart = nil
        }
        return nil
    }
}

// MARK: - Navigation Session Manager

// waypoints[0] is the user's starting position.
// Navigation begins at index 1. For loops, returning to index 0 (start) completes a lap.
@Observable
@MainActor
final class NavigationSessionManager: NSObject, CLLocationManagerDelegate {
    var currentWaypointIndex = 1
    var currentLap = 1
    var distanceToNextWaypoint: Double = 0
    var totalDistanceCovered: Double = 0
    var elapsedTime: TimeInterval = 0
    var isCompleted = false
    var splitTimes: [(label: String, elapsed: TimeInterval)] = []
    var liveSteps: Int = 0
    var cadence: Double? = nil  // steps/min; nil until pedometer warms up
    var trackPoints: [CLLocationCoordinate2D] = []

    var onCheckpointReached: ((String) -> Void)?

    // Trail walks: position along the trail's line, and off-trail alerts
    // (2026-09-24). Nil for every other route.
    private(set) var trailProgress: TrailProgress? {
        // However the off-trail state clears — back on the trail, alerts
        // switched off, a pause, the route turned round — the lock-screen
        // notification saying otherwise goes with it.
        didSet {
            if oldValue?.isOffTrail == true, trailProgress?.isOffTrail != true {
                NotificationService.shared.withdraw(.offTrail)
            }
        }
    }
    /// Off-trail alerts; the session screen's switch sets this.
    var offTrailAlertsEnabled = true
    /// Called with true when the person leaves the trail, false when back.
    var onOffTrailChange: ((Bool) -> Void)?
    /// The session screen is on screen (ActiveSessionView sets it). Minimized
    /// to the mini tile, the off-trail banner is not visible either.
    var isSessionScreenVisible = false
    /// Called when the session's route changes under it: a closed trail or
    /// recording turned round because the person set off the other way, or a
    /// session heading to a trail turned into the trail walk. ActiveWalkStore
    /// republishes the route so the map redraws it.
    var onRouteChanged: ((NavigableRoute) -> Void)?
    /// Called once when a guided walk reaches its end (`finish()`).
    var onCompleted: (() -> Void)?

    // Out and back (2026-10-09): the route carries `turnaroundMeters`; the
    // session says when to turn, and "Head back now" ends the out leg early.
    /// The turnaround has been reached or passed (said once).
    private(set) var hasPassedTurnaround = false

    // Heading to a trail (2026-09-26): the route carries `approach`, and
    // within `TrailWalkPlanner.startRadiusMeters` of the trail the session
    // offers the trail walk instead of finishing at the access point.
    /// The person has reached the trail this session is heading for.
    private(set) var arrivedAtTrail = false
    /// Where they were when they reached it, in case they have wandered out
    /// of range again by the time they say yes.
    private var trailArrivalLocation: CLLocationCoordinate2D?
    /// `totalDistanceCovered` when the current route began: the 20/40/60/80%
    /// markers of a trail walk count from the trail, not from home.
    private(set) var legStartDistance: Double = 0

    private(set) var route: NavigableRoute
    private let locationManager = CLLocationManager()
    private let pedometer = CMPedometer()
    private(set) var startTime = Date()
    private var timer: Timer?
    private var lastLocation: CLLocation?
    /// A trail walk gets more room: its checkpoints come from trail data that
    /// can sit tens of metres from where the path runs on the ground
    /// (2026-09-24), and a missed checkpoint stalls the session.
    private var arrivalRadius: Double { route.path == nil ? 30 : 60 }
    private(set) var triggeredCheckpoints: Set<Int> = []
    private let checkpointFractions = [0.2, 0.4, 0.6, 0.8]
    private var workoutWriter: HealthWorkoutWriter?
    var isPaused = false
    private var pausedDuration: TimeInterval = 0
    private var pauseStart: Date?
    private var snapshotTickCounter = 0

    // Stop detection — shared between the stop-count tally and break prompt.
    private var stopTracker = StopTracker(breakThresholdSeconds: 180)
    private var lastMovementTime: Date = Date()
    private let movementWindow: TimeInterval = 8  // seconds; no GPS update in this window → considered stopped
    var showBreakPrompt: Bool = false
    private var breakPromptShownAt: Date?
    var autoPausedForInactivity = false
    private var autoResumeWatch: AutoResumeWatch?
    private var autoResumeTimer: Timer?

    // Driving detection — compares GPS speed and CoreMotion automotive classification.
    private var drivingDetector = DrivingDetector(speedCeiling: 3.5)
    private var lastKnownSpeed: Double = -1   // -1 until first GPS fix
    var drivingSuspected: Bool = false
    private(set) var drivingEverDetected: Bool = false
    private(set) var drivingAffirmedByUser: Bool = false

    init(route: NavigableRoute) {
        self.route = route
        super.init()
        trailProgress = TrailProgress(route: route)
        drivingDetector = DrivingDetector(speedCeiling: route.activityMode.drivingSpeedCeiling)
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 5
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        startTime = Date()
        beginTracking()
        writeSnapshot()
    }

    /// Pure helper: how much pausedDuration a restored session should carry —
    /// snapshot's completed pauses plus the dead-time gap from the reference point
    /// (pause start if the app died while paused, otherwise the checkpoint) to `now`.
    /// Kept nonisolated static so it's directly unit-testable without main-actor dispatch.
    /// True when an ignored break prompt should escalate to auto-pause:
    /// prompt is showing, session isn't already paused, and it's been up
    /// for at least `threshold` seconds.
    nonisolated static func shouldAutoPause(showBreakPrompt: Bool, isPaused: Bool,
                                            promptShownAt: Date?, now: Date,
                                            threshold: TimeInterval = 300) -> Bool {
        guard showBreakPrompt, !isPaused, let shownAt = promptShownAt else { return false }
        return now.timeIntervalSince(shownAt) >= threshold
    }

    nonisolated static func thinned(_ points: [CLLocationCoordinate2D],
                                    maxCount: Int = 2000) -> [CLLocationCoordinate2D] {
        guard points.count > maxCount else { return points }
        let stride = Double(points.count) / Double(maxCount)
        return (0..<maxCount).map { points[Int(Double($0) * stride)] }
    }

    nonisolated static func restoredPausedDuration(for snapshot: ActiveWalkSnapshot, now: Date) -> TimeInterval {
        let referenceDate = snapshot.isPaused
            ? (snapshot.pauseStartDate ?? snapshot.checkpointDate)
            : snapshot.checkpointDate
        return snapshot.pausedDuration + now.timeIntervalSince(referenceDate)
    }

    /// Reconstructs an in-progress walk from a checkpoint after the app process
    /// died unexpectedly. Always comes back active (not paused) — the caller only
    /// invokes this once the user has confirmed they want to continue. The entire
    /// gap between the checkpoint and now is folded into pausedDuration so elapsed
    /// time and pace stay honest instead of jumping forward by however long the
    /// app was closed.
    func restore(from snapshot: ActiveWalkSnapshot) {
        applySnapshot(snapshot)
        beginTracking()
        writeSnapshot()
    }

    /// The state half of `restore(from:)`: everything but starting location,
    /// motion and Health tracking. Separate so tests can restore a snapshot
    /// without starting a CLLocationManager.
    func applySnapshot(_ snapshot: ActiveWalkSnapshot) {
        startTime            = snapshot.startTime
        totalDistanceCovered = snapshot.totalDistanceCovered
        currentWaypointIndex = snapshot.currentWaypointIndex
        currentLap           = snapshot.currentLap
        triggeredCheckpoints = snapshot.triggeredCheckpoints
        splitTimes           = snapshot.splitTimes.map { (label: $0.label, elapsed: $0.elapsed) }
        liveSteps            = snapshot.liveSteps

        pausedDuration = Self.restoredPausedDuration(for: snapshot, now: Date())
        isPaused   = false
        pauseStart = nil
        elapsedTime = Date().timeIntervalSince(startTime) - pausedDuration

        trackPoints = (snapshot.trackPoints ?? []).map { $0.clCoordinate }
        legStartDistance = snapshot.legStartDistance ?? 0
        // Pick up along the trail where the walk was, not from the nearest
        // stretch on the first fix. Snapshots from before 1.13 have no
        // position; the last checkpoint passed is the best guess then.
        if var progress = trailProgress {
            // On a loop, index 0 is the finish, so the last one passed wraps round.
            let count = route.waypoints.count
            let lastPassed = count > 0 ? (currentWaypointIndex - 1 + count) % count : 0
            let fallback = progress.checkpointAlong.indices.contains(lastPassed) ? progress.checkpointAlong[lastPassed] : 0
            progress.resume(at: snapshot.trailAlong ?? fallback, since: snapshot.checkpointDate)
            trailProgress = progress
            // Restored past the turnaround: it was said already.
            if Self.hasReachedTurnaround(along: progress.along, turnaround: route.turnaroundMeters) {
                hasPassedTurnaround = true
            }
        }
    }

    private func beginTracking() {
        stopped = false
        UIApplication.shared.isIdleTimerDisabled = true
        locationManager.startUpdatingLocation()
        let storedMins = UserDefaults.standard.integer(forKey: "walk_breakPromptMinutes")
        let breakMins = storedMins > 0 ? storedMins : 3
        stopTracker = StopTracker(breakThresholdSeconds: TimeInterval(breakMins * 60))
        lastMovementTime = Date()
        startTimer()
        // Real-time step count + cadence from the motion coprocessor (walking and running).
        // pedometer.startUpdates(from: startTime) works for restored sessions too —
        // CMPedometer reports historical steps, so step count recovers across the gap.
        if (route.activityMode == .walking || route.activityMode == .running) && CMPedometer.isStepCountingAvailable() {
            let from = startTime
            pedometer.startUpdates(from: from) { [weak self] data, error in
                guard let self, let data, error == nil else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.liveSteps = data.numberOfSteps.intValue
                    if let c = data.currentCadence {
                        self.cadence = c.doubleValue * 60  // steps/sec → steps/min
                    }
                }
            }
        }
        let capturedStartTime = startTime
        Task { @MainActor [weak self] in
            guard let self else { return }
            let writer = HealthWorkoutWriter(activityType: route.activityMode.hkActivityType)
            await writer.start(at: capturedStartTime)
            self.workoutWriter = writer
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.elapsedTime = Date().timeIntervalSince(self.startTime) - self.pausedDuration
                guard !self.isPaused else { return }
                self.snapshotTickCounter += 1
                if self.snapshotTickCounter >= 15 {
                    self.snapshotTickCounter = 0
                    self.writeSnapshot()
                }
                let now = Date()
                if var progress = self.trailProgress {
                    let event = progress.tick(at: now, alertsEnabled: self.offTrailAlertsEnabled)
                    self.trailProgress = progress
                    if let event { self.handleOffTrail(event) }
                }
                let isMoving = now.timeIntervalSince(self.lastMovementTime) < self.movementWindow
                if self.stopTracker.tick(isMoving: isMoving, now: now) != nil {
                    if !self.showBreakPrompt {
                        self.showBreakPrompt = true
                        self.breakPromptShownAt = now
                    }
                }
                // If the prompt has been ignored for 5+ minutes, auto-pause to keep stats honest.
                if Self.shouldAutoPause(showBreakPrompt: self.showBreakPrompt,
                                        isPaused: self.isPaused,
                                        promptShownAt: self.breakPromptShownAt,
                                        now: now) {
                    self.autoPause(at: now)
                }
                if !self.drivingAffirmedByUser, !self.drivingSuspected {
                    let isAutomotive = ActivityDetectionService.shared.isAutomotiveHighConfidence
                    if self.drivingDetector.tick(speed: self.lastKnownSpeed, isAutomotiveHigh: isAutomotive, now: now) != nil {
                        self.drivingEverDetected = true
                        self.drivingSuspected = true
                    }
                }
            }
        }
    }

    func pause() {
        pause(keepingAwake: false)
    }

    /// `keepingAwake` leaves low-power location running so iOS does not
    /// suspend the app, which is what lets an auto-pause hear Core Motion.
    /// Fixes that arrive while paused are ignored.
    private func pause(keepingAwake: Bool) {
        guard !isPaused else { return }
        isPaused = true
        pauseStart = Date()
        timer?.invalidate()
        timer = nil
        if keepingAwake {
            locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            locationManager.distanceFilter = 100
        } else {
            locationManager.stopUpdatingLocation()
        }
        UIApplication.shared.isIdleTimerDisabled = false
        resetOffTrail()
        writeSnapshot()
    }

    // MARK: - Auto-pause and auto-resume

    /// Internal, not private, so tests can start the watch without waiting
    /// out the break prompt.
    func autoPause(at now: Date) {
        autoPausedForInactivity = true
        pause(keepingAwake: true)
        autoResumeWatch = AutoResumeWatch(mode: route.activityMode, pausedAt: now)
        autoResumeTimer?.invalidate()
        autoResumeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.autoResumeTick(confident: ActivityDetectionService.shared.confidentActivity, at: Date())
            }
        }
        postAutoPauseNotification()
        pushLiveActivityState()
    }

    /// Internal, not private, so tests can drive it without Core Motion.
    func autoResumeTick(confident: ActivityDetectionService.DetectedActivity?, at now: Date) {
        guard isPaused, var watch = autoResumeWatch else { return }
        let decision = watch.observe(confident, at: now)
        autoResumeWatch = watch
        switch decision {
        case .keepWatching:
            return
        case .giveUp:
            // Past the window: pause fully, as a manual pause does.
            endAutoResumeWatch()
            locationManager.stopUpdatingLocation()
        case .resume:
            dismissBreakPrompt()
            resume()
            let label = route.activityMode.sessionLabel
            WalkAudioCueService.shared.announce("You're moving again. Resuming your \(label.lowercased()).")
            Task {
                // Same kind as the pause notice, so it replaces it.
                await NotificationService.shared.schedule(.autoPause, title: "\(label) resumed",
                    body: "You started moving again, so Wockett picked up tracking where it paused.",
                    trigger: nil)
            }
            pushLiveActivityState()
        }
    }

    private func endAutoResumeWatch() {
        autoResumeTimer?.invalidate()
        autoResumeTimer = nil
        autoResumeWatch = nil
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 5
    }

    /// The Live Activity cannot rely on the walk screen's onChange, which only
    /// runs while the screen renders; an auto-pause usually happens pocketed.
    private func pushLiveActivityState() {
        let dist = totalDistanceCovered
        let elapsed = elapsedTime
        let paused = isPaused
        let pace = dist > 100 && elapsed > 10 ? elapsed / (dist / 1000) : nil
        let pausedTotal = totalPausedDuration
        Task {
            await WalkLiveActivityManager.shared.update(
                distanceCovered: dist,
                elapsedSeconds: Int(elapsed),
                isPaused: paused,
                paceSecsPerKm: pace,
                pausedDuration: pausedTotal,
                pauseTime: paused ? Date() : nil
            )
        }
    }

    func resume() {
        guard isPaused else { return }
        if let ps = pauseStart {
            pausedDuration += Date().timeIntervalSince(ps)
            pauseStart = nil
        }
        autoPausedForInactivity = false
        endAutoResumeWatch()
        breakPromptShownAt = nil
        isPaused = false
        UIApplication.shared.isIdleTimerDisabled = true
        lastMovementTime = Date()   // prevent a phantom stop on the first ticks after resuming
        resetOffTrail()
        locationManager.startUpdatingLocation()
        startTimer()
        writeSnapshot()
    }

    func stop() {
        stopTracking()
        ActiveWalkSnapshotStore.clear()
    }

    /// Everything `stop()` does except deleting the checkpoint. `finish()`
    /// uses it: the walk is over but not yet saved.
    private func stopTracking() {
        stopped = true
        autoPausedForInactivity = false
        endAutoResumeWatch()
        NotificationService.shared.withdraw(.offTrail)
        NotificationService.shared.withdraw(.trailArrival)
        locationManager.stopUpdatingLocation()
        pedometer.stopUpdates()
        timer?.invalidate()
        timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Total time paused so far, including a pause currently in progress —
    /// used to keep the Live Activity's live-ticking timer correctly offset.
    var totalPausedDuration: TimeInterval {
        pausedDuration + (pauseStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    /// Off in unit tests, which run in parallel with the snapshot store's own
    /// tests and would otherwise write into the file those tests check.
    var writesSnapshots = true

    /// Set by stopTracking(). A late event (a location fix in flight, the
    /// write at the end of advanceWaypoint()) must not put a checkpoint back
    /// after stop() deleted it: until 2026-09-28 every completed guided walk
    /// left one behind, which the next launch offered to resume.
    private var stopped = false

    private func writeSnapshot() {
        guard writesSnapshots, !stopped else { return }
        ActiveWalkSnapshotStore.save(snapshot)
    }

    /// The crash checkpoint as it stands now.
    var snapshot: ActiveWalkSnapshot {
        // Thin the breadcrumb trail so very long walks keep the checkpoint
        // file small — cap ~2000 points, evenly strided.
        let thinned = Self.thinned(trackPoints)

        return ActiveWalkSnapshot(
            route: .init(route),
            startTime: startTime,
            totalDistanceCovered: totalDistanceCovered,
            pausedDuration: pausedDuration,
            isPaused: isPaused,
            pauseStartDate: pauseStart,
            currentWaypointIndex: currentWaypointIndex,
            currentLap: currentLap,
            triggeredCheckpoints: triggeredCheckpoints,
            splitTimes: splitTimes.map { .init(label: $0.label, elapsed: $0.elapsed) },
            liveSteps: liveSteps,
            checkpointDate: Date(),
            trackPoints: thinned.map { WaypointCoord($0) },
            trailAlong: trailProgress?.along,
            legStartDistance: legStartDistance,
            isCompleted: isCompleted
        )
    }

    /// What the Live Activity treats as the whole distance: the current
    /// route's length plus whatever came before it. The widget shows
    /// total − covered as the distance left, and covered includes the way to
    /// a trail, so the trail's length alone read 0 left after a long approach.
    nonisolated static func liveActivityTotal(routeTotal: Double, legStart: Double) -> Double {
        max(0, legStart) + routeTotal
    }

    var liveActivityTotalMeters: Double {
        Self.liveActivityTotal(routeTotal: route.totalDistance, legStart: legStartDistance)
    }

    func dismissBreakPrompt() {
        stopTracker.reset()
        showBreakPrompt = false
        breakPromptShownAt = nil
    }

    func clearDrivingSuspicion() {
        drivingAffirmedByUser = true
        drivingSuspected = false
    }

    // Finalises the HealthKit workout after the session is saved to local history.
    func finishWorkoutSession() async {
        guard let writer = workoutWriter else { return }
        workoutWriter = nil
        await writer.finish(totalDistanceMeters: totalDistanceCovered, endDate: Date())
    }

    // Discards the in-progress HealthKit workout without writing anything to Health.
    func discardWorkoutSession() {
        guard let writer = workoutWriter else { return }
        workoutWriter = nil
        writer.discard()
    }

    var nextWaypoint: CLLocationCoordinate2D? {
        guard !route.waypoints.isEmpty else { return nil }
        if route.isLoop {
            return route.waypoints[currentWaypointIndex % route.waypoints.count]
        }
        guard currentWaypointIndex < route.waypoints.count else { return nil }
        return route.waypoints[currentWaypointIndex]
    }

    var progressText: String {
        if route.approach != nil {
            return arrivedAtTrail ? "You're at the trail" : "Heading to the trail"
        }
        if route.path != nil, !route.isLoop { return "On the \(route.lineNoun)" }
        return route.isLoop
            ? "Lap \(min(currentLap, route.lapCount)) of \(route.lapCount)"
            : "Heading to destination"
    }

    var remainingDistance: Double {
        // A trail walk counts what is left along the trail, not what is left
        // of the planned distance after however far the GPS track wandered.
        if let progress = trailProgress, progress.along != nil { return progress.remaining }
        return max(0, route.totalDistance - (totalDistanceCovered - legStartDistance))
    }

    // Pace (walking/running) or speed (cycling) — shown as "--" until enough data.
    var paceText: String {
        if route.activityMode == .cycling {
            guard totalDistanceCovered > 50, elapsedTime > 5 else { return "--" }
            let useMetric = Locale.current.measurementSystem != .us
            let speed = (totalDistanceCovered / elapsedTime) * 3.6   // km/h
            let value = useMetric ? speed : speed / 1.609344
            return String(format: "%.1f %@", value, useMetric ? "km/h" : "mph")
        }
        guard totalDistanceCovered > 50, elapsedTime > 5 else { return "--:--" }
        let useMetric = Locale.current.measurementSystem != .us
        let divisor   = useMetric ? 1000.0 : 1609.34
        let unit      = useMetric ? "/km" : "/mi"
        let minPerUnit = (elapsedTime / 60.0) / (totalDistanceCovered / divisor)
        let mins      = Int(minPerUnit)
        let secs      = Int((minPerUnit - Double(mins)) * 60)
        return String(format: "%d:%02d%@", mins, secs, unit)
    }

    var paceLabel: String { route.activityMode == .cycling ? "speed" : "pace" }

    var elapsedText: String {
        let s = Int(elapsedTime); let m = s / 60
        return m < 60 ? "\(m)m \(s % 60)s" : "\(m / 60)h \(m % 60)m"
    }

    func distanceText(_ meters: Double) -> String {
        MKDistanceFormatter.abbreviated.string(fromDistance: max(0, meters))
    }

    var estimatedSteps: Int { liveSteps > 0 ? liveSteps : Int(totalDistanceCovered / 0.762) }
    var stopCount: Int { stopTracker.stopCount }

    var estimatedSecondsRemaining: Double? {
        guard totalDistanceCovered > 100, elapsedTime > 10, remainingDistance > 10 else { return nil }
        let mps = totalDistanceCovered / elapsedTime
        return mps > 0 ? remainingDistance / mps : nil
    }

    // MARK: - Pet credit
    //
    // Which pets walked which part of this walk. Kept on the session so it
    // survives the walk screen being minimised and reaches every way a walk
    // ends. Until 2026-09-28 it lived in the walk screen's @State: minimising
    // wiped it, and the mini tile and Live Activity saved no pet credit.

    /// Distance covered when each pet now on the walk joined it.
    private(set) var petJoinedAt: [UUID: Double] = [:]
    /// Distance each pet walked in stretches that have already ended.
    private var petWalkedBefore: [UUID: Double] = [:]

    /// Every pet that was on this walk at any point.
    var sessionPetIds: Set<UUID> { Set(petJoinedAt.keys).union(petWalkedBefore.keys) }

    /// A pet joins the walk at the distance covered so far. No-op if it is
    /// already on it, so re-adopting the active pets never resets a stretch.
    func petJoined(_ id: UUID) {
        guard petJoinedAt[id] == nil else { return }
        petJoinedAt[id] = totalDistanceCovered
    }

    /// A pet leaves the walk; the stretch it walked is kept.
    func petLeft(_ id: UUID) {
        guard let since = petJoinedAt.removeValue(forKey: id) else { return }
        petWalkedBefore[id, default: 0] += max(0, totalDistanceCovered - since)
    }

    /// Distance each pet has walked so far, counting a stretch in progress.
    var petDistances: [UUID: Double] {
        var walked = petWalkedBefore
        for (id, since) in petJoinedAt { walked[id, default: 0] += max(0, totalDistanceCovered - since) }
        return walked
    }

    var completedSession: WalkSession {
        WalkSession(
            id: UUID(),
            routeName: route.name,
            date: startTime,
            elapsedTime: elapsedTime,
            totalDistance: totalDistanceCovered,
            // A trail walk records its checkpoints, like every guided walk,
            // not its full line: the summary's "Save as Custom Route" saves
            // these points for MKDirections to join, and a trail's dozens of
            // vertices would come back routed on streets, one request each.
            // A recorded route keeps its line, which RecordedRoute recognises
            // again when the walk is restarted or saved.
            waypoints: route.waypoints.isEmpty
                ? trackPoints.map { WaypointCoord($0) }
                : route.historyWaypoints.map { WaypointCoord($0) },
            lapCount: route.lapCount,
            isLoop: route.isLoop,
            activityType: route.activityMode.rawValue,
            steps: liveSteps,
            customRouteId: route.customRouteId,
            stopCount: stopTracker.stopCount,
            flaggedPossibleVehicle: drivingEverDetected && !drivingAffirmedByUser
        )
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy < 50 else { return }
        Task { @MainActor [weak self] in
            // An auto-pause keeps location running only to stay awake; its
            // fixes are not part of the walk.
            guard let self, !self.isPaused else { return }
            self.elapsedTime = Date().timeIntervalSince(self.startTime) - self.pausedDuration
            if let last = self.lastLocation {
                let delta = loc.distance(from: last)
                if delta < 100 { self.totalDistanceCovered += delta }
            }
            self.lastLocation = loc
            self.trackPoints.append(loc.coordinate)
            if var progress = self.trailProgress {
                let event = progress.update(location: loc.coordinate, accuracy: loc.horizontalAccuracy,
                                            at: Date(), alertsEnabled: self.offTrailAlertsEnabled)
                self.trailProgress = progress
                if let event { self.handleOffTrail(event) }
                if let turned = progress.turnedRound(self.route) { self.turnRouteRound(turned) }
            }
            self.lastMovementTime = Date()
            self.lastKnownSpeed = loc.speed
            self.workoutWriter?.addLocations(locations)
            self.checkArrival(at: loc)
            if !self.route.isCustomRoute { self.checkDistanceCheckpoints() }
            let paceSecsPerKm: Double? = self.totalDistanceCovered > 100 && self.elapsedTime > 10
                ? self.elapsedTime / (self.totalDistanceCovered / 1000)
                : nil
            WalkAudioCueService.shared.update(
                distanceCoveredMeters: self.totalDistanceCovered,
                paceSecsPerKm: paceSecsPerKm,
                activityMode: self.route.activityMode
            )
            // Push the Live Activity directly from here too — don't rely on
            // WalkNavigationView's onChange, which only fires while the view is
            // actively rendering. This is what keeps the lock screen's distance/
            // pace/timer moving during a normal backgrounded walk, not just when
            // Pause/Resume happens to push an update.
            // isPaused: false is intentional — fixes that arrive while paused
            // (an auto-pause keeps location running) returned above.
            await WalkLiveActivityManager.shared.update(
                distanceCovered: self.totalDistanceCovered,
                elapsedSeconds: Int(self.elapsedTime),
                isPaused: false,
                paceSecsPerKm: paceSecsPerKm,
                pausedDuration: self.totalPausedDuration,
                pauseTime: nil
            )
        }
    }

    /// Internal, not private, so tests can check the 20/40/60/80% markers.
    func checkDistanceCheckpoints() {
        guard route.totalDistance > 0, onCheckpointReached != nil else { return }
        for (i, fraction) in checkpointFractions.enumerated() {
            guard !triggeredCheckpoints.contains(i) else { continue }
            if totalDistanceCovered - legStartDistance >= route.totalDistance * fraction {
                triggeredCheckpoints.insert(i)
                let label = "\(Int(fraction * 100))%"
                splitTimes.append((label: label, elapsed: elapsedTime))
                onCheckpointReached?(label)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    /// Internal, not private, so tests can feed a fix without a CLLocationManager.
    func checkArrival(at location: CLLocation) {
        // Heading to a trail: no finish at the access point. Reaching the
        // trail anywhere offers the trail walk; the person decides.
        if let approach = route.approach {
            checkTrailArrival(approach, at: location)
            return
        }
        // A trail walk advances by position along the trail: a checkpoint
        // counts once it has been passed, however far the trail data sits
        // from the ground path, and "to next" follows the trail's bends.
        if trailProgress != nil {
            advanceAlongTrail()
            checkTurnaround()
            return
        }
        guard let next = nextWaypoint else { return }
        let dist = location.distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
        distanceToNextWaypoint = dist
        guard dist < arrivalRadius else { return }
        advanceWaypoint()
    }

    /// Internal, not private, so tests can walk a route to its end.
    func advanceWaypoint() {
        let arrivedIndex = currentWaypointIndex
        let step = WaypointStep.after(index: currentWaypointIndex, lap: currentLap, count: route.waypoints.count,
                                      isLoop: route.isLoop, lapCount: route.lapCount)
        currentWaypointIndex = step.index
        if route.isCustomRoute, onCheckpointReached != nil {
            let label = WaypointStep.label(arrivingAt: arrivedIndex, count: route.waypoints.count)
            splitTimes.append((label: label, elapsed: elapsedTime))
            onCheckpointReached?(label)
        }
        currentLap = step.lap
        if route.isLoop {
            if step.index == 1 {
                if step.finished {
                    finish()
                } else {
                    let lapsLeft = route.lapCount - (currentLap - 1)
                    fireBackgroundNotification(
                        title: "Lap \(currentLap - 1) of \(route.lapCount) complete 🔄",
                        body: lapsLeft == 1 ? "Last lap — finish strong!" : "\(lapsLeft) laps to go"
                    )
                }
            }
        } else if step.finished {
            finish()
        } else {
            let total = route.waypoints.count - 1
            let left = route.waypoints.count - currentWaypointIndex
            fireBackgroundNotification(
                title: "Checkpoint \(arrivedIndex) of \(total) ✓",
                body: left == 1 ? "Almost there — final stretch!" : "\(left) waypoints to go"
            )
        }
        writeSnapshot()
    }

    private func advanceAlongTrail() {
        let count = route.waypoints.count
        guard count > 0, let progress = trailProgress else { return }
        // Several checkpoints can be passed in one fix after a gap in GPS, but
        // never the finish with them (TrailProgress.checkpointsToAdvance).
        let passed = progress.checkpointsToAdvance(from: currentWaypointIndex, waypointCount: count)
        for _ in 0..<passed where !isCompleted { advanceWaypoint() }
        let index = route.isLoop ? currentWaypointIndex % count : min(currentWaypointIndex, count - 1)
        distanceToNextWaypoint = progress.distanceAlong(toWaypoint: index)
    }

    /// The person is going round a closed line the other way: the walk
    /// restarts on the reversed route (`TrailProgress.turnedRound`).
    /// Internal, not private, so tests can check the route change is published.
    func turnRouteRound(_ turned: TrailProgress.TurnedRound) {
        route = turned.route
        trailProgress = turned.progress
        currentWaypointIndex = turned.index
        currentLap = turned.lap
        onRouteChanged?(turned.route)
        writeSnapshot()
    }

    // MARK: Out and back

    /// How close to the turnaround counts as there: trail data can sit tens of
    /// metres from the path on the ground, and progress is a best guess.
    nonisolated static let turnaroundSlack = 15.0

    /// Whether `along` (distance walked on the route's line) is at or past
    /// the turnaround. One rule for saying it on the walk and for a walk
    /// restored after it.
    nonisolated static func hasReachedTurnaround(along: Double?, turnaround: Double?) -> Bool {
        guard let along, let turnaround else { return false }
        return along >= turnaround - turnaroundSlack
    }

    /// Internal, not private, so tests can walk a route past its turnaround.
    func checkTurnaround() {
        guard !hasPassedTurnaround, let along = trailProgress?.along,
              Self.hasReachedTurnaround(along: along, turnaround: route.turnaroundMeters) else { return }
        hasPassedTurnaround = true
        let back = distanceText(max(0, (trailProgress?.guide.length ?? 0) - along))
        fireBackgroundNotification(title: "Turn around here", body: "\(back) back to the start of \(route.name).")
        WalkAudioCueService.shared.announce("Turn around here. \(back) back to the start.")
        writeSnapshot()
    }

    /// "Head back now" is offered on a trail walk that has gone somewhere and
    /// is still heading out: before an out-and-back's turnaround, or anywhere
    /// along a walk to the end of a line or round a loop.
    var canHeadBack: Bool {
        guard !isCompleted, route.approach == nil, route.path != nil,
              let along = trailProgress?.along, along >= 50 else { return false }
        if let turn = route.turnaroundMeters { return along < turn - Self.turnaroundSlack }
        return true
    }

    /// Ends the way out where the person is: the rest of the walk becomes the
    /// trail back to where it started. One session throughout, as when a walk
    /// to a trail becomes the trail walk (`beginTrailWalk`). Returns the new
    /// route, or nil when there is no way out to cut short.
    @discardableResult
    func headBack() -> NavigableRoute? {
        guard canHeadBack, let progress = trailProgress, let along = progress.along,
              let path = route.path else { return nil }
        let back = Array(TrailWalkPlanner.prefix(of: path, meters: along).reversed())
        guard back.count >= 2 else { return nil }
        let length = TrailWalkPlanner.length(back)
        let next = NavigableRoute(name: route.name,
                                  waypoints: TrailWalkPlanner.checkpoints(along: back, isLoop: false, length: length),
                                  lapCount: 1, isLoop: false, totalDistance: length,
                                  isCustomRoute: route.isCustomRoute, isCommunityRoute: route.isCommunityRoute,
                                  activityMode: route.activityMode, customRouteId: route.customRouteId,
                                  path: back, pathIsRecording: route.pathIsRecording)
        route = next
        trailProgress = TrailProgress(route: next)
        currentWaypointIndex = 1
        currentLap = 1
        triggeredCheckpoints = []
        splitTimes.removeAll { $0.label.hasSuffix("%") }
        legStartDistance = totalDistanceCovered
        hasPassedTurnaround = true
        WalkAudioCueService.shared.announce("Heading back. \(distanceText(length)) to the start.")
        onRouteChanged?(next)
        writeSnapshot()
        return next
    }

    // MARK: Heading to a trail

    private func checkTrailArrival(_ approach: TrailApproach, at location: CLLocation) {
        if let access = route.waypoints.last {
            distanceToNextWaypoint = location.distance(from: CLLocation(latitude: access.latitude, longitude: access.longitude))
        }
        guard !arrivedAtTrail, approach.arrivalPlan(at: location.coordinate) != nil else { return }
        arrivedAtTrail = true
        trailArrivalLocation = location.coordinate
        let noun = route.activityMode.noun
        WalkAudioCueService.shared.announce("You've reached \(approach.trailName). Start the trail \(noun) when you're ready.")
        if Self.shouldNotifyOffTrail(appIsActive: UIApplication.shared.applicationState == .active,
                                     sessionScreenVisible: isSessionScreenVisible) {
            fireBackgroundNotification(title: "You're at \(approach.trailName)",
                                       body: "Open Wockett to start the trail \(noun).",
                                       kind: .trailArrival)
        }
    }

    /// Turns a session heading to a trail into the walk along it, from where
    /// the person is (or where they reached it, if they have moved out of
    /// range since). One session throughout: the time, distance, steps and
    /// Health workout carry on, and the walk is saved under the trail's name.
    /// Returns the new route, or nil when there is no trail walk to start.
    @discardableResult
    func beginTrailWalk() -> NavigableRoute? {
        guard let approach = route.approach else { return nil }
        let here = lastLocation?.coordinate
        let mode = route.activityMode
        guard let plan = here.flatMap({ approach.arrivalPlan(at: $0, activityMode: mode) })
                ?? trailArrivalLocation.flatMap({ approach.arrivalPlan(at: $0, activityMode: mode) }) else { return nil }
        let next = plan.navigableRoute(activityMode: route.activityMode)
        route = next
        trailProgress = TrailProgress(route: next)
        currentWaypointIndex = 1
        currentLap = 1
        triggeredCheckpoints = []
        // The way there's 20/40/60/80% splits would sit beside the trail's
        // own and read as the same markers twice in the summary.
        splitTimes.removeAll { $0.label.hasSuffix("%") }
        legStartDistance = totalDistanceCovered
        NotificationService.shared.withdraw(.trailArrival)
        distanceToNextWaypoint = 0
        arrivedAtTrail = false
        trailArrivalLocation = nil
        onRouteChanged?(next)
        writeSnapshot()
        return next
    }

    // MARK: Off trail

    /// "The trail is about 200 ft to the northeast."
    var offTrailDirectionText: String? { offTrailDescription(spoken: false) }

    /// Bearing from the person to the nearest point of the trail, degrees from north.
    var bearingToTrail: Double? {
        guard let nearest = trailProgress?.nearest, let here = lastLocation?.coordinate else { return nil }
        return HeadingTracker.bearing(from: here, to: nearest)
    }

    private func offTrailDescription(spoken: Bool) -> String? {
        guard let offset = trailProgress?.offset, let bearing = bearingToTrail else { return nil }
        let formatter = MKDistanceFormatter()
        formatter.unitStyle = spoken ? .full : .abbreviated
        let distance = formatter.string(fromDistance: max(10, (offset / 10).rounded() * 10))
        return "The \(route.lineNoun) is about \(distance) to the \(CompassDirection.name(for: bearing))."
    }

    private func handleOffTrail(_ event: OffTrailMonitor.Event) {
        switch event {
        case .left:
            let direction = offTrailDescription(spoken: true) ?? ""
            WalkAudioCueService.shared.announce("You've left \(route.name). \(direction)")
            // On the session screen the banner and a haptic say it; anywhere
            // else — a pocket, or the app with the walk minimized — a
            // notification, which in-walk kinds show even in the foreground.
            if Self.shouldNotifyOffTrail(appIsActive: UIApplication.shared.applicationState == .active,
                                         sessionScreenVisible: isSessionScreenVisible) {
                fireBackgroundNotification(title: "Off \(route.name)",
                                           body: offTrailDescription(spoken: false) ?? "Head back to the \(route.lineNoun).",
                                           kind: .offTrail)
            }
        case .returned:
            WalkAudioCueService.shared.announce("Back on \(route.name).")
        }
        onOffTrailChange?(event == .left)
    }

    /// Whether leaving the trail needs a notification: only the session
    /// screen shows the off-trail banner. Minimized, it used to be a haptic
    /// and nothing to read (2026-09-25 review of #65).
    nonisolated static func shouldNotifyOffTrail(appIsActive: Bool, sessionScreenVisible: Bool) -> Bool {
        !(appIsActive && sessionScreenVisible)
    }

    /// Clears the off-trail state, and the banner and notification with it
    /// (`trailProgress`'s didSet).
    private func resetOffTrail() {
        trailProgress?.resetOffTrail()
    }

    private func finish() {
        isCompleted = true
        // The walk is over but not yet saved. Keep the checkpoint, marked
        // completed, so a kill before the save still reaches Walk History
        // (salvaged at launch, never offered for resume). Every save path
        // clears it; until 2026-09-28 stop() deleted it here, before anything
        // had saved the walk.
        writeSnapshot()
        stopTracking()
        fireBackgroundNotification(title: "Walk complete! 🎉", body: "Great work on \(route.name)")
        WalkAudioCueService.shared.announce("Walk complete! Great job on \(route.name).")
        onCompleted?()
    }

    private func postAutoPauseNotification() {
        Task {
            await NotificationService.shared.schedule(.autoPause, title: "Session paused",
                body: "You've been stopped for a while, so we paused your session to keep your stats honest. Resume anytime.",
                trigger: nil)
        }
    }

    private func fireBackgroundNotification(title: String, body: String,
                                            kind: NotificationKind = .routeEvent(UUID().uuidString)) {
        Task {
            await NotificationService.shared.schedule(kind, title: title, body: body,
                                                      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false))
        }
    }
}

// MARK: - Navigation Map

// Annotation dropped on the route at every 1 km milestone during an active walk.
final class MilestoneAnnotation: NSObject, MKAnnotation {
    var coordinate: CLLocationCoordinate2D
    let distanceMeters: Double
    init(coordinate: CLLocationCoordinate2D, distanceMeters: Double) {
        self.coordinate = coordinate
        self.distanceMeters = distanceMeters
    }
    var title: String? { String(format: "%.0f km", distanceMeters / 1000) }
}

struct NavigationMapView: UIViewRepresentable {
    let route: NavigableRoute
    let computedLegs: [RouteLeg]
    let currentWaypointIndex: Int
    let checkpointsEnabled: Bool
    var distanceCoveredMeters: Double = 0
    /// Which way the person faces, degrees from north, for the beam; nil hides it.
    var headingDegrees: Double?
    /// The map turns with the person instead of staying north up.
    var headingUp = false
    /// Bumped by the recentre button; each new value re-follows the person.
    var recenterToken = 0
    /// Off a trail: from the person to the nearest point of it, drawn dashed.
    var offTrailLink: [CLLocationCoordinate2D]?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.userTrackingMode = .follow
        // Two-finger rotation, with the compass to get back to north.
        map.isRotateEnabled = true
        map.showsCompass = true
        map.overrideUserInterfaceStyle = .unspecified
        // Allow zooming from street-level (30 m) to neighbourhood-level (50 km)
        map.setCameraZoomRange(
            MKMapView.CameraZoomRange(
                minCenterCoordinateDistance: 30,
                maxCenterCoordinateDistance: 50_000
            ),
            animated: false
        )
        for (i, wp) in route.waypoints.enumerated() {
            let ann = MKPointAnnotation()
            ann.coordinate = wp
            ann.title = i == 0 ? "Start" : "\(i)"
            map.addAnnotation(ann)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.lastHeadingUp != headingUp || coordinator.lastRecenterToken != recenterToken {
            coordinator.lastHeadingUp = headingUp
            coordinator.lastRecenterToken = recenterToken
            if headingUp {
                map.setUserTrackingMode(.followWithHeading, animated: true)
            } else {
                // Back to north first; .follow keeps whatever rotation it finds.
                let camera = map.camera.copy() as? MKMapCamera ?? map.camera
                camera.heading = 0
                map.setCamera(camera, animated: true)
                map.setUserTrackingMode(.follow, animated: true)
            }
        }
        coordinator.headingDegrees = headingDegrees
        coordinator.updateBeam(on: map)
        let link = offTrailLink ?? []
        if !Self.sameCoordinates(link, coordinator.lastOffTrailLink) {
            coordinator.lastOffTrailLink = link
            map.removeOverlays(map.overlays.filter { $0 is OffTrailLine })
            if link.count == 2 {
                map.addOverlay(OffTrailLine(coordinates: link, count: link.count), level: .aboveLabels)
            }
        }

        if !computedLegs.isEmpty, !context.coordinator.hasAddedLegs {
            context.coordinator.hasAddedLegs = true
            for leg in computedLegs { map.addOverlay(leg.polyline) }
        }
        if checkpointsEnabled && !computedLegs.isEmpty && !context.coordinator.hasAddedCheckpoints {
            context.coordinator.hasAddedCheckpoints = true
            Self.addCheckpointMarkers(on: map, legs: computedLegs)
        } else if !checkpointsEnabled && context.coordinator.hasAddedCheckpoints {
            context.coordinator.hasAddedCheckpoints = false
            map.removeOverlays(map.overlays.filter { $0 is NavCheckpointCircle })
        }
        // Refresh annotation tints when the current waypoint advances
        if context.coordinator.lastWaypointIndex != currentWaypointIndex {
            context.coordinator.lastWaypointIndex = currentWaypointIndex
            for ann in map.annotations {
                guard let marker = map.view(for: ann) as? MKMarkerAnnotationView,
                      let pt = ann as? MKPointAnnotation,
                      let title = pt.title else { continue }
                let idx = title == "Start" ? 0 : (Int(title) ?? 0)
                marker.markerTintColor = idx < currentWaypointIndex ? .systemGray3 : (title == "Start" ? .brandOrangeFill : route.activityMode.tileFillUIColor)
                marker.alpha = idx < currentWaypointIndex ? 0.45 : 1.0
            }
        }

        // 1 km milestone markers — placed on the route polyline as the user walks
        if !computedLegs.isEmpty && distanceCoveredMeters > 0 {
            let milestoneKm = Int(distanceCoveredMeters / 1000)
            guard milestoneKm > context.coordinator.lastMilestoneKm else { return }
            var allCoords: [CLLocationCoordinate2D] = []
            for leg in computedLegs {
                let pts = leg.polyline.points()
                for i in 0..<leg.polyline.pointCount { allCoords.append(pts[i].coordinate) }
            }
            guard allCoords.count > 1 else { return }
            var combined = allCoords
            let poly = MKPolyline(coordinates: &combined, count: combined.count)
            let totalLegDist = computedLegs.reduce(0.0) { $0 + $1.distance }
            guard totalLegDist > 0 else { return }
            for km in (context.coordinator.lastMilestoneKm + 1)...milestoneKm {
                let targetMeters = Double(km) * 1000
                let fraction = min(targetMeters / totalLegDist, 0.99)
                if let coord = poly.coordinate(atFraction: fraction) {
                    map.addAnnotation(MilestoneAnnotation(coordinate: coord, distanceMeters: targetMeters))
                }
            }
            context.coordinator.lastMilestoneKm = milestoneKm
        }
    }

    static func sameCoordinates(_ a: [CLLocationCoordinate2D], _ b: [CLLocationCoordinate2D]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
    }

    static func addCheckpointMarkers(on map: MKMapView, legs: [RouteLeg]) {
        var allCoords: [CLLocationCoordinate2D] = []
        for leg in legs {
            let pts = leg.polyline.points()
            for i in 0..<leg.polyline.pointCount { allCoords.append(pts[i].coordinate) }
        }
        guard allCoords.count > 1 else { return }
        var combined = allCoords
        let poly = MKPolyline(coordinates: &combined, count: combined.count)
        for fraction in [0.2, 0.4, 0.6, 0.8] {
            if let c = poly.coordinate(atFraction: fraction) {
                map.addOverlay(NavCheckpointCircle(center: c, radius: 18), level: .aboveRoads)
            }
        }
        guard let lastCoord = allCoords.last else { return }
        let finish = NavCheckpointCircle(center: lastCoord, radius: 24)
        finish.isFinish = true
        map.addOverlay(finish, level: .aboveRoads)
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.activityColor = route.activityMode.tileUIColor
        c.activityFillColor = route.activityMode.tileFillUIColor
        return c
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        // activityColor (bright) draws the polyline line itself; activityFillColor
        // (darkened) fills waypoint marker pins, which carry a white glyph on top --
        // same text-vs-fill split as the rest of the v1.10 design system.
        var activityColor: UIColor = .brandGreen
        var activityFillColor: UIColor = .brandGreenFill
        var hasAddedLegs = false
        var lastWaypointIndex = 0
        var hasAddedCheckpoints = false
        var lastMilestoneKm = 0
        var lastHeadingUp = false
        var lastRecenterToken = 0
        var headingDegrees: Double?
        var lastOffTrailLink: [CLLocationCoordinate2D] = []

        /// Points the beam where the person faces, relative to the map's own
        /// rotation, so it stays right while the map turns.
        func updateBeam(on map: MKMapView) {
            guard let view = map.view(for: map.userLocation) as? UserHeadingAnnotationView else { return }
            view.beam.angle = headingDegrees.map { $0 - map.camera.heading }
        }

        func mapViewDidChangeVisibleRegion(_ map: MKMapView) {
            updateBeam(on: map)
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? OffTrailLine {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = .brandOrange
                r.lineWidth = 3
                r.lineCap = .round
                r.lineDashPattern = [6, 6]
                return r
            }
            if let circle = overlay as? NavCheckpointCircle {
                let r = MKCircleRenderer(circle: circle)
                if circle.isFinish {
                    r.fillColor = UIColor.systemOrange.withAlphaComponent(0.3)
                    r.strokeColor = UIColor.systemOrange
                    r.lineWidth = 2
                } else {
                    r.fillColor = UIColor.white.withAlphaComponent(0.4)
                    r.strokeColor = UIColor.systemGray2.withAlphaComponent(0.9)
                    r.lineWidth = 1.5
                }
                return r
            }
            guard let pl = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: pl)
            r.strokeColor = activityColor
            r.lineWidth = 5
            r.alpha = 0.85
            return r
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                let view = (map.dequeueReusableAnnotationView(withIdentifier: UserHeadingAnnotationView.reuseID)
                            as? UserHeadingAnnotationView)
                    ?? UserHeadingAnnotationView(annotation: annotation, reuseIdentifier: UserHeadingAnnotationView.reuseID)
                view.annotation = annotation
                view.beam.angle = headingDegrees.map { $0 - map.camera.heading }
                return view
            }
            if let milestone = annotation as? MilestoneAnnotation {
                let view = MKMarkerAnnotationView(annotation: milestone, reuseIdentifier: "milestone")
                view.glyphImage = UIImage(systemName: WktSymbol.finish.name)
                view.markerTintColor = .accentRideFill
                view.titleVisibility = .visible
                view.canShowCallout = false
                return view
            }
            guard let ann = annotation as? MKPointAnnotation else { return nil }
            let view = MKMarkerAnnotationView(annotation: ann, reuseIdentifier: "nav")
            view.glyphText = ann.title ?? ""
            view.markerTintColor = ann.title == "Start" ? .brandOrangeFill : activityFillColor
            view.canShowCallout = false
            return view
        }
    }
}

// MARK: - Route leg

/// One drawn stretch of a guided route: a leg MKDirections computed, or a
/// trail's own line. The navigation map needs only these two things from either.
struct RouteLeg {
    let polyline: MKPolyline
    let distance: CLLocationDistance

    init(_ route: MKRoute) {
        polyline = route.polyline
        distance = route.distance
    }

    init(path: [CLLocationCoordinate2D]) {
        polyline = MKPolyline(coordinates: path, count: path.count)
        distance = TrailWalkPlanner.length(path)
    }
}
