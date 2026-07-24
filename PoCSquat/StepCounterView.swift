import SwiftUI
import Combine
import HealthKit
import CoreMotion
import MapKit
import CoreLocation

// MARK: - Radius Preset

enum RadiusPreset: String, CaseIterable, Identifiable {
    case nearby   = "Nearby"
    case close    = "Close"
    case moderate = "Moderate"
    case far      = "Far"
    case veryFar  = "Very Far"

    var id: String { rawValue }

    var meters: Double {
        switch self {
        case .nearby:   return 200
        case .close:    return 500
        case .moderate: return 1_000
        case .far:      return 2_000
        case .veryFar:  return 4_000
        }
    }

    var subtitle: String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: meters)
    }
}

// MARK: - Step Manager

@MainActor
final class StepManager: ObservableObject {
    @Published var todaySteps: Int = 0
    @Published var trackingMode: TrackingMode = .healthKit
    @Published var isLoading = false
    @Published var permissionDenied = false

    @Published var dailyGoal: Int = 10_000 {
        didSet { UserDefaults.standard.set(dailyGoal, forKey: UDKey.dailyGoal) }
    }
    @Published var useCustomSchedule: Bool = false {
        didSet { UserDefaults.standard.set(useCustomSchedule, forKey: UDKey.useCustomSchedule) }
    }
    @Published var weekdayGoals: [Int: Int] = [:] {
        didSet { saveWeekdayGoals() }
    }

    enum TrackingMode: String, CaseIterable, Identifiable {
        case healthKit = "Apple Health"
        case appOnly   = "App Only"
        var id: String { rawValue }
    }

    private enum UDKey {
        static let dailyGoal          = "stepDailyGoal"
        static let useCustomSchedule  = "stepUseCustomSchedule"
        static let weekdayGoals       = "stepWeekdayGoals"
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

        suggestedRoutes = routes
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
        req.source        = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        req.destination   = destination
        req.transportType = .walking

        guard let route = try? await MKDirections(request: req).calculate().routes.first else {
            locationError = "No walking route found to \(destination.name ?? "that destination")."
            return
        }

        suggestedRoutes = [SuggestedRoute(
            polyline:       route.polyline,
            openInMapsItem: destination,
            isLoop:         false,
            bearing:        location.coordinate.bearing(to: destination.placemark.coordinate),
            totalDistance:  route.distance,
            totalTime:      route.expectedTravelTime,
            lapCount:       1,
            label:          destination.name
        )]
    }

    // MARK: - Loop Routes

    private func generateLoopRoutes(from start: CLLocation, targetMeters: Double, radius: Double) async -> [SuggestedRoute] {
        var routes: [SuggestedRoute] = []
        for bearing in [0.0, 120.0, 240.0] {
            if let r = await makeLoopRoute(from: start, bearing: bearing, targetMeters: targetMeters, radius: radius) {
                routes.append(r)
            }
        }
        return routes
    }

    /// Triangular loop: Start → A → B → Start.
    /// Waypoints are placed at `radius × 0.75` so the entire circuit stays within the chosen radius.
    /// Lap count is auto-calculated from actual MKDirections distance so the total meets targetMeters.
    private func makeLoopRoute(from start: CLLocation,
                               bearing: Double,
                               targetMeters: Double,
                               radius: Double) async -> SuggestedRoute? {
        let legDist = radius * 0.75
        let coordA  = start.coordinate.offset(bearing: bearing,       meters: legDist)
        let coordB  = start.coordinate.offset(bearing: bearing + 120, meters: legDist)

        guard let leg1 = await walkingRoute(from: start.coordinate, to: coordA),
              let leg2 = await walkingRoute(from: coordA,            to: coordB),
              let leg3 = await walkingRoute(from: coordB,            to: start.coordinate) else { return nil }

        let perLapDist = leg1.distance + leg2.distance + leg3.distance
        let perLapTime = leg1.expectedTravelTime + leg2.expectedTravelTime + leg3.expectedTravelTime
        let laps       = max(1, min(8, Int(ceil(targetMeters / max(perLapDist, 1)))))

        return SuggestedRoute(
            polyline:       combinePolylines([leg1.polyline, leg2.polyline, leg3.polyline]),
            openInMapsItem: MKMapItem(placemark: MKPlacemark(coordinate: coordA)),
            isLoop:         true,
            bearing:        bearing,
            totalDistance:  perLapDist * Double(laps),
            totalTime:      perLapTime * Double(laps),
            lapCount:       laps,
            label:          nil
        )
    }

