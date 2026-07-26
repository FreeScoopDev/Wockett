import SwiftUI
import Combine
import HealthKit
import CoreMotion
import MapKit
import CoreLocation

// MARK: - Calendar Day Model

struct CalendarDay: Identifiable {
    let id: Date
    let date: Date
    let weekday: Int
    let goal: Int
    let steps: Int?
    let tag: String?
    let tagEmoji: String?
    let tagColor: Color?

    var isToday: Bool  { Calendar.current.isDateInToday(date) }
    var isFuture: Bool { date > Calendar.current.startOfDay(for: Date()) && !isToday }
    var progress: Double {
        guard let s = steps else { return 0 }
        return min(1.0, Double(s) / Double(max(1, goal)))
    }
    var goalMet: Bool? {
        guard let s = steps, !isFuture else { return nil }
        return s >= goal
    }
}

// MARK: - Activity Tag Config

struct ActivityTagConfig: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var emoji: String
    var colorIndex: Int

    static let palette: [Color] = [
        Color(red: 0.40, green: 0.60, blue: 0.90),  // blue
        Color(red: 0.35, green: 0.65, blue: 0.45),  // green
        Color(red: 0.90, green: 0.45, blue: 0.20),  // orange
        Color(red: 0.62, green: 0.45, blue: 0.30),  // brown
        Color(red: 0.85, green: 0.30, blue: 0.30),  // red
        Color(red: 0.55, green: 0.35, blue: 0.80),  // purple
    ]

    var color: Color { Self.palette[colorIndex % Self.palette.count] }

    static let defaults: [ActivityTagConfig] = [
        ActivityTagConfig(id: "Rest",   name: "Rest",   emoji: "🛋️",  colorIndex: 0),
        ActivityTagConfig(id: "Walk",   name: "Walk",   emoji: "🚶",  colorIndex: 1),
        ActivityTagConfig(id: "Run",    name: "Run",    emoji: "🏃",  colorIndex: 2),
        ActivityTagConfig(id: "Hike",   name: "Hike",   emoji: "⛰️", colorIndex: 3),
        ActivityTagConfig(id: "Cardio", name: "Cardio", emoji: "❤️‍🔥", colorIndex: 4),
        ActivityTagConfig(id: "Bike",   name: "Bike",   emoji: "🚴", colorIndex: 5),
    ]
}

// MARK: - Step Manager

@MainActor
final class StepManager: ObservableObject {
    @Published var todaySteps: Int = 0
    @Published var trackingMode: TrackingMode = .healthKit
    @Published var isLoading = false
    @Published var permissionDenied = false

    @Published var dailyGoal: Int = 10_000 {
        didSet {
            UserDefaults.standard.set(dailyGoal, forKey: UDKey.dailyGoal)
            // Nil out unlocked weekday overrides so they inherit the new goal
            for wd in 1...7 where !lockedWeekdays.contains(wd) {
                weekdayGoals[wd] = nil
            }
        }
    }
    @Published var useCustomSchedule: Bool = false {
        didSet { UserDefaults.standard.set(useCustomSchedule, forKey: UDKey.useCustomSchedule) }
    }
    @Published var weekdayGoals: [Int: Int] = [:] {
        didSet { saveWeekdayGoals() }
    }
    @Published var lockedWeekdays: Set<Int> = [] {
        didSet { saveLockedWeekdays() }
    }
    @Published var weekdayTags: [Int: String] = [:] {
        didSet { saveWeekdayTags() }
    }
    @Published var tagConfigs: [ActivityTagConfig] = ActivityTagConfig.defaults {
        didSet { saveTagConfigs() }
    }
    @Published var historicalDayGoals: [String: Int] = [:] {
        didSet { saveHistoricalDayGoals() }
    }
    @Published var weeklyCalendar: [CalendarDay] = []

    enum TrackingMode: String, CaseIterable, Identifiable {
        case healthKit = "Apple Health"
        case appOnly   = "App Only"
        var id: String { rawValue }
    }

