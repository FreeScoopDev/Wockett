import CoreLocation
import Foundation

// MARK: - Trail data model
//
// One normalized shape for a trail regardless of where it came from — OSM,
// USGS, NPS, a state GIS layer. Consuming code never learns the source; the
// source is recorded on the row so attribution can be rendered, nothing more.
//
// This mirrors the `trails` table that `tools/build_trail_pack.py` writes
// (schema version 1). The two must move together: a pack the app cannot read
// is refused by `BundledTrailSource`, not guessed at.

/// Whether dogs are welcome on a trail, in the vocabulary the pack builder
/// writes. The differentiating field, so it is an enum and not a string.
enum DogAccess: String, CaseIterable, Codable, Hashable {
    case offLeashAllowed
    case leashRequired
    case notPermitted
    case unknown
}

/// How the pack builder arrived at a `DogAccess` value. "We inferred this" is
/// not the same as "the data said so", and the UI must be able to say which:
/// a tagged value is shown confidently, an inferred one cautiously, a default
/// not at all.
enum DogAccessProvenance: String, Codable, Hashable {
    /// An explicit `dog=` tag, or `leisure=dog_park`.
    case tagged
    /// Derived from something else — currently `access=private` with no
    /// `foot=yes` override. A path nobody may enter is a path dogs may not.
    case inferred
    /// Nothing in the data spoke to it.
    case `default`
}

/// A rectangle in degrees. Stored on every trail so "near me" is an index
/// lookup rather than a geometry decode.
struct TrailBounds: Hashable {
    var minLatitude: Double
    var minLongitude: Double
    var maxLatitude: Double
    var maxLongitude: Double

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2,
                               longitude: (minLongitude + maxLongitude) / 2)
    }

    func intersects(_ other: TrailBounds) -> Bool {
        minLatitude <= other.maxLatitude && maxLatitude >= other.minLatitude
            && minLongitude <= other.maxLongitude && maxLongitude >= other.minLongitude
    }

    /// The bounds of a circle of `radiusMeters` around `center`, in degrees.
    /// Longitude degrees shrink with latitude, so the width is scaled by
    /// cos(latitude); the clamp keeps a pole-adjacent query from dividing by
    /// something near zero.
    static func around(_ center: CLLocationCoordinate2D, radiusMeters: Double) -> TrailBounds {
        let metersPerDegreeLatitude = 111_320.0
        let dLat = radiusMeters / metersPerDegreeLatitude
        let cosLat = max(0.01, cos(center.latitude * .pi / 180))
        let dLon = radiusMeters / (metersPerDegreeLatitude * cosLat)
        return TrailBounds(minLatitude: center.latitude - dLat,
                           minLongitude: center.longitude - dLon,
                           maxLatitude: center.latitude + dLat,
                           maxLongitude: center.longitude + dLon)
    }
}

/// One trail from a region pack.
///
/// Geometry stays encoded until asked for: a "near me" list of fifty trails
/// should not decode fifty polylines to render fifty names.
struct TrailFeature: Identifiable, Hashable {
    /// Stable within a pack. Identity across packs is `sourceID` + `sourceRef`,
    /// which the builder derives from the upstream object id so a rebuild does
    /// not reassign every trail — see the 2026-09-10 note on what happened
    /// when it did.
    let id: Int64
    let sourceID: String
    let sourceRef: String
    let name: String?
    let encodedPolyline: String
    let pointCount: Int
    let lengthMeters: Double
    let bounds: TrailBounds
    /// OSM `surface` vocabulary (`gravel`, `asphalt`, `ground`…), or nil.
    let surface: String?
    /// OSM `sac_scale` vocabulary (`hiking`, `mountain_hiking`…), or nil.
    let difficulty: String?
    let dogAccess: DogAccess
    let dogAccessProvenance: DogAccessProvenance
    let allowsFoot: Bool
    let allowsBike: Bool
    let allowsHorse: Bool
    let isLoop: Bool

    /// The trail's coordinates, decoded on demand.
    var coordinates: [CLLocationCoordinate2D] { EncodedPolyline.decode(encodedPolyline) }

    /// A name a detail screen can show without looking broken. Unnamed trails
    /// are the majority in OSM (81% in North Carolina), and they still need a
    /// label — same rule as a routeless walk in `WalkHistoryView`.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return isLoop ? "Unnamed Loop" : "Unnamed Trail"
    }

    /// Whether the dog-access value is worth showing with confidence. Only a
    /// tagged value is; an inferred one should be hedged and a default hidden.
    var dogAccessIsConfident: Bool { dogAccessProvenance == .tagged }
}

/// One data source's attribution, carried inside the pack so it can never
/// drift from the data it credits. ODbL attribution for OSM is a legal
/// obligation, not a courtesy.
struct TrailAttribution: Identifiable, Hashable {
    let sourceID: String
    let name: String
    let attribution: String
    let license: String
    let url: URL?
    let requiresAttribution: Bool

    var id: String { sourceID }
}

/// What a pack says about itself.
struct TrailPackInfo: Hashable {
    let schemaVersion: Int
    let builderVersion: String
    let region: String
    let regionName: String
    let builtAt: Date?
    let trailCount: Int
    let sourceIDs: [String]
}

/// Filters for a trail query. All optional; nil means "don't filter on this".
struct TrailQuery: Hashable {
    var dogAccess: Set<DogAccess>?
    var minLengthMeters: Double?
    var maxLengthMeters: Double?
    var surfaces: Set<String>?
    var allowsBike: Bool?
    var loopsOnly = false
    var nameContains: String?

    init(dogAccess: Set<DogAccess>? = nil,
         minLengthMeters: Double? = nil,
         maxLengthMeters: Double? = nil,
         surfaces: Set<String>? = nil,
         allowsBike: Bool? = nil,
         loopsOnly: Bool = false,
         nameContains: String? = nil) {
        self.dogAccess = dogAccess
        self.minLengthMeters = minLengthMeters
        self.maxLengthMeters = maxLengthMeters
        self.surfaces = surfaces
        self.allowsBike = allowsBike
        self.loopsOnly = loopsOnly
        self.nameContains = nameContains
    }

    static let any = TrailQuery()
}