    // MARK: - Fallback

    private func makeFallbackRoute(from start: CLLocation, targetMeters: Double) async -> SuggestedRoute? {
        let perLapTarget = 400.0
        let laps   = max(1, min(8, Int(ceil(targetMeters / perLapTarget))))
        let coordA = start.coordinate.offset(bearing: 0,   meters: 150)
        let coordB = start.coordinate.offset(bearing: 120, meters: 150)

        guard let leg1 = await walkingRoute(from: start.coordinate, to: coordA),
              let leg2 = await walkingRoute(from: coordA,            to: coordB),
              let leg3 = await walkingRoute(from: coordB,            to: start.coordinate) else { return nil }

        let perLapDist = leg1.distance + leg2.distance + leg3.distance
        let perLapTime = leg1.expectedTravelTime + leg2.expectedTravelTime + leg3.expectedTravelTime

        return SuggestedRoute(
            polyline:       combinePolylines([leg1.polyline, leg2.polyline, leg3.polyline]),
            openInMapsItem: MKMapItem(placemark: MKPlacemark(coordinate: coordA)),
            isLoop:         true,
            bearing:        0,
            totalDistance:  perLapDist * Double(laps),
            totalTime:      perLapTime * Double(laps),
            lapCount:       laps,
            label:          "Neighbourhood Loop"
        )
    }

    // MARK: - Helpers

    private func walkingRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> MKRoute? {
        let req = MKDirections.Request()
        req.source        = MKMapItem(placemark: MKPlacemark(coordinate: from))
        req.destination   = MKMapItem(placemark: MKPlacemark(coordinate: to))
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
}

// MARK: - Step Counter View

struct StepCounterView: View {
    @StateObject private var stepManager  = StepManager()
    @StateObject private var routeManager = RouteManager()
    @StateObject private var routeStore   = CustomRouteStore()

