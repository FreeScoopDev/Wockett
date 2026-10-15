import Testing
import CoreLocation
import Foundation
import HealthKit
import SwiftData
@testable import PoCSquat

/// A walk started from a trail in the Trails list is a hike, unless the trail
/// is mapped as paved or as a bike path (feat/hike-wording, Joe 2026-10-15,
/// option B). A hike says "Hike" and is saved to Health as Hiking; its
/// `activityType` stays "walking". Whether a session is a hike is stored on
/// it, so these tests follow the flag from the trail to the saved walk.
@MainActor
struct HikeWordingTests {

    // MARK: Fixtures

    /// Google's polyline encoding at precision 5, as in TrailWalkTests.
    private func encode(_ coords: [CLLocationCoordinate2D]) -> String {
        var out = ""
        var lastLat = 0, lastLon = 0
        for c in coords {
            let lat = Int((c.latitude * 1e5).rounded()), lon = Int((c.longitude * 1e5).rounded())
            for delta in [lat - lastLat, lon - lastLon] {
                var v = delta < 0 ? ~(delta << 1) : (delta << 1)
                while v >= 0x20 {
                    out.append(Character(UnicodeScalar(UInt8((0x20 | (v & 0x1f)) + 63))))
                    v >>= 5
                }
                out.append(Character(UnicodeScalar(UInt8(v + 63))))
            }
            lastLat = lat; lastLon = lon
        }
        return out
    }

