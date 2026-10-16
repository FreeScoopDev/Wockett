#if DEBUG
import CoreLocation
import Foundation
import SwiftData

// MARK: - Demo mode (-WKTDemo)
//
// The how-to videos are recorded from UI tests on a fresh simulator, which has
// none of what those screens need: a finished walk to save as a route, a saved
// route, a location for Find Routes, and a Home screen with no permission sheet
// or banner over it. `-WKTDemo` starts the app with exactly that, so every
// recording begins from the same known state.
//
// - Only the launch argument turns it on: no setting, link or stored value.
// - The data lives in an in-memory store with CloudKit explicitly `.none`, the
//   same store the unit tests use. The user's store and the CloudKit
//   configuration are never opened.
// - Debug only. Release builds contain none of this file, and
//   `isWKTDemoMode` is a constant `false` there.

enum DemoMode {

    static let launchArgument = "-WKTDemo"

    static func isRequested(by arguments: [String]) -> Bool {
        arguments.contains(launchArgument)
    }

    // MARK: Store

    /// The store demo mode runs on, or nil when the flag is absent.
    /// `AppModelContainer.shared` returns this before it tries CloudKit.
    static func container(arguments: [String]) -> ModelContainer? {
        guard isRequested(by: arguments) else { return nil }
        // `.none` must be explicit: in-memory is not local by default, and the
        // default `.automatic` syncs whenever the app has the iCloud entitlement.
        let config = ModelConfiguration(schema: AppModelContainer.schema,
                                        isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: AppModelContainer.schema, configurations: config)
        } catch {
            fatalError("DemoMode: in-memory ModelContainer failed — schema is unusable: \(error)")
        }
    }

    // MARK: Location

    /// Downtown Raleigh, Fayetteville St at Hargett St. Inside the bundled
    /// North Carolina trail pack, so Trails has data here as well as Find Routes.
    static let coordinate = CLLocationCoordinate2D(latitude: 35.7779, longitude: -78.6387)

    /// The location Find Routes uses in demo mode, or nil when the flag is absent.
    static func location(arguments: [String]) -> CLLocation? {
        guard isRequested(by: arguments) else { return nil }
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    // MARK: Seed

    // Fixed IDs so tests (and anyone checking a recording) can find the seed.
    static let walkID  = UUID(uuidString: "D3E70000-0000-4000-8000-000000000001") ?? UUID()
    static let routeID = UUID(uuidString: "D3E70000-0000-4000-8000-000000000002") ?? UUID()
    static let walkName  = "Downtown Loop"
    static let routeName = "Capitol Loop"

    /// Seeds one finished walk and one saved route when the flag is present.
    /// Returns whether it seeded. The stores must be on `container(arguments:)`.
    @MainActor
    @discardableResult
    static func seedIfRequested(arguments: [String], history: WalkHistoryStore,
                                routes: CustomRouteStore, now: Date = Date()) -> Bool {
        guard isRequested(by: arguments) else { return false }
        history.add(finishedWalk(now: now))
        routes.save(savedRoute(now: now))
        return true
    }

    /// A free walk recorded the way a real one is (a point every ~5 m), so the
    /// summary's "Save as Custom Route" rule and `RecordedRoute` both accept it.
    static func finishedWalk(now: Date = Date()) -> WalkSession {
        let path = recordedPath(through: [
            (35.7779, -78.6387), (35.7779, -78.6362),
            (35.7752, -78.6362), (35.7752, -78.6387), (35.7779, -78.6387)
        ], spacing: 5)
        let distance = length(of: path)
        return WalkSession(
            id: walkID, routeName: walkName,
            date: now.addingTimeInterval(-2 * 3600),
            elapsedTime: distance / 1.35,
            totalDistance: distance,
            waypoints: path.map(WaypointCoord.init),
            lapCount: 1, isLoop: false,
            steps: Int(distance / 0.762)
        )
    }

    /// A hand-built route: a few taps, legs hundreds of metres long.
    static func savedRoute(now: Date = Date()) -> CustomRoute {
        let points = [
            CLLocationCoordinate2D(latitude: 35.7779, longitude: -78.6387),
            CLLocationCoordinate2D(latitude: 35.7804, longitude: -78.6387),
            CLLocationCoordinate2D(latitude: 35.7804, longitude: -78.6403),
            CLLocationCoordinate2D(latitude: 35.7779, longitude: -78.6403)
        ]
        return CustomRoute(
            id: routeID, name: routeName,
            waypoints: points.map(WaypointCoord.init),
            totalDistance: length(of: points + [points[0]]),
            isLoop: true,
            createdAt: now.addingTimeInterval(-86_400)
        )
    }

    // MARK: Geometry

    private static func recordedPath(through corners: [(Double, Double)],
                                     spacing: Double) -> [CLLocationCoordinate2D] {
        let coords = corners.map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }
        var out: [CLLocationCoordinate2D] = []
        for (a, b) in zip(coords, coords.dropFirst()) {
            let steps = max(1, Int((meters(a, b) / spacing).rounded()))
            for i in 0..<steps {
                let t = Double(i) / Double(steps)
                out.append(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                  longitude: a.longitude + (b.longitude - a.longitude) * t))
            }
        }
        if let last = coords.last { out.append(last) }
        return out
    }

    private static func length(of points: [CLLocationCoordinate2D]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + meters($1.0, $1.1) }
    }

    private static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
#endif