    @State private var selectedRadius: RadiusPreset = .moderate
    @State private var selectedRoute: SuggestedRoute?
    @State private var showGoalSheet         = false
    @State private var showScheduleSheet     = false
    @State private var showMyRoutes          = false
    @State private var showDestinationSearch = false
    @State private var routeWeather: RouteWeather?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                progressSection.padding(.top, 8)
                settingsSection
                if stepManager.remainingSteps > 0 { routeFindSection }
                routeResultsSection
            }
            .padding(.bottom, 40)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Step Counter")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await stepManager.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.green)
                }
            }
        }
        .task { await stepManager.initialize() }
        .onAppear { if !routeManager.isGenerating { clearRoutes() } }
        .navigationDestination(isPresented: $showMyRoutes) {
            CustomRoutesListView(store: routeStore)
        }
        .onChange(of: stepManager.currentGoal) { _, _ in clearRoutes() }
        .onChange(of: selectedRadius) { _, _ in clearRoutes() }
        .sheet(isPresented: $showGoalSheet)     { GoalEditorSheet(stepManager: stepManager) }
        .sheet(isPresented: $showScheduleSheet) { WeeklyScheduleSheet(stepManager: stepManager) }
        .sheet(isPresented: $showDestinationSearch) {
            DestinationSearchSheet(userLocation: routeManager.lastLocation) { destination in
                clearRoutes()
                Task {
                    await routeManager.generateDestinationRoute(to: destination)
                    if let loc = routeManager.lastLocation, !routeManager.suggestedRoutes.isEmpty {
                        routeWeather = await RouteWeatherService.shared.fetchWeather(for: loc.coordinate)
                    }
                }
            }
        }
    }

    private func clearRoutes() {
        routeManager.suggestedRoutes = []
        routeManager.locationError   = nil
        selectedRoute = nil
        routeWeather  = nil
    }

    // MARK: Progress Ring

    private var progressSection: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.green.opacity(0.12), lineWidth: 18)
                    .frame(width: 190, height: 190)
                Circle()
                    .trim(from: 0, to: stepManager.progress)
                    .stroke(
                        LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 18, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 190, height: 190)
                    .animation(.easeInOut(duration: 0.6), value: stepManager.progress)

                VStack(spacing: 2) {
                    Text(stepManager.todaySteps.formatted())
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("/ \(stepManager.currentGoal.formatted())")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.45))
                }
            }

            if stepManager.todaySteps >= stepManager.currentGoal {
                Label("Goal Complete!", systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundColor(.green)
            } else {
                Text("\(stepManager.remainingSteps.formatted()) remaining · ~\(String(format: "%.1f", stepManager.remainingMeters / 1000)) km to go")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .padding()
    }

    // MARK: Settings

    private var settingsSection: some View {
        VStack(spacing: 1) {
            row {
                Text("Daily Goal").foregroundColor(.white)
                Spacer()
                Text("\(stepManager.currentGoal.formatted()) steps").foregroundColor(.green)
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.white.opacity(0.3))
            }
            .contentShape(Rectangle())
            .onTapGesture { showGoalSheet = true }

            row {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom Weekly Schedule").foregroundColor(.white)
                    Text("Set different goals per day of week")
                        .font(.caption).foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                if stepManager.useCustomSchedule {
                    Button("Edit") { showScheduleSheet = true }
                        .font(.caption).foregroundColor(.green).padding(.trailing, 8)
                }
                Toggle("", isOn: $stepManager.useCustomSchedule).labelsHidden().tint(.green)
            }

            row {
                Text("Data Source").foregroundColor(.white)
                Spacer()
                Picker("", selection: $stepManager.trackingMode) {
                    ForEach(StepManager.TrackingMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(.green)
                .onChange(of: stepManager.trackingMode) { _, m in stepManager.switchTrackingMode(to: m) }
            }

            Button { showMyRoutes = true } label: {
                HStack {
                    Label("My Saved Routes", systemImage: "bookmark.map").foregroundColor(.white)
                    Spacer()
                    if !routeStore.routes.isEmpty {
                        Text("\(routeStore.routes.count)")
                            .font(.caption).foregroundColor(.green).padding(.trailing, 4)
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.white.opacity(0.3))
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
        }
        .background(Color.white.opacity(0.06))
        .cornerRadius(16)
        .padding(.horizontal)
    }

    // MARK: Find Routes

    private var routeFindSection: some View {
        VStack(spacing: 12) {
            // Radius chips control how far from your start point the loop will stray
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RadiusPreset.allCases) { preset in
                        Button { selectedRadius = preset } label: {
                            VStack(spacing: 2) {
                                Text(preset.rawValue)
                                    .font(.caption.bold())
                                Text(preset.subtitle)
                                    .font(.system(size: 10))
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(selectedRadius == preset ? Color.green : Color.white.opacity(0.1))
                            .foregroundColor(selectedRadius == preset ? .black : .white)
                            .cornerRadius(20)
                        }
                    }
                }
                .padding(.horizontal)
            }

            // Primary action: loop route
            Button {
                clearRoutes()
                Task {
                    await routeManager.generateRoutes(
                        remainingMeters: stepManager.remainingMeters,
                        radius: selectedRadius.meters
                    )
                    if let loc = routeManager.lastLocation, !routeManager.suggestedRoutes.isEmpty {
                        routeWeather = await RouteWeatherService.shared.fetchWeather(for: loc.coordinate)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if routeManager.isGenerating { ProgressView().tint(.black) }
                    else { Image(systemName: "map.fill") }
                    Text(routeManager.isGenerating ? "Finding routes..." : "Suggest a Route")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .foregroundColor(.black)
                .cornerRadius(14)
                .padding(.horizontal)
            }
            .disabled(routeManager.isGenerating)

            // Secondary action: walk to a specific destination (de-emphasised)
            Button { showDestinationSearch = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                    Text("Walk to a destination")
                }
                .font(.caption)
                .foregroundColor(.white.opacity(0.4))
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

                ForEach(routeManager.suggestedRoutes) { route in
                    RouteCard(route: route, isSelected: selectedRoute?.id == route.id)
                        .padding(.horizontal)
                        .onTapGesture { selectedRoute = route }
                }

                if let selected = selectedRoute {
                    Button { selected.openInAppleMaps() } label: {
                        Label(
                            selected.isLoop ? "Navigate to First Waypoint" : "Open in Apple Maps",
                            systemImage: "arrow.triangle.turn.up.right.circle.fill"
                        )
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.blue).foregroundColor(.white)
                        .cornerRadius(14).padding(.horizontal)
                    }
                }
            }
        }
    }

    // MARK: Helper

    private func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack { content() }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .overlay(Rectangle().frame(height: 0.5).foregroundColor(.white.opacity(0.08)), alignment: .bottom)
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
        map.overrideUserInterfaceStyle = .dark
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)

        var coords: [CLLocationCoordinate2D] = []
        for route in routes {
            let pl = route.polyline
            pl.title = route.id.uuidString
            map.addOverlay(pl)
            let pts = pl.points()
            for i in 0..<pl.pointCount { coords.append(pts[i].coordinate) }
        }
        if let user = map.userLocation.location { coords.append(user.coordinate) }

        if !coords.isEmpty {
            let rect = coords.reduce(MKMapRect.null) { r, c in
                let p = MKMapPoint(c); return r.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
            }
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50), animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RouteMapView
        init(_ p: RouteMapView) { parent = p }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let pl = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r          = MKPolylineRenderer(polyline: pl)
            let isSelected = parent.routes.first { $0.id.uuidString == pl.title }?.id == parent.selectedRoute?.id
            r.strokeColor  = isSelected ? .systemBlue : .systemGreen
            r.lineWidth    = isSelected ? 5 : 3
            r.alpha        = isSelected ? 1.0 : 0.55
            return r
        }
    }
}

