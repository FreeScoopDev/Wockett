import SwiftUI
import Combine
import HealthKit
import CoreMotion
import MapKit
import CoreLocation
import EventKit
import CloudKit

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
            let qEnd   = cal.date(byAdding: .day, value: min(range.upperBound, -1), to: today)
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
        do {
            try await healthStore.requestAuthorization(toShare: [], read: [stepType])
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

    func generateRoutes(remainingMeters: Double, radius: Double) async {
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

        var routes = await generateLoopRoutes(from: location, targetMeters: targetMeters, radius: radius)

        // If Nearby radius found nothing walkable, silently bump to Close.
        if routes.isEmpty && radius <= 200 {
            routes = await generateLoopRoutes(from: location, targetMeters: targetMeters, radius: 500)
        }
        // Guaranteed fallback so results are never empty.
        if routes.isEmpty, let fallback = await makeFallbackRoute(from: location, targetMeters: targetMeters) {
            routes.append(fallback)
        }

        suggestedRoutes = routes.enumerated().map { i, r in
            var r = r; r.colorIndex = i; return r
        }
    }

    func generateDestinationRoute(to destination: MKMapItem) async {
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
        req.transportType = .walking

        guard let route = try? await MKDirections(request: req).calculate().routes.first else {
            locationError = "No walking route found to \(destination.name ?? "that destination")."
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

    func generateLoopDestinationRoute(to destination: MKMapItem) async {
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
        outReq.transportType = .walking

        let backReq = MKDirections.Request()
        backReq.source        = destination
        backReq.destination   = userItem
        backReq.transportType = .walking

        guard let outbound = try? await MKDirections(request: outReq).calculate().routes.first,
              let inbound  = try? await MKDirections(request: backReq).calculate().routes.first else {
            locationError = "No walking route found to \(destination.name ?? "that destination")."
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

    private func generateLoopRoutes(from start: CLLocation, targetMeters: Double, radius: Double) async -> [SuggestedRoute] {
        var routes: [SuggestedRoute] = []
        // All 8 compass orientations — N/NE/E/SE/S/SW/W/NW
        await withTaskGroup(of: SuggestedRoute?.self) { group in
            for bearing in [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0] {
                group.addTask {
                    await self.makeLoopRoute(from: start, bearing: bearing, targetMeters: targetMeters, radius: radius)
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
                               radius: Double) async -> SuggestedRoute? {
        let legDist = radius * 0.65
        let coordA  = start.coordinate.offset(bearing: bearing,       meters: legDist)
        let coordB  = coordA.offset(          bearing: bearing + 90,  meters: legDist)
        let coordC  = coordB.offset(          bearing: bearing + 180, meters: legDist)

        guard let leg1 = await walkingRoute(from: start.coordinate, to: coordA),
              let leg2 = await walkingRoute(from: coordA,            to: coordB),
              let leg3 = await walkingRoute(from: coordB,            to: coordC),
              let leg4 = await walkingRoute(from: coordC,            to: start.coordinate) else { return nil }

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

    private func makeFallbackRoute(from start: CLLocation, targetMeters: Double) async -> SuggestedRoute? {
        let legDist = 120.0
        let coordA  = start.coordinate.offset(bearing: 0,   meters: legDist)
        let coordB  = coordA.offset(          bearing: 90,  meters: legDist)
        let coordC  = coordB.offset(          bearing: 180, meters: legDist)

        guard let leg1 = await walkingRoute(from: start.coordinate, to: coordA),
              let leg2 = await walkingRoute(from: coordA,            to: coordB),
              let leg3 = await walkingRoute(from: coordB,            to: coordC),
              let leg4 = await walkingRoute(from: coordC,            to: start.coordinate) else { return nil }

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

    private func walkingRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> MKRoute? {
        let req = MKDirections.Request()
        req.source        = MKMapItem(location: from.clLocation, address: nil)
        req.destination   = MKMapItem(location: to.clLocation,   address: nil)
        req.transportType = .walking
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

    func openInAppleMaps() {
        openInMapsItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    func toNavigableRoute() -> NavigableRoute {
        NavigableRoute(
            name:          label ?? "\(directionName) \(isLoop ? "Loop" : "Route")",
            waypoints:     legWaypoints,
            lapCount:      lapCount,
            isLoop:        isLoop,
            totalDistance: totalDistance
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

// MARK: - Step Counter View

struct StepCounterView: View {
    @StateObject private var stepManager  = StepManager()
    @StateObject private var routeManager = RouteManager()
    @StateObject private var routeStore   = CustomRouteStore()
    @StateObject private var historyStore = WalkHistoryStore()

    @EnvironmentObject private var petStore: PetStore

    @State private var selectedRadius: Double = 1_000
    @State private var selectedRoute: SuggestedRoute?
    @State private var walkIntent: WalkIntent = .finishGoal
    @State private var showBadges               = false
    @State private var earnedBadge: WalkBadge?  = nil
    @State private var showGoalSheet            = false
    @State private var showMyRoutes             = false
    @State private var showDestinationSearch = false
    @State private var showNearbySheet       = false
    @State private var showBuildRoute        = false
    @State private var showWalkHistory       = false
    @State private var showPetManagement     = false
    @State private var navigatingRoute: NavigableRoute?
    @State private var routeWeather: RouteWeather?
    @State private var elevationProfile: ElevationProfile?
    @State private var isLoadingElevation = false
    @State private var shouldScrollToResults = false
    @State private var showUserDetail = false
    @State private var selectedPetForDetail: PetProfile?
    @State private var selectedCalendarDay: CalendarDay?
    @State private var containerWidth: CGFloat = 350
    @State private var calendarWeekOffset: Int = 0
    @State private var showSettings = false
    @State private var showMonthCalendar = false
    @State private var showFreeWalk = false
    @State private var communityRoutes: [SharedRoute] = []
    @State private var isLoadingCommunity = false
    @State private var showCommunityRoutes = false
    @State private var savedRouteIds: Set<UUID> = []
    @State private var savedCommunityIds: Set<String> = []
    @State private var routeForPosting: SuggestedRoute? = nil

    var body: some View {
        stepCounterCore
            .sheet(isPresented: $showUserDetail) {
                UserStepDetailSheet(stepManager: stepManager, historyStore: historyStore)
            }
            .sheet(item: $selectedCalendarDay) { day in
                DayDetailSheet(day: day, sessions: historyStore.sessions)
            }
            .sheet(isPresented: $showMonthCalendar) {
                MonthCalendarView(stepManager: stepManager, sessions: historyStore.sessions)
            }
            .sheet(item: $selectedPetForDetail) { pet in
                PetDetailSheet(pet: pet, petStore: petStore, historyStore: historyStore) {
                    selectedPetForDetail = pet
                }
            }
            .sheet(isPresented: $showGoalSheet) { GoalEditorSheet(stepManager: stepManager) }
            .sheet(item: $routeForPosting) { route in
                PostToCommunitySheet(route: route, routeStore: routeStore) {
                    savedRouteIds.insert(route.id)
                }
            }
            .fullScreenCover(isPresented: $showFreeWalk) {
                FreeWalkView(historyStore: historyStore, routeStore: routeStore)
            }
            .sheet(isPresented: $showDestinationSearch) {
                DestinationSearchSheet(userLocation: routeManager.lastLocation) { destination in
                    clearRoutes()
                    Task {
                        await routeManager.generateDestinationRoute(to: destination)
                        if let loc = routeManager.lastLocation, !routeManager.suggestedRoutes.isEmpty {
                            routeWeather = await RouteWeatherService.shared.fetchWeather(for: loc.coordinate)
                        }
                        if !routeManager.suggestedRoutes.isEmpty { shouldScrollToResults = true }
                    }
                }
            }
            .sheet(isPresented: $showNearbySheet) {
                NearbyPlacesSheet(fetchLocation: { await routeManager.fetchCurrentLocation() }) { destination, wantsLoop in
                    clearRoutes()
                    Task {
                        if wantsLoop {
                            await routeManager.generateLoopDestinationRoute(to: destination)
                        } else {
                            await routeManager.generateDestinationRoute(to: destination)
                        }
                        if let loc = routeManager.lastLocation, !routeManager.suggestedRoutes.isEmpty {
                            routeWeather = await RouteWeatherService.shared.fetchWeather(for: loc.coordinate)
                        }
                        if !routeManager.suggestedRoutes.isEmpty { shouldScrollToResults = true }
                    }
                }
            }
            .sheet(isPresented: $showBadges) {
                BadgesView(
                    sessions: historyStore.sessions,
                    todaySteps: stepManager.todaySteps,
                    dailyGoal: stepManager.currentGoal
                )
            }
            .fullScreenCover(item: $earnedBadge) { badge in
                BadgeEarnedView(badge: badge)
            }
    }

    // Split into layers so each chunk stays within the Swift type-checker's budget.
    private var stepCounterCore: some View {
        scrollWithDestinations
            .onChange(of: stepManager.currentGoal) { _, _ in clearRoutes() }
            .onChange(of: selectedRadius) { _, _ in clearRoutes() }
            .onChange(of: selectedRoute?.id) { _, _ in handleSelectionChange() }
            .onChange(of: historyStore.sessions.count) { _, _ in
                Task { await stepManager.refreshWeeklyCalendar(sessions: historyStore.sessions, weekOffset: calendarWeekOffset) }
            }
    }

    private var scrollWithDestinations: some View {
        scrollWithLifecycle
            .navigationDestination(isPresented: $showSettings) { SettingsView(stepManager: stepManager, historyStore: historyStore, routeStore: routeStore) }
            .navigationDestination(isPresented: $showMyRoutes) { CustomRoutesListView(store: routeStore, historyStore: historyStore) }
            .navigationDestination(isPresented: $showBuildRoute) { CustomRouteBuilderView { route in routeStore.save(route) } }
            .navigationDestination(isPresented: $showWalkHistory) { WalkHistoryView(store: historyStore) }
            .navigationDestination(isPresented: $showPetManagement) { PetManagementView(historyStore: historyStore, defaultGoal: stepManager.currentGoal) }
            .navigationDestination(item: $navigatingRoute) { (route: NavigableRoute) in WalkNavigationView(route: route, historyStore: historyStore) }
    }

    private var scrollWithLifecycle: some View {
        ScrollViewReader { proxy in mainScrollView(proxy: proxy) }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear").foregroundColor(.earthGreen)
                    }
                }
                ToolbarItem(placement: .principal) { BannerTitleView() }
            }
            .task {
                await stepManager.initialize()
                await stepManager.refreshWeeklyCalendar(sessions: historyStore.sessions, weekOffset: calendarWeekOffset)
            }
            .onChange(of: stepManager.todaySteps) { _, _ in
                Task { await stepManager.refreshWeeklyCalendar(sessions: historyStore.sessions, weekOffset: calendarWeekOffset) }
            }
            .onChange(of: stepManager.tagConfigs) { _, _ in
                Task { await stepManager.refreshWeeklyCalendar(sessions: historyStore.sessions, weekOffset: calendarWeekOffset) }
            }
            .onAppear { handleAppear() }
            .onChange(of: stepManager.todaySteps) { _, steps in handleStepGoalCheck(steps) }
    }

    private func handleSelectionChange() {
        elevationProfile = nil
        guard let coords = selectedRoute?.legWaypoints, coords.count >= 2 else { return }
        isLoadingElevation = true
        Task {
            elevationProfile = try? await ElevationService.shared.fetchProfile(for: coords)
            isLoadingElevation = false
        }
    }

    @ViewBuilder
    private func mainScrollView(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                progressSection.padding(.top, 8)
                actionGrid.padding(.horizontal)
                WeeklyCalendarView(
                    days: stepManager.weeklyCalendar,
                    sessions: historyStore.sessions,
                    weekOffset: calendarWeekOffset,
                    onDayTap: { selectedCalendarDay = $0 },
                    onWeekChange: { delta in
                        let newOffset = (calendarWeekOffset + delta).clamped(to: -52...52)
                        guard newOffset != calendarWeekOffset else { return }
                        calendarWeekOffset = newOffset
                        Task { await stepManager.refreshWeeklyCalendar(sessions: historyStore.sessions, weekOffset: newOffset) }
                    },
                    onCalendarTap: { showMonthCalendar = true }
                )
                settingsSection
                routeFindSection
                routeResultsSection.id("routeResults")
            }
            .padding(.bottom, 40)
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { containerWidth = geo.size.width }
                }
            )
        }
        .refreshable { await stepManager.refresh() }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.earthBg.ignoresSafeArea())
        .onChange(of: routeManager.suggestedRoutes.count) { old, new in
            guard old == 0, new > 0 else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo("routeResults", anchor: .top)
                }
            }
        }
    }

    private func handleAppear() {
        if !routeManager.isGenerating { clearRoutes() }
        if stepManager.todaySteps >= stepManager.currentGoal, walkIntent == .finishGoal {
            walkIntent = .quickWalk(minutes: 30)
        }
        if calendarWeekOffset != 0 {
            calendarWeekOffset = 0
            Task { await stepManager.refreshWeeklyCalendar(sessions: historyStore.sessions, weekOffset: 0) }
        }
        if let badge = StreakStore.shared.refresh(sessions: historyStore.sessions, todaySteps: stepManager.todaySteps, dailyGoal: stepManager.currentGoal) {
            earnedBadge = badge
        }
    }

    private func handleStepGoalCheck(_ steps: Int) {
        if steps >= stepManager.currentGoal, walkIntent == .finishGoal {
            walkIntent = .quickWalk(minutes: 30)
        }
        if let badge = StreakStore.shared.refresh(sessions: historyStore.sessions, todaySteps: steps, dailyGoal: stepManager.currentGoal) {
            earnedBadge = badge
        }
    }

    private func clearRoutes() {
        routeManager.suggestedRoutes = []
        routeManager.locationError   = nil
        selectedRoute    = nil
        routeWeather     = nil
        elevationProfile = nil
    }

    private var petRowLabel: String {
        let active = petStore.activePets
        if petStore.pets.isEmpty { return "Add a Pet" }
        switch active.count {
        case 0: return "\(petStore.pets.count) \(petStore.pets.count == 1 ? "pet" : "pets")"
        case 1: return "Walking with \(active[0].name)"
        case 2: return "Walking with \(active[0].name) & \(active[1].name)"
        default: return "Walking with \(active.count) pets"
        }
    }

    private static func formatDistance(_ meters: Double) -> String {
        let f = MKDistanceFormatter()
        f.unitStyle = .abbreviated
        return f.string(fromDistance: meters)
    }

    // MARK: Progress Ring

    private func userRingView(diameter: CGFloat) -> some View {
        let stroke    = diameter * 18 / 190
        let stepFont  = diameter * 36 / 190
        let goalFont  = diameter * 14 / 190
        return ZStack {
            Circle()
                .stroke(Color.earthMuted.opacity(0.15), lineWidth: stroke)
            Circle()
                .trim(from: 0, to: stepManager.progress)
                .stroke(
                    LinearGradient(colors: [.earthGreen, .earthOrange], startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: stepManager.progress)
            VStack(spacing: 1) {
                Text(stepManager.todaySteps.formatted())
                    .font(.system(size: stepFont, weight: .bold, design: .rounded))
                    .foregroundColor(.earthCream)
                Text("/ \(stepManager.currentGoal.formatted())")
                    .font(.system(size: goalFont))
                    .foregroundColor(.earthMuted)
            }
        }
        .frame(width: diameter, height: diameter)
        .onTapGesture { showUserDetail = true }
    }

    private var progressSection: some View {
        let available = max(containerWidth - 32, 280)
        let noPetsDiam: CGFloat   = min(available * 0.70, 275)
        let withPetsDiam: CGFloat = min(available * 0.46, 200)
        let hasPets = !petStore.activePets.isEmpty
        return VStack(spacing: 14) {
            if hasPets {
                HStack(alignment: .center, spacing: 20) {
                    userRingView(diameter: withPetsDiam)
                    VStack(spacing: 16) {
                        ForEach(petStore.activePets) { pet in
                            smallPetRing(pet: pet)
                        }
                    }
                }
                .padding(.horizontal)
            } else {
                userRingView(diameter: noPetsDiam)
                    .frame(maxWidth: .infinity)
            }

            if stepManager.todaySteps >= stepManager.currentGoal {
                Label("Goal Complete!", systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundColor(.earthGreen)
            } else {
                Text("\(stepManager.remainingSteps.formatted()) remaining · ~\(Self.formatDistance(stepManager.remainingMeters)) to go")
                    .font(.subheadline).foregroundColor(.earthMuted)
            }

            streakIndicator
            homeBadgeRings(compact: hasPets)
        }
        .padding(.vertical, 24)
        .padding(.horizontal)
    }

    private func homeBadgeRings(compact: Bool) -> some View {
        let sessions = historyStore.sessions
        let streak   = StreakStore.shared.currentStreak
        let earned   = walkBadges.filter { $0.isEarned(sessions: sessions, currentStreak: streak) }
        let unearned = walkBadges.filter { !$0.isEarned(sessions: sessions, currentStreak: streak) }
        // Pick the unearned badge closest to completion
        let nextBadge   = unearned.max { $0.progress(sessions: sessions, currentStreak: streak) < $1.progress(sessions: sessions, currentStreak: streak) }
        let recentBadge = earned.last

        let ringSize: CGFloat  = compact ? 52 : 68
        let lineWidth: CGFloat = compact ? 3 : 4
        let emojiSize: CGFloat = compact ? 20 : 28
        let labelSize: CGFloat = compact ? 9 : 10

        return Button { showBadges = true } label: {
            HStack(spacing: compact ? 16 : 24) {
                if let badge = recentBadge {
                    homeBadgeRing(badge, progress: 1.0, sessions: sessions, streak: streak,
                                  ringSize: ringSize, lineWidth: lineWidth, emojiSize: emojiSize, labelSize: labelSize)
                }
                if let next = nextBadge {
                    let p = next.progress(sessions: sessions, currentStreak: streak)
                    homeBadgeRing(next, progress: p, sessions: sessions, streak: streak,
                                  ringSize: ringSize, lineWidth: lineWidth, emojiSize: emojiSize, labelSize: labelSize)
                }
                if recentBadge == nil, nextBadge == nil, let first = walkBadges.first {
                    homeBadgeRing(first, progress: 0, sessions: sessions, streak: streak,
                                  ringSize: ringSize, lineWidth: lineWidth, emojiSize: emojiSize, labelSize: labelSize)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func homeBadgeRing(_ badge: WalkBadge, progress: Double, sessions: [WalkSession], streak: Int,
                                ringSize: CGFloat, lineWidth: CGFloat, emojiSize: CGFloat, labelSize: CGFloat) -> some View {
        let earned = progress >= 1.0
        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.earthMuted.opacity(0.15), lineWidth: lineWidth)
                if progress > 0 {
                    Circle()
                        .trim(from: 0, to: min(progress, 1.0))
                        .stroke(
                            earned ? Color.earthGreen : Color.earthOrange,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                Text(badge.emoji)
                    .font(.system(size: emojiSize))
                    .opacity(earned ? 1.0 : 0.55)
            }
            .frame(width: ringSize, height: ringSize)

            Text(badge.name)
                .font(.system(size: labelSize, weight: .semibold))
                .foregroundColor(earned ? .earthCream : .earthMuted)
                .multilineTextAlignment(.center)
                .lineLimit(1)
        }
    }

    private var streakIndicator: some View {
        let streak = StreakStore.shared.currentStreak
        return Button { showBadges = true } label: {
            HStack(spacing: 6) {
                Text(streak > 0 ? "🔥" : "💤")
                    .font(.system(size: 14))
                if streak > 0 {
                    Text("\(streak)-day streak")
                        .font(.caption.bold())
                        .foregroundColor(.earthGreen)
                } else {
                    Text("Start your streak today")
                        .font(.caption)
                        .foregroundColor(.earthMuted)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.earthMuted)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color.earthCard)
            .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }

    private func smallPetRing(pet: PetProfile) -> some View {
        let steps = petStore.todaySteps(for: pet, in: historyStore.sessions)
        let progress = min(1.0, Double(steps) / Double(max(1, pet.goalSteps)))
        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(pet.accentColor.opacity(0.2), lineWidth: 6)
                    .frame(width: 64, height: 64)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(pet.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: progress)
                VStack(spacing: 1) {
                    Text(pet.displayEmoji).font(.system(size: 22))
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.earthMuted)
                }
            }
            Text(pet.name)
                .font(.caption2.bold())
                .foregroundColor(.earthMuted)
        }
        .onTapGesture { selectedPetForDetail = pet }
    }

    // MARK: Settings

    private var settingsSection: some View {
        VStack(spacing: 1) {
            row {
                Text("Daily Goal").foregroundColor(.earthCream)
                Spacer()
                Text("\(stepManager.currentGoal.formatted()) steps").foregroundColor(.earthGreen)
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.earthMuted.opacity(0.6))
            }
            .contentShape(Rectangle())
            .onTapGesture { showGoalSheet = true }

            Button { showMyRoutes = true } label: {
                HStack {
                    Label("Saved Items", systemImage: "bookmark.map").foregroundColor(.earthCream)
                    Spacer()
                    if !routeStore.routes.isEmpty {
                        Text("\(routeStore.routes.count)")
                            .font(.caption).foregroundColor(.earthGreen).padding(.trailing, 4)
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.earthMuted.opacity(0.6))
                }
                .padding(.horizontal, 16).padding(.vertical, 16)
            }

            Button { showWalkHistory = true } label: {
                HStack {
                    Label("Walk History", systemImage: "clock.arrow.circlepath").foregroundColor(.earthCream)
                    Spacer()
                    if !historyStore.sessions.isEmpty {
                        Text("\(historyStore.sessions.count)")
                            .font(.caption).foregroundColor(.earthGreen).padding(.trailing, 4)
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.earthMuted.opacity(0.6))
                }
                .padding(.horizontal, 16).padding(.vertical, 16)
            }

            Button { showPetManagement = true } label: {
                HStack {
                    Label(petRowLabel, systemImage: petStore.activePets.isEmpty ? "pawprint" : "pawprint.fill")
                        .foregroundColor(petStore.pets.isEmpty ? .earthCream : .earthGreen)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.earthMuted.opacity(0.6))
                }
                .padding(.horizontal, 16).padding(.vertical, 16)
            }
        }
        .background(Color.earthCard)
        .cornerRadius(16)
        .padding(.horizontal)
    }

    // MARK: Action Grid

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            actionTile(icon: "figure.walk", label: "Start Walking",
                       color: Color.earthGreen) { showFreeWalk = true }

            actionTile(icon: routeManager.isGenerating ? "" : "map.fill",
                       label: routeManager.isGenerating ? "Finding…" : "Recommend",
                       color: Color(red: 0.13, green: 0.57, blue: 0.64),
                       loading: routeManager.isGenerating) { triggerRecommend() }

            actionTile(icon: "sparkles", label: "Explore",
                       color: Color.earthOrange) { showNearbySheet = true }

            actionTile(icon: "plus.circle.fill", label: "Build Route",
                       color: Color(red: 0.28, green: 0.49, blue: 0.84)) { showBuildRoute = true }
        }
    }

    private func actionTile(icon: String, label: String, color: Color, loading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                if loading {
                    ProgressView().tint(.white).scaleEffect(1.1)
                        .frame(height: 28)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 26, weight: .medium))
                        .frame(height: 28)
                }
                Text(label)
                    .font(.subheadline.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(color)
            .cornerRadius(16)
        }
        .disabled(loading)
    }

    private func triggerRecommend() {
        clearRoutes()
        Task {
            let targetMeters: Double = {
                switch walkIntent {
                case .finishGoal:          return stepManager.remainingMeters
                case .quickWalk(let mins): return Double(mins) * 80
                }
            }()
            await routeManager.generateRoutes(remainingMeters: targetMeters, radius: selectedRadius)
            if let loc = routeManager.lastLocation, !routeManager.suggestedRoutes.isEmpty {
                routeWeather = await RouteWeatherService.shared.fetchWeather(for: loc.coordinate)
            }
            if !routeManager.suggestedRoutes.isEmpty { shouldScrollToResults = true }
        }
    }

    // MARK: Find Routes

    private var routeFindSection: some View {
        VStack(spacing: 12) {
            // Walk intent chips: finish goal vs quick walk durations
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    intentChip(.finishGoal)
                    ForEach(WalkIntent.quickOptions, id: \.self) { mins in
                        intentChip(.quickWalk(minutes: mins))
                    }
                }
                .padding(.horizontal)
            }

            // Radius slider — how far the loop can stray from your start point
            VStack(spacing: 6) {
                HStack {
                    Text("Route reach")
                        .font(.caption.bold())
                        .foregroundColor(.earthMuted)
                    Spacer()
                    Text(Self.formatDistance(selectedRadius))
                        .font(.caption.bold())
                        .foregroundColor(.earthGreen)
                        .monospacedDigit()
                        .animation(.none, value: selectedRadius)
                }
                Slider(value: $selectedRadius, in: 200...4_000)
                    .tint(.earthGreen)
            }
            .padding(.horizontal)

            // Search for a specific destination
            Button { showDestinationSearch = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                    Text("Search for a specific place")
                }
                .font(.subheadline)
                .foregroundColor(.earthMuted)
            }
            .disabled(routeManager.isGenerating)
        }
    }

    // MARK: Route Results

    @ViewBuilder
    private var routeResultsSection: some View {
        if let err = routeManager.locationError {
            Text(err).font(.caption).foregroundColor(.orange)
                .multilineTextAlignment(.center).padding(.horizontal)
        } else if !routeManager.suggestedRoutes.isEmpty {
            VStack(spacing: 12) {
                if let weather = routeWeather {
                    WeatherWidget(weather: weather)
                        .padding(.horizontal)
                }
                RouteMapView(routes: routeManager.suggestedRoutes, selectedRoute: $selectedRoute)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)

                let totalRoutes = routeManager.suggestedRoutes.count
                ForEach(routeManager.suggestedRoutes) { route in
                    RouteCard(
                        route: route,
                        isSelected: selectedRoute?.id == route.id,
                        totalRoutes: totalRoutes,
                        isSaved: savedRouteIds.contains(route.id),
                        onSelect: { selectedRoute = (selectedRoute?.id == route.id) ? nil : route },
                        onSave: {
                            routeStore.save(route.toCustomRoute())
                            savedRouteIds.insert(route.id)
                        },
                        onPost: { routeForPosting = route }
                    )
                    .padding(.horizontal)
                }

                if let selected = selectedRoute {
                    if let profile = elevationProfile {
                        ElevationProfileChart(profile: profile)
                            .padding(.horizontal)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else if isLoadingElevation {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.earthCard)
                            .frame(height: 80)
                            .overlay(ProgressView().tint(.earthGreen))
                            .padding(.horizontal)
                    }

                    Button {
                        navigatingRoute = selected.toNavigableRoute()
                    } label: {
                        Label("Start Walk", systemImage: "figure.walk")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18).padding(.horizontal, 20)
                            .background(Color.earthGreen).foregroundColor(.white)
                            .fontWeight(.semibold).cornerRadius(14).padding(.horizontal)
                    }

                    VStack(spacing: 4) {
                        Button { selected.openInAppleMaps() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "map")
                                Text("Open in Apple Maps")
                            }
                            .font(.subheadline).foregroundColor(.earthMuted)
                        }
                        Text("Laps and multi-stop routes aren't supported in Apple Maps")
                            .font(.caption)
                            .foregroundColor(.earthMuted.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }

                communityRoutesSection
            }
        }
    }

    // MARK: - Community Routes

    @ViewBuilder
    private var communityRoutesSection: some View {
        VStack(spacing: 10) {
            Button {
                showCommunityRoutes.toggle()
                if showCommunityRoutes && communityRoutes.isEmpty {
                    Task { await loadCommunityRoutes() }
                }
            } label: {
                HStack {
                    Label("Community Routes", systemImage: "person.2.fill")
                        .font(.subheadline.bold())
                        .foregroundColor(.earthCream)
                    Spacer()
                    if isLoadingCommunity {
                        ProgressView().tint(.earthGreen).scaleEffect(0.8)
                    } else {
                        Image(systemName: showCommunityRoutes ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundColor(.earthMuted)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Color.earthCard)
                .cornerRadius(12)
                .padding(.horizontal)
            }

            if showCommunityRoutes {
                if communityRoutes.isEmpty && !isLoadingCommunity {
                    Text("No routes shared yet — be the first!")
                        .font(.caption).foregroundColor(.earthMuted)
                        .padding(.vertical, 8)
                } else {
                    ForEach($communityRoutes) { $route in
                        CommunityRouteCard(
                            route: $route,
                            hasVoted: CommunityRouteService.shared.hasVoted(for: route.id),
                            isSaved: savedCommunityIds.contains(route.id.recordName),
                            onUpvote: {
                                guard !CommunityRouteService.shared.hasVoted(for: route.id) else { return }
                                route.upvotes += 1
                                CommunityRouteService.shared.markVoted(for: route.id)
                                Task { try? await CommunityRouteService.shared.upvote(id: route.id) }
                            },
                            onSave: {
                                routeStore.save(CustomRoute(
                                    id: UUID(),
                                    name: route.name,
                                    waypoints: route.waypoints,
                                    totalDistance: route.distanceMeters,
                                    isLoop: route.isLoop,
                                    createdAt: Date()
                                ))
                                savedCommunityIds.insert(route.id.recordName)
                            },
                            onStart: { navigatingRoute = route.toNavigableRoute() }
                        )
                        .padding(.horizontal)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCommunityRoutes)
    }

    private func loadCommunityRoutes() async {
        isLoadingCommunity = true
        communityRoutes = (try? await CommunityRouteService.shared.fetchRoutes()) ?? []
        isLoadingCommunity = false
    }

    // MARK: Helper

    @ViewBuilder
    private func intentChip(_ intent: WalkIntent) -> some View {
        let isSelected = walkIntent == intent
        Button { walkIntent = intent } label: {
            Text(intent.label)
                .font(.caption.bold())
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(isSelected ? Color.earthOrange : Color.earthCard)
                .foregroundColor(isSelected ? .white : .earthCream)
                .cornerRadius(20)
        }
    }

    private func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack { content() }
            .padding(.horizontal, 16).padding(.vertical, 16)
            .overlay(Rectangle().frame(height: 0.5).foregroundColor(Color.earthMuted.opacity(0.2)), alignment: .bottom)
    }
}

// MARK: - Route Map View

struct RouteMapView: UIViewRepresentable {
    let routes: [SuggestedRoute]
    @Binding var selectedRoute: SuggestedRoute?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.overrideUserInterfaceStyle = .unspecified
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let currentIds = routes.map { $0.id }

        // Only rebuild overlays when the route set itself changes
        if context.coordinator.lastRouteIds != currentIds {
            context.coordinator.lastRouteIds = currentIds
            context.coordinator.lastSelectedId = nil  // reset so renderer update runs below
            map.removeOverlays(map.overlays)
            var coords: [CLLocationCoordinate2D] = []
            for route in routes {
                let pl = route.polyline
                pl.title = route.id.uuidString
                map.addOverlay(pl, level: .aboveRoads)
                let pts = pl.points()
                for i in 0..<pl.pointCount { coords.append(pts[i].coordinate) }
            }
            if let user = map.userLocation.location { coords.append(user.coordinate) }
            if !coords.isEmpty {
                let rect = coords.reduce(MKMapRect.null) { r, c in
                    let p = MKMapPoint(c)
                    return r.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
                map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: false)
            }
        }

        // When selection changes, update renderer properties directly (no flash)
        let newSelectedId = selectedRoute?.id
        if context.coordinator.lastSelectedId != newSelectedId {
            context.coordinator.lastSelectedId = newSelectedId
            let total = routes.count
            let hasSelection = selectedRoute != nil
            for overlay in map.overlays {
                guard let pl = overlay as? MKPolyline,
                      let renderer = map.renderer(for: overlay) as? MKPolylineRenderer,
                      let route = routes.first(where: { $0.id.uuidString == pl.title }) else { continue }
                let isSelected = route.id == newSelectedId
                renderer.strokeColor = SuggestedRoute.paletteUIColor(index: route.colorIndex, total: total)
                renderer.lineWidth = isSelected ? 6 : 3
                renderer.alpha     = isSelected ? 1.0 : (hasSelection ? 0.2 : 0.6)
                renderer.setNeedsDisplay()
            }

            // Zoom to selected route; zoom out to show all when deselected
            if let sel = selectedRoute {
                var rect = MKMapRect.null
                let pts = sel.polyline.points()
                for i in 0..<sel.polyline.pointCount {
                    let p = MKMapPoint(pts[i].coordinate)
                    rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
                if !rect.isNull {
                    map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50), animated: true)
                }
            } else if !routes.isEmpty {
                var coords: [CLLocationCoordinate2D] = []
                for route in routes {
                    let pts = route.polyline.points()
                    for i in 0..<route.polyline.pointCount { coords.append(pts[i].coordinate) }
                }
                let rect = coords.reduce(MKMapRect.null) { r, c in
                    let p = MKMapPoint(c)
                    return r.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
                if !rect.isNull {
                    map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: true)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RouteMapView
        var lastRouteIds: [UUID] = []
        var lastSelectedId: UUID? = UUID()  // non-nil sentinel forces first render
        init(_ p: RouteMapView) { parent = p }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let pl = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: pl)
            let total = parent.routes.count
            let hasSelection = parent.selectedRoute != nil
            if let route = parent.routes.first(where: { $0.id.uuidString == pl.title }) {
                let isSelected = route.id == parent.selectedRoute?.id
                r.strokeColor = SuggestedRoute.paletteUIColor(index: route.colorIndex, total: total)
                r.lineWidth   = isSelected ? 6 : 3
                r.alpha       = isSelected ? 1.0 : (hasSelection ? 0.2 : 0.6)
            }
            return r
        }
    }
}

// MARK: - Goal Editor Sheet

struct GoalEditorSheet: View {
    @ObservedObject var stepManager: StepManager
    @Environment(\.dismiss) private var dismiss
    @State private var goalText = ""
    @State private var distText = ""
    @State private var mode     = 0  // 0 = Steps, 1 = Distance

    private var todayWeekday: Int { Calendar.current.component(.weekday, from: Date()) }

    private var orderedDays: [(Int, String)] {
        let all: [(Int, String)] = [
            (1, "Sunday"), (2, "Monday"), (3, "Tuesday"), (4, "Wednesday"),
            (5, "Thursday"), (6, "Friday"), (7, "Saturday")
        ]
        let idx = all.firstIndex(where: { $0.0 == todayWeekday }) ?? 0
        return Array(all[idx...] + all[..<idx])
    }

    private let stepPresets  = [5_000, 7_500, 10_000, 12_500, 15_000, 20_000]
    @State private var showTagCustomizer = false

    // MARK: - Locale-aware unit helpers

    private static var useMetric: Bool {
        Locale.current.measurementSystem == .metric
    }

    // steps per km ≈ 1312 (0.762 m/step); steps per mile ≈ 2112 (1609 m/mile ÷ 0.762)
    private static var stepsPerUnit: Double { useMetric ? 1312 : 2112 }

    private static var unitLabel: String { useMetric ? "km" : "mi" }

    private static var unitPresets: [Double] {
        useMetric ? [3, 5, 7.5, 10, 15, 20] : [2, 3, 5, 6, 8, 12]
    }

    private static func distString(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(value))"
            : String(format: "%.1f", value)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 28) {
                        Picker("", selection: $mode) {
                            Text("Steps").tag(0)
                            Text("Distance").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 28)

                        if mode == 0 {
                            Text("Set your daily step goal")
                                .font(.subheadline).foregroundColor(.earthMuted)

                            TextField("Steps", text: $goalText)
                                .keyboardType(.numberPad)
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .multilineTextAlignment(.center)
                                .foregroundColor(.earthCream)

                            let columns = [GridItem(.adaptive(minimum: 70))]
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(stepPresets, id: \.self) { p in
                                    Button {
                                        goalText = "\(p)"
                                        stepManager.dailyGoal = p
                                    } label: {
                                        Text(p >= 10_000 ? "\(p / 1000)K" : "\(p / 1000).5K")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 14).padding(.vertical, 8)
                                            .background(stepManager.dailyGoal == p ? Color.earthGreen : Color.earthCard)
                                            .foregroundColor(stepManager.dailyGoal == p ? .white : .earthCream)
                                            .cornerRadius(20)
                                    }
                                }
                            }
                        } else {
                            Text("Set your daily distance goal")
                                .font(.subheadline).foregroundColor(.earthMuted)

                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                TextField(Self.unitLabel, text: $distText)
                                    .keyboardType(.decimalPad)
                                    .font(.system(size: 48, weight: .bold, design: .rounded))
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.earthCream)
                                    .frame(maxWidth: 180)
                                Text(Self.unitLabel)
                                    .font(.title2.bold())
                                    .foregroundColor(.earthMuted)
                            }

                            let columns = [GridItem(.adaptive(minimum: 60))]
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(Self.unitPresets, id: \.self) { dist in
                                    let steps = Int(dist * Self.stepsPerUnit)
                                    Button {
                                        distText = Self.distString(dist)
                                        stepManager.dailyGoal = steps
                                    } label: {
                                        Text("\(Self.distString(dist)) \(Self.unitLabel)")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 14).padding(.vertical, 8)
                                            .background(stepManager.dailyGoal == steps ? Color.earthGreen : Color.earthCard)
                                            .foregroundColor(stepManager.dailyGoal == steps ? .white : .earthCream)
                                            .cornerRadius(20)
                                    }
                                }
                            }
                        }

                        // ── Custom Weekly Schedule ────────────────────────
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Custom Weekly Schedule")
                                        .font(.subheadline).foregroundColor(.earthCream)
                                    Text(stepManager.useCustomSchedule
                                         ? "Goals below override your default"
                                         : "Set different goals per day of week")
                                        .font(.caption).foregroundColor(.earthMuted)
                                }
                                Spacer()
                                Toggle("", isOn: $stepManager.useCustomSchedule)
                                    .labelsHidden().tint(.earthGreen)
                            }
                            .padding(14)

                            if stepManager.useCustomSchedule {
                                Divider().background(Color.earthMuted.opacity(0.2))

                                // Lock All / Unlock All header
                                let allLocked = orderedDays.allSatisfy { stepManager.lockedWeekdays.contains($0.0) }
                                HStack {
                                    Text("Tap 🔒 to preserve a day's goal when the default changes")
                                        .font(.caption2).foregroundColor(.earthMuted)
                                    Spacer()
                                    Button {
                                        if allLocked {
                                            stepManager.lockedWeekdays = []
                                        } else {
                                            // Snapshot each day's effective value before locking
                                            for (wd, _) in orderedDays {
                                                stepManager.weekdayGoals[wd] = stepManager.weekdayGoals[wd] ?? stepManager.dailyGoal
                                            }
                                            stepManager.lockedWeekdays = Set(orderedDays.map(\.0))
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: allLocked ? "lock.fill" : "lock.open")
                                            Text(allLocked ? "Unlock All" : "Lock All")
                                                .font(.caption.bold())
                                        }
                                        .foregroundColor(allLocked ? .earthGreen : .earthMuted)
                                    }
                                }
                                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)

                                ForEach(orderedDays, id: \.0) { (wd, name) in
                                    VStack(spacing: 0) {
                                        HStack(spacing: 8) {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(name)
                                                    .foregroundColor(wd == todayWeekday ? .earthGreen : .earthCream)
                                                    .font(.subheadline)
                                                if wd == todayWeekday {
                                                    Text("Today").font(.caption2).foregroundColor(.earthGreen)
                                                }
                                            }
                                            Spacer()
                                            TextField("steps", value: Binding(
                                                get: { stepManager.weekdayGoals[wd] ?? stepManager.dailyGoal },
                                                set: { stepManager.weekdayGoals[wd] = ($0 == 0) ? nil : $0 }
                                            ), format: .number)
                                            .keyboardType(.numberPad)
                                            .multilineTextAlignment(.trailing)
                                            .foregroundColor(.earthGreen)
                                            .frame(width: 90)

                                            Button {
                                                if stepManager.lockedWeekdays.contains(wd) {
                                                    stepManager.lockedWeekdays.remove(wd)
                                                } else {
                                                    // Snapshot the current effective value before locking
                                                    stepManager.weekdayGoals[wd] = stepManager.weekdayGoals[wd] ?? stepManager.dailyGoal
                                                    stepManager.lockedWeekdays.insert(wd)
                                                }
                                            } label: {
                                                Image(systemName: stepManager.lockedWeekdays.contains(wd) ? "lock.fill" : "lock.open")
                                                    .font(.subheadline)
                                                    .foregroundColor(stepManager.lockedWeekdays.contains(wd) ? .earthGreen : .earthMuted.opacity(0.4))
                                            }
                                            .frame(width: 28)
                                        }
                                        .padding(.horizontal, 14).padding(.vertical, 10)

                                        // Activity tag chips — clipped so they respect card edge
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 6) {
                                                ForEach(stepManager.tagConfigs) { config in
                                                    let selected = stepManager.weekdayTags[wd] == config.id
                                                    Button {
                                                        stepManager.weekdayTags[wd] = selected ? nil : config.id
                                                    } label: {
                                                        HStack(spacing: 3) {
                                                            Text(config.emoji).font(.system(size: 10))
                                                            Text(config.name).font(.caption2.bold())
                                                        }
                                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                                        .background(selected ? config.color : Color.earthBg)
                                                        .foregroundColor(selected ? .white : config.color)
                                                        .cornerRadius(20)
                                                    }
                                                }
                                            }
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 2)
                                        }
                                        .clipped()
                                        .padding(.bottom, 10)
                                    }

                                    if wd != orderedDays.last?.0 {
                                        Divider().background(Color.earthMuted.opacity(0.15)).padding(.horizontal, 14)
                                    }
                                }
                            }
                        }
                        .background(Color.earthCard)
                        .cornerRadius(12)
                        .animation(.easeInOut(duration: 0.22), value: stepManager.useCustomSchedule)

                        // ── Customize Tags ───────────────────────────────
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Customize Tags")
                                        .font(.subheadline).foregroundColor(.earthCream)
                                    Text("Change emoji and color for each activity")
                                        .font(.caption).foregroundColor(.earthMuted)
                                }
                                Spacer()
                                Button { showTagCustomizer.toggle() } label: {
                                    Image(systemName: showTagCustomizer ? "chevron.up" : "chevron.down")
                                        .font(.caption).foregroundColor(.earthMuted.opacity(0.7))
                                }
                            }
                            .padding(14)

                            if showTagCustomizer {
                                Divider().background(Color.earthMuted.opacity(0.2))
                                ForEach($stepManager.tagConfigs) { $config in
                                    VStack(spacing: 0) {
                                        HStack(spacing: 10) {
                                            // Emoji field
                                            TextField("", text: $config.emoji)
                                                .font(.system(size: 22))
                                                .frame(width: 36)
                                                .multilineTextAlignment(.center)

                                            // Name field — 12 char limit
                                            TextField("Name", text: Binding(
                                                get: { config.name },
                                                set: { config.name = String($0.prefix(12)) }
                                            ))
                                            .font(.subheadline.bold())
                                            .foregroundColor(.earthCream)
                                            .frame(maxWidth: 80)

                                            Spacer()

                                            // Color palette — checkmark on selected
                                            HStack(spacing: 6) {
                                                ForEach(0..<ActivityTagConfig.palette.count, id: \.self) { i in
                                                    Button { withAnimation(.spring(duration: 0.2)) { config.colorIndex = i } } label: {
                                                        ZStack {
                                                            Circle()
                                                                .fill(ActivityTagConfig.palette[i])
                                                                .frame(width: config.colorIndex == i ? 26 : 20,
                                                                       height: config.colorIndex == i ? 26 : 20)
                                                                .shadow(color: config.colorIndex == i
                                                                    ? ActivityTagConfig.palette[i].opacity(0.55) : .clear,
                                                                    radius: 4, y: 2)
                                                            if config.colorIndex == i {
                                                                Image(systemName: "checkmark")
                                                                    .font(.system(size: 9, weight: .bold))
                                                                    .foregroundColor(.white)
                                                            }
                                                        }
                                                    }
                                                    .animation(.spring(duration: 0.2), value: config.colorIndex)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 14).padding(.vertical, 10)
                                        if config.id != stepManager.tagConfigs.last?.id {
                                            Divider().background(Color.earthMuted.opacity(0.12)).padding(.horizontal, 14)
                                        }
                                    }
                                }
                            }
                        }
                        .background(Color.earthCard)
                        .cornerRadius(12)
                        .animation(.easeInOut(duration: 0.22), value: showTagCustomizer)
                    }
                    .padding(28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Daily Goal")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                goalText = "\(stepManager.dailyGoal)"
                let units = Double(stepManager.dailyGoal) / Self.stepsPerUnit
                distText = Self.distString(units)
            }

            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if mode == 0 {
                            if let v = Int(goalText), v > 0 { stepManager.dailyGoal = v }
                        } else {
                            if let units = Double(distText), units > 0 {
                                stepManager.dailyGoal = Int(units * Self.stepsPerUnit)
                            }
                        }
                        dismiss()
                    }.foregroundColor(.earthGreen)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.earthMuted)
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Day Detail Sheet

