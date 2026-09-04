import SwiftUI
import MapKit
import CoreLocation
import CoreMotion
import UserNotifications
import UIKit
import HealthKit

// MARK: - Checkpoint Circle Overlay

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
        if stoppedSince == nil { stoppedSince = now }
        let elapsed = now.timeIntervalSince(stoppedSince!)

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
            if episodeStart == nil { episodeStart = now }
            let elapsed = now.timeIntervalSince(episodeStart!)
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

    private let route: NavigableRoute
    private let locationManager = CLLocationManager()
    private let pedometer = CMPedometer()
    private(set) var startTime = Date()
    private var timer: Timer?
    private var lastLocation: CLLocation?
    private let arrivalRadius = 30.0
    private var triggeredCheckpoints: Set<Int> = []
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

    // Driving detection — compares GPS speed and CoreMotion automotive classification.
    private var drivingDetector = DrivingDetector(speedCeiling: 3.5)
    private var lastKnownSpeed: Double = -1   // -1 until first GPS fix
    var drivingSuspected: Bool = false
    private(set) var drivingEverDetected: Bool = false
    private(set) var drivingAffirmedByUser: Bool = false

    init(route: NavigableRoute) {
        self.route = route
        super.init()
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

        beginTracking()
        writeSnapshot()
    }

    private func beginTracking() {
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
                    self.autoPausedForInactivity = true
                    self.pause()
                    self.postAutoPauseNotification()
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
        guard !isPaused else { return }
        isPaused = true
        pauseStart = Date()
        timer?.invalidate()
        timer = nil
        locationManager.stopUpdatingLocation()
        UIApplication.shared.isIdleTimerDisabled = false
        writeSnapshot()
    }

    func resume() {
        guard isPaused else { return }
        if let ps = pauseStart {
            pausedDuration += Date().timeIntervalSince(ps)
            pauseStart = nil
        }
        autoPausedForInactivity = false
        breakPromptShownAt = nil
        isPaused = false
        UIApplication.shared.isIdleTimerDisabled = true
        lastMovementTime = Date()   // prevent a phantom stop on the first ticks after resuming
        locationManager.startUpdatingLocation()
        startTimer()
        writeSnapshot()
    }

    func stop() {
        autoPausedForInactivity = false
        ActiveWalkSnapshotStore.clear()
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

    private func writeSnapshot() {
        // Thin the breadcrumb trail so very long walks keep the checkpoint
        // file small — cap ~2000 points, evenly strided.
        let thinned = Self.thinned(trackPoints)

        let snapshot = ActiveWalkSnapshot(
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
            trackPoints: thinned.map { WaypointCoord($0) }
        )
        ActiveWalkSnapshotStore.save(snapshot)
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
        route.isLoop
            ? "Lap \(min(currentLap, route.lapCount)) of \(route.lapCount)"
            : "Heading to destination"
    }

    var remainingDistance: Double {
        max(0, route.totalDistance - totalDistanceCovered)
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

    var completedSession: WalkSession {
        WalkSession(
            id: UUID(),
            routeName: route.name,
            date: startTime,
            elapsedTime: elapsedTime,
            totalDistance: totalDistanceCovered,
            waypoints: route.waypoints.isEmpty
                ? trackPoints.map { WaypointCoord($0) }
                : route.waypoints.map { WaypointCoord($0) },
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
            guard let self else { return }
            self.elapsedTime = Date().timeIntervalSince(self.startTime) - self.pausedDuration
            if let last = self.lastLocation {
                let delta = loc.distance(from: last)
                if delta < 100 { self.totalDistanceCovered += delta }
            }
            self.lastLocation = loc
            self.trackPoints.append(loc.coordinate)
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
            // isPaused: false is intentional — didUpdateLocations only fires while
            // location updates are flowing; pause() stops them, so we can't arrive
            // here while actually paused.
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

    private func checkDistanceCheckpoints() {
        guard route.totalDistance > 0, onCheckpointReached != nil else { return }
        for (i, fraction) in checkpointFractions.enumerated() {
            guard !triggeredCheckpoints.contains(i) else { continue }
            if totalDistanceCovered >= route.totalDistance * fraction {
                triggeredCheckpoints.insert(i)
                let label = "\(Int(fraction * 100))%"
                splitTimes.append((label: label, elapsed: elapsedTime))
                onCheckpointReached?(label)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func checkArrival(at location: CLLocation) {
        guard let next = nextWaypoint else { return }
        let dist = location.distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
        distanceToNextWaypoint = dist
        guard dist < arrivalRadius else { return }
        advanceWaypoint()
    }

    private func advanceWaypoint() {
        let arrivedIndex = currentWaypointIndex
        currentWaypointIndex += 1
        if route.isCustomRoute, onCheckpointReached != nil {
            let wpNum = min(currentWaypointIndex, route.waypoints.count)
            let label = "WP \(wpNum)/\(route.waypoints.count)"
            splitTimes.append((label: label, elapsed: elapsedTime))
            onCheckpointReached?(label)
        }
        if route.isLoop {
            if currentWaypointIndex >= route.waypoints.count {
                currentWaypointIndex = 0
            } else if currentWaypointIndex == 1 {
                currentLap += 1
                if currentLap > route.lapCount {
                    finish()
                } else {
                    let lapsLeft = route.lapCount - (currentLap - 1)
                    fireBackgroundNotification(
                        title: "Lap \(currentLap - 1) of \(route.lapCount) complete 🔄",
                        body: lapsLeft == 1 ? "Last lap — finish strong!" : "\(lapsLeft) laps to go"
                    )
                }
            }
        } else if currentWaypointIndex >= route.waypoints.count {
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

    private func finish() {
        isCompleted = true
        stop()
        fireBackgroundNotification(title: "Walk complete! 🎉", body: "Great work on \(route.name)")
        WalkAudioCueService.shared.announce("Walk complete! Great job on \(route.name).")
    }

    private func postAutoPauseNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Session paused"
        content.body = "You've been stopped for a while, so we paused your session to keep your stats honest. Resume anytime."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "autoPause", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func fireBackgroundNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "nav-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )
        Task { try? await UNUserNotificationCenter.current().add(req) }
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
    let computedLegs: [MKRoute]
    let currentWaypointIndex: Int
    let checkpointsEnabled: Bool
    var distanceCoveredMeters: Double = 0

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.userTrackingMode = .follow
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
                if let coord = Self.coordAlong(poly, fraction: fraction) {
                    map.addAnnotation(MilestoneAnnotation(coordinate: coord, distanceMeters: targetMeters))
                }
            }
            context.coordinator.lastMilestoneKm = milestoneKm
        }
    }

    static func addCheckpointMarkers(on map: MKMapView, legs: [MKRoute]) {
        var allCoords: [CLLocationCoordinate2D] = []
        for leg in legs {
            let pts = leg.polyline.points()
            for i in 0..<leg.polyline.pointCount { allCoords.append(pts[i].coordinate) }
        }
        guard allCoords.count > 1 else { return }
        var combined = allCoords
        let poly = MKPolyline(coordinates: &combined, count: combined.count)
        for fraction in [0.2, 0.4, 0.6, 0.8] {
            if let c = coordAlong(poly, fraction: fraction) {
                map.addOverlay(NavCheckpointCircle(center: c, radius: 18), level: .aboveRoads)
            }
        }
        guard let lastCoord = allCoords.last else { return }
        let finish = NavCheckpointCircle(center: lastCoord, radius: 24)
        finish.isFinish = true
        map.addOverlay(finish, level: .aboveRoads)
    }

    static func coordAlong(_ polyline: MKPolyline, fraction: Double) -> CLLocationCoordinate2D? {
        let n = polyline.pointCount
        // An empty polyline has no point 0 to fall back on, and points()[0] is an
        // unchecked C-array read — it traps the process rather than returning nil.
        // MKDirections can hand back a degenerate route (no walkable path, a bad
        // fix, poor connectivity), so this is reachable in ordinary use.
        guard n > 0 else { return nil }
        guard n > 1, fraction > 0 else { return polyline.points()[0].coordinate }
        if fraction >= 1 { return polyline.points()[n - 1].coordinate }
        let pts = polyline.points()
        var total = 0.0
        var lens = [Double]()
        for i in 0..<n - 1 {
            let a = CLLocation(latitude: pts[i].coordinate.latitude, longitude: pts[i].coordinate.longitude)
            let b = CLLocation(latitude: pts[i + 1].coordinate.latitude, longitude: pts[i + 1].coordinate.longitude)
            let seg = a.distance(from: b)
            lens.append(seg); total += seg
        }
        let target = total * fraction
        var accum = 0.0
        for i in 0..<lens.count {
            guard lens[i] > 0 else { accum += lens[i]; continue }
            if accum + lens[i] >= target {
                let t = (target - accum) / lens[i]
                let a = pts[i].coordinate, b = pts[i + 1].coordinate
                return CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t
                )
            }
            accum += lens[i]
        }
        return pts[n - 1].coordinate
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

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
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
