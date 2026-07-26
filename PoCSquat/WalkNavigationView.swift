import SwiftUI
import Combine
import MapKit
import CoreLocation
import UserNotifications
import UIKit

// MARK: - Walk Session

struct WalkSession: Identifiable, Codable {
    let id: UUID
    let routeName: String
    let date: Date
    let elapsedTime: TimeInterval
    let totalDistance: Double
    let waypoints: [WaypointCoord]
    let lapCount: Int
    let isLoop: Bool
    var activePetIds: [UUID]
    var activityType: String  // "walking" or "cycling"; decoded with fallback for existing sessions
    var notes: String         // user notes per session; empty string for existing sessions

    init(id: UUID, routeName: String, date: Date, elapsedTime: TimeInterval,
         totalDistance: Double, waypoints: [WaypointCoord], lapCount: Int,
         isLoop: Bool, activePetIds: [UUID] = [], activityType: String = "walking", notes: String = "") {
        self.id = id; self.routeName = routeName; self.date = date
        self.elapsedTime = elapsedTime; self.totalDistance = totalDistance
        self.waypoints = waypoints; self.lapCount = lapCount
        self.isLoop = isLoop; self.activePetIds = activePetIds
        self.activityType = activityType; self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(UUID.self,            forKey: .id)
        routeName     = try c.decode(String.self,          forKey: .routeName)
        date          = try c.decode(Date.self,            forKey: .date)
        elapsedTime   = try c.decode(TimeInterval.self,    forKey: .elapsedTime)
        totalDistance = try c.decode(Double.self,          forKey: .totalDistance)
        waypoints     = try c.decode([WaypointCoord].self, forKey: .waypoints)
        lapCount      = try c.decode(Int.self,             forKey: .lapCount)
        isLoop        = try c.decode(Bool.self,            forKey: .isLoop)
        activePetIds  = (try? c.decode([UUID].self,        forKey: .activePetIds)) ?? []
        activityType  = (try? c.decode(String.self,        forKey: .activityType)) ?? "walking"
        notes         = (try? c.decode(String.self,        forKey: .notes))        ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, routeName, date, elapsedTime, totalDistance, waypoints, lapCount, isLoop, activePetIds, activityType, notes
    }

    var estimatedSteps: Int { Int(totalDistance / 0.762) }

    var distanceText: String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: totalDistance)
    }

    var timeText: String {
        let s = Int(elapsedTime); let m = s / 60
        return m < 60 ? "\(m)m \(s % 60)s" : "\(m / 60)h \(m % 60)m"
    }

    var formattedDate: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }

    func toNavigableRoute() -> NavigableRoute {
        NavigableRoute(
            name: routeName,
            waypoints: waypoints.map { $0.clCoordinate },
            lapCount: lapCount,
            isLoop: isLoop,
            totalDistance: totalDistance,
            activityMode: ActivityMode(rawValue: activityType) ?? .walking
        )
    }
}

// MARK: - Walk History Store

@MainActor
final class WalkHistoryStore: ObservableObject {
    @Published var sessions: [WalkSession] = []
    private let udKey = "walkHistory_v1"

    init() { load() }

    func add(_ session: WalkSession) {
        sessions.insert(session, at: 0)
        persist()
    }

    func addAll(_ newSessions: [WalkSession]) {
        sessions.insert(contentsOf: newSessions.sorted { $0.date > $1.date }, at: 0)
        persist()
    }

    func delete(at offsets: IndexSet) {
        sessions.remove(atOffsets: offsets)
        persist()
    }

    func updateNotes(id: UUID, notes: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].notes = notes
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: udKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([WalkSession].self, from: data) else { return }
        sessions = decoded
    }
}

// MARK: - Navigable Route

struct NavigableRoute: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let waypoints: [CLLocationCoordinate2D]
    let lapCount: Int
    let isLoop: Bool
    let totalDistance: Double
    var isCustomRoute: Bool = false
    var activityMode:  ActivityMode = .walking

    static func == (l: NavigableRoute, r: NavigableRoute) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Navigation Session Manager

