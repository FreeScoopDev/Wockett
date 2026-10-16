import Testing
import SwiftData
import CoreLocation
import Foundation
@testable import PoCSquat

/// `-WKTDemo` seeds the how-to videos' starting state, in memory only, and
/// nothing at all without the flag. The tests pass the arguments in, because
/// the unit-test host itself is launched without the flag.
@MainActor
struct DemoModeTests {

    private let flag = ["-AppleLanguages", "(en)", DemoMode.launchArgument]

    /// The ordinary store a launch without the flag uses: in memory, no CloudKit.
    private func plainStores() throws -> (WalkHistoryStore, CustomRouteStore) {
        let container = try ModelContainer(for: AppModelContainer.schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                                              cloudKitDatabase: .none))
        return (WalkHistoryStore(context: container.mainContext), CustomRouteStore(context: container.mainContext))
    }

    // MARK: Flag absent

    @Test("Without -WKTDemo nothing is seeded, no demo store and no fixed location")
    func flagAbsentSeedsNothing() throws {
        let (history, routes) = try plainStores()
        let seeded = DemoMode.seedIfRequested(arguments: ["-WKTUITest"], history: history, routes: routes)
        #expect(!seeded)
        #expect(history.sessions.isEmpty)
        #expect(routes.routes.isEmpty)
        #expect(DemoMode.container(arguments: ["-WKTUITest"]) == nil)
        #expect(DemoMode.location(arguments: ["-WKTUITest"]) == nil)
        // The flag must be the exact argument, not a lookalike.
        #expect(!DemoMode.isRequested(by: ["-WKTDemoMode", "WKTDemo"]))
    }

    // MARK: Flag present

    @Test("With -WKTDemo a finished walk and a saved route are seeded")
    func flagPresentSeedsWalkAndRoute() throws {
        let container = try #require(DemoMode.container(arguments: flag))
        let history = WalkHistoryStore(context: container.mainContext)
        let routes  = CustomRouteStore(context: container.mainContext)

        #expect(DemoMode.seedIfRequested(arguments: flag, history: history, routes: routes))

        // In the walk history, and still there when the store reads its records again.
        let walk = try #require(WalkHistoryStore(context: container.mainContext).sessions.first { $0.id == DemoMode.walkID })
        #expect(history.sessions.count == 1)
        #expect(walk.date < Date())
        #expect(walk.totalDistance > 500)
        // What the summary's "Save as Custom Route" needs: a free walk with a
        // real breadcrumb line, recorded the way a phone records one.
        #expect(walk.customRouteId == nil)
        #expect(walk.waypoints.count > 5)
        #expect(RecordedRoute.isRecorded(walk.waypoints.map(\.clCoordinate)))

        // Under My Routes.
        let route = try #require(CustomRouteStore(context: container.mainContext).routes.first { $0.id == DemoMode.routeID })
        #expect(routes.routes.count == 1)
        #expect(route.waypoints.count >= 2)
        #expect(route.totalDistance > 0)
    }

    @Test("With -WKTDemo Find Routes searches from the fixed location, without asking")
    func flagPresentFixesLocation() async throws {
        let fixed = try #require(DemoMode.location(arguments: flag))
        #expect(fixed.coordinate.latitude == DemoMode.coordinate.latitude)
        #expect(fixed.coordinate.longitude == DemoMode.coordinate.longitude)

        // What the app hands RouteManager in demo mode. Every search
        // (Find Routes, nearby, trails) goes through this one lookup.
        let manager = RouteManager(fixedLocation: fixed)
        let found = try #require(await manager.fetchCurrentLocation())
        // Without it this would ask CoreLocation, which in the test host has no
        // permission and answers nil.
        #expect(found.distance(from: fixed) < 1)
    }

    // MARK: Not the CloudKit store

    /// The guard is the -WKTDemo branch at the top of `AppModelContainer.make`,
    /// the function `shared` is built from. Without that branch this call
    /// would open the persistent store (CloudKit-backed outside tests).
    @Test("With -WKTDemo the app's store is in memory with CloudKit off")
    func demoLaunchStoreIsInMemoryWithoutCloudKit() throws {
        let container = AppModelContainer.make(arguments: flag)
        let config = try #require(container.configurations.first)
        #expect(container.configurations.count == 1)
        #expect(config.isStoredInMemoryOnly)
        #expect(config.cloudKitContainerIdentifier == nil,
                "demo store syncs to \(config.cloudKitContainerIdentifier ?? "")")
    }

    // MARK: Nothing outlives the demo

    /// A walk recorded in demo mode must leave no checkpoint behind: a normal
    /// launch would offer to resume it or salvage it into the real store. And
    /// the demo must not read or delete a real walk's checkpoint.
    @Test("With -WKTDemo the walk checkpoint is never read, written or deleted")
    func demoHasNoCheckpointFile() {
        #expect(ActiveWalkSnapshotStore.fileURL(demo: true) == nil)
        #expect(ActiveWalkSnapshotStore.fileURL(demo: false) != nil)
    }

    @Test("With -WKTDemo streaks and seen badges are kept in memory, not UserDefaults")
    func demoStreaksAreNotPersisted() throws {
        #expect(StreakStore.make(demo: true).defaults == nil)
        #expect(StreakStore.make(demo: false).defaults === UserDefaults.standard)

        let walks = [DemoMode.finishedWalk()]
        // In memory: a badge is still announced once, not on every refresh.
        let demo = StreakStore(defaults: nil)
        #expect(demo.refresh(sessions: walks, todaySteps: 0, dailyGoal: 1) != nil)
        #expect(demo.refresh(sessions: walks, todaySteps: 0, dailyGoal: 1) == nil)

        // Control: a store with defaults does write them, so the nil case above
        // is a real difference and not a store that never writes.
        let suiteName = "DemoModeTests.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        StreakStore(defaults: suite).refresh(sessions: walks, todaySteps: 0, dailyGoal: 1)
        #expect(!(suite.stringArray(forKey: "wkt_seenBadges_v1") ?? []).isEmpty)
    }
}
