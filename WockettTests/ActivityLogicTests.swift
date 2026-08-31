import Testing
import CoreLocation
@testable import PoCSquat

struct ActivityLogicTests {

    // MARK: - Helpers

    private func session(
        distance: Double,
        elapsed: TimeInterval,
        activityType: String = "walking"
    ) -> WalkSession {
        WalkSession(
            id: UUID(), routeName: "Test", date: Date(),
            elapsedTime: elapsed, totalDistance: distance,
            waypoints: [], lapCount: 1, isLoop: false,
            activityType: activityType
        )
    }

    // MARK: - ActivityMode vocabulary

    @Test func activityMode_vocabulary_walking() {
        #expect(ActivityMode.walking.noun == "walk")
        #expect(ActivityMode.walking.gerund == "walking")
    }

    @Test func activityMode_vocabulary_running() {
        #expect(ActivityMode.running.noun == "run")
        #expect(ActivityMode.running.gerund == "running")
    }

    @Test func activityMode_vocabulary_cycling() {
        #expect(ActivityMode.cycling.noun == "ride")
        #expect(ActivityMode.cycling.gerund == "riding")
    }

    // stationary has no own case in noun/gerund — falls through to default ("walk"/"walking")
    @Test func activityMode_vocabulary_stationaryDefaultsToWalk() {
        #expect(ActivityMode.stationary.noun == "walk")
        #expect(ActivityMode.stationary.gerund == "walking")
    }

    // MARK: - paceOrSpeedText — walking

    // 1 km / 10 min (600 s) → 600 s/km → "10:00/km"
    @Test func paceOrSpeedText_walkingMetric() {
        let s = session(distance: 1000, elapsed: 600)
        #expect(s.paceOrSpeedText(metric: true) == "10:00/km")
    }

    // 1 mi (1609.34 m) / 10 min → 600 s/mi → "10:00/mi"
    @Test func paceOrSpeedText_walkingImperial() {
        let s = session(distance: 1609.34, elapsed: 600)
        #expect(s.paceOrSpeedText(metric: false) == "10:00/mi")
    }

    // MARK: - paceOrSpeedText — cycling

    // 10 km / 30 min (1800 s): speed = (10000/1800)*3.6 = 20.0 km/h
    @Test func paceOrSpeedText_cyclingMetric() {
        let s = session(distance: 10_000, elapsed: 1800, activityType: "cycling")
        #expect(s.paceOrSpeedText(metric: true) == "20.0 km/h")
    }

    // same session in imperial: 20 km/h / 1.609344 = 12.427… → "12.4 mph"
    @Test func paceOrSpeedText_cyclingImperial() {
        let s = session(distance: 10_000, elapsed: 1800, activityType: "cycling")
        #expect(s.paceOrSpeedText(metric: false) == "12.4 mph")
    }

    // MARK: - paceOrSpeedText — below threshold

    // 50 m distance is below the 100 m threshold → placeholder
    @Test func paceOrSpeedText_belowThresholdShowsPlaceholder() {
        let s = session(distance: 50, elapsed: 600)
        #expect(s.paceOrSpeedText(metric: true) == "—")
    }

    // MARK: - shouldAutoPause

    @Test func shouldAutoPause_falseWhenPromptNotShowing() {
        let shownAt = Date().addingTimeInterval(-400)
        #expect(NavigationSessionManager.shouldAutoPause(
            showBreakPrompt: false, isPaused: false,
            promptShownAt: shownAt, now: Date()
        ) == false)
    }

    @Test func shouldAutoPause_falseWhenAlreadyPaused() {
        let shownAt = Date().addingTimeInterval(-400)
        #expect(NavigationSessionManager.shouldAutoPause(
            showBreakPrompt: true, isPaused: true,
            promptShownAt: shownAt, now: Date()
        ) == false)
    }

    @Test func shouldAutoPause_falseAt299Seconds() {
        let now     = Date()
        let shownAt = now.addingTimeInterval(-299)
        #expect(NavigationSessionManager.shouldAutoPause(
            showBreakPrompt: true, isPaused: false,
            promptShownAt: shownAt, now: now
        ) == false)
    }

    @Test func shouldAutoPause_trueAt300Seconds() {
        let now     = Date()
        let shownAt = now.addingTimeInterval(-300)
        #expect(NavigationSessionManager.shouldAutoPause(
            showBreakPrompt: true, isPaused: false,
            promptShownAt: shownAt, now: now
        ) == true)
    }

    @Test func shouldAutoPause_falseWhenPromptShownAtIsNil() {
        #expect(NavigationSessionManager.shouldAutoPause(
            showBreakPrompt: true, isPaused: false,
            promptShownAt: nil, now: Date()
        ) == false)
    }

    // MARK: - thinned

    @Test func thinned_underCapUnchanged() {
        let coords = (0..<100).map { CLLocationCoordinate2D(latitude: Double($0) * 0.001, longitude: 0) }
        let result = NavigationSessionManager.thinned(coords)
        #expect(result.count == 100)
        #expect(result[0].latitude == coords[0].latitude)
        #expect(result[99].latitude == coords[99].latitude)
    }

    @Test func thinned_overCapHitsCapAndKeepsFirstAndNearlyLast() {
        // 5000 points; stride = 2.5; last picked index = Int(1999 * 2.5) = 4997
        let coords = (0..<5000).map { CLLocationCoordinate2D(latitude: Double($0) * 0.001, longitude: 0) }
        let result = NavigationSessionManager.thinned(coords)
        #expect(result.count == 2000)
        // First element is preserved exactly.
        #expect(result[0].latitude == coords[0].latitude)
        // Last thinned element should be within 3 original-point spacings of the true last.
        let lastResultLat  = result[result.count - 1].latitude
        let lastOriginalLat = coords[coords.count - 1].latitude
        #expect(abs(lastResultLat - lastOriginalLat) < 0.005)
    }
}