// waypoints[0] is the user's starting position.
// Navigation begins at index 1. For loops, returning to index 0 (start) completes a lap.
@MainActor
final class NavigationSessionManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var currentWaypointIndex = 1
    @Published var currentLap = 1
    @Published var distanceToNextWaypoint: Double = 0
    @Published var totalDistanceCovered: Double = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var isCompleted = false
    @Published var splitTimes: [(label: String, elapsed: TimeInterval)] = []

    var onCheckpointReached: ((String) -> Void)?

    private let route: NavigableRoute
    private let locationManager = CLLocationManager()
    private var startTime = Date()
    private var timer: Timer?
    private var lastLocation: CLLocation?
    private let arrivalRadius = 30.0
    private var triggeredCheckpoints: Set<Int> = []
    private let checkpointFractions = [0.2, 0.4, 0.6, 0.8]
    private var workoutWriter: HealthWorkoutWriter?

    init(route: NavigableRoute) {
        self.route = route
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 5
    }

    func start() {
        startTime = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        locationManager.startUpdatingLocation()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.elapsedTime = Date().timeIntervalSince(self.startTime)
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

    func stop() {
        locationManager.stopUpdatingLocation()
        timer?.invalidate()
        timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // Finalises the HealthKit workout after the session is saved to local history.
    func finishWorkoutSession() async {
        guard let writer = workoutWriter else { return }
        workoutWriter = nil
        await writer.finish(totalDistanceMeters: totalDistanceCovered, endDate: Date())
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

    var completedSession: WalkSession {
        WalkSession(
            id: UUID(),
            routeName: route.name,
            date: startTime,
            elapsedTime: elapsedTime,
            totalDistance: totalDistanceCovered,
            waypoints: route.waypoints.map { WaypointCoord($0) },
            lapCount: route.lapCount,
            isLoop: route.isLoop,
            activityType: route.activityMode.rawValue
        )
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy < 50 else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let last = self.lastLocation {
                let delta = loc.distance(from: last)
                if delta < 100 { self.totalDistanceCovered += delta }
            }
            self.lastLocation = loc
            self.workoutWriter?.addLocations(locations)
            self.checkArrival(at: loc)
            if !self.route.isCustomRoute { self.checkDistanceCheckpoints() }
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
                if currentLap > route.lapCount { finish() }
            }
        } else if currentWaypointIndex >= route.waypoints.count {
            finish()
        }
    }

    private func finish() {
        isCompleted = true
        stop()
    }
}

// MARK: - Navigation Map

struct NavigationMapView: UIViewRepresentable {
    let route: NavigableRoute
    let computedLegs: [MKRoute]
    let currentWaypointIndex: Int
    let checkpointsEnabled: Bool

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.userTrackingMode = .follow
        map.overrideUserInterfaceStyle = .unspecified
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
                marker.markerTintColor = idx < currentWaypointIndex ? .systemGray3 : (title == "Start" ? .brandOrange : .brandGreen)
                marker.alpha = idx < currentWaypointIndex ? 0.45 : 1.0
            }
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
        let finish = NavCheckpointCircle(center: allCoords.last!, radius: 24)
        finish.isFinish = true
        map.addOverlay(finish, level: .aboveRoads)
    }

    static func coordAlong(_ polyline: MKPolyline, fraction: Double) -> CLLocationCoordinate2D? {
        let n = polyline.pointCount
        guard n > 1, fraction > 0 else { return polyline.points()[0].coordinate }
        if fraction >= 1 { return polyline.points()[n - 1].coordinate }
        let pts = polyline.points()
        var total = 0.0
        var lens = [Double]()
        for i in 0..<n - 1 {
            let a = CLLocation(latitude: pts[i].coordinate.latitude, longitude: pts[i].coordinate.longitude)
            let b = CLLocation(latitude: pts[i + 1].coordinate.latitude, longitude: pts[i + 1].coordinate.longitude)
            lens.append(a.distance(from: b)); total += lens.last!
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MKMapViewDelegate {
        var hasAddedLegs = false
        var lastWaypointIndex = 0
        var hasAddedCheckpoints = false

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
            r.strokeColor = .brandGreen
            r.lineWidth = 5
            r.alpha = 0.85
            return r
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let ann = annotation as? MKPointAnnotation else { return nil }
            let view = MKMarkerAnnotationView(annotation: ann, reuseIdentifier: "nav")
            view.glyphText = ann.title ?? ""
            view.markerTintColor = ann.title == "Start" ? .brandOrange : .brandGreen
            view.canShowCallout = false
            return view
        }
    }
}

// MARK: - Walk Navigation View

struct WalkNavigationView: View {
    let route: NavigableRoute
    @ObservedObject var historyStore: WalkHistoryStore
    @EnvironmentObject var petStore: PetStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var session: NavigationSessionManager
    @StateObject private var localRouteStore = CustomRouteStore()
    @State private var showComplete            = false
    @State private var showStopAlert           = false
    @State private var waterBreakEnabled       = false
    @State private var checkpointsEnabled      = false
    @State private var scheduledBreakCount     = 0
    @State private var showHeatBanner          = false
    @State private var walkWeather: RouteWeather? = nil
    @State private var petCompletions: [PetCompletion] = []
    @State private var completedSession: WalkSession?
    @State private var completedPetNames: [String] = []
    @State private var computedLegs: [MKRoute] = []
    @State private var everActivePetIds: Set<UUID> = []

    init(route: NavigableRoute, historyStore: WalkHistoryStore) {
        self.route = route
        self.historyStore = historyStore
        _session = StateObject(wrappedValue: NavigationSessionManager(route: route))
    }