    private enum UDKey {
        static let dailyGoal          = "stepDailyGoal"
        static let useCustomSchedule  = "stepUseCustomSchedule"
        static let weekdayGoals       = "stepWeekdayGoals"
        static let lockedWeekdays     = "stepLockedWeekdays"
        static let weekdayTags        = "stepWeekdayTags"
        static let tagConfigs         = "stepTagConfigs"
        static let historicalDayGoals = "stepHistoricalDayGoals"
    }

    private let healthStore = HKHealthStore()
    private let pedometer   = CMPedometer()

    var currentGoal: Int {
        if useCustomSchedule {
            let wd = Calendar.current.component(.weekday, from: Date())
            return weekdayGoals[wd] ?? dailyGoal
        }
        return dailyGoal
    }

    var remainingSteps:  Int    { max(0, currentGoal - todaySteps) }
    var remainingMeters: Double { Double(remainingSteps) * 0.762 }
    var progress:        Double { min(1.0, Double(todaySteps) / Double(max(1, currentGoal))) }

    /// Tracking "day" starts at 3 AM local time (not midnight).
    var dayStart: Date {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day], from: Date())
        c.hour = 3; c.minute = 0; c.second = 0
        guard let t = cal.date(from: c) else { return cal.startOfDay(for: Date()) }
        return Date() < t ? t.addingTimeInterval(-86400) : t
    }

    init() { loadPersistedValues() }

    func initialize() async {
        switch trackingMode {
        case .healthKit: await authorizeAndFetchHealthKit()
        case .appOnly:   startPedometer()
        }
    }

    func switchTrackingMode(to mode: TrackingMode) {
        pedometer.stopUpdates()
        trackingMode = mode
        Task { await initialize() }
    }

    func refresh() async {
        if trackingMode == .healthKit { await fetchHealthKitSteps() }
    }

    // MARK: - Weekly Calendar

    func refreshWeeklyCalendar(sessions: [WalkSession], weekOffset: Int = 0) async {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())

        // The 7-day window: weekOffset=0 → -3…+3, weekOffset=-1 → -10…-4, etc.
        let base  = weekOffset * 7
        let range = (base - 3)...(base + 3)

        // Fetch HealthKit counts for any past portion of the window
        let hkCounts: [Date: Int]
        if trackingMode == .healthKit, range.lowerBound < 0 {
            let qStart = cal.date(byAdding: .day, value: range.lowerBound, to: today)!
            // +1 so qEnd is the start of the day AFTER the last wanted day,
            // ensuring enumerateStatistics includes yesterday's bucket (weekOffset=0).
            let qEnd   = cal.date(byAdding: .day, value: min(range.upperBound + 1, 0), to: today)
                         ?? today
            hkCounts = await fetchWeeklyStepCounts(from: qStart, to: qEnd)
        } else {
            hkCounts = [:]
        }

        var days: [CalendarDay] = []
        for offset in range {
            guard let date = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let wd = cal.component(.weekday, from: date)

            // Past days use frozen historical goal; today/future always track current settings
            let computed = (useCustomSchedule ? weekdayGoals[wd] : nil) ?? dailyGoal
            let goal: Int
            if offset < 0 {
                let key = dayKey(date)
                if let stored = historicalDayGoals[key] {
                    goal = stored
                } else {
                    historicalDayGoals[key] = computed
                    goal = computed
                }
            } else {
                goal = computed
            }

            let steps: Int?
            if offset > 0 {
                steps = nil
            } else if offset == 0 {
                steps = weekOffset == 0 ? todaySteps : nil
            } else if trackingMode == .healthKit {
                steps = hkCounts[date]
            } else {
                steps = sessions
                    .filter { cal.isDate($0.date, inSameDayAs: date) }
                    .reduce(0) { $0 + $1.estimatedSteps }
            }

            let tag       = weekdayTags[wd]
            let tagConfig = tag.flatMap { id in tagConfigs.first { $0.id == id } }
            days.append(CalendarDay(
                id: date, date: date, weekday: wd, goal: goal, steps: steps,
                tag: tag, tagEmoji: tagConfig?.emoji, tagColor: tagConfig?.color
            ))
        }
        weeklyCalendar = days
    }

    private func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale     = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    func fetchStepCounts(from startDate: Date, to endDate: Date) async -> [Date: Int] {
        return await fetchWeeklyStepCounts(from: startDate, to: endDate)
    }

    private func fetchWeeklyStepCounts(from startDate: Date, to endDate: Date) async -> [Date: Int] {
        guard HKHealthStore.isHealthDataAvailable() else { return [:] }
        let cal       = Calendar.current
        let stepType  = HKQuantityType(.stepCount)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate)

        return await withCheckedContinuation { cont in
            let q = HKStatisticsCollectionQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: startDate,
                intervalComponents: DateComponents(day: 1)
            )
            q.initialResultsHandler = { _, results, _ in
                var counts: [Date: Int] = [:]
                results?.enumerateStatistics(from: startDate, to: endDate) { stats, _ in
                    let steps = stats.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    counts[cal.startOfDay(for: stats.startDate)] = Int(steps)
                }
                cont.resume(returning: counts)
            }
            healthStore.execute(q)
        }
    }

    // MARK: - HealthKit

    private func authorizeAndFetchHealthKit() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let stepType = HKQuantityType(.stepCount)
        // Write types: workout records, distance samples, calories.
        // These are requested here so a single system prompt covers all HealthKit access.
        let typesToShare: Set<HKSampleType> = [
            .workoutType(),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.activeEnergyBurned)
        ]
        do {
            try await healthStore.requestAuthorization(toShare: typesToShare, read: [stepType])
            permissionDenied = false
            await fetchHealthKitSteps()
            observeHealthKit()
        } catch {
            permissionDenied = true
        }
    }

    private func fetchHealthKitSteps() async {
        let stepType  = HKQuantityType(.stepCount)
        let predicate = HKQuery.predicateForSamples(withStart: dayStart, end: Date())
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { [weak self] _, result, _ in
                let steps = result?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                Task { @MainActor [weak self] in self?.todaySteps = Int(steps) }
                cont.resume()
            }
            healthStore.execute(q)
        }
    }

    private func observeHealthKit() {
        let stepType = HKQuantityType(.stepCount)
        let q = HKObserverQuery(sampleType: stepType, predicate: nil) { [weak self] _, _, _ in
            Task { [weak self] in await self?.fetchHealthKitSteps() }
        }
        healthStore.execute(q)
    }

    // MARK: - Core Motion

    private func startPedometer() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometer.startUpdates(from: dayStart) { [weak self] data, error in
            guard let data, error == nil else { return }
            Task { @MainActor [weak self] in self?.todaySteps = data.numberOfSteps.intValue }
        }
    }

    // MARK: - Persistence

    private func loadPersistedValues() {
        let d = UserDefaults.standard
        // Load lockedWeekdays first so dailyGoal.didSet respects locks when it fires
        if let raw = d.array(forKey: UDKey.lockedWeekdays) as? [Int] {
            lockedWeekdays = Set(raw)
        }
        if let raw = d.dictionary(forKey: UDKey.weekdayTags) as? [String: String] {
            weekdayTags = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
        }
        if let data = d.data(forKey: UDKey.tagConfigs),
           let configs = try? JSONDecoder().decode([ActivityTagConfig].self, from: data) {
            tagConfigs = configs
        }
        if let raw = d.dictionary(forKey: UDKey.historicalDayGoals) as? [String: Int] {
            historicalDayGoals = raw
        }
        if d.object(forKey: UDKey.dailyGoal) != nil { dailyGoal = d.integer(forKey: UDKey.dailyGoal) }
        useCustomSchedule = d.bool(forKey: UDKey.useCustomSchedule)
        if let raw = d.dictionary(forKey: UDKey.weekdayGoals) as? [String: Int] {
            weekdayGoals = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
        }
    }

    private func saveWeekdayGoals() {
        let raw = Dictionary(uniqueKeysWithValues: weekdayGoals.map { ("\($0.key)", $0.value) })
        UserDefaults.standard.set(raw, forKey: UDKey.weekdayGoals)
    }

    private func saveLockedWeekdays() {
        UserDefaults.standard.set(Array(lockedWeekdays), forKey: UDKey.lockedWeekdays)
    }

    private func saveWeekdayTags() {
        let raw = Dictionary(uniqueKeysWithValues: weekdayTags.map { ("\($0.key)", $0.value) })
        UserDefaults.standard.set(raw, forKey: UDKey.weekdayTags)
    }

    private func saveTagConfigs() {
        if let data = try? JSONEncoder().encode(tagConfigs) {
            UserDefaults.standard.set(data, forKey: UDKey.tagConfigs)
        }
    }

    private func saveHistoricalDayGoals() {
        UserDefaults.standard.set(historicalDayGoals, forKey: UDKey.historicalDayGoals)
    }
}

