import CoreLocation
import Foundation
import MapKit

// MARK: - Getting to a trail
//
// A trail's detail offers the way there inside Wockett before handing off to
// Apple Maps (Joe, 2026-09-26: "If it's close, maybe the user will want to
// bike or walk to the listed trail."). MKDirections gives an on-foot and a
// cycling route from where the person is to the trail's nearest point; they
// pick one, and "Start Walk to Trail" runs an ordinary guided session to it.
// Within `TrailWalkPlanner.startRadiusMeters` of the trail the session offers
// to carry on along the trail itself (`TrailApproach`, and
// `NavigationSessionManager.beginTrailWalk`).
//
// The decisions — which option leads, when to ask MapKit again, the words —
// are pure functions here, so they are tested without MapKit.

/// The two ways Wockett can take someone to a trail itself. Driving is Apple
/// Maps' job.
enum TrailDirectionsMode: String, CaseIterable, Hashable {
    case onFoot, cycling

    /// The session's own transport, so the preview asks MapKit exactly what
    /// the session will (a run and a walk both route as walking).
    var transportType: MKDirectionsTransportType {
        sessionMode(current: .walking).transportType
    }

    /// The session this option starts. On foot keeps a run a run; everything
    /// else on foot is a walk, including picking "on foot" while in Ride mode.
    func sessionMode(current: ActivityMode) -> ActivityMode {
        switch self {
        case .cycling: return .cycling
        case .onFoot:  return current == .running ? .running : .walking
        }
    }

    var launchMode: String {
        self == .cycling ? MKLaunchOptionsDirectionsModeCycling : MKLaunchOptionsDirectionsModeWalking
    }
}

enum TrailDirectionsPlanner {

    // MARK: Which option leads

    /// Under this, on foot leads: about 2 mi, a 35–40 minute walk.
    static let onFootLeadsBelowMeters = 3_000.0
    /// From this, driving leads and Wockett's own options drop below it:
    /// about 8 mi, 40+ minutes on a bike.
    static let driveLeadsFromMeters = 13_000.0

    enum Lead: Equatable { case onFoot, cycling, drive }

    /// What the detail puts first for a trail `meters` away by the on-foot
    /// route (or in a straight line, when there is no route). In Ride mode the
    /// bike leads at any distance a ride is sensible: someone who chose Ride
    /// is on a bike already, and a 1 km walk would not be what they want.
    static func lead(distanceMeters meters: Double, activityMode: ActivityMode) -> Lead {
        if meters >= driveLeadsFromMeters { return .drive }
        if activityMode == .cycling { return .cycling }
        return meters < onFootLeadsBelowMeters ? .onFoot : .cycling
    }

    /// The options in the order the detail lists them.
    static func order(for lead: Lead) -> [TrailDirectionsMode] {
        lead == .cycling ? [.cycling, .onFoot] : [.onFoot, .cycling]
    }

    // MARK: When to ask MapKit again

    /// Moving less than this keeps the routes already found. MapKit throttles
    /// an app that asks too often (`MKError.loadingThrottled`), and the
    /// Trails screen re-renders on every location update.
    static let recomputeAfterMeters = 100.0

    struct CacheKey: Equatable {
        let trailID: String
        let origin: CLLocationCoordinate2D

        static func == (a: CacheKey, b: CacheKey) -> Bool {
            a.trailID == b.trailID
                && a.origin.latitude == b.origin.latitude && a.origin.longitude == b.origin.longitude
        }
    }

    /// Whether routes found for `cached` are stale for `trailID` from `origin`.
    static func needsRecompute(cached: CacheKey?, trailID: String, origin: CLLocationCoordinate2D) -> Bool {
        guard let cached, cached.trailID == trailID else { return true }
        return TrailWalkPlanner.meters(cached.origin, origin) > recomputeAfterMeters
    }

    // MARK: Words

    /// A person running covers ground about twice as fast as MapKit's walking
    /// estimate (~1.4 m/s). 2.7 m/s is a 10-minute mile, an easy run.
    static let runningMetersPerSecond = 2.7

    /// Travel time for `mode` in seconds: MapKit's own estimate, except for a
    /// run, which MapKit does not estimate.
    static func travelSeconds(for mode: ActivityMode, expected: TimeInterval, meters: Double) -> TimeInterval {
        mode == .running ? meters / runningMetersPerSecond : expected
    }

