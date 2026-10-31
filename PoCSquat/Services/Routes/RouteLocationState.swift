import CoreLocation

/// What Routes and Trails can offer, given the location permission (spec
/// fix/route-location-recovery). Views read this, never `authStatus`, so
/// the panel explains a denial before a search instead of after it fails.
enum RouteLocationState: Equatable {
    /// Allowed, or a test or demo run that supplies its own location.
    case live
    /// Not asked yet: the first search asks, then waits for the answer.
    case willAsk
    /// Denied. iOS also reports this when Location Services are off for the whole phone.
    case off
    /// Restricted (Screen Time, a managed phone): the person usually can't change it.
    case restricted

    /// `bypass` is a `-WKTDemo` or `-WKTUITest` run, whose RouteManager
    /// answers with a fixed location and never asks iOS.
    static func make(auth: CLAuthorizationStatus, bypass: Bool) -> RouteLocationState {
        if bypass { return .live }
        switch auth {
        case .authorizedAlways, .authorizedWhenInUse: return .live
        case .notDetermined: return .willAsk
        case .restricted: return .restricted
        default: return .off
        }
    }

    var canFindRoutes: Bool { self == .live || self == .willAsk }

    /// "Search a place" and "Nearby places": each starts from the live
    /// location, and waits for the prompt's answer when not asked yet.
    var showsNearbyActions: Bool { canFindRoutes }

    /// After a failed search, "Try nearby loops" only if it could work: it
    /// needs the same location the failed search lacked.
    func offersNearbyLoops(afterLocationFailure: Bool) -> Bool {
        self == .live && !afterLocationFailure
    }

    /// Only a denial can be reversed in Settings.
    var showsOpenSettings: Bool { self == .off }

    var showsPlanOnMap: Bool { self == .off || self == .restricted }

    var message: String? {
        switch self {
        case .live: return nil
        case .willAsk: return "Wockett will ask to use your location."
        case .off: return "Location is off for Wockett, so routes can't start from where you are."
        case .restricted: return "Location is restricted on this iPhone."
        }
    }
}