    var body: some View {
        mapContent
            .toolbar(.hidden, for: .navigationBar)
            .task { await startWalk() }
            .onDisappear { session.stop(); cancelWaterBreakReminders() }
            .onChange(of: checkpointsEnabled) { _, enabled in handleCheckpointToggle(enabled) }
            .onChange(of: session.isCompleted) { _, completed in
                guard completed else { return }
                handleWalkComplete()
            }
            .onChange(of: petStore.activePets.count) { _, count in handlePetCountChange(count) }
            .onChange(of: waterBreakEnabled) { _, enabled in
                guard enabled else { return }
                Task { await scheduleWaterBreakReminders() }
            }
            .alert("End Walk?", isPresented: $showStopAlert) {
                Button("Save Route & Exit") { saveCurrentRoute(); session.stop(); dismiss() }
                Button("Exit", role: .destructive) { session.stop(); dismiss() }
                Button("Keep Walking", role: .cancel) {}
            } message: {
                Text("Save this route to My Routes so you can walk it again later?")
            }
    }

    @ViewBuilder private var mapContent: some View {
        ZStack(alignment: .bottom) {
            NavigationMapView(route: route, computedLegs: computedLegs, currentWaypointIndex: session.currentWaypointIndex, checkpointsEnabled: checkpointsEnabled)
                .ignoresSafeArea()
            hudPanel
        }
        .fullScreenCover(isPresented: $showComplete, onDismiss: { dismiss() }) {
            if let s = completedSession {
                WalkCompleteView(
                    session: s,
                    activePetNames: completedPetNames,
                    petCompletions: petCompletions,
                    splits: session.splitTimes,
                    onDismiss: { showComplete = false }
                )
            }
        }
    }

    private func handleCheckpointToggle(_ enabled: Bool) {
        session.onCheckpointReached = enabled ? { [self] lbl in self.handleCheckpoint(lbl) } : nil
    }

    private func startWalk() async {
        everActivePetIds = Set(petStore.activePetIds)
        session.start()
        session.onCheckpointReached = checkpointsEnabled ? { [self] lbl in self.handleCheckpoint(lbl) } : nil
        computedLegs = await computeWalkingLegs()
        if let firstWaypoint = route.waypoints.first {
            walkWeather = await RouteWeatherService.shared.fetchWeather(for: firstWaypoint)
        }
        if let w = walkWeather, w.temperatureCelsius > 27, !petStore.activePets.isEmpty {
            showHeatBanner = true
        }
    }

    private func handleWalkComplete() {
        var s = session.completedSession
        s.activePetIds = Array(everActivePetIds)
        historyStore.add(s)
        Task { await session.finishWorkoutSession() }
        completedSession = s
        completedPetNames = petNamesFor(ids: s.activePetIds)
        petCompletions = petStore.activePets.map { pet in
            let todaySteps = petStore.todaySteps(for: pet, in: historyStore.sessions)
            return PetCompletion(pet: pet, progress: min(1.0, Double(todaySteps) / Double(max(1, pet.goalSteps))))
        }
        showComplete = true
    }

    private func handlePetCountChange(_ count: Int) {
        if count == 0 {
            showHeatBanner = false
            if waterBreakEnabled { cancelWaterBreakReminders(); waterBreakEnabled = false }
        } else if let w = walkWeather, w.temperatureCelsius > 27 {
            showHeatBanner = true
        }
    }

