import SwiftUI
import Combine
import MapKit
import CoreLocation
import HealthKit
import SwiftData

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
    case walking, cycling, stationary

    var icon: String {
        switch self {
        case .walking:    return "figure.walk"
        case .cycling:    return "bicycle"
        case .stationary: return "figure.walk.motion"
        }
    }

    var sessionLabel: String {
        switch self {
        case .walking:    return "Walk"
        case .cycling:    return "Ride"
        case .stationary: return "Indoor"
        }
    }

    var transportType: MKDirectionsTransportType {
        self == .cycling ? .cycling : .walking
    }

    var hkActivityType: HKWorkoutActivityType {
        self == .cycling ? .cycling : .walking
    }

    var isIndoor: Bool { self == .stationary }

    var next: ActivityMode {
        switch self {
        case .walking:    return .cycling
        case .cycling:    return .stationary
        case .stationary: return .walking
        }
    }

    var tileColor: Color {
        switch self {
        case .walking:    return Color.earthGreen
        case .cycling:    return Color(red: 0.13, green: 0.57, blue: 0.64)
        case .stationary: return Color(red: 0.42, green: 0.32, blue: 0.76)
        }
    }

    var tileLabel: String {
        switch self {
        case .walking:    return "Start Walking"
        case .cycling:    return "Start Biking"
        case .stationary: return "Start Indoor"
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
        let f = MKDistanceFormatter.abbreviated
        return "↑ \(f.string(fromDistance: elevationGainMeters)) · ↓ \(f.string(fromDistance: elevationLossMeters))"
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
        let f = MKDistanceFormatter.abbreviated
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

// MARK: - Shared distance formatter (avoids creating a new instance per call)

extension MKDistanceFormatter {
    static let abbreviated: MKDistanceFormatter = {
        let f = MKDistanceFormatter()
        f.unitStyle = .abbreviated
        return f
    }()
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
    var petDistances: [UUID: Double]  // meters walked per pet; empty on pre-v1.7 sessions
    var steps: Int            // pedometer step count; 0 for pre-v1.7 sessions (falls back to distance estimate)

    init(id: UUID, routeName: String, date: Date, elapsedTime: TimeInterval,
         totalDistance: Double, waypoints: [WaypointCoord], lapCount: Int,
         isLoop: Bool, activePetIds: [UUID] = [], activityType: String = "walking",
         notes: String = "", petDistances: [UUID: Double] = [:], steps: Int = 0) {
        self.id = id; self.routeName = routeName; self.date = date
        self.elapsedTime = elapsedTime; self.totalDistance = totalDistance
        self.waypoints = waypoints; self.lapCount = lapCount
        self.isLoop = isLoop; self.activePetIds = activePetIds
        self.activityType = activityType; self.notes = notes
        self.petDistances = petDistances; self.steps = steps
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
        activePetIds  = (try? c.decode([UUID].self,         forKey: .activePetIds))  ?? []
        activityType  = (try? c.decode(String.self,         forKey: .activityType))  ?? "walking"
        notes         = (try? c.decode(String.self,         forKey: .notes))         ?? ""
        petDistances  = (try? c.decode([UUID: Double].self, forKey: .petDistances))  ?? [:]
        steps         = (try? c.decode(Int.self,            forKey: .steps))          ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case id, routeName, date, elapsedTime, totalDistance, waypoints, lapCount, isLoop, activePetIds, activityType, notes, petDistances, steps
    }

    // Returns actual pedometer steps when available, otherwise estimates from GPS distance.
    var estimatedSteps: Int { steps > 0 ? steps : Int(totalDistance / 0.762) }

    var distanceText: String {
        MKDistanceFormatter.abbreviated.string(fromDistance: totalDistance)
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
//
// SwiftData-backed store. Publishes [WalkSession] structs so all existing views
// remain unchanged. Records are fetched from SwiftData on init and kept in sync
// via the published array — no JSON file or UserDefaults involved.

@MainActor
final class WalkHistoryStore: ObservableObject {
    @Published var sessions: [WalkSession] = []

    private let context: ModelContext

    init(context: ModelContext? = nil) {
        self.context = context ?? AppModelContainer.shared.mainContext
        load()
    }

    func add(_ session: WalkSession) {
        let record = WalkSessionRecord(from: session)
        context.insert(record)
        save()
        sessions.insert(session, at: 0)
    }

    func addAll(_ newSessions: [WalkSession]) {
        let sorted = newSessions.sorted { $0.date > $1.date }
        sorted.forEach { context.insert(WalkSessionRecord(from: $0)) }
        save()
        sessions.insert(contentsOf: sorted, at: 0)
    }

    func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { sessions[$0] }
        sessions.remove(atOffsets: offsets)
        deleteRecords(ids: toDelete.map(\.id))
    }

    func updateNotes(id: UUID, notes: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].notes = notes
        if let record = fetchRecord(id: id) {
            record.notes = notes
            save()
        }
    }

    // MARK: - Private helpers

    private func load() {
        let descriptor = FetchDescriptor<WalkSessionRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        sessions = (try? context.fetch(descriptor))?.map { $0.toWalkSession() } ?? []
    }

    private func save() {
        try? context.save()
    }

    private func fetchRecord(id: UUID) -> WalkSessionRecord? {
        var descriptor = FetchDescriptor<WalkSessionRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func deleteRecords(ids: [UUID]) {
        ids.forEach { id in
            if let record = fetchRecord(id: id) {
                context.delete(record)
            }
        }
        save()
    }
}

// MARK: - Personal Records

enum PRType: Identifiable {
    case longestWalk(distance: Double)
    case fastestPace(secsPerKm: Double)

    var id: String {
        switch self {
        case .longestWalk: return "longest"
        case .fastestPace: return "fastest"
        }
    }

    var emoji: String {
        switch self {
        case .longestWalk: return "📏"
        case .fastestPace: return "⚡️"
        }
    }

    var title: String {
        switch self {
        case .longestWalk: return "Longest Walk"
        case .fastestPace: return "Fastest Pace"
        }
    }

    var valueText: String {
        switch self {
        case .longestWalk(let d):
            return MKDistanceFormatter.abbreviated.string(fromDistance: d)
        case .fastestPace(let s):
            let mins = Int(s) / 60; let secs = Int(s) % 60
            return String(format: "%d'%02d\"/km", mins, secs)
        }
    }
}

// Returns any PRs the new session sets against the previous session list.
// Call BEFORE adding the new session to the store.
func checkNewPRs(newSession: WalkSession, against previousSessions: [WalkSession]) -> [PRType] {
    guard newSession.totalDistance > 200, newSession.activePetIds.isEmpty else { return [] }
    let prev = previousSessions.filter { $0.totalDistance > 200 }
    var records: [PRType] = []

    let prevLongest = prev.map(\.totalDistance).max() ?? 0
    if newSession.totalDistance > prevLongest {
        records.append(.longestWalk(distance: newSession.totalDistance))
    }

    if newSession.totalDistance > 500, newSession.elapsedTime > 0,
       newSession.activityType != ActivityMode.stationary.rawValue {
        let newPace = newSession.elapsedTime / (newSession.totalDistance / 1000)
        let prevBest = prev
            .filter { $0.totalDistance > 500 && $0.elapsedTime > 0 && $0.activityType != ActivityMode.stationary.rawValue }
            .map { $0.elapsedTime / ($0.totalDistance / 1000) }
            .min() ?? .infinity
        if newPace < prevBest {
            records.append(.fastestPace(secsPerKm: newPace))
        }
    }

    return records
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