    /// "18 min", "1h 5m" — the app's existing duration style
    /// (`TrailText.walkingTime`, `SuggestedRoute.timeText`). Never "0 min".
    static func durationText(_ seconds: TimeInterval) -> String {
        let mins = max(1, Int((seconds / 60).rounded()))
        return mins < 60 ? "\(mins) min" : "\(mins / 60)h \(mins % 60)m"
    }

    /// "18 minutes", "1 hour 5 minutes" — for VoiceOver, which reads "min"
    /// as a word.
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let mins = max(1, Int((seconds / 60).rounded()))
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        guard mins >= 60 else { return unit(mins, "minute") }
        let rest = mins % 60
        return rest == 0 ? unit(mins / 60, "hour") : "\(unit(mins / 60, "hour")) \(unit(rest, "minute"))"
    }

    /// "Walk to trail, 18 minutes, 0.9 miles"
    static func accessibilityLabel(sessionLabel: String, seconds: TimeInterval, spokenDistance: String) -> String {
        "\(sessionLabel) to trail, \(spokenDuration(seconds)), \(spokenDistance)"
    }

    /// Why the in-app options are missing, in plain words.
    static func failureMessage(for error: Error?) -> String {
        if let mk = error as? MKError, mk.code == .loadingThrottled {
            return "Apple Maps is busy. Try again in a minute, or open the trail in Maps."
        }
        if let url = error as? URLError, url.code == .notConnectedToInternet {
            return "You're offline, so Wockett can't show the way here. Maps can use its offline maps."
        }
        return "Wockett couldn't get directions to this trail right now. Maps can still take you there."
    }
}

// MARK: - The trail a session is heading for

/// Carried by the route of a session that is going *to* a trail, so the
/// session can offer the trail walk on arrival. Holds the trail's sections
/// themselves: a restored session has no Trails list to look them up in.
struct TrailApproach: Hashable, Codable {
    let trailID: String
    let trailName: String
    let sections: [TrailFeature]

    init(item: TrailListItem) {
        trailID = item.id
        trailName = item.name
        sections = item.sections
    }

    var item: TrailListItem {
        TrailListItem(id: trailID, name: trailName, sections: sections, distanceMeters: 0)
    }

    /// The trail walk to offer at `location`, or nil until the person is
    /// within `TrailWalkPlanner.startRadiusMeters` of a section — the same
    /// rule and the same plan as Start Walk on the trail's own detail, with
    /// the "how far" the person last chose there (2026-10-09).
    func arrivalPlan(at location: CLLocationCoordinate2D, activityMode: ActivityMode = .walking,
                     defaults: UserDefaults = .standard) -> TrailWalkPlan? {
        guard let section = TrailWalkPlanner.section(of: item, at: location),
              let whole = TrailWalkPlanner.plan(for: section, name: trailName, from: location) else { return nil }
        let reach = whole.isLoop ? whole.distanceMeters / 2 : whole.distanceMeters
        let target = TrailWalkOption.lastChosenTarget(reach: reach, isLoop: whole.isLoop, activityMode: activityMode,
                                                      defaults: defaults)
        return TrailWalkPlanner.plan(along: section.coordinates, isLoop: section.isLoop, name: trailName,
                                     from: location, target: target) ?? whole
    }

    /// The session that takes someone to the trail: an ordinary guided route
    /// from `origin` to the trail's access point, routed on streets by the
    /// session's own MKDirections legs like every other guided route.
    func navigableRoute(from origin: CLLocationCoordinate2D, to access: CLLocationCoordinate2D,
                        distanceMeters: Double, activityMode: ActivityMode) -> NavigableRoute {
        NavigableRoute(name: "To \(trailName)", waypoints: [origin, access], lapCount: 1, isLoop: false,
                       totalDistance: distanceMeters, activityMode: activityMode, approach: self)
    }
}

// MARK: - Directions for the detail screen

/// The on-foot and cycling routes to one trail, kept across leaving and
/// reopening its detail so MapKit is asked once per trail and place.
@Observable
@MainActor
final class TrailDirectionsModel {

    enum Option {
        case route(MKRoute)
        /// MapKit has no route of this kind here (cycling directions do not
        /// cover everywhere); the other option may still exist.
        case unavailable
    }

    enum Phase {
        case idle
        case loading
        case loaded([TrailDirectionsMode: Option])
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The trail the current phase is for.
    private(set) var trailID: String?
    var selected: TrailDirectionsMode?
    /// What the loaded routes are for, or what is being loaded.
    private var cacheKey: TrailDirectionsPlanner.CacheKey?
    private var task: Task<Void, Never>?

