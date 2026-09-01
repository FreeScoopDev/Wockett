import SwiftUI
import Combine
import MapKit
import CoreLocation
import SwiftData

// MARK: - Waypoint Coord

struct WaypointCoord: Codable, Hashable {
    let latitude: Double
    let longitude: Double

    init(_ coord: CLLocationCoordinate2D) {
        latitude  = coord.latitude
        longitude = coord.longitude
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Custom Route

struct CustomRoute: Identifiable, Codable {
    let id:            UUID
    var name:          String
    let waypoints:     [WaypointCoord]
    var totalDistance: Double        // metres
    var isLoop:        Bool
    let createdAt:     Date
    var activityMode:  ActivityMode = .walking

    var estimatedSteps: Int { Int(totalDistance / 0.762) }

    var distanceText: String {
        MKDistanceFormatter.abbreviated.string(fromDistance: totalDistance)
    }

    var timeText: String {
        let mins = Int(totalDistance / 1.4 / 60)
        return mins < 60 ? "\(mins) min" : "\(mins / 60)h \(mins % 60)m"
    }

    var centroid: CLLocationCoordinate2D {
        guard !waypoints.isEmpty else { return CLLocationCoordinate2D() }
        let n   = Double(waypoints.count)
        let lat = waypoints.reduce(0.0) { $0 + $1.latitude }  / n
        let lon = waypoints.reduce(0.0) { $0 + $1.longitude } / n
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

// MARK: - Custom Route Store

@MainActor
final class CustomRouteStore: ObservableObject {
    @Published var routes: [CustomRoute] = []

    private let context: ModelContext

    init(context: ModelContext? = nil) {
        self.context = context ?? AppModelContainer.shared.mainContext
        load()
    }

    func save(_ route: CustomRoute) {
        context.insert(CustomRouteRecord(from: route))
        try? context.save()
        routes.insert(route, at: 0)
    }

    func update(_ route: CustomRoute) {
        guard let idx = routes.firstIndex(where: { $0.id == route.id }) else { return }
        routes[idx] = route
        if let record = fetchRecord(id: route.id) {
            record.name          = route.name
            record.totalDistance = route.totalDistance
            record.isLoop        = route.isLoop
            record.activityMode  = route.activityMode.rawValue
        }
        try? context.save()
    }

    func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { routes[$0] }
        routes.remove(atOffsets: offsets)
        toDelete.forEach { route in
            if let record = fetchRecord(id: route.id) { context.delete(record) }
        }
        try? context.save()
    }

    func reload() { load() }

    private func load() {
        let descriptor = FetchDescriptor<CustomRouteRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        routes = (try? context.fetch(descriptor))?.map { $0.toCustomRoute() } ?? []
    }

    private func fetchRecord(id: UUID) -> CustomRouteRecord? {
        var descriptor = FetchDescriptor<CustomRouteRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

// MARK: - Bookmarked Location

struct BookmarkedLocation: Identifiable, Codable {
    let id: UUID
    var name: String
    var address: String
    let latitude: Double
    let longitude: Double
    let createdAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Bookmark Store

@MainActor
final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()
    @Published var bookmarks: [BookmarkedLocation] = []

    private let context: ModelContext

    init(context: ModelContext? = nil) {
        self.context = context ?? AppModelContainer.shared.mainContext
        load()
    }

    func add(_ location: BookmarkedLocation) {
        guard !bookmarks.contains(where: { $0.id == location.id }) else { return }
        context.insert(BookmarkedLocationRecord(from: location))
        try? context.save()
        bookmarks.insert(location, at: 0)
    }

    func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { bookmarks[$0] }
        bookmarks.remove(atOffsets: offsets)
        toDelete.forEach { loc in
            if let record = fetchRecord(id: loc.id) { context.delete(record) }
        }
        try? context.save()
    }

    func isBookmarked(id: UUID) -> Bool {
        bookmarks.contains { $0.id == id }
    }

    private func load() {
        let descriptor = FetchDescriptor<BookmarkedLocationRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        bookmarks = (try? context.fetch(descriptor))?.map { $0.toBookmarkedLocation() } ?? []
    }

    private func fetchRecord(id: UUID) -> BookmarkedLocationRecord? {
        var descriptor = FetchDescriptor<BookmarkedLocationRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