// MARK: - Route Manager

@MainActor
final class RouteManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var suggestedRoutes: [SuggestedRoute] = []
    @Published var isGenerating   = false
    @Published var locationError: String?
    @Published var authStatus: CLAuthorizationStatus = .notDetermined
    @Published var lastLocation: CLLocation?

    private let locationManager = CLLocationManager()
    nonisolated(unsafe) private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authStatus = locationManager.authorizationStatus
    }

    // MARK: - Public

    func generateRoutes(remainingMeters: Double, radius: Double,
                        transportType: MKDirectionsTransportType = .walking) async {
        isGenerating    = true
        locationError   = nil
        suggestedRoutes = []
        defer { isGenerating = false }

        guard let location = await currentLocation() else {
            locationError = "Unable to get your location. Check that location permission is granted."
            return
        }
        lastLocation = location

        // Apply +12% buffer so routes slightly exceed the remaining goal.
        let targetMeters = remainingMeters * 1.12

        var routes = await generateLoopRoutes(from: location, targetMeters: targetMeters,
                                              radius: radius, transportType: transportType)

        // If Nearby radius found nothing routable, silently bump to Close.
        if routes.isEmpty && radius <= 200 {
            routes = await generateLoopRoutes(from: location, targetMeters: targetMeters,
                                              radius: 500, transportType: transportType)
        }
        // Guaranteed fallback so results are never empty.
        if routes.isEmpty, let fallback = await makeFallbackRoute(from: location,
                                                                   targetMeters: targetMeters,
                                                                   transportType: transportType) {
            routes.append(fallback)
        }

        suggestedRoutes = routes.enumerated().map { i, r in
            var r = r; r.colorIndex = i; return r
        }
    }

    func generateDestinationRoute(to destination: MKMapItem,
                                   transportType: MKDirectionsTransportType = .walking) async {
        isGenerating    = true
        locationError   = nil
        suggestedRoutes = []
        defer { isGenerating = false }

        guard let location = await currentLocation() else {
            locationError = "Unable to get your location. Check that location permission is granted."
            return
        }
        lastLocation = location

        let req = MKDirections.Request()
        req.source        = MKMapItem(location: location, address: nil)
        req.destination   = destination
        req.transportType = transportType

        guard let route = try? await MKDirections(request: req).calculate().routes.first else {
            locationError = "No route found to \(destination.name ?? "that destination")."
            return
        }

        let destCoord = destination.location.coordinate
        suggestedRoutes = [SuggestedRoute(
            polyline:       route.polyline,
            openInMapsItem: destination,
            isLoop:         false,
            bearing:        location.coordinate.bearing(to: destCoord),
            totalDistance:  route.distance,
            totalTime:      route.expectedTravelTime,
            lapCount:       1,
            label:          destination.name,
            legWaypoints:   [location.coordinate, destCoord]
        )]
    }

    func generateLoopDestinationRoute(to destination: MKMapItem,
                                       transportType: MKDirectionsTransportType = .walking) async {
        isGenerating    = true
        locationError   = nil
        suggestedRoutes = []
        defer { isGenerating = false }

        guard let location = await currentLocation() else {
            locationError = "Unable to get your location. Check that location permission is granted."
            return
        }
        lastLocation = location

        let userItem  = MKMapItem(location: location, address: nil)
        let destCoord = destination.location.coordinate

        let outReq = MKDirections.Request()
        outReq.source        = userItem
        outReq.destination   = destination
        outReq.transportType = transportType

        let backReq = MKDirections.Request()
        backReq.source        = destination
        backReq.destination   = userItem
        backReq.transportType = transportType

        guard let outbound = try? await MKDirections(request: outReq).calculate().routes.first,
              let inbound  = try? await MKDirections(request: backReq).calculate().routes.first else {
            locationError = "No route found to \(destination.name ?? "that destination")."
            return
        }

        suggestedRoutes = [SuggestedRoute(
            polyline:       combinePolylines([outbound.polyline, inbound.polyline]),
            openInMapsItem: destination,
            isLoop:         true,
            bearing:        location.coordinate.bearing(to: destCoord),
            totalDistance:  outbound.distance + inbound.distance,
            totalTime:      outbound.expectedTravelTime + inbound.expectedTravelTime,
            lapCount:       1,
            label:          "\(destination.name ?? "Destination") & Back",
            legWaypoints:   [location.coordinate, destCoord]
        )]
    }

    func fetchCurrentLocation() async -> CLLocation? {
        await currentLocation()
    }

    // MARK: - Loop Routes

    private func generateLoopRoutes(from start: CLLocation, targetMeters: Double,
                                     radius: Double, transportType: MKDirectionsTransportType) async -> [SuggestedRoute] {
        var routes: [SuggestedRoute] = []
        // All 8 compass orientations — N/NE/E/SE/S/SW/W/NW
        await withTaskGroup(of: SuggestedRoute?.self) { group in
            for bearing in [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0] {
                group.addTask {
                    await self.makeLoopRoute(from: start, bearing: bearing,
                                            targetMeters: targetMeters, radius: radius,
                                            transportType: transportType)
                }
            }
            for await result in group {
                if let r = result { routes.append(r) }
            }
        }
        routes.sort { $0.bearing < $1.bearing }
        return routes
    }

    /// Quadrilateral loop: Start → A → B → C → Start, each leg at 90° to the previous.
    /// This "around the block" geometry avoids the backtracking that triangular routes produce on street grids.
    /// Waypoints sit at `radius × 0.65` so the diagonal corner stays within the chosen radius.
    private func makeLoopRoute(from start: CLLocation,
                               bearing: Double,
                               targetMeters: Double,
                               radius: Double,
                               transportType: MKDirectionsTransportType) async -> SuggestedRoute? {
        let legDist = radius * 0.65
        let coordA  = start.coordinate.offset(bearing: bearing,       meters: legDist)
        let coordB  = coordA.offset(          bearing: bearing + 90,  meters: legDist)
        let coordC  = coordB.offset(          bearing: bearing + 180, meters: legDist)

        guard let leg1 = await route(from: start.coordinate, to: coordA, transportType: transportType),
              let leg2 = await route(from: coordA,            to: coordB, transportType: transportType),
              let leg3 = await route(from: coordB,            to: coordC, transportType: transportType),
              let leg4 = await route(from: coordC,            to: start.coordinate, transportType: transportType) else { return nil }

        let perLapDist = leg1.distance + leg2.distance + leg3.distance + leg4.distance
        let perLapTime = leg1.expectedTravelTime + leg2.expectedTravelTime + leg3.expectedTravelTime + leg4.expectedTravelTime
        let laps       = max(1, min(8, Int(ceil(targetMeters / max(perLapDist, 1)))))

        let elevCoords = [start.coordinate, coordA, coordB, coordC, start.coordinate]
        let profile    = try? await ElevationService.shared.fetchProfile(for: elevCoords)

        return SuggestedRoute(
            polyline:            combinePolylines([leg1.polyline, leg2.polyline, leg3.polyline, leg4.polyline]),
            openInMapsItem:      MKMapItem(location: coordA.clLocation, address: nil),
            isLoop:              true,
            bearing:             bearing,
            totalDistance:       perLapDist * Double(laps),
            totalTime:           perLapTime * Double(laps),
            lapCount:            laps,
            label:               nil,
            legWaypoints:        [start.coordinate, coordA, coordB, coordC],
            elevationGainMeters: (profile?.totalGainMeters ?? 0) * Double(laps),
            elevationLossMeters: (profile?.totalLossMeters ?? 0) * Double(laps)
        )
    }

    // MARK: - Fallback

    private func makeFallbackRoute(from start: CLLocation, targetMeters: Double,
                                    transportType: MKDirectionsTransportType) async -> SuggestedRoute? {
        let legDist = 120.0
        let coordA  = start.coordinate.offset(bearing: 0,   meters: legDist)
        let coordB  = coordA.offset(          bearing: 90,  meters: legDist)
        let coordC  = coordB.offset(          bearing: 180, meters: legDist)

        guard let leg1 = await route(from: start.coordinate, to: coordA, transportType: transportType),
              let leg2 = await route(from: coordA,            to: coordB, transportType: transportType),
              let leg3 = await route(from: coordB,            to: coordC, transportType: transportType),
              let leg4 = await route(from: coordC,            to: start.coordinate, transportType: transportType) else { return nil }

        let perLapDist = leg1.distance + leg2.distance + leg3.distance + leg4.distance
        let perLapTime = leg1.expectedTravelTime + leg2.expectedTravelTime + leg3.expectedTravelTime + leg4.expectedTravelTime
        let laps       = max(1, min(8, Int(ceil(targetMeters / max(perLapDist, 1)))))

        return SuggestedRoute(
            polyline:       combinePolylines([leg1.polyline, leg2.polyline, leg3.polyline, leg4.polyline]),
            openInMapsItem: MKMapItem(location: coordA.clLocation, address: nil),
            isLoop:         true,
            bearing:        0,
            totalDistance:  perLapDist * Double(laps),
            totalTime:      perLapTime * Double(laps),
            lapCount:       laps,
            label:          "Neighbourhood Loop",
            legWaypoints:   [start.coordinate, coordA, coordB, coordC]
        )
    }

    // MARK: - Helpers

    private func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                       transportType: MKDirectionsTransportType) async -> MKRoute? {
        let req = MKDirections.Request()
        req.source        = MKMapItem(location: from.clLocation, address: nil)
        req.destination   = MKMapItem(location: to.clLocation,   address: nil)
        req.transportType = transportType
        return try? await MKDirections(request: req).calculate().routes.first
    }

    private func combinePolylines(_ polylines: [MKPolyline]) -> MKPolyline {
        var coords: [CLLocationCoordinate2D] = []
        for pl in polylines {
            let pts = pl.points()
            for i in 0..<pl.pointCount { coords.append(pts[i].coordinate) }
        }
        return MKPolyline(coordinates: &coords, count: coords.count)
    }

    // MARK: - Location

    private func currentLocation() async -> CLLocation? {
        if authStatus == .notDetermined { locationManager.requestWhenInUseAuthorization() }
        guard authStatus == .authorizedWhenInUse || authStatus == .authorizedAlways else { return nil }
        if let cached = locationManager.location, -cached.timestamp.timeIntervalSinceNow < 300 { return cached }
        return await withCheckedContinuation { cont in
            locationContinuation = cont
            locationManager.requestLocation()
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        Task { @MainActor in
            locationContinuation?.resume(returning: loc)
            locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            locationContinuation?.resume(returning: nil)
            locationContinuation = nil
            locationError = "Location error: \(error.localizedDescription)"
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in authStatus = manager.authorizationStatus }
    }
}

