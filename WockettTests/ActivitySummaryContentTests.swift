import Testing
import Foundation
import CoreLocation
@testable import PoCSquat

// Which figures each activity's summary, notes sheet and share card show
// (`ActivitySummaryContent`). Until 2026-10-13 a ride showed steps worked out
// from its distance and an indoor share card a pace worked out from steps.
struct ActivitySummaryContentTests {

    private func session(_ type: String, distance: Double = 3000, elapsed: TimeInterval = 1800,
                         steps: Int = 0, waypoints: Int = 0) -> WalkSession {
        WalkSession(
            id: UUID(), routeName: "Test", date: Date(),
            elapsedTime: elapsed, totalDistance: distance,
            waypoints: (0..<waypoints).map { WaypointCoord(CLLocationCoordinate2D(latitude: 35 + Double($0) * 0.001, longitude: -78)) },
            lapCount: 1, isLoop: false, activityType: type, steps: steps
        )
    }

    @Test func walkAndRun_showDistanceTimePaceSteps() {
        for type in ["walking", "running"] {
            #expect(ActivitySummaryContent.stats(for: session(type)) == [.distance, .time, .pace, .steps])
            #expect(ActivitySummaryContent.cardStats(for: session(type)) == [.distance, .time, .pace])
        }
    }

    @Test func ride_neverShowsSteps() {
        let ride = session("cycling", distance: 14_000, elapsed: 2520)
        #expect(ActivitySummaryContent.stats(for: ride) == [.distance, .time, .speed])
        #expect(ActivitySummaryContent.cardStats(for: ride) == [.distance, .time, .speed])
    }

    @Test func indoor_neverShowsPace() {
        let indoor = session("stationary", distance: 3048, steps: 4000)
        let stats = ActivitySummaryContent.stats(for: indoor)
        #expect(stats == [.steps, .time, .cadence, .estimatedDistance])
        #expect(ActivitySummaryContent.cardStats(for: indoor) == [.steps, .time, .cadence])
        #expect(!stats.contains(.pace) && !stats.contains(.speed))
    }

    // Pet-credit entries and walks with no time have no cadence to show.
    @Test func indoorWithNoTime_hasNoCadenceTile() {
        let indoor = session("stationary", distance: 3048, elapsed: 0, steps: 4000)
        #expect(ActivitySummaryContent.stats(for: indoor) == [.steps, .time, .estimatedDistance])
    }

    // The existing pace rule: none under 100 m or with no time.
    @Test func shortWalk_hasNoPaceTile() {
        #expect(ActivitySummaryContent.stats(for: session("walking", distance: 80)) == [.distance, .time, .steps])
        #expect(ActivitySummaryContent.stats(for: session("cycling", elapsed: 0)) == [.distance, .time])
    }

    @Test func values() {
        let indoor = session("stationary", distance: 3048, elapsed: 1800, steps: 4000)
        #expect(SummaryStat.steps.value(for: indoor) == 4000.formatted())
        #expect(SummaryStat.cadence.value(for: indoor) == "133 spm")
        let ride = session("cycling", distance: 15_000, elapsed: 3000)
        #expect(SummaryStat.speed.value(for: ride, metric: true) == "18.0 km/h")
        #expect(SummaryStat.pace.value(for: session("walking", distance: 1000, elapsed: 600), metric: true) == "10:00/km")
    }

    @Test func onlyAnActivityWithALine_hasARoute() {
        #expect(!ActivitySummaryContent.hasRoute(session("stationary")))
        #expect(!ActivitySummaryContent.hasRoute(session("walking", waypoints: 1)))
        #expect(ActivitySummaryContent.hasRoute(session("walking", waypoints: 2)))
    }

    @Test func shareCaption_followsTheActivity() {
        #expect(ActivitySummaryContent.shareCaption(for: session("walking")).hasPrefix("Just walked "))
        #expect(ActivitySummaryContent.shareCaption(for: session("running")).hasPrefix("Just ran "))
        #expect(ActivitySummaryContent.shareCaption(for: session("cycling")).hasPrefix("Just rode "))
        let indoor = ActivitySummaryContent.shareCaption(for: session("stationary", steps: 4000))
        #expect(indoor.hasPrefix("Just walked \(4000.formatted()) steps indoors in "))
    }

    @Test func titlesFollowTheActivity() {
        #expect(ActivityMode.walking.displayName == "Walk")
        #expect(ActivityMode.running.displayName == "Run")
        #expect(ActivityMode.cycling.displayName == "Ride")
        #expect(ActivityMode.stationary.displayName == "Indoor walk")
    }
}
