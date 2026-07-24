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
            totalDistance: totalDistance
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

    func delete(at offsets: IndexSet) {
        sessions.remove(atOffsets: offsets)
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

    private let route: NavigableRoute
    private let locationManager = CLLocationManager()
    private var startTime = Date()
    private var timer: Timer?
    private var lastLocation: CLLocation?
    private let arrivalRadius = 30.0

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
    }

    func stop() {
        locationManager.stopUpdatingLocation()
        timer?.invalidate()
        timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
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
            isLoop: route.isLoop
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
            self.checkArrival(at: loc)
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
        if route.isLoop {
            if currentWaypointIndex >= route.waypoints.count {
                // Reached last point before start; now head back to start to close the loop
                currentWaypointIndex = 0
            } else if currentWaypointIndex == 1 {
                // Just passed through start — lap complete
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

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.userTrackingMode = .follow
        map.overrideUserInterfaceStyle = .dark

        var coords = route.waypoints
        if route.isLoop && !coords.isEmpty { coords.append(coords[0]) }
        if coords.count >= 2 {
            map.addOverlay(MKPolyline(coordinates: coords, count: coords.count))
        }
        for (i, wp) in route.waypoints.enumerated() {
            let ann = MKPointAnnotation()
            ann.coordinate = wp
            ann.title = i == 0 ? "Start" : "\(i)"
            map.addAnnotation(ann)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let pl = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: pl)
            r.strokeColor = .systemGreen
            r.lineWidth = 5
            r.alpha = 0.8
            return r
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let ann = annotation as? MKPointAnnotation else { return nil }
            let view = MKMarkerAnnotationView(annotation: ann, reuseIdentifier: "nav")
            view.glyphText = ann.title ?? ""
            view.markerTintColor = ann.title == "Start" ? .systemBlue : .systemGreen
            view.canShowCallout = false
            return view
        }
    }
}

// MARK: - Walk Navigation View

struct WalkNavigationView: View {
    let route: NavigableRoute
    @ObservedObject var historyStore: WalkHistoryStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var session: NavigationSessionManager
    @State private var showComplete = false
    @State private var showStopAlert = false
    @State private var completedSession: WalkSession?

    init(route: NavigableRoute, historyStore: WalkHistoryStore) {
        self.route = route
        self.historyStore = historyStore
        _session = StateObject(wrappedValue: NavigationSessionManager(route: route))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationMapView(route: route)
                .ignoresSafeArea()
            hudPanel
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { session.start() }
        .onDisappear { session.stop() }
        .onChange(of: session.isCompleted) { _, completed in
            guard completed else { return }
            let s = session.completedSession
            completedSession = s
            historyStore.add(s)
            showComplete = true
        }
        .alert("End Walk?", isPresented: $showStopAlert) {
            Button("End Walk", role: .destructive) { session.stop(); dismiss() }
            Button("Continue", role: .cancel) {}
        } message: {
            Text("Your walk progress won't be saved to history.")
        }
        .fullScreenCover(isPresented: $showComplete) {
            if let s = completedSession {
                WalkCompleteView(session: s) { showComplete = false; dismiss() }
            }
        }
    }

    private var hudPanel: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(route.name)
                        .font(.headline).foregroundColor(.white).lineLimit(1)
                    Text(session.progressText)
                        .font(.caption).foregroundColor(.green)
                }
                Spacer()
                Button { showStopAlert = true } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title)
                        .foregroundColor(.red.opacity(0.85))
                }
            }
            .padding(.horizontal, 20).padding(.top, 20)

            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(.white.opacity(0.12))
                .padding(.top, 14)

            HStack(spacing: 0) {
                hudStat(value: distText(session.distanceToNextWaypoint), label: "to next", icon: "location.fill")
                Rectangle().frame(width: 0.5, height: 36).foregroundColor(.white.opacity(0.12))
                hudStat(value: distText(session.remainingDistance), label: "remaining", icon: "flag.fill")
                Rectangle().frame(width: 0.5, height: 36).foregroundColor(.white.opacity(0.12))
                hudStat(value: timeText(session.elapsedTime), label: "elapsed", icon: "clock.fill")
            }
            .padding(.vertical, 18)
        }
        .background(.ultraThinMaterial)
    }

    private func hudStat(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.caption2).foregroundColor(.green)
            Text(value).font(.subheadline.bold()).foregroundColor(.white)
            Text(label).font(.system(size: 10)).foregroundColor(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }

    private func distText(_ m: Double) -> String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: max(0, m))
    }

    private func timeText(_ t: TimeInterval) -> String {
        let s = Int(t); let m = s / 60
        return m < 60 ? "\(m)m \(s % 60)s" : "\(m / 60)h \(m % 60)m"
    }
}

