import Testing
import CoreLocation
@testable import PoCSquat

/// The direction behind the beam on the user's dot: a usable compass reading,
/// or the direction of travel from the recorded track when there is none.
struct HeadingTrackerTests {

    private let origin = CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64)

    /// A point `meters` from `origin` along `bearing` degrees (flat-earth, fine at this scale).
    private func point(_ meters: Double, bearing: Double) -> CLLocationCoordinate2D {
        let rad = bearing * .pi / 180
        let dLat = meters * cos(rad) / 111_320
        let dLon = meters * sin(rad) / (111_320 * cos(origin.latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: origin.latitude + dLat, longitude: origin.longitude + dLon)
    }

    @Test("Bearings point the right way round the compass")
    func bearings() {
        for expected in [0.0, 45, 90, 180, 270, 315] {
            let b = HeadingTracker.bearing(from: origin, to: point(100, bearing: expected))
            let diff = abs(((b - expected) + 540).truncatingRemainder(dividingBy: 360) - 180)
            #expect(diff < 0.5, "expected \(expected), got \(b)")
            #expect(b >= 0 && b < 360)
        }
    }

    @Test("Direction of travel comes from the last few metres of the track")
    func courseFromTrack() throws {
        let track = [origin, point(20, bearing: 90), point(40, bearing: 90)]
        let course = try #require(HeadingTracker.course(along: track))
        #expect(abs(course - 90) < 1)
    }

    @Test("Standing still gives no direction, not a guess from GPS jitter")
    func standingStill() {
        let jitter = [origin, point(1, bearing: 10), point(2, bearing: 200), point(1.5, bearing: 90)]
        #expect(HeadingTracker.course(along: jitter) == nil)
        #expect(HeadingTracker.course(along: []) == nil)
        #expect(HeadingTracker.course(along: [origin]) == nil)
    }

    @Test("Only the recent track counts: a turn shows at once")
    func recentTrackWins() throws {
        // 200 m east, then 20 m north: the person is now heading north.
        let east = (0...20).map { point(Double($0) * 10, bearing: 90) }
        let corner = east.last ?? origin
        let north = (1...4).map { i in
            CLLocationCoordinate2D(latitude: corner.latitude + Double(i) * 5 / 111_320, longitude: corner.longitude)
        }
        let course = try #require(HeadingTracker.course(along: east + north))
        #expect(course < 5 || course > 355, "got \(course)")
    }

    @Test("Compass readings are used only when valid and reasonably accurate")
    func compassValidity() {
        #expect(HeadingTracker.usableHeading(accuracy: 10, trueHeading: 120, magneticHeading: 115) == 120)
        #expect(HeadingTracker.usableHeading(accuracy: 10, trueHeading: -1, magneticHeading: 115) == 115,
                "no true heading without location: fall back to magnetic")
        #expect(HeadingTracker.usableHeading(accuracy: -1, trueHeading: 120, magneticHeading: 115) == nil,
                "negative accuracy means the reading is invalid")
        #expect(HeadingTracker.usableHeading(accuracy: 60, trueHeading: 120, magneticHeading: 115) == nil,
                "a reading worse than 45° would point the beam the wrong way")
    }

    @MainActor
    @Test("With no compass, the tracker falls back to the direction of travel")
    func fallsBackToCourse() throws {
        let tracker = HeadingTracker()            // never started: no compass reading
        let track = [origin, point(30, bearing: 180)]
        let direction = try #require(tracker.direction(track: track))
        #expect(abs(direction - 180) < 1)
    }
}