    private func handleCheckpoint(_ label: String) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        if checkpointsEnabled {
            let content = UNMutableNotificationContent()
            content.title = "Checkpoint \(label) 🎯"
            content.body = "Keep it up!"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
            let req = UNNotificationRequest(identifier: "checkpoint-\(label)", content: content, trigger: trigger)
            Task { try? await UNUserNotificationCenter.current().add(req) }
        }
    }

    private var hudPanel: some View {
        VStack(spacing: 0) {
            if showHeatBanner {
                HeatAdvisoryBanner(
                    intervalMinutes: waterBreakIntervalMinutes,
                    onEnableWaterBreaks: {
                        waterBreakEnabled = true
                        showHeatBanner = false
                    },
                    onDismiss: { showHeatBanner = false }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color.earthMuted.opacity(0.25))
                    .transition(.opacity)
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: route.activityMode.icon)
                            .font(.subheadline).foregroundColor(.earthGreen)
                        Text(route.name)
                            .font(.headline).foregroundColor(.earthCream).lineLimit(1)
                    }
                    Text(session.progressText)
                        .font(.subheadline).foregroundColor(.earthGreen)
                }
                Spacer()
                if !petStore.pets.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(petStore.pets) { pet in
                            Button {
                                let willActivate = !pet.isActiveOnWalk
                                petStore.setActive(pet.id, active: willActivate)
                                if willActivate { everActivePetIds.insert(pet.id) }
                            } label: {
                                Text(pet.displayEmoji)
                                    .font(.title2)
                                    .opacity(pet.isActiveOnWalk ? 1.0 : 0.3)
                                    .scaleEffect(pet.isActiveOnWalk ? 1.0 : 0.85)
                                    .animation(.spring(duration: 0.2), value: pet.isActiveOnWalk)
                            }
                        }
                    }
                    .padding(.trailing, 6)
                }
                Button {
                    waterBreakEnabled.toggle()
                    if !waterBreakEnabled { cancelWaterBreakReminders() }
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: waterBreakEnabled ? "drop.fill" : "drop")
                            .font(.title2)
                            .foregroundColor(waterBreakEnabled ? Color(red: 0.28, green: 0.49, blue: 0.84) : .earthMuted)
                        if waterBreakEnabled {
                            Text("/ \(waterBreakIntervalMinutes)m")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Color(red: 0.28, green: 0.49, blue: 0.84))
                        }
                    }
                    .animation(.spring(duration: 0.2), value: waterBreakEnabled)
                }
                .padding(.trailing, 10)
                Button {
                    checkpointsEnabled.toggle()
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: checkpointsEnabled ? "flag.fill" : "flag")
                            .font(.title2)
                            .foregroundColor(checkpointsEnabled ? Color(red: 0.35, green: 0.22, blue: 0.72) : .earthMuted)
                        if checkpointsEnabled {
                            Text(route.isCustomRoute ? "WP" : "20%")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.72))
                        }
                    }
                    .animation(.spring(duration: 0.2), value: checkpointsEnabled)
                }
                .padding(.trailing, 10)
                Button { showStopAlert = true } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title)
                        .foregroundColor(.red.opacity(0.85))
                }
            }
            .padding(.horizontal, 20).padding(.top, 20)

            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.earthMuted.opacity(0.25))
                .padding(.top, 14)

            HStack(spacing: 0) {
                hudStat(value: distText(session.distanceToNextWaypoint), label: "to next", icon: "location.fill")
                Rectangle().frame(width: 0.5, height: 36).foregroundColor(Color.earthMuted.opacity(0.25))
                hudStat(value: distText(session.remainingDistance), label: "remaining", icon: "flag.fill")
                Rectangle().frame(width: 0.5, height: 36).foregroundColor(Color.earthMuted.opacity(0.25))
                hudStat(value: timeText(session.elapsedTime), label: "elapsed", icon: "clock.fill")
            }
            .padding(.vertical, 18)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showHeatBanner)
        .background(.ultraThinMaterial)
    }

    private func hudStat(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.caption).foregroundColor(.earthGreen)
            Text(value).font(.subheadline.bold()).foregroundColor(.earthCream)
            Text(label).font(.caption2).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private func petNamesFor(ids: [UUID]) -> [String] {
        ids.compactMap { id in petStore.pets.first { $0.id == id }?.name }
    }

    private func distText(_ m: Double) -> String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: max(0, m))
    }

    private func timeText(_ t: TimeInterval) -> String {
        let s = Int(t); let m = s / 60
        return m < 60 ? "\(m)m \(s % 60)s" : "\(m / 60)h \(m % 60)m"
    }

    private func saveCurrentRoute() {
        let customRoute = CustomRoute(
            id: UUID(),
            name: route.name,
            waypoints: route.waypoints.map { WaypointCoord($0) },
            totalDistance: route.totalDistance,
            isLoop: route.isLoop,
            createdAt: Date()
        )
        localRouteStore.save(customRoute)
    }

    private var waterBreakIntervalMinutes: Int {
        let temp = walkWeather?.temperatureCelsius ?? 20
        if temp > 32 { return 10 }
        if temp > 27 { return 15 }
        return 20
    }

    private func scheduleWaterBreakReminders() async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        } else if status != .authorized { return }
        let intervalSecs = Double(waterBreakIntervalMinutes) * 60
        let estimatedDurationMins = route.totalDistance / 1.4 / 60
        let count = min(12, max(1, Int(ceil(estimatedDurationMins / Double(waterBreakIntervalMinutes)))))
        scheduledBreakCount = count
        for i in 1...count {
            let content = UNMutableNotificationContent()
            content.title = "Water break! 💧"
            content.body = petStore.activePets.isEmpty
                ? "Time for a water break."
                : "Time to hydrate — your \(petStore.activePets.count == 1 ? "pup" : "pups") need water too."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Double(i) * intervalSecs, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "waterBreak-\(i)", content: content, trigger: trigger))
        }
    }

    private func cancelWaterBreakReminders() {
        let count = max(scheduledBreakCount, 12)
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: (1...count).map { "waterBreak-\($0)" }
        )
        scheduledBreakCount = 0
    }

    private func computeWalkingLegs() async -> [MKRoute] {
        let wps = route.waypoints
        guard wps.count >= 2 else { return [] }
        var legs: [MKRoute] = []
        let legCount = route.isLoop ? wps.count : wps.count - 1
        for i in 0..<legCount {
            let from = wps[i]
            let to = wps[(i + 1) % wps.count]
            let req = MKDirections.Request()
            req.source        = MKMapItem(location: CLLocation(latitude: from.latitude, longitude: from.longitude), address: nil)
            req.destination   = MKMapItem(location: CLLocation(latitude: to.latitude, longitude: to.longitude), address: nil)
            req.transportType = route.activityMode.transportType
            if let r = try? await MKDirections(request: req).calculate().routes.first {
                legs.append(r)
            }
        }
        return legs
    }
}

