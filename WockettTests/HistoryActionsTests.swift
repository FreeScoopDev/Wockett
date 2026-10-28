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

    private func session(_ name: String, mode: ActivityMode = .walking, meters: Double = 3_218.688,
                         seconds: TimeInterval = 2_730, isHike: Bool = false) -> WalkSession {
        WalkSession(id: UUID(), routeName: name, date: Date(timeIntervalSince1970: 1_800_000_000),
                    elapsedTime: seconds, totalDistance: meters, waypoints: [], lapCount: 1,
                    isLoop: false, activityType: mode.rawValue, isHike: isHike)
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
        let indoor = session("Indoor Walk", mode: .stationary, meters: 804.672, seconds: 1_200)
        let review = RepeatReview(session: indoor, activePets: [], distanceFormatter: Self.miles)
        #expect(review.title == "Repeat this walk")
        #expect(review.activity == "Indoor walk")
        #expect(review.distance == "0.5 mi")
        #expect(!review.canStart)
        #expect(review.unavailableReason
                == "Indoor walks have no route to follow. Start one from Home: choose Indoor, then Start Indoor.")
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
            review: RepeatReview(session: session("Indoor Walk", mode: .stationary), activePets: []),
            begin: { calls += 1; return true })
        #expect(controller.start() == .unavailable)
        #expect(calls == 0)
        #expect(!controller.showAlreadyActive)
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