// MARK: - Route Card

struct RouteCard: View {
    let route: SuggestedRoute
    let isSelected: Bool

    private var cardIcon: String {
        if route.label != nil { return "arrow.triangle.2.circlepath" }
        switch route.directionName {
        case "North":     return "arrow.up"
        case "Northeast": return "arrow.up.right"
        case "East":      return "arrow.right"
        case "Southeast": return "arrow.down.right"
        case "South":     return "arrow.down"
        case "Southwest": return "arrow.down.left"
        case "West":      return "arrow.left"
        default:          return "arrow.up.left"
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.blue.opacity(0.2) : Color.white.opacity(0.08))
                    .frame(width: 50, height: 50)
                Image(systemName: cardIcon)
                    .foregroundColor(isSelected ? .blue : .white.opacity(0.7))
                    .font(.title3)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(route.label ?? "\(route.directionName) \(route.isLoop ? "loop" : "route")")
                    .font(.headline).foregroundColor(.white)
                HStack(spacing: 14) {
                    Label(route.distanceText, systemImage: "ruler")
                    Label(route.timeText,     systemImage: "clock")
                }
                .font(.caption).foregroundColor(.white.opacity(0.5))
                HStack(spacing: 8) {
                    Text("~\(route.estimatedSteps.formatted()) steps")
                        .font(.caption).foregroundColor(.green.opacity(0.8))
                    DifficultyBadge(difficulty: .fromDistance(route.perLapDistance), compact: true)
                    if route.lapCount > 1 {
                        Text("×\(route.lapCount) laps")
                            .font(.caption.bold()).foregroundColor(.mint)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.mint.opacity(0.15))
                            .cornerRadius(20)
                    }
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.blue)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isSelected ? Color.blue.opacity(0.1) : Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isSelected ? Color.blue.opacity(0.4) : Color.clear, lineWidth: 1)
                )
        )
    }
}

// MARK: - Goal Editor Sheet

struct GoalEditorSheet: View {
    @ObservedObject var stepManager: StepManager
    @Environment(\.dismiss) private var dismiss
    @State private var goalText = ""