// MARK: - Checkpoint circle overlay

final class NavCheckpointCircle: MKCircle {
    var isFinish = false
}

// MARK: - Heat Advisory Banner

private struct HeatAdvisoryBanner: View {
    let intervalMinutes: Int
    let onEnableWaterBreaks: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "thermometer.high")
                .font(.title3).foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Heat Advisory")
                    .font(.caption.bold()).foregroundColor(.earthCream)
                Text("Hot pavement can burn paws. Keep pets hydrated.")
                    .font(.caption2).foregroundColor(.earthMuted)
            }
            Spacer()
            Button { onEnableWaterBreaks() } label: {
                Label("Every \(intervalMinutes) min", systemImage: "drop.fill")
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(red: 0.28, green: 0.49, blue: 0.84).opacity(0.85))
                    .foregroundColor(.white).cornerRadius(8)
            }
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.caption).foregroundColor(.earthMuted)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - Walk Complete View

struct WalkCompleteView: View {
    let session: WalkSession
    let activePetNames: [String]
    let petCompletions: [PetCompletion]
    var splits: [(label: String, elapsed: TimeInterval)] = []
    let onDismiss: () -> Void
    @State private var showSchedule = false
    @State private var ringProgress: [UUID: Double] = [:]

    private var completionMessage: String {
        switch activePetNames.count {
        case 0: return "Nice work on \(session.routeName). Keep the momentum going!"
        case 1: return "Nice work! \(activePetNames[0]) had a great walk too. 🐾"
        case 2: return "Nice work! \(activePetNames[0]) and \(activePetNames[1]) loved it. 🐾"
        default: return "Nice work! The whole crew crushed it. 🐾"
        }
    }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            ConfettiOverlay()
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 20) {
                    Image(systemName: "figure.walk.circle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(Color.earthGreen)
                        .padding(.bottom, 8)
                    Text("Walk Complete!")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.earthCream)
                    Text(completionMessage)
                        .font(.subheadline)
                        .foregroundColor(.earthMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()
                HStack(spacing: 10) {
                    statTile(value: session.distanceText, label: "Distance", icon: "ruler", color: .earthGreen)
                    statTile(value: session.timeText, label: "Time", icon: "clock", color: .earthOrange)
                    statTile(value: session.estimatedSteps.formatted(), label: "Steps", icon: "figure.walk", color: .earthCream)
                }
                .padding(.horizontal)
                if !petCompletions.isEmpty {
                    petRingsSection
                }
                if !splits.isEmpty {
                    splitsSection
                }
                Spacer()
                VStack(spacing: 12) {
                    Button { showSchedule = true } label: {
                        Label("Schedule This Walk Again", systemImage: "calendar.badge.plus")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18).padding(.horizontal, 20)
                            .background(Color.earthGreen).foregroundColor(.white)
                            .fontWeight(.semibold).cornerRadius(14)
                    }
                    Button { onDismiss() } label: {
                        Text("Done")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18).padding(.horizontal, 20)
                            .background(Color.earthCard)
                            .foregroundColor(.earthCream).cornerRadius(14)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
        }
        .sheet(isPresented: $showSchedule) {
            ScheduleWalkSheet(routeName: session.routeName)
        }
    }

    private func statTile(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(color).font(.title3)
            Text(value).font(.headline.bold()).foregroundColor(.earthCream)
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20)
        .background(Color.earthCard).cornerRadius(14)
    }

    private var splitsSection: some View {
        VStack(spacing: 8) {
            Text("Splits")
                .font(.caption.bold()).foregroundColor(.earthMuted)
            VStack(spacing: 4) {
                ForEach(splits.indices, id: \.self) { i in
                    HStack {
                        Text(splits[i].label)
                            .font(.caption.bold()).foregroundColor(.earthCream)
                        Spacer()
                        Text(splitTimeText(splits[i].elapsed))
                            .font(.caption).foregroundColor(.earthMuted)
                        if i > 0 {
                            Text("(+\(splitTimeText(splits[i].elapsed - splits[i-1].elapsed)))")
                                .font(.caption2).foregroundColor(.earthMuted.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Color.earthCard).cornerRadius(8)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private func splitTimeText(_ t: TimeInterval) -> String {
        let s = Int(t); let m = s / 60
        return m < 60 ? "\(m)m \(s % 60)s" : "\(m / 60)h \(m % 60)m"
    }

    private var petRingsSection: some View {
        VStack(spacing: 12) {
            Text("Your crew's progress today")
                .font(.caption.bold()).foregroundColor(.earthMuted)
            HStack(spacing: 24) {
                ForEach(petCompletions, id: \.pet.id) { completion in
                    petRingView(completion: completion)
                }
            }
        }
        .padding(.vertical, 16)
        .onAppear {
            for (i, completion) in petCompletions.enumerated() {
                withAnimation(.spring(duration: 0.9, bounce: 0.25).delay(Double(i) * 0.18)) {
                    ringProgress[completion.pet.id] = completion.progress
                }
            }
        }
    }

    private func petRingView(completion: PetCompletion) -> some View {
        let progress = ringProgress[completion.pet.id] ?? 0
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(completion.pet.accentColor.opacity(0.2), lineWidth: 7)
                    .frame(width: 72, height: 72)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(completion.pet.accentColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .frame(width: 72, height: 72)
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(completion.pet.displayEmoji)
                        .font(.system(size: 26))
                        .scaleEffect(progress > 0 ? 1.0 : 0.6)
                        .animation(.spring(duration: 0.5, bounce: 0.4).delay(0.3), value: progress)
                    Text("\(Int(completion.progress * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.earthMuted)
                }
            }
            Text(completion.pet.name)
                .font(.caption2.bold())
                .foregroundColor(.earthMuted)
        }
    }
}

// MARK: - Schedule Walk Sheet

struct ScheduleWalkSheet: View {
    let routeName: String
    @Environment(\.dismiss) private var dismiss
    @State private var scheduledDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var notifDenied = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 52)).foregroundColor(.earthGreen)
                    Text("Schedule \"\(routeName)\"")
                        .font(.headline).foregroundColor(.earthCream).multilineTextAlignment(.center)
                    DatePicker(
                        "Walk time",
                        selection: $scheduledDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical).tint(.earthGreen)
                    .padding(.horizontal)
                    if notifDenied {
                        Label("Enable notifications in iOS Settings to receive reminders", systemImage: "bell.slash")
                            .font(.caption).foregroundColor(.orange)
                            .multilineTextAlignment(.center).padding(.horizontal)
                    }
                    Spacer()
                }
                .padding(.top, 24)
            }
            .navigationTitle("Schedule Walk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set Reminder") { Task { await schedule() } }.foregroundColor(.earthGreen)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.earthMuted)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func schedule() async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if !granted { notifDenied = true; return }
        } else if status == .denied {
            notifDenied = true; return
        }
        let content = UNMutableNotificationContent()
        content.title = "Time for your walk!"
        content.body = "Your \(routeName) walk is scheduled — lace up!"
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: scheduledDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
        dismiss()
    }
}