// MARK: - Walk Intent

enum WalkIntent: Equatable {
    case finishGoal
    case quickWalk(minutes: Int)

    static let quickOptions: [Int] = [20, 30, 45]

    var label: String {
        switch self {
        case .finishGoal:          return "Finish Goal"
        case .quickWalk(let mins): return "\(mins) min"
        }
    }

    var targetMeters: Double {
        switch self {
        case .finishGoal:          return 0  // caller supplies remainingMeters
        case .quickWalk(let mins): return Double(mins) * 80
        }
    }
}

// MARK: - Activity Mode

enum ActivityMode: String {
    case walking, cycling

    var icon:            String                    { self == .cycling ? "figure.cycling" : "figure.walk" }
    var sessionLabel:    String                    { self == .cycling ? "Ride" : "Walk" }
    var transportType:   MKDirectionsTransportType { self == .cycling ? .cycling : .walking }
    var hkActivityType:  HKWorkoutActivityType     { self == .cycling ? .cycling : .walking }
}

// MARK: - Suggested Route Model

struct SuggestedRoute: Identifiable {
    let id            = UUID()
    let polyline:      MKPolyline
    let openInMapsItem: MKMapItem
    let isLoop:        Bool
    let bearing:       Double
    let totalDistance: Double
    let totalTime:     TimeInterval
    let lapCount:      Int      // 1 for single-circuit routes; >1 means repeat N times
    let label:         String?  // custom name (fallback only); nil shows direction-based name
    let legWaypoints:  [CLLocationCoordinate2D]
    var elevationGainMeters: Double = 0
    var elevationLossMeters: Double = 0
    var colorIndex: Int = 0     // position in result list; drives unique hue per route