    /// `count` points ~100 m apart, east from (35.78, -78.64), shifted `offset` points along.
    private func line(_ count: Int, offset: Int = 0) -> [CLLocationCoordinate2D] {
        (0..<count).map { CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64 + Double($0 + offset) * 0.0011) }
    }

    private func section(_ id: Int64, _ coords: [CLLocationCoordinate2D], surface: String?,
                         highway: String = "footway") -> TrailFeature {
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        return TrailFeature(id: id, sourceID: "osm", sourceRef: "w\(id)", name: "Test Trail",
                            encodedPolyline: encode(coords), pointCount: coords.count,
                            lengthMeters: TrailWalkPlanner.length(coords),
                            bounds: TrailBounds(minLatitude: lats.min() ?? 0, minLongitude: lons.min() ?? 0,
                                                maxLatitude: lats.max() ?? 0, maxLongitude: lons.max() ?? 0),
                            surface: surface, difficulty: nil, dogAccess: .unknown, dogAccessProvenance: .default,
                            allowsFoot: true, allowsBike: highway == "cycleway", allowsHorse: false, isLoop: false,
                            tagsJSON: #"{"highway":"\#(highway)"}"#)
    }

    /// A one-section trail ~1 km long.
    private func trail(surface: String?, highway: String = "footway") -> TrailListItem {
        TrailListItem(id: "osm:w1", name: "Test Trail", sections: [section(1, line(11), surface: surface, highway: highway)],
                      distanceMeters: 0)
    }

    /// Two sections that chain end to end, so the planner walks them as one line.
    private func group(_ a: (String?, String), _ b: (String?, String)) -> TrailListItem {
        TrailListItem(id: "osm:g", name: "Test Trail",
                      sections: [section(1, line(6), surface: a.0, highway: a.1),
                                 section(2, line(6, offset: 5), surface: b.0, highway: b.1)],
                      distanceMeters: 0)
    }

    private var atStart: CLLocationCoordinate2D { line(1)[0] }

    // MARK: Which trails are hikes

    @Test("A trail is a hike unless it is mapped as paved or as a bike path")
    func classifier() {
        #expect(trail(surface: "dirt").isHikeable)
        #expect(trail(surface: "gravel").isHikeable)
        #expect(trail(surface: nil).isHikeable, "no surface tag: only a stated paved surface makes it a walk")
        #expect(trail(surface: "something_new").isHikeable, "an unknown surface is not a stated paved one")
        #expect(!trail(surface: "asphalt").isHikeable, "a paved greenway stays a walk")
        #expect(!trail(surface: "concrete").isHikeable)
        #expect(!trail(surface: "dirt", highway: "cycleway").isHikeable, "a bike path stays a walk, whatever its surface")
        #expect(!trail(surface: nil, highway: "cycleway").isHikeable)
    }

    @Test("A grouped trail: sections that disagree on surface are a hike; all bike path is a walk")
    func groupedClassifier() {
        #expect(group(("asphalt", "footway"), ("dirt", "footway")).isHikeable, "mixed surfaces state no single paved surface")
        #expect(!group(("asphalt", "footway"), ("asphalt", "footway")).isHikeable)
        #expect(!group((nil, "cycleway"), (nil, "cycleway")).isHikeable)
        #expect(group((nil, "cycleway"), (nil, "footway")).isHikeable, "only partly a bike path")
    }

    // MARK: From the trail to the session

    @Test("The plan from the Trails list carries the trail's hikeability, single or grouped")
    func planCarriesHikeability() throws {
        #expect(try #require(TrailWalkPlanner.plan(for: trail(surface: "dirt"), from: atStart)).isHikeable)
        #expect(try #require(TrailWalkPlanner.plan(for: trail(surface: "asphalt"), from: atStart)).isHikeable == false)
        let stitched = try #require(TrailWalkPlanner.plan(for: group(("dirt", "footway"), ("dirt", "footway")),
                                                           from: atStart))
        #expect(stitched.isHikeable, "a group walked as one stitched line")
        let pavedGroup = try #require(TrailWalkPlanner.plan(for: group(("asphalt", "footway"), ("asphalt", "footway")),
                                                             from: atStart))
        #expect(!pavedGroup.isHikeable)
        #expect(try #require(TrailWalkPlanner.plan(along: line(11), isLoop: false, name: "x", from: atStart))
                    .isHikeable == false, "a plan not made from a Trails-list trail is never a hike")
    }

    @Test("Start Hike on a hikeable trail for a walk; a run and a ride keep their words; a paved trail says Walk")
    func startButtonLabel() throws {
        let hike = try #require(TrailWalkPlanner.plan(for: trail(surface: "dirt"), from: atStart))
        let paved = try #require(TrailWalkPlanner.plan(for: trail(surface: "asphalt"), from: atStart))
        #expect(hike.wording(activityMode: .walking).sessionLabel == "Hike")
        #expect(hike.wording(activityMode: .running).sessionLabel == "Run")
        #expect(hike.wording(activityMode: .cycling).sessionLabel == "Ride")
        #expect(paved.wording(activityMode: .walking).sessionLabel == "Walk")
    }

    @Test("The session started from the plan is a hike exactly when the button said Hike")
    func sessionRouteIsHike() throws {
        let hike = try #require(TrailWalkPlanner.plan(for: trail(surface: "dirt"), from: atStart))
        let paved = try #require(TrailWalkPlanner.plan(for: trail(surface: "asphalt"), from: atStart))
        let walk = hike.navigableRoute(activityMode: .walking)
        #expect(walk.isHike && walk.activityMode == .walking, "a hike's activity stays walking")
        #expect(!hike.navigableRoute(activityMode: .running).isHike)
        #expect(!hike.navigableRoute(activityMode: .cycling).isHike)
        #expect(!paved.navigableRoute(activityMode: .walking).isHike)
    }

    @Test("A walk to a trail stays a walk when it carries on along the trail")
    func approachStaysAWalk() throws {
        let item = trail(surface: "dirt")
        #expect(item.isHikeable)
        let home = CLLocationCoordinate2D(latitude: 35.7881, longitude: -78.6345)
        let access = CLLocationCoordinate2D(latitude: 35.78, longitude: -78.6345)
        let mgr = NavigationSessionManager(route: TrailApproach(item: item)
            .navigableRoute(from: home, to: access, distanceMeters: 1_100, activityMode: .walking))
        mgr.writesSnapshots = false
        #expect(!mgr.route.isHike)
        mgr.checkArrival(at: CLLocation(coordinate: access, altitude: 0, horizontalAccuracy: 5,
                                        verticalAccuracy: 5, timestamp: Date()))
        let next = try #require(mgr.beginTrailWalk())
        #expect(!next.isHike, "its Health workout began as a walk, so it stays one")
        #expect(!mgr.completedSession.isHike)
    }

    // MARK: Words

    @Test("Each activity's words, and a hike's")
    func wordingForEachMode() {
        let hike = SessionWording(.walking, isHike: true)
        #expect([hike.sessionLabel, hike.displayName, hike.noun, hike.gerund] == ["Hike", "Hike", "hike", "hiking"])
        let walk = SessionWording(.walking)
        #expect([walk.sessionLabel, walk.displayName, walk.noun, walk.gerund] == ["Walk", "Walk", "walk", "walking"])
        // isHike is ignored for anything but a walk.
        for mode in [ActivityMode.running, .cycling, .stationary] {
            let w = SessionWording(mode, isHike: true)
            #expect(!w.isHike)
            #expect(w.sessionLabel == mode.sessionLabel && w.displayName == mode.displayName
                    && w.noun == mode.noun && w.gerund == mode.gerund && w.hkActivityType == mode.hkActivityType)
        }
        #expect(SessionWording(.cycling, isHike: true).sessionLabel == "Ride")
    }

    @Test("A saved hike reads as a hike; changed to a run in Past Walks, it reads as a run")
    func savedSessionWording() {
        var session = WalkSession(id: UUID(), routeName: "Test Trail", date: Date(), elapsedTime: 600,
                                  totalDistance: 1_000, waypoints: [], lapCount: 1, isLoop: false, isHike: true)
        #expect(session.wording.sessionLabel == "Hike")
        #expect(session.activityType == "walking")
        session.activityType = "running"
        #expect(session.wording.sessionLabel == "Run")
    }

    @Test("The Live Activity says Hike for a hike, Walk for a walk, and decodes an older activity as a walk")
    func liveActivityNoun() throws {
        func attrs(_ mode: String, _ hike: Bool) -> WalkActivityAttributes {
            WalkActivityAttributes(routeName: "T", totalDistanceMeters: 0, activityMode: mode, isHike: hike, startDate: Date())
        }
        #expect(attrs("walking", true).activityNoun == "Hike")
        #expect(attrs("walking", false).activityNoun == "Walk")
        #expect(attrs("running", true).activityNoun == "Run")
        #expect(attrs("cycling", false).activityNoun == "Ride")
        #expect(attrs("stationary", false).activityNoun == "Walk")
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(attrs("walking", true)))
                                as? [String: Any])
        json.removeValue(forKey: "isHike")
        let old = try JSONDecoder().decode(WalkActivityAttributes.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.activityNoun == "Walk")
    }

    // MARK: Apple Health, through the WalkWorkoutRecording seam

    private final class TypedFakeWriter: WalkWorkoutRecording {
        private(set) var started = false
        func start(at date: Date) async { started = true }
        func addLocations(_ locations: [CLLocation]) {}
        func discard() {}
        func finish(totalDistanceMeters: Double, endDate: Date) async -> HKWorkout? { nil }
    }

    private func workoutType(for route: NavigableRoute) async -> HKWorkoutActivityType? {
        let mgr = NavigationSessionManager(route: route)
        mgr.writesSnapshots = false
        var asked: HKWorkoutActivityType?
        let fake = TypedFakeWriter()
        mgr.makeWorkoutWriter = { asked = $0; return fake }
        await mgr.startWorkout(at: Date())
        #expect(fake.started && mgr.workoutWriter === fake, "the session keeps the writer it started")
        return asked
    }

    @Test("A hike is saved to Health as Hiking; a trail walk on a paved trail, a run and a free walk are not")
    func healthWorkoutType() async throws {
        let hike = try #require(TrailWalkPlanner.plan(for: trail(surface: "dirt"), from: atStart))
        let paved = try #require(TrailWalkPlanner.plan(for: trail(surface: "asphalt"), from: atStart))
        #expect(await workoutType(for: hike.navigableRoute(activityMode: .walking)) == .hiking)
        #expect(await workoutType(for: paved.navigableRoute(activityMode: .walking)) == .walking)
        #expect(await workoutType(for: hike.navigableRoute(activityMode: .running)) == .running)
        #expect(await workoutType(for: hike.navigableRoute(activityMode: .cycling)) == .cycling)
        let free = NavigableRoute(name: "Free Walk", waypoints: [], lapCount: 1, isLoop: false, totalDistance: 0)
        #expect(await workoutType(for: free) == .walking)
    }

    // MARK: Stored on the session

    @Test("The saved walk keeps the route's hike flag")
    func completedSessionIsHike() throws {
        let hike = try #require(TrailWalkPlanner.plan(for: trail(surface: "dirt"), from: atStart))
        let paved = try #require(TrailWalkPlanner.plan(for: trail(surface: "asphalt"), from: atStart))
        for (plan, expected) in [(hike, true), (paved, false)] {
            let mgr = NavigationSessionManager(route: plan.navigableRoute(activityMode: .walking))
            mgr.writesSnapshots = false
            let saved = mgr.completedSession
            #expect(saved.isHike == expected)
            #expect(saved.activityType == "walking")
        }
    }

    @Test("Head back now keeps a hike a hike")
    func headBackKeepsHike() throws {
        let item = TrailListItem(id: "osm:w1", name: "Long Trail",
                                 sections: [section(1, line(51), surface: "dirt")], distanceMeters: 0)
        let from = line(51)[10]
        let plan = try #require(TrailWalkPlanner.plan(for: item, from: from, target: .roundTrip(meters: 2_000)))
        let route = plan.navigableRoute(activityMode: .walking)
        #expect(route.isHike)
        let mgr = NavigationSessionManager(route: route)
        mgr.writesSnapshots = false
        mgr.applySnapshot(ActiveWalkSnapshot(route: .init(route), startTime: Date().addingTimeInterval(-600),
                                             totalDistanceCovered: 600, pausedDuration: 0, isPaused: false,
                                             pauseStartDate: nil, currentWaypointIndex: 1, currentLap: 1,
                                             triggeredCheckpoints: [], splitTimes: [], liveSteps: 0,
                                             checkpointDate: Date(), trailAlong: 600))
        let back = try #require(mgr.headBack())
        #expect(back.isHike)
        #expect(mgr.completedSession.isHike)
    }

    @Test("A hike set off round a loop the other way is still a hike, saved as one")
    func turnedRoundLoopKeepsHike() throws {
        let square = [CLLocationCoordinate2D(latitude: 35.780, longitude: -78.640),
                      CLLocationCoordinate2D(latitude: 35.780, longitude: -78.6356),
                      CLLocationCoordinate2D(latitude: 35.7836, longitude: -78.6356),
                      CLLocationCoordinate2D(latitude: 35.7836, longitude: -78.640),
                      CLLocationCoordinate2D(latitude: 35.780, longitude: -78.640)]
        let lats = square.map(\.latitude), lons = square.map(\.longitude)
        let loop = TrailFeature(id: 9, sourceID: "osm", sourceRef: "w9", name: "Loop",
                                encodedPolyline: encode(square), pointCount: square.count,
                                lengthMeters: TrailWalkPlanner.length(square),
                                bounds: TrailBounds(minLatitude: lats.min() ?? 0, minLongitude: lons.min() ?? 0,
                                                    maxLatitude: lats.max() ?? 0, maxLongitude: lons.max() ?? 0),
                                surface: "dirt", difficulty: nil, dogAccess: .unknown, dogAccessProvenance: .default,
                                allowsFoot: true, allowsBike: false, allowsHorse: false, isLoop: true,
                                tagsJSON: #"{"highway":"footway"}"#)
        let item = TrailListItem(id: "osm:w9", name: "Loop", sections: [loop], distanceMeters: 0)
        let plan = try #require(TrailWalkPlanner.plan(for: item, from: square[0]))
        let route = plan.navigableRoute(activityMode: .walking)
        #expect(route.isHike)
        let turned = try #require(route.reversedAlongLine())
        #expect(turned.isHike, "turning round must not make the hike a walk")
        let mgr = NavigationSessionManager(route: route)
        mgr.writesSnapshots = false
        let progress = try #require(TrailProgress(route: turned))
        mgr.turnRouteRound(TrailProgress.TurnedRound(route: turned, progress: progress, index: 1, lap: 1))
        #expect(mgr.route.isHike)
        #expect(mgr.completedSession.isHike)
    }

    @Test("A hike survives the crash checkpoint and its salvage; an older checkpoint restores as a walk")
    func snapshotKeepsHike() throws {
        let plan = try #require(TrailWalkPlanner.plan(for: trail(surface: "dirt"), from: atStart))
        let route = plan.navigableRoute(activityMode: .walking)
        let data = try JSONEncoder().encode(ActiveWalkSnapshot.RouteData(route))
        let restored = try JSONDecoder().decode(ActiveWalkSnapshot.RouteData.self, from: data)
        #expect(restored.navigableRoute.isHike)

        let snapshot = ActiveWalkSnapshot(route: restored, startTime: Date().addingTimeInterval(-900),
                                          totalDistanceCovered: 800, pausedDuration: 0, isPaused: false,
                                          pauseStartDate: nil, currentWaypointIndex: 1, currentLap: 1,
                                          triggeredCheckpoints: [], splitTimes: [], liveSteps: 0,
                                          checkpointDate: Date())
        #expect(ActiveWalkStore.salvagedSession(from: snapshot).isHike)

        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "isHike")
        let old = try JSONDecoder().decode(ActiveWalkSnapshot.RouteData.self,
                                           from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.navigableRoute.isHike)
    }

    @Test("WalkSession: a hike round-trips; a session saved before hikes decodes as a walk")
    func walkSessionCodable() throws {
        let hike = WalkSession(id: UUID(), routeName: "Test Trail", date: Date(), elapsedTime: 600,
                               totalDistance: 1_000, waypoints: [], lapCount: 1, isLoop: false, isHike: true)
        let data = try JSONEncoder().encode(hike)
        #expect(try JSONDecoder().decode(WalkSession.self, from: data).isHike)

        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "isHike")
        let old = try JSONDecoder().decode(WalkSession.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.isHike)
        #expect(old.wording.sessionLabel == "Walk")
    }

    @Test("The SwiftData record saves and loads the flag")
    func recordRoundTrip() throws {
        let config = ModelConfiguration(schema: AppModelContainer.schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppModelContainer.schema, configurations: config)
        let context = ModelContext(container)
        let store = WalkHistoryStore(context: context)
        let hike = WalkSession(id: UUID(), routeName: "Test Trail", date: Date(), elapsedTime: 600,
                               totalDistance: 1_000, waypoints: [], lapCount: 1, isLoop: false, isHike: true)
        let walk = WalkSession(id: UUID(), routeName: "Free Walk", date: Date().addingTimeInterval(-60),
                               elapsedTime: 600, totalDistance: 1_000, waypoints: [], lapCount: 1, isLoop: false)
        store.add(hike)
        store.add(walk)
        // A second store reads the records back from SwiftData, not the first one's memory.
        let reloaded = WalkHistoryStore(context: context).sessions
        #expect(reloaded.first { $0.id == hike.id }?.isHike == true)
        #expect(reloaded.first { $0.id == walk.id }?.isHike == false)
    }
}