    private let presets = [5_000, 7_500, 10_000, 12_500, 15_000, 20_000]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 28) {
                    Text("Set your daily step goal")
                        .font(.subheadline).foregroundColor(.white.opacity(0.5))

                    TextField("Steps", text: $goalText)
                        .keyboardType(.numberPad)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                        .onAppear { goalText = "\(stepManager.dailyGoal)" }

                    let columns = [GridItem(.adaptive(minimum: 70))]
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(presets, id: \.self) { p in
                            Button {
                                goalText = "\(p)"
                                stepManager.dailyGoal = p
                            } label: {
                                Text(p >= 10_000 ? "\(p / 1000)K" : "\(p / 1000).5K")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(stepManager.dailyGoal == p ? Color.green : Color.white.opacity(0.1))
                                    .foregroundColor(stepManager.dailyGoal == p ? .black : .white)
                                    .cornerRadius(20)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(28)
            }
            .navigationTitle("Daily Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let v = Int(goalText), v > 0 { stepManager.dailyGoal = v }
                        dismiss()
                    }.foregroundColor(.green)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Weekly Schedule Sheet

struct WeeklyScheduleSheet: View {
    @ObservedObject var stepManager: StepManager
    @Environment(\.dismiss) private var dismiss

    private let days: [(Int, String)] = [
        (2, "Monday"), (3, "Tuesday"), (4, "Wednesday"),
        (5, "Thursday"), (6, "Friday"), (7, "Saturday"), (1, "Sunday")
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    Section {
                        ForEach(days, id: \.0) { (wd, name) in
                            HStack {
                                Text(name).foregroundColor(.white)
                                Spacer()
                                TextField("steps", value: Binding(
                                    get: { stepManager.weekdayGoals[wd] ?? stepManager.dailyGoal },
                                    set: { stepManager.weekdayGoals[wd] = $0 }
                                ), format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .foregroundColor(.green)
                                .frame(width: 90)
                            }
                            .listRowBackground(Color.white.opacity(0.07))
                        }
                    } header: {
                        Text("Steps per day (leave blank to use your default goal)")
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Weekly Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.green)
                }
            }
        }
    }
}

// MARK: - CLLocationCoordinate2D extensions

extension CLLocationCoordinate2D {
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
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    // Search field
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.white.opacity(0.4))
                        TextField("Café, park, gym, landmark...", text: $searchText)
                            .foregroundColor(.white)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.white.opacity(0.35))
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(12)
                    .padding()

                    if searchText.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 44))
                                .foregroundColor(.white.opacity(0.15))
                            Text("Search for anywhere you'd like to walk — a café, park, gym, landmark, or friend's street.")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white.opacity(0.35))
                                .padding(.horizontal, 32)
                        }
                        Spacer()
                    } else if isSearching {
                        Spacer()
                        ProgressView().tint(.green)
                        Spacer()
                    } else if results.isEmpty {
                        Spacer()
                        Text("No places found")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.35))
                        Spacer()
                    } else {
                        List {
                            ForEach(results) { result in
                                SearchResultRow(result: result, userLocation: userLocation) {
                                    onSelect(result.mapItem)
                                    dismiss()
                                }
                                .listRowBackground(Color.white.opacity(0.05))
                                .listRowSeparatorTint(.white.opacity(0.08))
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("Walk to a Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.white.opacity(0.6))
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

    private var subtitle: String? { result.mapItem.placemark.thoroughfare ?? result.mapItem.placemark.locality }

    private var distanceText: String? {
        guard let userLoc = userLocation else { return nil }
        let coord = result.mapItem.placemark.coordinate
        let dist = userLoc.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: dist)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundColor(.green.opacity(0.8))
                    .font(.title3)

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.mapItem.name ?? "Unknown place")
                        .foregroundColor(.white)
                        .font(.body)
                    if let sub = subtitle {
                        Text(sub)
                            .foregroundColor(.white.opacity(0.4))
                            .font(.caption)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let dist = distanceText {
                    Text(dist)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.35))
                }
            }
            .padding(.vertical, 4)
        }
    }
}
