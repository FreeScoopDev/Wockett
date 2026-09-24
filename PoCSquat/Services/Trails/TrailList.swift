import CoreLocation
import Foundation

// MARK: - Trail list
//
// What the Routes tab's Trails list shows, built from ranked pack rows.
//
// A pack stores a long trail as several rows: the builder merges same-named
// ways only where exactly two meet end to end, so a greenway with side
// branches stays in pieces (Walnut Creek Trail is four rows inside ten miles
// of downtown Raleigh). Listed as-is, the same name appears four times. So
// sections are grouped by default and shown with their total length; Joe asked
// for the separate view to stay available (2026-09-23), which is `grouped:
// false`.
//
// Grouping is by name AND proximity. "Main Trail" and "Loop Trail" are common
// names, and two parks ten miles apart must not become one trail, so sections
// only join a group when one of them sits within `joinGapMeters` of another.

/// Paved or not, from OSM's `surface` vocabulary. Anything else (boardwalk,
/// metal, a typo) is neither, and shows no surface tag rather than a guess.
enum TrailSurfaceKind: String, CaseIterable, Hashable {
    case paved
    case unpaved

    static let pavedValues: Set<String> = [
        "paved", "asphalt", "concrete", "concrete:plates", "concrete:lanes",
        "paving_stones", "sett", "chipseal"
    ]
    static let unpavedValues: Set<String> = [
        "unpaved", "ground", "dirt", "earth", "gravel", "fine_gravel", "compacted",
        "sand", "grass", "mud", "pebblestone", "woodchips", "rock"
    ]

    init?(surface: String?) {
        guard let surface = surface?.lowercased() else { return nil }
        if Self.pavedValues.contains(surface) {
            self = .paved
        } else if Self.unpavedValues.contains(surface) {
            self = .unpaved
        } else {
            return nil
        }
    }

    /// The raw values to hand `TrailQuery.surfaces` for this kind.
    var osmValues: Set<String> { self == .paved ? Self.pavedValues : Self.unpavedValues }
}

/// The chips above the list. All off means every trail within range.
struct TrailFilters: Hashable {
    var loopsOnly = false
    var surface: TrailSurfaceKind?
    /// Upper bound on the length *shown on the card* — the group's total when
    /// grouped, the section's when not — so the filter matches what is read.
    var shortOnly = false
    /// Hides trails tagged "no dogs". Deliberately not "dog-friendly only":
    /// 96% of North Carolina's trails say nothing about dogs, and a filter that
    /// required a yes would empty the list.
    var hideNoDogs = false

    /// "Under 2 mi" where distances read in miles, "Under 3 km" elsewhere.
    static func shortThresholdMeters(usesMiles: Bool) -> Double { usesMiles ? 3_218.69 : 3_000 }

    /// The part of the filtering the pack can do in SQL. Length is applied
    /// after grouping (see `shortOnly`).
    func query(cycling: Bool) -> TrailQuery {
        TrailQuery(
            dogAccess: hideNoDogs ? Set(DogAccess.allCases).subtracting([.notPermitted]) : nil,
            surfaces: surface?.osmValues,
            allowsBike: cycling ? true : nil,
            loopsOnly: loopsOnly
        )
    }
}

/// One row of the list: a single section, or every nearby section of one trail.
struct TrailListItem: Identifiable, Hashable {
    let id: String
    let name: String
    /// Nearest first.
    let sections: [TrailFeature]
    /// From the user to the nearest point of the nearest section.
    let distanceMeters: Double

    var isGroup: Bool { sections.count > 1 }
    var lengthMeters: Double { sections.reduce(0) { $0 + $1.lengthMeters } }
    /// Only a single section can be a loop; a group of sections is a network.
    var isLoop: Bool { sections.count == 1 && sections[0].isLoop }
    var allowsBike: Bool { sections.allSatisfy(\.allowsBike) }

    /// A surface tag only when every section that states one agrees.
    var surfaceKind: TrailSurfaceKind? {
        let kinds = Set(sections.compactMap { TrailSurfaceKind(surface: $0.surface) })
        return kinds.count == 1 ? kinds.first : nil
    }

    /// The dog rule worth showing, or nil. Only a tagged value is confident
    /// (see `DogAccessProvenance`); across sections the strictest tagged rule
    /// wins, because "no dogs" on one section is what an owner needs to know.
    var confidentDogAccess: DogAccess? {
        let tagged = sections.filter(\.dogAccessIsConfident).map(\.dogAccess)
        for rule in [DogAccess.notPermitted, .leashRequired, .offLeashAllowed] where tagged.contains(rule) {
            return rule
        }
        return nil
    }

    /// Every coordinate, section by section, for drawing and framing.
    var polylines: [[CLLocationCoordinate2D]] { sections.map(\.coordinates) }
}

enum TrailListBuilder {

    /// Sections of the same name closer than this join one group.
    static let joinGapMeters = 400.0