    func route(for mode: TrailDirectionsMode) -> MKRoute? {
        guard case .loaded(let options) = phase, case .route(let route)? = options[mode] else { return nil }
        return route
    }

    /// The selected route's line, for the Trails map, while `trailID` is shown.
    func selectedPolyline(forTrail id: String?) -> MKPolyline? {
        guard let id, id == trailID, let mode = selected else { return nil }
        return route(for: mode)?.polyline
    }

    /// Finds both routes unless they are found, or being found, for this
    /// trail from within `recomputeAfterMeters` of `origin`. Safe to call on
    /// every render and every location update: only a real change asks MapKit.
    func request(trailID: String, from origin: CLLocationCoordinate2D, to target: CLLocationCoordinate2D,
                 activityMode: ActivityMode, straightLineMeters: Double) {
        guard TrailDirectionsPlanner.needsRecompute(cached: cacheKey, trailID: trailID, origin: origin) else { return }
        task?.cancel()
        self.trailID = trailID
        cacheKey = .init(trailID: trailID, origin: origin)
        selected = nil
        phase = .loading
        task = Task { [weak self] in
            async let onFoot = Self.calculate(.onFoot, from: origin, to: target)
            async let cycling = Self.calculate(.cycling, from: origin, to: target)
            let results = await [TrailDirectionsMode.onFoot: onFoot, .cycling: cycling]
            guard !Task.isCancelled, let self else { return }
            self.apply(results, activityMode: activityMode, straightLineMeters: straightLineMeters)
        }
    }

    /// Stops a request in flight (the detail left the screen). Nothing half
    /// found is kept, so opening the trail again asks afresh.
    func cancel() {
        guard case .loading = phase else { return }
        task?.cancel()
        task = nil
        cacheKey = nil
        phase = .idle
    }

    private func apply(_ results: [TrailDirectionsMode: Result<MKRoute, Error>],
                       activityMode: ActivityMode, straightLineMeters: Double) {
        var options: [TrailDirectionsMode: Option] = [:]
        var firstError: Error?
        for mode in TrailDirectionsMode.allCases {
            switch results[mode] {
            case .success(let route)?: options[mode] = .route(route)
            case .failure(let error)?:
                options[mode] = .unavailable
                firstError = firstError ?? error
            case nil: options[mode] = .unavailable
            }
        }
        guard options.values.contains(where: { if case .route = $0 { return true }; return false }) else {
            phase = .failed(TrailDirectionsPlanner.failureMessage(for: firstError))
            // A failure is not cached: Try Again, or coming back, asks again.
            cacheKey = nil
            return
        }
        phase = .loaded(options)
        reselect(activityMode: activityMode, straightLineMeters: straightLineMeters)
    }

    /// Chooses the leading option that has a route: after loading, and when
    /// the activity changes with the detail open, so the tick and the Start
    /// button follow the new order.
    func reselect(activityMode: ActivityMode, straightLineMeters: Double) {
        guard case .loaded = phase else { return }
        let lead = TrailDirectionsPlanner.lead(distanceMeters: leadDistance(straightLine: straightLineMeters),
                                               activityMode: activityMode)
        selected = TrailDirectionsPlanner.order(for: lead).first { route(for: $0) != nil }
    }

    /// Forgets a failure so the next `request` asks again (the Try Again link).
    func retry() {
        if case .failed = phase { phase = .idle }
        cacheKey = nil
    }

    /// The distance that decides which option leads: the on-foot route, or
    /// the cycling one, or the straight line.
    func leadDistance(straightLine: Double) -> Double {
        route(for: .onFoot)?.distance ?? route(for: .cycling)?.distance ?? straightLine
    }

    private static func calculate(_ mode: TrailDirectionsMode, from origin: CLLocationCoordinate2D,
                                  to target: CLLocationCoordinate2D) async -> Result<MKRoute, Error> {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: target.latitude, longitude: target.longitude), address: nil)
        request.transportType = mode.transportType
        let directions = MKDirections(request: request)
        do {
            let response = try await withTaskCancellationHandler {
                try await directions.calculate()
            } onCancel: {
                Task { @MainActor in directions.cancel() }
            }
            guard let route = response.routes.first else { return .failure(MKError(.directionsNotFound)) }
            return .success(route)
        } catch {
            return .failure(error)
        }
    }
}
