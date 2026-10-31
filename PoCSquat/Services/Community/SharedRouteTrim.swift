import Foundation
import CoreLocation
import MapKit

/// A user's secret shift of the privacy zones (`SharedRouteTrim`): a random
/// direction and 50-150 m, plus a random 0-100 m added to every zone's radius.
/// Made once, from the system's random number generator and nothing public,
/// and kept in the user's private iCloud database (`SharePrivacyOffsetStore`),
/// so every device the user shares from moves the zones the same way.
struct SharePrivacyOffset: Equatable {
    /// The shift of each zone's centre from the end it hides, in metres.
    let east: Double
    let north: Double
    /// Added to every zone's radius, so the radius doesn't give away the
    /// length of the shift.
    let extra: Double

    static let shiftRange: ClosedRange<Double> = 50...150
    static let extraRange: ClosedRange<Double> = 0...100

    var shift: Double { hypot(east, north) }

    /// A value the store would never have written is treated as missing.
    var isValid: Bool {
        east.isFinite && north.isFinite && extra.isFinite
            && Self.shiftRange.contains(shift) && Self.extraRange.contains(extra)
    }

    static func random() -> SharePrivacyOffset {
        var rng = SystemRandomNumberGenerator()
        let bearing = Double.random(in: 0..<(2 * .pi), using: &rng)
        let shift = Double.random(in: shiftRange, using: &rng)
        return SharePrivacyOffset(east: shift * sin(bearing), north: shift * cos(bearing),
                                  extra: Double.random(in: extraRange, using: &rng))
    }

    /// The centre of the zone that hides `end`.
    func centre(for end: WaypointCoord) -> WaypointCoord {
        let metresPerDegree = 111_320.0
        let eastDegrees = east / (metresPerDegree * max(0.01, cos(end.latitude * .pi / 180)))
        return WaypointCoord(CLLocationCoordinate2D(latitude: end.latitude + north / metresPerDegree,
                                                    longitude: end.longitude + eastDegrees))
    }
}

/// What a shared route publishes. Anyone can read a shared route, and most
/// walks start and end at home, so both share buttons warn about that and
/// offer **Hide start and finish** (`prepare`, on until the user turns it off;
/// the choice is remembered under `hideEndsKey`). The route the user keeps on
/// the phone is never changed. Either way:
///
/// - **Only a path, never control points.** The input must be the line the
///   route follows (a recording, or walking directions), not the few points a
///   route was planned from: a suggested loop's points are three corners of a
///   square whose fourth corner is home.
/// - **Evenly respaced.** Published points are every 10 m along the path, so
///   other phones follow it as a recorded line (`RecordedRoute`) instead of
///   asking for directions between hundreds of points.
///
/// With Hide start and finish on (`trim`), each rule answering a way the start
/// was recovered from an earlier version in review:
///
/// - **A privacy zone whose centre is moved by a secret.** Each end is hidden
///   by a circle centred on that end plus the user's `SharePrivacyOffset`, with
///   a radius of the shift + 200 m + the user's extra, so the end is at least
///   200 m inside it. Every published point lies outside both circles. The
///   published line of a loop starts and ends on one circle, and an observer
///   can find that circle's centre from a few routes; the centre is the same
///   false place for all of one user's routes, 50-150 m from home.
/// - **Tested every 10 m.** The path is redrawn with a point every 10 m before
///   the zones are applied, so a long straight segment through a zone can't
///   carry a point into it, and those tested points are what is published.
/// - **One unbroken stretch, and a real one.** Only the longest run of points
///   outside the zones is published, so the line never jumps across a zone,
///   and only if it is at least 400 m and a quarter of the route.
///
/// This hides where a route starts and finishes, not the area around it.
enum SharedRouteTrim {
    /// UserDefaults: the user's last Hide start and finish choice. Written
    /// only when the toggle changes, so a missing value means the user never
    /// chose, and gets `hideEndsDefault`; a stored off stays off.
    static let hideEndsKey = "wkt_routeShareHideEnds"
    static let hideEndsDefault = true
    /// Shown above the choice on both share screens.
    static let homeWarning = "If this route starts or ends at your home, people will be able to see where you live."

    /// The least distance between a published point and either end.
    static let trimMeters: Double = 200
    /// The shortest route that can be shared at all.
    static let minimumMeters: Double = 600
    /// The kept stretch must be at least this long, and this share of the route.
    static let minimumKeptMeters: Double = 400
    static let minimumKeptFraction: Double = 0.25
    /// Spacing of the tested, and published, points.
    static let spacingMeters: Double = 10
    /// A path has at least this many points, at most this far apart (median).
    /// Planned routes' control points are hundreds of metres apart; walking
    /// directions and recordings are tens of metres or less.
    static let minimumPathPoints = 10
    static let maxMedianSpacingMeters: Double = 100
    /// The most points one shared route carries: about 120 km at 10 m, and
    /// well under CloudKit's 1 MB record limit as JSON (about 63 bytes each).
    static let maxPublishedPoints = 12_000