struct DayDetailSheet: View {
    let day: CalendarDay
    let sessions: [WalkSession]
    @Environment(\.dismiss) private var dismiss
    @State private var reminderScheduled = false
    @State private var showReminderError = false

    private static let fullDateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .full; return f
    }()

    private var daySessions: [WalkSession] {
        sessions.filter { Calendar.current.isDate($0.date, inSameDayAs: day.date) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        // Ring — circles are inset by stroke/2 so they don't clip
                        ZStack {
                            Circle()
                                .stroke(Color.earthMuted.opacity(0.15), lineWidth: 14)
                                .padding(7)
                            if !day.isFuture && day.progress > 0 {
                                Circle()
                                    .trim(from: 0, to: day.progress)
                                    .stroke(
                                        LinearGradient(colors: [.earthGreen, .earthOrange],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                                    )
                                    .rotationEffect(.degrees(-90))
                                    .padding(7)
                            }
                            VStack(spacing: 4) {
                                if let steps = day.steps {
                                    Text(steps.formatted())
                                        .font(.system(size: 38, weight: .bold, design: .rounded))
                                        .foregroundColor(.earthCream)
                                    Text("/ \(day.goal.formatted())")
                                        .font(.caption).foregroundColor(.earthMuted)
                                } else if day.isFuture {
                                    Text(day.goal.formatted())
                                        .font(.system(size: 32, weight: .bold, design: .rounded))
                                        .foregroundColor(.earthMuted.opacity(0.5))
                                    Text("planned")
                                        .font(.caption).foregroundColor(.earthMuted.opacity(0.4))
                                } else {
                                    Text("—")
                                        .font(.system(size: 38, weight: .bold, design: .rounded))
                                        .foregroundColor(.earthMuted.opacity(0.4))
                                    Text("no data")
                                        .font(.caption).foregroundColor(.earthMuted.opacity(0.4))
                                }
                            }
                        }
                        .frame(width: 180, height: 180)

                        // Tag + accomplishment badge
                        HStack(spacing: 10) {
                            if let emoji = day.tagEmoji, let color = day.tagColor, let tag = day.tag {
                                HStack(spacing: 5) {
                                    Text(emoji)
                                    Text(tag)
                                }
                                .font(.caption.bold())
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(color.opacity(0.15))
                                .foregroundColor(color)
                                .cornerRadius(20)
                            }
                            if day.isFuture {
                                Label("Scheduled", systemImage: "calendar.badge.clock")
                                    .font(.caption.bold()).foregroundColor(.earthMuted)
                            } else if let met = day.goalMet {
                                Label(met ? "Goal achieved" : "Goal not met",
                                      systemImage: met ? "checkmark.seal.fill" : "xmark.circle")
                                    .font(.caption.bold())
                                    .foregroundColor(met ? .earthGreen : .earthMuted)
                            }
                        }

                        // Stats row — always show goal; add steps/progress for non-future days
                        HStack(spacing: 0) {
                            statCell(label: "Goal", value: day.goal.formatted())
                            if let steps = day.steps {
                                Divider().frame(height: 40)
                                statCell(label: "Steps", value: steps.formatted())
                                Divider().frame(height: 40)
                                statCell(label: "Progress", value: "\(Int(day.progress * 100))%")
                                Divider().frame(height: 40)
                                statCell(label: "Distance", value: Self.formatDist(Double(steps) * 0.762))
                            }
                        }
                        .padding(.vertical, 8)
                        .background(Color.earthCard)
                        .cornerRadius(14)
                        .padding(.horizontal)

                        // Reminder button for future days
                        if day.isFuture {
                            Button {
                                Task { await scheduleReminder() }
                            } label: {
                                Label(
                                    reminderScheduled ? "Added to Reminders" : "Add to Reminders",
                                    systemImage: reminderScheduled ? "checkmark.circle.fill" : "bell.badge.plus"
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(reminderScheduled ? Color.earthCard : Color.earthGreen)
                                .foregroundColor(reminderScheduled ? .earthGreen : .white)
                                .fontWeight(.semibold)
                                .cornerRadius(12)
                            }
                            .disabled(reminderScheduled)
                            .padding(.horizontal)
                            .alert("Couldn't Add Reminder", isPresented: $showReminderError) {
                                Button("OK", role: .cancel) {}
                            } message: {
                                Text("Please allow Reminders access in Settings to use this feature.")
                            }
                        }

                        // Walk sessions
                        if !daySessions.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Walks").font(.caption.bold()).foregroundColor(.earthMuted)
                                    .padding(.horizontal, 20)
                                ForEach(daySessions) { session in
                                    sessionRow(session)
                                }
                            }
                        } else if !day.isFuture {
                            Text("No walks recorded this day")
                                .font(.caption).foregroundColor(.earthMuted.opacity(0.6))
                        }
                    }
                    .padding(.vertical, 24)
                }
            }
            .navigationTitle(Self.fullDateFmt.string(from: day.date))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.earthGreen)
                }
            }
        }
        .presentationDetents([.large])
    }

    @MainActor
    private func scheduleReminder() async {
        let store = EKEventStore()
        let granted: Bool
        do {
            if #available(iOS 17, *) {
                granted = try await store.requestFullAccessToReminders()
            } else {
                granted = await withCheckedContinuation { cont in
                    store.requestAccess(to: .reminder) { success, _ in cont.resume(returning: success) }
                }
            }
        } catch {
            showReminderError = true
            return
        }
        guard granted else { showReminderError = true; return }
        do {
            let reminder = EKReminder(eventStore: store)
            reminder.title = "Time for your walk! Goal: \(day.goal.formatted()) steps"
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: day.date)
            comps.hour = 8; comps.minute = 0
            reminder.dueDateComponents = comps
            reminder.calendar = store.defaultCalendarForNewReminders()
            try store.save(reminder, commit: true)
            reminderScheduled = true
            if let url = URL(string: "x-apple-reminder://") {
                await UIApplication.shared.open(url)
            }
        } catch {
            showReminderError = true
        }
    }

    private static func formatDist(_ meters: Double) -> String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: meters)
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.headline.monospacedDigit()).foregroundColor(.earthCream)
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private func sessionRow(_ session: WalkSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.routeName)
                    .font(.subheadline).foregroundColor(.earthCream)
                HStack(spacing: 12) {
                    Label(session.distanceText, systemImage: "ruler")
                    Label(session.timeText, systemImage: "clock")
                }
                .font(.caption).foregroundColor(.earthMuted)
            }
            Spacer()
            Text("\(session.estimatedSteps.formatted()) steps")
                .font(.caption.bold()).foregroundColor(.earthGreen)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.earthCard)
        .cornerRadius(12)
        .padding(.horizontal)
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