// MARK: - Walk Complete View

struct WalkCompleteView: View {
    let session: WalkSession
    let onDismiss: () -> Void
    @State private var showSchedule = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 20) {
                    Image(systemName: "figure.walk.circle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.green)
                        .padding(.bottom, 8)
                    Text("Walk Complete!")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Nice work on \(session.routeName). Keep the momentum going!")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()
                HStack(spacing: 10) {
                    statTile(value: session.distanceText, label: "Distance", icon: "ruler", color: .green)
                    statTile(value: session.timeText, label: "Time", icon: "clock", color: .mint)
                    statTile(value: session.estimatedSteps.formatted(), label: "Steps", icon: "figure.walk", color: .cyan)
                }
                .padding(.horizontal)
                Spacer()
                VStack(spacing: 12) {
                    Button { showSchedule = true } label: {
                        Label("Schedule This Walk Again", systemImage: "calendar.badge.plus")
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.green).foregroundColor(.black)
                            .fontWeight(.semibold).cornerRadius(14)
                    }
                    Button { onDismiss() } label: {
                        Text("Done")
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.white.opacity(0.08))
                            .foregroundColor(.white).cornerRadius(14)
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
            Text(value).font(.headline.bold()).foregroundColor(.white)
            Text(label).font(.caption2).foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .background(Color.white.opacity(0.06)).cornerRadius(14)
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
                Color.black.ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 52)).foregroundColor(.green)
                    Text("Schedule \"\(routeName)\"")
                        .font(.headline).foregroundColor(.white).multilineTextAlignment(.center)
                    DatePicker(
                        "Walk time",
                        selection: $scheduledDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical).tint(.green).colorScheme(.dark)
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
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set Reminder") { Task { await schedule() } }.foregroundColor(.green)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.white.opacity(0.6))
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
    @State private var navigatingRoute: NavigableRoute?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                if store.sessions.isEmpty { emptyState } else { historyList }
            }
        }
        .navigationTitle("Walk History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(item: $navigatingRoute) { route in
            WalkNavigationView(route: route, historyStore: store)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 64)).foregroundColor(.white.opacity(0.12))
            Text("No Walks Yet")
                .font(.headline).foregroundColor(.white.opacity(0.45))
            Text("Complete a walk to build your history")
                .font(.subheadline).foregroundColor(.white.opacity(0.3)).multilineTextAlignment(.center)
        }.padding()
    }

    private var historyList: some View {
        List {
            ForEach(store.sessions) { session in
                WalkHistoryRow(session: session) {
                    navigatingRoute = session.toNavigableRoute()
                }
                .listRowBackground(Color.white.opacity(0.06))
                .listRowSeparatorTint(.white.opacity(0.08))
            }
            .onDelete { store.delete(at: $0) }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
    }
}

struct WalkHistoryRow: View {
    let session: WalkSession
    let onWalkAgain: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.green.opacity(0.15)).frame(width: 46, height: 46)
                Image(systemName: "figure.walk").foregroundColor(.green)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(session.routeName).font(.headline).foregroundColor(.white)
                Text(session.formattedDate).font(.caption).foregroundColor(.white.opacity(0.4))
                HStack(spacing: 10) {
                    Label(session.distanceText, systemImage: "ruler")
                    Label(session.timeText, systemImage: "clock")
                }
                .font(.caption).foregroundColor(.white.opacity(0.5))
            }
            Spacer()
            Button { onWalkAgain() } label: {
                Label("Walk Again", systemImage: "arrow.clockwise")
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.green.opacity(0.15)).foregroundColor(.green).cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }
}