// MARK: - Walk History View

struct WalkHistoryView: View {
    @ObservedObject var store: WalkHistoryStore
    @EnvironmentObject var petStore: PetStore
    @State private var navigatingRoute: NavigableRoute?
    @State private var showManualEntry = false
    @State private var selectedSession: WalkSession?

    private var totalWalks: Int { store.sessions.count }

    private var avgDistanceText: String {
        guard !store.sessions.isEmpty else { return "—" }
        let avg = store.sessions.reduce(0.0) { $0 + $1.totalDistance } / Double(store.sessions.count)
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: avg)
    }

    private var avgDurationText: String {
        guard !store.sessions.isEmpty else { return "—" }
        let avg = store.sessions.reduce(0.0) { $0 + $1.elapsedTime } / Double(store.sessions.count)
        let mins = Int(avg) / 60
        return mins < 60 ? "\(mins)m" : "\(mins / 60)h \(mins % 60)m"
    }

    private var walksThisWeek: Int {
        let cal = Calendar.current
        guard let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) else { return 0 }
        return store.sessions.filter { $0.date >= weekStart }.count
    }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            Group {
                if store.sessions.isEmpty { emptyState } else { historyList }
            }
        }
        .navigationTitle("Walk History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showManualEntry = true
                } label: {
                    Image(systemName: "plus").foregroundColor(.earthGreen)
                }
            }
        }
        .navigationDestination(item: $navigatingRoute) { route in
            WalkNavigationView(route: route, historyStore: store)
        }
        .sheet(isPresented: $showManualEntry) {
            ManualWalkEntrySheet { session in store.add(session) }
        }
        .sheet(item: $selectedSession) { session in
            WalkSessionDetailSheet(session: session, store: store)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 64)).foregroundColor(.earthMuted.opacity(0.4))
            Text("No Walks Yet")
                .font(.headline).foregroundColor(.earthCream)
            Text("Complete a walk to build your history")
                .font(.subheadline).foregroundColor(.earthMuted).multilineTextAlignment(.center)
            Button("Log a Past Walk") { showManualEntry = true }
                .foregroundColor(.earthGreen).fontWeight(.semibold)
        }.padding()
    }

    private var statsHeader: some View {
        HStack(spacing: 0) {
            statCell("\(totalWalks)", "Total")
            Divider().frame(height: 36)
            statCell(avgDistanceText, "Avg Dist")
            Divider().frame(height: 36)
            statCell(avgDurationText, "Avg Time")
            Divider().frame(height: 36)
            statCell("\(walksThisWeek)", "This Week")
        }
        .padding(.vertical, 12)
        .background(Color.earthCard)
        .cornerRadius(14)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func statCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).foregroundColor(.earthCream)
            Text(label).font(.caption2).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private var historyList: some View {
        List {
            Section {
                statsHeader
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(store.sessions) { session in
                WalkHistoryRow(session: session) {
                    navigatingRoute = session.toNavigableRoute()
                } onInfo: {
                    selectedSession = session
                }
                .listRowBackground(Color.earthCard)
                .listRowSeparatorTint(Color.earthMuted.opacity(0.2))
            }
            .onDelete { store.delete(at: $0) }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
    }
}

// MARK: - Walk Session Detail Sheet

struct WalkSessionDetailSheet: View {
    let session: WalkSession
    @ObservedObject var store: WalkHistoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var notes: String = ""

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .short; return f
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        Text(Self.dateFmt.string(from: session.date))
                            .font(.subheadline).foregroundColor(.earthMuted)
                            .padding(.top, 4)

                        HStack(spacing: 12) {
                            detailTile(session.distanceText, "Distance", "ruler")
                            detailTile(session.timeText,     "Duration", "clock")
                            detailTile("\(session.estimatedSteps.formatted())", "Steps", "figure.walk")
                        }
                        .padding(.horizontal)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Notes")
                                .font(.caption.bold()).foregroundColor(.earthMuted)
                                .padding(.horizontal)
                            ZStack(alignment: .topLeading) {
                                if notes.isEmpty {
                                    Text("Add a note about this walk…")
                                        .font(.subheadline).foregroundColor(.earthMuted.opacity(0.5))
                                        .padding(.horizontal, 14).padding(.top, 12)
                                }
                                TextEditor(text: $notes)
                                    .foregroundColor(.earthCream)
                                    .font(.subheadline)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 88)
                                    .padding(.horizontal, 10)
                            }
                            .padding(.vertical, 4)
                            .background(Color.earthCard)
                            .cornerRadius(14)
                            .padding(.horizontal)
                        }

                        ShareLink(item: shareText) {
                            Label("Share this Walk", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.earthCard)
                                .foregroundColor(.earthCream)
                                .fontWeight(.semibold)
                                .cornerRadius(14)
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.earthGreen.opacity(0.4), lineWidth: 1.5))
                        }
                        .padding(.horizontal)

                        Spacer(minLength: 24)
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(session.routeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        store.updateNotes(id: session.id, notes: notes)
                        dismiss()
                    }
                    .foregroundColor(.earthGreen)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .fontWeight(.semibold).foregroundColor(.earthGreen)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { notes = session.notes }
    }

    private var shareText: String {
        var text = "Just \(session.activityType == "cycling" ? "rode" : "walked") \(session.distanceText) in \(session.timeText) on Wockett 🚶"
        if !notes.isEmpty { text += "\n\n\"\(notes)\"" }
        return text
    }

    private func detailTile(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(.earthGreen).font(.title3)
            Text(value).font(.headline.bold()).foregroundColor(.earthCream)
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
        .background(Color.earthCard).cornerRadius(14)
    }
}