// MARK: - Destination Search Sheet

private struct SearchResult: Identifiable {
    let id = UUID()
    let mapItem: MKMapItem
}

struct DestinationSearchSheet: View {
    let userLocation: CLLocation?
    let onSelect: (MKMapItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    // Search field
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.earthMuted)
                        TextField("Café, park, gym, landmark...", text: $searchText)
                            .foregroundColor(.earthCream)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.earthMuted)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.earthCard)
                    .cornerRadius(12)
                    .padding()

                    if searchText.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 44))
                                .foregroundColor(.earthMuted.opacity(0.4))
                            Text("Search for anywhere you'd like to walk — a café, park, gym, landmark, or friend's street.")
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.earthMuted)
                                .padding(.horizontal, 32)
                        }
                        Spacer()
                    } else if isSearching {
                        Spacer()
                        ProgressView().tint(.earthGreen)
                        Spacer()
                    } else if results.isEmpty {
                        Spacer()
                        Text("No places found")
                            .font(.subheadline)
                            .foregroundColor(.earthMuted)
                        Spacer()
                    } else {
                        List {
                            ForEach(results) { result in
                                SearchResultRow(result: result, userLocation: userLocation) {
                                    onSelect(result.mapItem)
                                    dismiss()
                                }
                                .listRowBackground(Color.earthCard.opacity(0.7))
                                .listRowSeparatorTint(Color.earthMuted.opacity(0.2))
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("Walk to a Destination")
            .navigationBarTitleDisplayMode(.inline)
            

            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.earthMuted)
                }
            }
        }
        .onChange(of: searchText) { _, query in
            searchTask?.cancel()
            guard !query.isEmpty else { results = []; return }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await performSearch(query: query)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                    .fontWeight(.semibold).foregroundColor(.earthGreen)
            }
        }
    }

    private func performSearch(query: String) async {
        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let location = userLocation {
            request.region = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: 10_000,
                longitudinalMeters: 10_000
            )
        }
        if let response = try? await MKLocalSearch(request: request).start() {
            results = response.mapItems.map { SearchResult(mapItem: $0) }
        }
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    let userLocation: CLLocation?
    let onTap: () -> Void

    private var subtitle: String? { result.mapItem.address?.shortAddress ?? result.mapItem.addressRepresentations?.cityName }

    private var distanceText: String? {
        guard let userLoc = userLocation else { return nil }
        let coord = result.mapItem.location.coordinate
        let dist = userLoc.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: dist)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundColor(.earthGreen)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.mapItem.name ?? "Unknown place")
                        .foregroundColor(.earthCream)
                        .font(.body)
                    if let sub = subtitle {
                        Text(sub)
                            .foregroundColor(.earthMuted)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let dist = distanceText {
                    Text(dist)
                        .font(.subheadline)
                        .foregroundColor(.earthMuted)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - POI Category

struct POICategory: Identifiable {
    enum SearchType {
        case category(MKPointOfInterestCategory)
        case naturalLanguage(String)
    }

    let id = UUID()
    let name: String
    let emoji: String
    let searchType: SearchType

    init(name: String, emoji: String, mkCategory: MKPointOfInterestCategory) {
        self.name = name; self.emoji = emoji; self.searchType = .category(mkCategory)
    }
    init(name: String, emoji: String, query: String) {
        self.name = name; self.emoji = emoji; self.searchType = .naturalLanguage(query)
    }

    // Nature and landmarks first, then social/amenity, then dog-walker
    static let all: [POICategory] = [
        POICategory(name: "Parks",          emoji: "🌳", mkCategory: .park),
        POICategory(name: "National Parks", emoji: "🏞️", mkCategory: .nationalPark),
        POICategory(name: "Beaches",        emoji: "🏖️", mkCategory: .beach),
        POICategory(name: "Museums",        emoji: "🏛️", mkCategory: .museum),
        POICategory(name: "Libraries",      emoji: "📚", mkCategory: .library),
        POICategory(name: "Cafés",          emoji: "☕", mkCategory: .cafe),
        POICategory(name: "Restaurants",    emoji: "🍽️", mkCategory: .restaurant),
        POICategory(name: "Bakeries",       emoji: "🥐", mkCategory: .bakery),
        POICategory(name: "Gyms",           emoji: "💪", mkCategory: .fitnessCenter),
        POICategory(name: "Dog Parks",      emoji: "🐕", query: "dog park"),
        POICategory(name: "Pet Stores",     emoji: "🦴", query: "pet store"),
        POICategory(name: "Vets",           emoji: "🩺", query: "veterinarian"),
    ]
}

// MARK: - Nearby Places Sheet

struct NearbyPlacesSheet: View {
    let fetchLocation: () async -> CLLocation?
    let onSelect: (MKMapItem, Bool) -> Void   // (destination, wantsLoop)

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: POICategory?
    @State private var resolvedLocation: CLLocation?
    @State private var results: [MKMapItem] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                Group {
                    if let category = selectedCategory {
                        poiResultsList(for: category)
                    } else {
                        categoryGrid
                    }
                }
            }
            .navigationTitle(selectedCategory?.name ?? "What's around you?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if selectedCategory != nil {
                        Button {
                            selectedCategory = nil
                            results = []
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Categories")
                            }
                            .foregroundColor(.earthGreen)
                        }
                    } else {
                        Button("Cancel") { dismiss() }
                            .foregroundColor(.earthMuted)
                    }
                }
            }
        }
    }

    private var categoryGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pick a vibe and we'll find somewhere to walk to.")
                    .font(.subheadline)
                    .foregroundColor(.earthMuted)
                    .padding(.horizontal)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(POICategory.all) { category in
                        Button {
                            selectedCategory = category
                            Task { await loadPOIs(for: category) }
                        } label: {
                            VStack(spacing: 10) {
                                Text(category.emoji)
                                    .font(.system(size: 42))
                                Text(category.name)
                                    .font(.subheadline.bold())
                                    .foregroundColor(.earthCream)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 22)
                            .background(Color.earthCard)
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.earthGreen.opacity(0.2), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private func poiResultsList(for category: POICategory) -> some View {
        if isLoading {
            VStack(spacing: 12) {
                Spacer()
                ProgressView().tint(.earthGreen)
                Text("Finding \(category.name.lowercased()) nearby…")
                    .font(.subheadline).foregroundColor(.earthMuted)
                Spacer()
            }
        } else if results.isEmpty {
            VStack(spacing: 14) {
                Spacer()
                Text(category.emoji).font(.system(size: 52))
                Text("None found nearby")
                    .font(.headline).foregroundColor(.earthCream)
                Text("Try a different category or expand your walk radius.")
                    .font(.subheadline).foregroundColor(.earthMuted)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                Spacer()
            }
        } else {
            List {
                ForEach(results, id: \.self) { item in
                    NearbyPlaceRow(
                        item: item,
                        userLocation: resolvedLocation,
                        onWalkThere: { onSelect(item, false); dismiss() },
                        onLoopBack:  { onSelect(item, true);  dismiss() }
                    )
                    .listRowBackground(Color.earthCard)
                    .listRowSeparatorTint(Color.earthMuted.opacity(0.2))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func loadPOIs(for category: POICategory) async {
        isLoading = true
        defer { isLoading = false }

        if resolvedLocation == nil {
            resolvedLocation = await fetchLocation()
        }
        guard let location = resolvedLocation else { return }

        let region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 3_000,
            longitudinalMeters: 3_000
        )

        let request = MKLocalSearch.Request()
        request.region = region

        switch category.searchType {
        case .category(let mkCat):
            request.resultTypes = .pointOfInterest
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [mkCat])
        case .naturalLanguage(let query):
            request.naturalLanguageQuery = query
        }

        guard let response = try? await MKLocalSearch(request: request).start() else {
            results = []
            return
        }

        results = response.mapItems.sorted { a, b in
            location.distance(from: a.location) < location.distance(from: b.location)
        }
    }
}

// MARK: - POI Category Metadata

extension MKPointOfInterestCategory {
    var tagEmoji: String {
        switch self {
        case .park:          return "🌳"
        case .nationalPark:  return "🏞️"
        case .beach:         return "🏖️"
        case .cafe:          return "☕"
        case .bakery:        return "🥐"
        case .restaurant:    return "🍽️"
        case .museum:        return "🏛️"
        case .library:       return "📚"
        case .fitnessCenter: return "💪"
        case .brewery:       return "🍺"
        case .winery:        return "🍷"
        case .theater:       return "🎭"
        case .movieTheater:  return "🎬"
        case .zoo:           return "🦁"
        case .amusementPark: return "🎡"
        case .aquarium:      return "🐠"
        case .stadium:       return "🏟️"
        default:             return "📍"
        }
    }

    var tagLabel: String {
        switch self {
        case .park:          return "Park"
        case .nationalPark:  return "National Park"
        case .beach:         return "Beach"
        case .cafe:          return "Café"
        case .bakery:        return "Bakery"
        case .restaurant:    return "Restaurant"
        case .museum:        return "Museum"
        case .library:       return "Library"
        case .fitnessCenter: return "Gym"
        case .brewery:       return "Brewery"
        case .winery:        return "Winery"
        case .theater:       return "Theatre"
        case .movieTheater:  return "Cinema"
        case .zoo:           return "Zoo"
        case .amusementPark: return "Amusement Park"
        case .aquarium:      return "Aquarium"
        case .stadium:       return "Stadium"
        default:             return "Place"
        }
    }

    var tagColor: Color {
        switch self {
        case .park, .nationalPark, .beach, .zoo, .aquarium, .campground:
            return .earthGreen
        case .cafe, .bakery, .restaurant, .brewery, .winery, .foodMarket:
            return .earthOrange
        case .museum, .library, .theater, .movieTheater, .amusementPark, .university:
            return Color(red: 0.50, green: 0.30, blue: 0.80)
        case .fitnessCenter:
            return Color(red: 0.20, green: 0.50, blue: 0.90)
        default:
            return .earthMuted
        }
    }
}

// MARK: - Mini Route Shape

private struct MiniRouteShape: View {
    let origin: CLLocationCoordinate2D
    let destination: CLLocationCoordinate2D

    @State private var points: [CGPoint] = []

    var body: some View {
        Canvas { ctx, size in
            guard points.count > 1 else { return }
            var path = Path()
            path.move(to: points[0])
            for pt in points.dropFirst() { path.addLine(to: pt) }
            ctx.stroke(path, with: .color(.earthGreen), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            // Origin dot
            ctx.fill(Path(ellipseIn: CGRect(x: points[0].x - 4, y: points[0].y - 4, width: 8, height: 8)), with: .color(.earthGreen))
            // Destination dot
            if let last = points.last {
                ctx.fill(Path(ellipseIn: CGRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8)), with: .color(.earthOrange))
            }
        }
        .frame(width: 64, height: 64)
        .background(Color.earthCard)
        .cornerRadius(10)
        .task(id: "\(origin.latitude),\(destination.latitude)") { await fetchRoute() }
    }

    private func fetchRoute() async {
        let req = MKDirections.Request()
        req.source        = MKMapItem(location: origin.clLocation,      address: nil)
        req.destination   = MKMapItem(location: destination.clLocation, address: nil)
        req.transportType = .walking

        guard let route = try? await MKDirections(request: req).calculate().routes.first else { return }

        let pl = route.polyline
        let ptCount = pl.pointCount
        guard ptCount > 1 else { return }

        var raw: [CLLocationCoordinate2D] = []
        let mkPts = pl.points()
        for i in 0..<ptCount { raw.append(mkPts[i].coordinate) }

        let minLat = raw.map(\.latitude).min()!
        let maxLat = raw.map(\.latitude).max()!
        let minLon = raw.map(\.longitude).min()!
        let maxLon = raw.map(\.longitude).max()!
        let latSpan = max(maxLat - minLat, 1e-6)
        let lonSpan = max(maxLon - minLon, 1e-6)
        let pad: Double = 6
        let drawW: Double = 64 - pad * 2
        let drawH: Double = 64 - pad * 2

        points = raw.map { coord in
            CGPoint(
                x: pad + (coord.longitude - minLon) / lonSpan * drawW,
                y: pad + (1 - (coord.latitude - minLat) / latSpan) * drawH
            )
        }
    }
}

// MARK: - Nearby Place Row

private struct NearbyPlaceRow: View {
    let item: MKMapItem
    let userLocation: CLLocation?
    let onWalkThere: () -> Void
    let onLoopBack:  () -> Void

    @Environment(\.openURL) private var openURL

    private var subtitle: String? { item.address?.shortAddress ?? item.addressRepresentations?.cityName }

    private var distanceText: String? {
        guard let userLoc = userLocation else { return nil }
        let dist = userLoc.distance(from: item.location)
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: dist)
    }

    private var callURL: URL? {
        guard let phone = item.phoneNumber else { return nil }
        let cleaned = phone.filter { $0.isNumber || $0 == "+" }
        return cleaned.isEmpty ? nil : URL(string: "tel:\(cleaned)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill((item.pointOfInterestCategory?.tagColor ?? .earthGreen).opacity(0.15))
                        .frame(width: 44, height: 44)
                    Text(item.pointOfInterestCategory?.tagEmoji ?? "📍")
                        .font(.system(size: 20))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name ?? "Unknown place")
                        .foregroundColor(.earthCream)
                        .font(.body)
                    if let sub = subtitle {
                        Text(sub)
                            .foregroundColor(.earthMuted)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                    if let cat = item.pointOfInterestCategory {
                        Text("\(cat.tagEmoji) \(cat.tagLabel)")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(cat.tagColor.opacity(0.15))
                            .foregroundColor(cat.tagColor)
                            .cornerRadius(20)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    if let userLoc = userLocation {
                        MiniRouteShape(
                            origin: userLoc.coordinate,
                            destination: item.location.coordinate
                        )
                    }
                    if let dist = distanceText {
                        Text(dist)
                            .font(.caption)
                            .foregroundColor(.earthMuted)
                    }
                }
            }

            HStack(spacing: 8) {
                Button { onWalkThere() } label: {
                    Label("Walk There", systemImage: "arrow.right")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.earthGreen.opacity(0.15))
                        .foregroundColor(.earthGreen)
                        .cornerRadius(8)
                }
                Button { onLoopBack() } label: {
                    Label("& Back", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.earthCard)
                        .foregroundColor(.earthMuted)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.earthMuted.opacity(0.3), lineWidth: 1))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .contextMenu {
            if let url = callURL {
                Button { openURL(url) } label: {
                    Label("Call", systemImage: "phone.fill")
                }
            }
            if let url = item.url {
                Button { openURL(url) } label: {
                    Label("Visit Website", systemImage: "globe")
                }
            }
            Button {
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
            } label: {
                Label("Open in Apple Maps", systemImage: "map.fill")
            }
        }
    }
}

// MARK: - User Step Detail Sheet

struct UserStepDetailSheet: View {
    @ObservedObject var stepManager: StepManager
    @ObservedObject var historyStore: WalkHistoryStore
    @Environment(\.dismiss) private var dismiss

    private var recentSessions: [WalkSession] {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return historyStore.sessions.filter { $0.date >= cutoff }
    }

    private var weeklySteps: Int { recentSessions.reduce(0) { $0 + $1.estimatedSteps } }
    private var weeklyDistance: Double { recentSessions.reduce(0) { $0 + $1.totalDistance } }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        ZStack {
                            Circle()
                                .stroke(Color.earthMuted.opacity(0.15), lineWidth: 18)
                                .frame(width: 160, height: 160)
                            Circle()
                                .trim(from: 0, to: stepManager.progress)
                                .stroke(
                                    LinearGradient(colors: [.earthGreen, .earthOrange], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    style: StrokeStyle(lineWidth: 18, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                                .frame(width: 160, height: 160)
                                .animation(.easeInOut(duration: 0.6), value: stepManager.progress)
                            VStack(spacing: 2) {
                                Text("\(Int(stepManager.progress * 100))%")
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .foregroundColor(.earthCream)
                                Text("of goal")
                                    .font(.caption).foregroundColor(.earthMuted)
                            }
                        }
                        .padding(.top, 8)

                        HStack(spacing: 12) {
                            detailTile(value: stepManager.todaySteps.formatted(), label: "Steps Today", icon: "figure.walk", color: .earthGreen)
                            detailTile(value: stepManager.currentGoal.formatted(), label: "Daily Goal", icon: "flag.fill", color: .earthOrange, subtitle: {
                                let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
                                return "≈ \(f.string(fromDistance: Double(stepManager.currentGoal) * 0.762))"
                            }())
                        }
                        .padding(.horizontal)

                        HStack(spacing: 12) {
                            detailTile(value: stepManager.remainingSteps.formatted(), label: "Remaining", icon: "arrow.right.circle", color: .earthMuted)
                            let f = MKDistanceFormatter(); let _ = f.unitStyle = .abbreviated
                            detailTile(value: f.string(fromDistance: stepManager.remainingMeters), label: "Distance Left", icon: "ruler", color: .earthMuted)
                        }
                        .padding(.horizontal)

                        if !recentSessions.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Last 7 Days")
                                    .font(.headline).foregroundColor(.earthCream)
                                    .padding(.horizontal)

                                HStack(spacing: 12) {
                                    detailTile(value: weeklySteps.formatted(), label: "Steps", icon: "figure.walk", color: .earthGreen)
                                    let df = MKDistanceFormatter(); let _ = df.unitStyle = .abbreviated
                                    detailTile(value: df.string(fromDistance: weeklyDistance), label: "Distance", icon: "ruler", color: .earthGreen)
                                }
                                .padding(.horizontal)

                                ForEach(recentSessions.prefix(5)) { session in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(session.routeName).font(.subheadline).foregroundColor(.earthCream).lineLimit(1)
                                            Text(session.formattedDate).font(.caption).foregroundColor(.earthMuted)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(session.distanceText).font(.subheadline.bold()).foregroundColor(.earthGreen)
                                            Text("\(session.estimatedSteps.formatted()) steps").font(.caption).foregroundColor(.earthMuted)
                                        }
                                    }
                                    .padding(.horizontal).padding(.vertical, 8)
                                    .background(Color.earthCard).cornerRadius(10)
                                    .padding(.horizontal)
                                }
                            }
                        }
                        Spacer(minLength: 32)
                    }
                }
            }
            .navigationTitle("Your Progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.earthGreen)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func detailTile(value: String, label: String, icon: String, color: Color, subtitle: String? = nil) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(color).font(.title3)
            Text(value).font(.headline.bold()).foregroundColor(.earthCream)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundColor(.earthMuted)
            }
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .background(Color.earthCard).cornerRadius(14)
    }
}