    var elevationSummary: String? {
        guard elevationGainMeters > 0 || elevationLossMeters > 0 else { return nil }
        let fmt = MKDistanceFormatter(); fmt.unitStyle = .abbreviated
        return "↑ \(fmt.string(fromDistance: elevationGainMeters)) · ↓ \(fmt.string(fromDistance: elevationLossMeters))"
    }

    static func paletteColor(index: Int, total: Int) -> Color {
        let hue = total > 1 ? Double(index) / Double(total) : 0.55
        return Color(hue: hue, saturation: 0.72, brightness: 0.78)
    }

    static func paletteUIColor(index: Int, total: Int) -> UIColor {
        let hue = total > 1 ? CGFloat(index) / CGFloat(total) : 0.55
        return UIColor(hue: hue, saturation: 0.72, brightness: 0.78, alpha: 1)
    }

    var estimatedSteps: Int    { Int(totalDistance / 0.762) }
    var perLapDistance: Double { totalDistance / Double(lapCount) }

    var directionName: String {
        switch bearing.truncatingRemainder(dividingBy: 360) {
        case 0..<22.5, 337.5...360: return "North"
        case 22.5..<67.5:           return "Northeast"
        case 67.5..<112.5:          return "East"
        case 112.5..<157.5:         return "Southeast"
        case 157.5..<202.5:         return "South"
        case 202.5..<247.5:         return "Southwest"
        case 247.5..<292.5:         return "West"
        default:                    return "Northwest"
        }
    }

