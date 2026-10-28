import Testing
import Foundation
import MapKit
@testable import PoCSquat

/// Activity History's labelled actions (2026-10-27, spec fix/history-actions):
/// the Repeat review says what would start before anything does, only its
/// Start begins a walk, and the header's totals are the sums of the rows.
/// Every expected string is written by hand from the fixture.
@MainActor
struct HistoryActionsTests {

    /// Miles in US English whatever the simulator's region, so the expected
    /// strings below can be written by hand. MapKit's rounding: one decimal
    /// under 10 mi ("2.0 mi"), whole miles from 10 ("13 mi" for 12.5).
    private static let miles: MKDistanceFormatter = {
        let f = MKDistanceFormatter()
        f.unitStyle = .abbreviated
        f.units = .imperial
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    /// Two points: a route Repeat can follow. Pass `waypoints: []` for a
    /// session saved with none (manual, untracked, no GPS, pet entry, indoor).
    private static let path = [WaypointCoord(CLLocationCoordinate2D(latitude: 35.7779, longitude: -78.6387)),
                               WaypointCoord(CLLocationCoordinate2D(latitude: 35.7752, longitude: -78.6362))]

    private func session(_ name: String, mode: ActivityMode = .walking, meters: Double = 3_218.688,
                         seconds: TimeInterval = 2_730, isHike: Bool = false,
                         waypoints: [WaypointCoord] = HistoryActionsTests.path,
                         activePetIds: [UUID] = []) -> WalkSession {
        WalkSession(id: UUID(), routeName: name, date: Date(timeIntervalSince1970: 1_800_000_000),
                    elapsedTime: seconds, totalDistance: meters, waypoints: waypoints, lapCount: 1,
                    isLoop: false, activePetIds: activePetIds, activityType: mode.rawValue, isHike: isHike)
    }

    private func pet(_ name: String) -> PetProfile {
        PetProfile(name: name, isActiveOnWalk: true)
    }

    // MARK: Review model

    @Test("A hike repeats as a walk on the same route, and says so")
    func hikeReview() {
        let hike = session("Umstead Loop", meters: 3_218.688, seconds: 2_730, isHike: true)
        let review = RepeatReview(session: hike, activePets: [pet("Nala")], distanceFormatter: Self.miles)
        #expect(review.title == "Repeat this hike")
        #expect(review.activity == "Walk")
        #expect(review.routeName == "Umstead Loop")
        #expect(review.distance == "2.0 mi")        // 3,218.688 m = 2 mi; one decimal under 10
        #expect(review.duration == "45m 30s")       // 2,730 s
        #expect(review.companions == "Nala")
        #expect(review.note == "Starts as a walk on the same route. A hike starts from its trail.")
        #expect(review.canStart)
    }

    @Test("A ride with two pets names both")
    func rideReview() {
        let ride = session("River Greenway", mode: .cycling, meters: 16_093.44, seconds: 3_900)
        let review = RepeatReview(session: ride, activePets: [pet("Nala"), pet("Beef")],
                                  distanceFormatter: Self.miles)
        #expect(review.title == "Repeat this ride")
        #expect(review.activity == "Ride")
        #expect(review.distance == "10 mi")
        #expect(review.duration == "1h 5m")         // 3,900 s
        #expect(review.companions == "Nala and Beef")
        #expect(review.note == nil)
        #expect(review.canStart)
    }

    @Test("A run with no pets on the walk says No pets")
    func runNoPets() {
        let run = session("Track", mode: .running, meters: 1_609.344, seconds: 540)
        let review = RepeatReview(session: run, activePets: [], distanceFormatter: Self.miles)
        #expect(review.title == "Repeat this run")
        #expect(review.activity == "Run")
        #expect(review.distance == "1.0 mi")
        #expect(review.duration == "9m 0s")
        #expect(review.companions == "No pets")
    }

    @Test("An indoor walk cannot be repeated from History, and the sheet says why")
    func indoorReview() {
        let indoor = session("Indoor Walk", mode: .stationary, meters: 804.672, seconds: 1_200, waypoints: [])
        let review = RepeatReview(session: indoor, activePets: [], distanceFormatter: Self.miles)
        #expect(review.title == "Repeat this walk")
        #expect(review.activity == "Indoor walk")
        #expect(review.distance == "0.5 mi")
        #expect(!review.canStart)
        #expect(review.unavailableReason
                == "Indoor walks have no route to follow. Start one from Home: choose Indoor, then Start Indoor.")
    }

