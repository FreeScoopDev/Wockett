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

/// Flat-earth distances for the trail code's short-range checks (joins,
/// gaps, nearest points): metres north and east, east scaled by
/// cos(latitude). Accurate to well under a percent at these ranges, and it
/// needs no `CLLocation` per point. One place for the constant.
enum TrailGeometry {
    static let metersPerDegree = 111_320.0

    /// Metres between two nearby points.
    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let x = (a.longitude - b.longitude) * metersPerDegree * max(0.01, cos(a.latitude * .pi / 180))
        let y = (a.latitude - b.latitude) * metersPerDegree
        return (x * x + y * y).squareRoot()
    }
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
    /// The pack's `tags_json`, kept raw: the OSM tags the builder kept
    /// (`highway`, `bicycle`, `surface`…). Parsed only when a label asks for
    /// it (`tags`), so a query that scans thousands of rows in a city box
    /// never parses JSON for rows the list will not show. Nil when a source
    /// carries none.
    var tagsJSON: String?
    /// Which trail this piece belongs to (pack builder 1.3.0, 2026-10-08):
    /// every piece of one named trail shares it, so the list can show the
    /// whole trail rather than the pieces within the search radius. Nil for
    /// unnamed paths and in packs built before 1.3.0.
    var trailKey: String?

    /// `tagsJSON` as strings, parsed on each call. Read for labelling only;
    /// every filterable fact has its own column. Unreadable JSON is no tags.
    var tags: [String: String] { Self.tags(fromJSON: tagsJSON) }

    /// The trail's coordinates, decoded on demand.
    var coordinates: [CLLocationCoordinate2D] { EncodedPolyline.decode(encodedPolyline) }

    /// Whether the row carries a name. Whitespace is not a name — the same
    /// test the list's grouping uses. A name in the `name` column counts
    /// whatever produced it, including one the pack builder derived (marked
    /// `name_source` in the tags).
    var hasName: Bool { !(name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Whether the name is the trail's own, from the map data, rather than one
    /// the pack builder derived from a road alongside ("Duck Road Path",
    /// tagged `name_source: derived_road`). Only an own name may be presented
    /// as an official trail.
    var hasOwnName: Bool { hasName && tags["name_source"] != "derived_road" }

    /// A name a detail screen can show without looking broken. Unnamed trails
    /// are the majority in OSM (81% in North Carolina), and they still need a
    /// label — same rule as a routeless walk in `WalkHistoryView`.
    var displayName: String {
        if hasName, let name { return name }
        return label(isLoop: isLoop)
    }

    /// What an unnamed section is, as a card title, ignoring whether it is a
    /// loop. Unnamed sections only group when this matches (see
    /// `TrailListBuilder`), so a group's title is true of every section in it.
    var pathKindLabel: String { label(isLoop: false) }

    private func label(isLoop: Bool) -> String {
        let tags = tags
        return Self.unnamedLabel(surface: surface, highway: tags["highway"], bicycle: tags["bicycle"],
                                 allowsBike: allowsBike, isLoop: isLoop)
    }

    /// The one rule for naming a trail that has no name, from what the pack
    /// says about it: "Paved Bike Path", "Footpath", "Unpaved Track",
    /// "Boardwalk", "Paved Loop". "Unnamed Trail" / "Unnamed Loop" only when
    /// the data says nothing useful.
    ///
    /// - Material first: `surface=wood` is a boardwalk; otherwise
    ///   `TrailSurfaceKind` gives "Paved" or "Unpaved"; any other surface
    ///   (metal, a typo) or none adds nothing rather than a guess — except on
    ///   a track, which is unpaved unless it says otherwise. A bare "Track" is
    ///   65% of unnamed titles in North Carolina and reads like a running
    ///   track; "Unpaved Track" is what an OSM track is.
    /// - The noun comes from OSM's `highway`: `cycleway`, or
    ///   `bicycle=designated` on anything, is a bike path — but only when the
    ///   row allows bikes, so a cycleway closed to them is never called one;
    ///   `footway` a footpath; `track` a track; `bridleway` a bridle path.
    ///   `path` or no tag is the generic "Path", which alone would read as a
    ///   placeholder, so with no material either it falls back to
    ///   "Unnamed Trail".
    /// - A loop keeps the material and bike-ness and ends in "Loop"; a
    ///   footway loop with no surface is a "Footpath Loop".
    static func unnamedLabel(surface: String?, highway: String?, bicycle: String?,
                             allowsBike: Bool, isLoop: Bool) -> String {
        let surface = surface?.lowercased()
        let highway = highway?.lowercased()
        let isBoardwalk = surface == "wood"
        var material: String? = isBoardwalk ? "Boardwalk" : TrailSurfaceKind(surface: surface).map {
            $0 == .paved ? "Paved" : "Unpaved"
        }
        if material == nil, highway == "track" { material = "Unpaved" }
        let isBike = allowsBike && (highway == "cycleway" || bicycle?.lowercased() == "designated")

        if isLoop {
            let noun = isBike ? "Bike Loop" : "Loop"
            if let material { return "\(material) \(noun)" }
            if isBike { return noun }
            return highway == "footway" ? "Footpath Loop" : "Unnamed Loop"
        }
        if isBoardwalk { return "Boardwalk" }
        let noun: String?
        if isBike {
            noun = "Bike Path"
        } else {
            switch highway {
            case "footway": noun = "Footpath"
            case "track": noun = "Track"
            case "bridleway": noun = "Bridle Path"
            default: noun = nil
            }
        }
        switch (material, noun) {
        case let (material?, noun?): return "\(material) \(noun)"
        case let (nil, noun?): return noun
        case let (material?, nil): return "\(material) Path"
        case (nil, nil): return "Unnamed Trail"
        }
    }

    /// `tags_json` as strings. The builder writes a flat object of OSM tags
    /// (plus `merged_ways`, a number); anything unreadable is no tags, not an
    /// error — tags only feed labels.
    static func tags(fromJSON json: String?) -> [String: String] {
        guard let data = json?.data(using: .utf8), !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var tags: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case let string as String: tags[key] = string
            case let number as NSNumber: tags[key] = number.stringValue
            default: continue
            }
        }
        return tags
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

// Codable so a session heading to a trail survives a crash-and-restore with
// its destination (`TrailApproach`, `ActiveWalkSnapshot.RouteData.approach`).
// Synthesised, so it has to live in the file that declares the types.
extension TrailBounds: Codable {}
extension TrailFeature: Codable {}