    var distanceText: String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        if lapCount > 1 { return "\(f.string(fromDistance: perLapDistance)) × \(lapCount)" }
        return f.string(fromDistance: totalDistance)
    }

    var timeText: String {
        let mins = Int(totalTime / 60)
        return mins < 60 ? "\(mins) min" : "\(mins / 60)h \(mins % 60)m"
    }

    func openInAppleMaps(activityMode: ActivityMode = .walking) {
        let mode = activityMode == .cycling
            ? MKLaunchOptionsDirectionsModeCycling
            : MKLaunchOptionsDirectionsModeWalking
        openInMapsItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode])
    }

    func toNavigableRoute(activityMode: ActivityMode = .walking) -> NavigableRoute {
        NavigableRoute(
            name:          label ?? "\(directionName) \(isLoop ? "Loop" : "Route")",
            waypoints:     legWaypoints,
            lapCount:      lapCount,
            isLoop:        isLoop,
            totalDistance: totalDistance,
            activityMode:  activityMode
        )
    }

    func toCustomRoute(name: String? = nil) -> CustomRoute {
        CustomRoute(
            id: UUID(),
            name: name ?? (label ?? "\(directionName) \(isLoop ? "Loop" : "Route")"),
            waypoints: legWaypoints.map { WaypointCoord($0) },
            totalDistance: totalDistance,
            isLoop: isLoop,
            createdAt: Date()
        )
    }
}

// MARK: - Comparable clamped helper

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - CLLocationCoordinate2D extensions

extension CLLocationCoordinate2D {
    var clLocation: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    func offset(bearing degrees: Double, meters: Double) -> CLLocationCoordinate2D {
        let R    = 6_371_000.0
        let lat1 = latitude  * .pi / 180
        let lon1 = longitude * .pi / 180
        let brng = degrees   * .pi / 180
        let d    = meters / R

        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(brng))
        let lon2 = lon1 + atan2(sin(brng) * sin(d) * cos(lat1),
                                cos(d) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    func bearing(to other: CLLocationCoordinate2D) -> Double {
        let lat1 = latitude        * .pi / 180
        let lat2 = other.latitude  * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let y    = sin(dLon) * cos(lat2)
        let x    = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}
