import Testing
import SwiftData
import CoreLocation
import Foundation
@testable import PoCSquat

/// Saved routes survive a relaunch as they were last edited.
@MainActor
struct CustomRouteStoreTests {

    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: CustomRouteRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func coord(_ lat: Double, _ lon: Double) -> WaypointCoord {
        WaypointCoord(.init(latitude: lat, longitude: lon))
    }

    @Test("Waypoints edited in the builder are still there after a relaunch")
    func editedWaypointsPersist() throws {
        let ctx = try context()
        let store = CustomRouteStore(context: ctx)
        let original = CustomRoute(id: UUID(), name: "Park", waypoints: [coord(35.0, -78.0), coord(35.01, -78.0)],
                                   totalDistance: 1100, isLoop: false, createdAt: Date())
        store.save(original)

        // What CustomRoutesListView does with the builder's result: same id, new points.
        let edited = CustomRoute(id: original.id, name: "Park", waypoints: [coord(35.0, -78.0), coord(35.02, -78.01), coord(35.03, -78.0)],
                                 totalDistance: 3400, isLoop: true, createdAt: original.createdAt)
        store.update(edited)

        let relaunched = CustomRouteStore(context: ctx)   // reads the records again, as a relaunch does
        let saved = try #require(relaunched.routes.first { $0.id == original.id })
        #expect(saved.waypoints == edited.waypoints)
        #expect(saved.totalDistance == 3400 && saved.isLoop)
    }

    @Test("Renaming keeps the route's points")
    func renameKeepsWaypoints() throws {
        let ctx = try context()
        let store = CustomRouteStore(context: ctx)
        let route = CustomRoute(id: UUID(), name: "Old", waypoints: [coord(35.0, -78.0), coord(35.01, -78.0)],
                                totalDistance: 1100, isLoop: false, createdAt: Date())
        store.save(route)
        var renamed = route
        renamed.name = "New"
        store.update(renamed)
        let saved = try #require(CustomRouteStore(context: ctx).routes.first)
        #expect(saved.name == "New" && saved.waypoints == route.waypoints)
    }
}