    /// Builds list rows from pack rows ranked by distance (nearest first).
    /// `maxLengthMeters` drops rows whose shown length is longer.
    static func items(from ranked: [(trail: TrailFeature, distance: Double)],
                      grouped: Bool,
                      maxLengthMeters: Double? = nil) -> [TrailListItem] {
        var items: [TrailListItem]
        if grouped {
            items = groups(from: ranked)
        } else {
            items = ranked.map { TrailListItem(id: "t\($0.trail.id)", name: $0.trail.displayName,
                                               sections: [$0.trail], distanceMeters: $0.distance) }
        }
        if let maxLengthMeters {
            items = items.filter { $0.lengthMeters <= maxLengthMeters }
        }
        return items.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    private static func groups(from ranked: [(trail: TrailFeature, distance: Double)]) -> [TrailListItem] {
        var result: [TrailListItem] = []
        // Unnamed trails never group: "Unnamed Trail" is not a name.
        var byName: [String: [(trail: TrailFeature, distance: Double)]] = [:]
        var nameOrder: [String] = []
        for entry in ranked {
            guard let raw = entry.trail.name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                result.append(TrailListItem(id: "t\(entry.trail.id)", name: entry.trail.displayName,
                                            sections: [entry.trail], distanceMeters: entry.distance))
                continue
            }
            let key = raw.lowercased()
            if byName[key] == nil { nameOrder.append(key) }
            byName[key, default: []].append(entry)
        }
        for key in nameOrder {
            for cluster in clusters(byName[key] ?? []) {
                let sorted = cluster.sorted { $0.distance < $1.distance }
                let ids = sorted.map { String($0.trail.id) }.sorted().joined(separator: "-")
                result.append(TrailListItem(id: sorted.count == 1 ? "t\(ids)" : "g\(ids)",
                                            name: sorted[0].trail.displayName,
                                            sections: sorted.map(\.trail),
                                            distanceMeters: sorted[0].distance))
            }
        }
        return result
    }

    /// Splits same-named sections into clusters that are actually near each
    /// other: connected components where an edge is "boxes within the gap".
    private static func clusters(_ entries: [(trail: TrailFeature, distance: Double)]) -> [[(trail: TrailFeature, distance: Double)]] {
        var parent = Array(entries.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in entries.indices {
            for j in entries.indices where j > i {
                if gapMeters(entries[i].trail.bounds, entries[j].trail.bounds) <= joinGapMeters {
                    parent[find(i)] = find(j)
                }
            }
        }
        var buckets: [Int: [(trail: TrailFeature, distance: Double)]] = [:]
        var order: [Int] = []
        for i in entries.indices {
            let root = find(i)
            if buckets[root] == nil { order.append(root) }
            buckets[root, default: []].append(entries[i])
        }
        return order.compactMap { buckets[$0] }
    }

    /// Distance between two bounding boxes, 0 when they touch or overlap.
    /// Degrees to metres with the same cos(latitude) scaling as
    /// `TrailBounds.around`; plenty for a 400 m join rule.
    static func gapMeters(_ a: TrailBounds, _ b: TrailBounds) -> Double {
        let dLat = max(0, max(a.minLatitude, b.minLatitude) - min(a.maxLatitude, b.maxLatitude))
        let dLon = max(0, max(a.minLongitude, b.minLongitude) - min(a.maxLongitude, b.maxLongitude))
        let midLat = (a.minLatitude + a.maxLatitude + b.minLatitude + b.maxLatitude) / 4
        let metersPerDegree = 111_320.0
        let x = dLon * metersPerDegree * max(0.01, cos(midLat * .pi / 180))
        let y = dLat * metersPerDegree
        return (x * x + y * y).squareRoot()
    }
}

// MARK: - Trail finder

/// Runs the Trails list's query against every open region pack.
@MainActor
@Observable
final class TrailFinder {

    /// Ten miles, Joe's choice for the first version (2026-09-23).
    static let searchRadiusMeters = 16_093.44
    /// Sections considered per search, nearest first, before grouping.
    static let sectionLimit = 400

    var filters = TrailFilters()
    private(set) var items: [TrailListItem] = []
    private(set) var hasSearched = false
    private(set) var failure: String?

    private let library: TrailPackLibrary

    init(library: TrailPackLibrary? = nil) {
        self.library = library ?? .shared
    }

    func refresh(near center: CLLocationCoordinate2D?, grouped: Bool, cycling: Bool, usesMiles: Bool) {
        hasSearched = true
        failure = nil
        guard let center else { items = []; return }
        let query = filters.query(cycling: cycling)
        var ranked: [(trail: TrailFeature, distance: Double)] = []
        for source in library.sources.values {
            do {
                let rows = try source.trails(near: center, radiusMeters: Self.searchRadiusMeters,
                                             matching: query, limit: Self.sectionLimit)
                ranked += rows.map { ($0, BundledTrailSource.distanceMeters(from: center, to: $0)) }
            } catch {
                failure = "Trail data couldn't be read. Try again, or check Settings → Trail Regions."
            }
        }
        ranked.sort { $0.distance < $1.distance }
        items = TrailListBuilder.items(
            from: Array(ranked.prefix(Self.sectionLimit)),
            grouped: grouped,
            maxLengthMeters: filters.shortOnly ? TrailFilters.shortThresholdMeters(usesMiles: usesMiles) : nil
        )
    }
}