// MARK: - Manual Walk Entry Sheet

struct ManualWalkEntrySheet: View {
    let onSave: (WalkSession) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var walkDate = Date()
    @State private var durationHours = 0
    @State private var durationMinutes = 30
    @State private var distanceKm = ""
    @State private var stepCount = ""
    @State private var routeName = ""
    @State private var useSteps = false

    private var distanceMeters: Double? {
        if useSteps, let steps = Double(stepCount), steps > 0 { return steps * 0.762 }
        if !useSteps, let km = Double(distanceKm), km > 0 { return km * 1000 }
        return nil
    }

    private var isValid: Bool {
        let totalMins = durationHours * 60 + durationMinutes
        return totalMins > 0 && distanceMeters != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        sectionCard("When") {
                            DatePicker("Date & Time", selection: $walkDate, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                                .foregroundColor(.earthCream)
                                .tint(.earthGreen)
                        }

                        sectionCard("Duration") {
                            HStack(spacing: 24) {
                                VStack(spacing: 4) {
                                    Text("\(durationHours)").font(.title2.bold()).foregroundColor(.earthCream)
                                    Text("hours").font(.caption).foregroundColor(.earthMuted)
                                    Stepper("", value: $durationHours, in: 0...23).labelsHidden()
                                }
                                VStack(spacing: 4) {
                                    Text("\(durationMinutes)").font(.title2.bold()).foregroundColor(.earthCream)
                                    Text("minutes").font(.caption).foregroundColor(.earthMuted)
                                    Stepper("", value: $durationMinutes, in: 0...59).labelsHidden()
                                }
                                Spacer()
                            }
                        }

                        sectionCard("Distance") {
                            VStack(spacing: 12) {
                                Picker("", selection: $useSteps) {
                                    Text("Kilometres").tag(false)
                                    Text("Steps").tag(true)
                                }
                                .pickerStyle(.segmented)

                                if useSteps {
                                    TextField("Approximate steps", text: $stepCount)
                                        .keyboardType(.numberPad)
                                        .foregroundColor(.earthCream)
                                        .padding(12).background(Color.earthBg).cornerRadius(10)
                                } else {
                                    TextField("Distance in km (e.g. 3.5)", text: $distanceKm)
                                        .keyboardType(.decimalPad)
                                        .foregroundColor(.earthCream)
                                        .padding(12).background(Color.earthBg).cornerRadius(10)
                                }

                                if let meters = distanceMeters {
                                    Text("≈ \(formattedDistance(meters)) · \(Int(meters / 0.762).formatted()) steps")
                                        .font(.caption).foregroundColor(.earthGreen)
                                }
                            }
                        }

                        sectionCard("Notes (optional)") {
                            TextField("Route name or notes…", text: $routeName)
                                .foregroundColor(.earthCream)
                                .padding(12).background(Color.earthBg).cornerRadius(10)
                        }

                        Button(action: save) {
                            Text("Save Walk")
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .background(isValid ? Color.earthGreen : Color.earthMuted.opacity(0.3))
                                .foregroundColor(.white).font(.headline).cornerRadius(14)
                        }
                        .disabled(!isValid)
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Log a Past Walk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.earthMuted)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }.fontWeight(.semibold).foregroundColor(.earthGreen)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func formattedDistance(_ meters: Double) -> String {
        let fmt = MKDistanceFormatter(); fmt.unitStyle = .abbreviated
        return fmt.string(fromDistance: meters)
    }

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.bold()).foregroundColor(.earthMuted).padding(.horizontal)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(14).background(Color.earthCard).cornerRadius(14).padding(.horizontal)
        }
    }

    private func save() {
        guard let meters = distanceMeters else { return }
        let totalSeconds = TimeInterval((durationHours * 60 + durationMinutes) * 60)
        let name = routeName.trimmingCharacters(in: .whitespaces).isEmpty ? "Past Walk" : routeName
        let session = WalkSession(
            id: UUID(),
            routeName: name,
            date: walkDate,
            elapsedTime: totalSeconds,
            totalDistance: meters,
            waypoints: [],
            lapCount: 1,
            isLoop: false
        )
        onSave(session)
        dismiss()
    }
}