// MARK: - Pet Detail Sheet

struct PetDetailSheet: View {
    let pet: PetProfile
    @ObservedObject var petStore: PetStore
    @ObservedObject var historyStore: WalkHistoryStore
    let onEdit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showEditor = false

    private var todaySteps: Int { petStore.todaySteps(for: pet, in: historyStore.sessions) }
    private var progress: Double { min(1.0, Double(todaySteps) / Double(max(1, pet.goalSteps))) }
    private var totalWalks: Int { petStore.totalWalks(for: pet, in: historyStore.sessions) }
    private var totalDist: Double { petStore.totalDistance(for: pet, in: historyStore.sessions) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        ZStack {
                            Circle()
                                .stroke(pet.accentColor.opacity(0.2), lineWidth: 18)
                                .frame(width: 160, height: 160)
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(pet.accentColor, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 160, height: 160)
                                .animation(.easeInOut(duration: 0.7), value: progress)
                            VStack(spacing: 4) {
                                Text(pet.displayEmoji).font(.system(size: 40))
                                Text("\(Int(progress * 100))%")
                                    .font(.system(size: 22, weight: .bold, design: .rounded))
                                    .foregroundColor(.earthCream)
                            }
                        }
                        .padding(.top, 8)

                        Text(pet.name)
                            .font(.title2.bold()).foregroundColor(.earthCream)
                        if let breed = pet.breed {
                            Text(breed).font(.subheadline).foregroundColor(.earthMuted)
                        }

                        HStack(spacing: 12) {
                            detailTile(value: todaySteps.formatted(), label: "Steps Today", icon: "figure.walk", color: pet.accentColor)
                            detailTile(value: pet.goalSteps.formatted(), label: "Daily Goal", icon: "flag.fill", color: .earthMuted)
                        }
                        .padding(.horizontal)

                        HStack(spacing: 12) {
                            detailTile(value: "\(totalWalks)", label: "Total Walks", icon: "clock.arrow.circlepath", color: .earthGreen)
                            let f = MKDistanceFormatter(); let _ = f.unitStyle = .abbreviated
                            detailTile(value: f.string(fromDistance: totalDist), label: "Total Distance", icon: "ruler", color: .earthGreen)
                        }
                        .padding(.horizontal)

                        Spacer(minLength: 32)
                    }
                }
            }
            .navigationTitle(pet.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Edit") { showEditor = true }.foregroundColor(.earthGreen)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.earthMuted)
                }
            }
            .sheet(isPresented: $showEditor) {
                PetEditorSheet(pet: pet, defaultGoal: pet.goalSteps) { updated in
                    petStore.update(updated)
                    dismiss()
                } onDelete: {
                    petStore.remove(id: pet.id)
                    dismiss()
                }
            }
        }
        .presentationDetents([.large])
    }

    private func detailTile(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(color).font(.title3)
            Text(value).font(.headline.bold()).foregroundColor(.earthCream)
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .background(Color.earthCard).cornerRadius(14)
    }
}

// MARK: - POI Emoji Loader

struct POIEmojiLoader: View {
    private let emojis = ["🌳", "🏖️", "🏛️", "📚", "☕", "🍽️", "🥐", "💪"]
    @State private var index   = 0
    @State private var opacity = 1.0

    var body: some View {
        Text(emojis[index])
            .font(.system(size: 18))
            .opacity(opacity)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(650))
                    withAnimation(.easeInOut(duration: 0.2)) { opacity = 0 }
                    try? await Task.sleep(for: .milliseconds(220))
                    index = (index + 1) % emojis.count
                    withAnimation(.easeInOut(duration: 0.2)) { opacity = 1 }
                }
            }
    }
}

