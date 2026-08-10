import SwiftUI
import Combine
import MapKit
import CoreLocation

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

    var estimatedSteps: Int { Int(totalDistance / 0.762) }

    var distanceText: String {
        MKDistanceFormatter.abbreviated.string(fromDistance: totalDistance)
    }

    var timeText: String {
        let mins = Int(totalDistance / 1.4 / 60)
        return mins < 60 ? "\(mins) min" : "\(mins / 60)h \(mins % 60)m"
    }

    var centroid: CLLocationCoordinate2D {
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
    private let udKey = "customRoutes_v1"

    init() { load() }

    func save(_ route: CustomRoute) {
        routes.insert(route, at: 0)
        persist()
    }

    func update(_ route: CustomRoute) {
        if let idx = routes.firstIndex(where: { $0.id == route.id }) {
            routes[idx] = route
            persist()
        }
    }

    func delete(at offsets: IndexSet) {
        routes.remove(atOffsets: offsets)
        persist()
    }

    func reload() { load() }

    private func persist() {
        if let data = try? JSONEncoder().encode(routes) {
            UserDefaults.standard.set(data, forKey: udKey)
        }
    }

    private func load() {
        guard let data    = UserDefaults.standard.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([CustomRoute].self, from: data) else { return }
        routes = decoded
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
    private let udKey = "bookmarkedLocations_v1"

    init() { load() }

    func add(_ location: BookmarkedLocation) {
        guard !bookmarks.contains(where: { $0.id == location.id }) else { return }
        bookmarks.insert(location, at: 0)
        persist()
    }

    func delete(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        persist()
    }

    func isBookmarked(id: UUID) -> Bool {
        bookmarks.contains { $0.id == id }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: udKey)
        }
    }

    private func load() {
        guard let data    = UserDefaults.standard.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([BookmarkedLocation].self, from: data) else { return }
        bookmarks = decoded
    }
}
