import CoreLocation
import Observation

// MARK: - Heading tracker
//
// Which way the person is facing, for the beam on their dot during a session
// (Joe, 2026-09-24: a directional indicator whenever they are on the map).
// MapKit draws a heading only in follow-with-heading mode, so the beam is
// ours and needs its own reading.
//
// The compass is used when it gives a usable reading. Otherwise the
// direction of travel stands in, from the session's own recorded track: the
// simulator has no compass, and a phone's compass can be uncalibrated or
// disturbed by a magnet in a case. No reading from either means no beam,
// never a guessed one.

@MainActor
@Observable
final class HeadingTracker: NSObject, CLLocationManagerDelegate {

    /// Degrees clockwise from true north (magnetic if true is unavailable), or nil.
    private(set) var compassHeading: CLLocationDirection?

    /// A compass reading worse than this many degrees is not used.
    nonisolated static let maximumAccuracyDegrees = 45.0

    @ObservationIgnored private let manager = CLLocationManager()

    func start() {
        guard CLLocationManager.headingAvailable() else { return }
        manager.delegate = self
        manager.headingFilter = 5
        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingHeading()
        compassHeading = nil
    }

    /// The compass if usable, else the direction of travel along `track`.
    func direction(track: [CLLocationCoordinate2D]) -> CLLocationDirection? {
        compassHeading ?? Self.course(along: track)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let value = Self.usableHeading(accuracy: newHeading.headingAccuracy,
                                       trueHeading: newHeading.trueHeading,
                                       magneticHeading: newHeading.magneticHeading)
        Task { @MainActor in self.compassHeading = value }
    }

    // MARK: Pure parts (tested)

    /// A heading reading, or nil when CoreLocation marks it invalid or too rough.
    nonisolated static func usableHeading(accuracy: CLLocationDirection,
                                          trueHeading: CLLocationDirection,
                                          magneticHeading: CLLocationDirection) -> CLLocationDirection? {
        guard accuracy >= 0, accuracy <= maximumAccuracyDegrees else { return nil }
        return trueHeading >= 0 ? trueHeading : magneticHeading
    }

    /// Bearing from the most recent point at least `minimumMeters` back to the
    /// newest one. Standing still (GPS jitter inside a few metres) gives nil.
    /// Only the last `lookBack` points are considered: the direction of travel
    /// is about the last few seconds, not the whole walk.
    nonisolated static func course(along track: [CLLocationCoordinate2D],
                                   minimumMeters: Double = 5,
                                   lookBack: Int = 30) -> CLLocationDirection? {
        guard let newest = track.last else { return nil }
        let end = CLLocation(latitude: newest.latitude, longitude: newest.longitude)
        for point in track.dropLast().suffix(lookBack).reversed() {
            let start = CLLocation(latitude: point.latitude, longitude: point.longitude)
            if end.distance(from: start) >= minimumMeters {
                return bearing(from: point, to: newest)
            }
        }
        return nil
    }

    /// Initial great-circle bearing, 0..<360 degrees clockwise from north.
    nonisolated static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
}