    struct Trimmed: Equatable {
        /// The points to publish: every `spacingMeters` along the kept stretch.
        let waypoints: [WaypointCoord]
        /// Length along the path before trimming (a loop includes its leg home).
        let fullMeters: Double
        /// Length of the kept stretch: the distance a shared route publishes.
        let keptMeters: Double
        /// The start and finish were left off (`trim`).
        let hidesEnds: Bool
        /// Published as a loop. Never after `trim`: a viewer's app closes a
        /// loop by routing back to its first point, which would draw the
        /// hidden ends back in.
        let isLoop: Bool
    }

    enum Outcome: Equatable {
        case trimmed(Trimmed)
        /// Too short to share, or too little of it lies outside the zones.
        case tooShort(fullMeters: Double)
        /// Planning points rather than a path, or no path at all.
        case notAPath
        /// The user's `SharePrivacyOffset` isn't available yet.
        case offsetUnavailable
        /// More than `maxPublishedPoints`: too big for one record.
        case tooLong
    }

    /// Thrown by `CommunityRouteService.publish` for a route that can't be trimmed.
    struct CannotShareError: LocalizedError, Equatable {
        let outcome: Outcome
        var errorDescription: String? { message }
        var message: String { SharedRouteTrim.message(for: outcome) ?? "" }
    }

    /// Why a route can't be shared, or nil when it can.
    static func message(for outcome: Outcome) -> String? {
        switch outcome {
        case .trimmed:
            return nil
        case .tooShort:
            return "This route is too short to share with its start and finish hidden. Wockett leaves off everything within at least "
                + "\(formatted(trimMeters)) of where it starts and finishes, and needs at least "
                + "\(formatted(minimumKeptMeters)) left over."
        case .notAPath:
            return "Wockett couldn't load the path this route follows, which it needs to share it. "
                + "Check your connection, then open the route again."
        case .tooLong:
            return "This route is too long to share. Wockett can share routes up to "
                + "\(formatted(Double(maxPublishedPoints) * spacingMeters)) long."
        case .offsetUnavailable:
            return "Sharing needs iCloud to set up your privacy area, so it's the same on all your devices. "
                + "Check you're signed in to iCloud and online, then try again."
        }
    }

    /// What a share publishes: the whole path respaced, or with `hideEnds`
    /// the `trim`med one.
    static func prepare(_ waypoints: [WaypointCoord], isLoop: Bool, hideEnds: Bool,
                        offset: SharePrivacyOffset?) -> Outcome {
        let outcome = hideEnds ? trim(waypoints, isLoop: isLoop, offset: offset) : whole(waypoints, isLoop: isLoop)
        if case .trimmed(let t) = outcome, t.waypoints.count > maxPublishedPoints { return .tooLong }
        return outcome
    }

    static func prepare(_ route: CustomRoute, hideEnds: Bool, offset: SharePrivacyOffset?) -> Outcome {
        prepare(route.waypoints, isLoop: route.isLoop, hideEnds: hideEnds, offset: offset)
    }

    /// The whole path, as the user drew or walked it, respaced every 10 m.
    /// Refuses only what isn't a path: no length, or points hundreds of
    /// metres apart (a planned route's control points).
    static func whole(_ waypoints: [WaypointCoord], isLoop: Bool) -> Outcome {
        var cumulative = [0.0]
        for i in waypoints.indices.dropFirst() {
            cumulative.append(cumulative[i - 1] + distance(waypoints[i - 1], waypoints[i]))
        }
        let full = cumulative.last ?? 0
        guard waypoints.count >= 2, full > 0 else { return .notAPath }
        let spacings = zip(waypoints, waypoints.dropFirst()).map { distance($0, $1) }.sorted()
        guard spacings[spacings.count / 2] <= maxMedianSpacingMeters else { return .notAPath }
        let points = resample(waypoints, cumulative: cumulative)
        return .trimmed(Trimmed(waypoints: points, fullMeters: full, keptMeters: full,
                                hidesEnds: false, isLoop: isLoop))
    }