struct WalkHistoryRow: View {
    let session: WalkSession
    let onWalkAgain: () -> Void
    let onInfo: () -> Void

    private var rowIcon: String {
        switch session.activityType {
        case "cycling":    return "bicycle"
        case "stationary": return "figure.walk.motion"
        default:           return "figure.walk"
        }
    }

    private var rowColor: Color {
        switch session.activityType {
        case "cycling":    return Color(red: 0.13, green: 0.57, blue: 0.64)
        case "stationary": return Color(red: 0.42, green: 0.32, blue: 0.76)
        default:           return .earthGreen
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(rowColor.opacity(0.15)).frame(width: 46, height: 46)
                Image(systemName: rowIcon).foregroundColor(rowColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(session.routeName).font(.headline).foregroundColor(.earthCream).lineLimit(1)
                Text(session.formattedDate).font(.subheadline).foregroundColor(.earthMuted)
                HStack(spacing: 10) {
                    Label(session.distanceText, systemImage: "ruler")
                    Label(session.timeText, systemImage: "clock")
                }
                .font(.footnote).foregroundColor(.earthMuted)
                if !session.notes.isEmpty {
                    Text(session.notes)
                        .font(.caption).foregroundColor(.earthMuted.opacity(0.8))
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(spacing: 8) {
                Button { onWalkAgain() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(rowColor)
                        .frame(width: 34, height: 34)
                        .background(rowColor.opacity(0.12))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                Button { onInfo() } label: {
                    Image(systemName: session.notes.isEmpty ? "note.text.badge.plus" : "note.text")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.earthMuted)
                        .frame(width: 34, height: 34)
                        .background(Color.earthMuted.opacity(0.1))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }
}