    // MARK: Which sessions can be repeated (fix/history-repeat-no-route)

    private static let indoorReason =
        "Indoor walks have no route to follow. Start one from Home: choose Indoor, then Start Indoor."

    @Test("Routed walks, runs, rides and hikes can be repeated")
    func routedCanRepeat() {
        for routed in [session("Loop"), session("Track", mode: .running),
                       session("Greenway", mode: .cycling), session("Umstead", isHike: true)] {
            #expect(RepeatReview.unavailableReason(for: routed) == nil, "\(routed.activityType)")
            #expect(RepeatReview(session: routed, activePets: []).canStart)
        }
    }

    @Test("A session with no waypoints cannot be repeated, in its own words")
    func noRouteCannotRepeat() {
        let pet = UUID()
        let cases: [(WalkSession, String)] = [
            // Log a Past Walk (`ManualWalkEntrySheet`): no route, any activity.
            (session("Riverside Path", waypoints: []),
             "This walk has no route to follow, so it can't be repeated. Start a new one from Home."),
            (session("Morning run", mode: .running, waypoints: []),
             "This run has no route to follow, so it can't be repeated. Start a new one from Home."),
            (session("Commute", mode: .cycling, waypoints: []),
             "This ride has no route to follow, so it can't be repeated. Start a new one from Home."),
            // `UntrackedWalkDetector` saves "Untracked Walk" with no points.
            (session("Untracked Walk", waypoints: []),
             "This walk has no route to follow, so it can't be repeated. Start a new one from Home."),
            // A free walk that never got a GPS fix keeps no breadcrumbs.
            (session("Free Walk", meters: 0, waypoints: []),
             "This walk has no route to follow, so it can't be repeated. Start a new one from Home."),
            // A 1.6 pet-credit entry: one pet, no time, no points.
            (session("Nala's Walk", meters: 1_609.344, seconds: 0, waypoints: [], activePetIds: [pet]),
             "This walk has no route to follow, so it can't be repeated. Start a new one from Home.")
        ]
        for (noRoute, reason) in cases {
            #expect(RepeatReview.unavailableReason(for: noRoute) == reason, "\(noRoute.routeName)")
            let review = RepeatReview(session: noRoute, activePets: [])
            #expect(!review.canStart, "\(noRoute.routeName)")
            #expect(review.unavailableReason == reason)
        }
        #expect(session("Nala's Walk", seconds: 0, waypoints: [], activePetIds: [pet]).isPetCreditEntry,
                "The legacy fixture must be what the app calls a pet-credit entry")
    }

    @Test("Indoor keeps its own reason, with or without waypoints")
    func indoorKeepsItsReason() {
        // An indoor pet-credit entry ("Nala's Indoor Walk") is indoor first.
        let entry = session("Nala's Indoor Walk", mode: .stationary, seconds: 0, waypoints: [],
                            activePetIds: [UUID()])
        #expect(RepeatReview.unavailableReason(for: entry) == Self.indoorReason)
        // No indoor session has points, but if one did it still starts from Home.
        #expect(RepeatReview.unavailableReason(for: session("Indoor Walk", mode: .stationary)) == Self.indoorReason)
    }

    @Test("Three or more pets: commas, then and")
    func threePets() {
        #expect(RepeatReview.names(["Nala", "Beef", "Miso"]) == "Nala, Beef and Miso")
    }

    // MARK: Start is the only way in

    @Test("Start begins the walk exactly once, however often it is tapped")
    func startOnce() {
        var calls = 0
        let controller = RepeatReviewController(
            review: RepeatReview(session: session("Loop"), activePets: []),
            begin: { calls += 1; return true })
        #expect(calls == 0, "Nothing begins when the review is made")
        #expect(controller.start() == .started)
        #expect(controller.start() == .started)
        #expect(calls == 1)
        #expect(controller.started)
        #expect(!controller.showAlreadyActive)
    }

    /// Only that: it fails if making or releasing the review calls `begin`.
    /// Cancel, swipe-down and the sheet appearing live in the view, not the
    /// controller; `testHistoryRepeatReviewsBeforeStarting` (UI) covers them,
    /// and went red when Start was made to fire on appear (2026-10-27).
    @Test("Making and releasing a review begins nothing")
    func cancelBeginsNothing() {
        var calls = 0
        var controller: RepeatReviewController? = RepeatReviewController(
            review: RepeatReview(session: session("Loop"), activePets: []),
            begin: { calls += 1; return true })
        #expect(controller?.started == false)
        controller = nil
        #expect(calls == 0)
    }

    @Test("A walk already in progress: the alert shows, and the sheet is not marked started")
    func alreadyActive() {
        var calls = 0
        let controller = RepeatReviewController(
            review: RepeatReview(session: session("Loop"), activePets: []),
            begin: { calls += 1; return false })
        #expect(controller.start() == .alreadyActive)
        #expect(calls == 1)
        #expect(controller.showAlreadyActive)
        #expect(!controller.started)
    }

    @Test("An indoor review never calls begin")
    func indoorNeverBegins() {
        var calls = 0
        let controller = RepeatReviewController(
            review: RepeatReview(session: session("Indoor Walk", mode: .stationary, waypoints: []), activePets: []),
            begin: { calls += 1; return true })
        #expect(controller.start() == .unavailable)
        #expect(calls == 0)
        #expect(!controller.showAlreadyActive)
    }

    @Test("A review with no route never calls begin")
    func noRouteNeverBegins() {
        var calls = 0
        let controller = RepeatReviewController(
            review: RepeatReview(session: session("Untracked Walk", waypoints: []), activePets: []),
            begin: { calls += 1; return true })
        #expect(controller.start() == .unavailable)
        #expect(calls == 0)
        #expect(!controller.started)
    }

    // MARK: Header totals

    @Test("The header sums every listed session, rides and zero-distance records included")
    func totalsSumTheRows() {
        let rows = [
            session("Walk", meters: 3_218.688, seconds: 2_730),
            session("Ride", mode: .cycling, meters: 16_093.44, seconds: 3_900),
            session("Pet entry", meters: 0, seconds: 0),
            session("Indoor", mode: .stationary, meters: 804.672, seconds: 1_200)
        ]
        let totals = HistoryTotals(sessions: rows)
        #expect(totals.count == 4)
        #expect(abs(totals.meters - 20_116.8) < 0.001)   // 2 + 10 + 0 + 0.5 mi
        #expect(totals.seconds == 7_830)            // 2,730 + 3,900 + 0 + 1,200
        #expect(totals.countText == "4 activities")
        #expect(totals.timeText == "2h 10m")        // 7,830 s = 130.5 min
        #expect(totals.summary(formatter: Self.miles) == "4 activities · 13 mi · 2h 10m")   // 12.5 mi, whole miles from 10 up
    }

    @Test("One activity under an hour; no activities")
    func totalsSmall() {
        let one = HistoryTotals(sessions: [session("Walk", meters: 1_609.344, seconds: 2_700)])
        #expect(one.countText == "1 activity")
        #expect(one.timeText == "45m")
        let none = HistoryTotals(sessions: [])
        #expect(none.countText == "0 activities")
        #expect(none.timeText == "0m")
        #expect(none.meters == 0)
    }
}