    /// The trimmed path. A loop is closed first if its points don't already
    /// return to the start. Refuses (`offsetUnavailable`) without an offset.
    static func trim(_ waypoints: [WaypointCoord], isLoop: Bool, offset: SharePrivacyOffset?) -> Outcome {
        guard let offset, offset.isValid else { return .offsetUnavailable }
        var path = waypoints
        if isLoop, let first = path.first, let last = path.last, first != last {
            path.append(first)
        }
        var cumulative = [0.0]
        for i in path.indices.dropFirst() {
            cumulative.append(cumulative[i - 1] + distance(path[i - 1], path[i]))
        }
        let full = cumulative.last ?? 0
        guard full >= minimumMeters else { return .tooShort(fullMeters: full) }
        guard isPath(path) else { return .notAPath }

        let start = path[0], end = path[path.count - 1]
        let startCentre = offset.centre(for: start), endCentre = offset.centre(for: end)
        // Measured, not taken from `shift`, so each end is at least `trimMeters`
        // inside its circle exactly.
        let startRadius = distance(start, startCentre) + trimMeters + offset.extra
        let endRadius = distance(end, endCentre) + trimMeters + offset.extra

        let points = resample(path, cumulative: cumulative)
        let eligible = points.map { distance($0, startCentre) >= startRadius && distance($0, endCentre) >= endRadius }

        // The longest run of consecutive eligible points.
        var best = 0..<0
        var runStart: Int?
        for i in points.indices.map({ $0 }) + [points.count] {
            if i < points.count, eligible[i] {
                if runStart == nil { runStart = i }
                continue
            }
            if let s = runStart {
                if i - s > best.count { best = s..<i }
                runStart = nil
            }
        }
        let kept = Array(points[best])
        let keptMeters = zip(kept, kept.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
        guard kept.count >= 2, keptMeters >= max(minimumKeptMeters, minimumKeptFraction * full) else {
            return .tooShort(fullMeters: full)
        }
        return .trimmed(Trimmed(waypoints: kept, fullMeters: full, keptMeters: keptMeters,
                                hidesEnds: true, isLoop: false))
    }

    static func trim(_ route: CustomRoute, offset: SharePrivacyOffset?) -> Outcome {
        trim(route.waypoints, isLoop: route.isLoop, offset: offset)
    }

    /// The copy of a planned route that a share trims: the walking directions
    /// of every leg joined into one path, with that path's length as its
    /// distance (a saved suggestion's `totalDistance` counts every lap of a
    /// one-lap path). Nil until every leg has directions.
    static func shareRoute(planned route: CustomRoute, legPaths: [[WaypointCoord]]) -> CustomRoute? {
        let expected = max(0, route.waypoints.count - 1) + (route.isLoop ? 1 : 0)
        guard expected > 0, legPaths.count == expected, legPaths.allSatisfy({ !$0.isEmpty }) else { return nil }
        let path = legPaths.flatMap { $0 }
        let length = zip(path, path.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
        return CustomRoute(id: route.id, name: route.name, waypoints: path, totalDistance: length,
                           isLoop: route.isLoop, createdAt: route.createdAt, activityMode: route.activityMode)
    }

    /// `metres` in the user's units, as the share screens show it.
    static func formatted(_ metres: Double) -> String {
        MKDistanceFormatter.abbreviated.string(fromDistance: metres)
    }

    // MARK: - Geometry

    static func isPath(_ points: [WaypointCoord]) -> Bool {
        guard points.count >= minimumPathPoints else { return false }
        let spacings = zip(points, points.dropFirst()).map { distance($0, $1) }.sorted()
        return spacings[spacings.count / 2] <= maxMedianSpacingMeters
    }

    /// A point every `spacingMeters` along `points` from the first, plus the
    /// last. `along[i]` is `points[i]`'s distance from `points[0]`.
    private static func resample(_ points: [WaypointCoord], cumulative along: [Double]) -> [WaypointCoord] {
        let total = along[along.count - 1]
        var out = [points[0]]
        var segment = 1
        var target = spacingMeters
        while target < total {
            while along[segment] < target { segment += 1 }
            let a = points[segment - 1], b = points[segment]
            let span = along[segment] - along[segment - 1]
            let t = span > 0 ? (target - along[segment - 1]) / span : 0
            out.append(WaypointCoord(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                            longitude: a.longitude + (b.longitude - a.longitude) * t)))
            target += spacingMeters
        }
        if let last = points.last, out.last != last { out.append(last) }
        return out
    }

    /// Metres between two points on the WGS 84 ellipsoid, on a flat plane at
    /// their mean latitude. Against an exact geodesic: under 0.1 mm up to
    /// 1 km, under 3 cm at 10 km, and within 0.03% at 100 km.
    ///
    /// Not `CLLocation.distance(from:)`, because that isn't a pure function:
    /// it keeps one process-wide cache of the scale at a latitude and reuses
    /// it for any point within 0.005° (about 550 m) of it, so its answer
    /// depends on whatever distance any thread measured last. Two trims of
    /// one route differed by centimetres in CI, and could differ by a whole
    /// point where the 10 m spacing or a zone's edge falls between the two
    /// answers, so a share's preview could differ from what it publishes.
    static func distance(_ a: WaypointCoord, _ b: WaypointCoord) -> Double {
        let semiMajorAxis = 6_378_137.0, eccentricitySquared = 0.006_694_379_990_14
        let latitude = (a.latitude + b.latitude) / 2 * .pi / 180
        let w = 1 - eccentricitySquared * sin(latitude) * sin(latitude)
        let metresPerRadianNorth = semiMajorAxis * (1 - eccentricitySquared) / (w * w.squareRoot())
        let metresPerRadianEast = semiMajorAxis / w.squareRoot() * cos(latitude)
        var longitudeDelta = b.longitude - a.longitude
        if longitudeDelta > 180 { longitudeDelta -= 360 } else if longitudeDelta < -180 { longitudeDelta += 360 }
        return hypot((b.latitude - a.latitude) * .pi / 180 * metresPerRadianNorth,
                     longitudeDelta * .pi / 180 * metresPerRadianEast)
    }
}
