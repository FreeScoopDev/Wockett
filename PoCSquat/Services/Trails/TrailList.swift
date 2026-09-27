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
//
// Unnamed sections group too, more strictly: only pieces of the same kind of
// path (same `pathKindLabel`, same foot and bike access) that meet end to end.
// OSM splits a path wherever something crosses it, and with no name there is
// nothing to merge on in the builder, so the paved path along Duck Road from
// Kitty Hawk into Duck was 57 "Unnamed Trail" rows (Joe, 2026-09-26). Without
// a name, closeness alone would join a park's every footpath, so the rule is
// endpoints, not boxes: a chain of touching pieces is one card.

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

    /// Rows shorter than this are hidden unless the person asks for short
    /// paths. The packs keep every named way, and sorted by distance the top
    /// of downtown Raleigh's list was cemetery drives (500 ft) and 250 ft
    /// connectors; 304 of the 530 sections within ten miles are under a
    /// quarter mile. Joe chose 0.25 mi, with an option to show them
    /// (2026-09-24). Compared with the row's shown length, so a short piece
    /// of a long grouped trail still counts toward it.
    static func minimumLengthMeters(usesMiles: Bool) -> Double { usesMiles ? 402.34 : 400 }

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

    /// Unnamed sections of one kind join when an endpoint of one lies this
    /// close to an endpoint of another. Pieces that meet share an OSM node,
    /// but the pack drops ways under 30 m (`min_length_m`) — the driveway and
    /// road crossings along a side path — so real neighbours sit up to ~30 m
    /// apart. Measured on the NC pack along Duck Road (2026-09-26): gaps of
    /// 0–27 m between consecutive pieces; at 15 m the longest chain was 3
    /// pieces, at 30 m it is 30 pieces, 6.6 km.
    static let unnamedJoinMeters = 30.0

    /// Builds list rows from pack rows ranked by distance (nearest first).
    /// `maxLengthMeters` drops rows whose shown length is longer.
    static func items(from ranked: [(trail: TrailFeature, distance: Double)],
                      grouped: Bool,
                      minLengthMeters: Double? = nil,
                      maxLengthMeters: Double? = nil) -> [TrailListItem] {
        var items: [TrailListItem]
        if grouped {
            items = groups(from: ranked)
        } else {
            items = ranked.map { TrailListItem(id: "t\($0.trail.id)", name: $0.trail.displayName,
                                               sections: [$0.trail], distanceMeters: $0.distance) }
        }
        if let minLengthMeters {
            items = items.filter { $0.lengthMeters >= minLengthMeters }
        }
        if let maxLengthMeters {
            items = items.filter { $0.lengthMeters <= maxLengthMeters }
        }
        return items.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    private static func groups(from ranked: [(trail: TrailFeature, distance: Double)]) -> [TrailListItem] {
        var result: [TrailListItem] = []
        var byName: [String: [(trail: TrailFeature, distance: Double)]] = [:]
        var nameOrder: [String] = []
        var unnamed: [(trail: TrailFeature, distance: Double)] = []
        for entry in ranked {
            guard let raw = entry.trail.name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                unnamed.append(entry)
                continue
            }
            let key = raw.lowercased()
            if byName[key] == nil { nameOrder.append(key) }
            byName[key, default: []].append(entry)
        }
        for key in nameOrder {
            let members = byName[key] ?? []
            for cluster in clusters(members, joined: {
                gapMeters(members[$0].trail.bounds, members[$1].trail.bounds) <= joinGapMeters
            }) {
                result.append(item(for: cluster))
            }
        }
        result += unnamedGroups(unnamed).map(item(for:))
        return result
    }

    /// One row for a cluster: nearest section first, an id that does not
    /// depend on arrival order, and the nearest section's name. Unnamed
    /// sections in a cluster share a `pathKindLabel`, so a group is titled by
    /// it (a group is never a loop); a single section keeps its own label.
    private static func item(for cluster: [(trail: TrailFeature, distance: Double)]) -> TrailListItem {
        let sorted = cluster.sorted { $0.distance < $1.distance }
        let ids = sorted.map { String($0.trail.id) }.sorted().joined(separator: "-")
        let nearest = sorted[0].trail
        let name = sorted.count > 1 && !nearest.hasName ? nearest.pathKindLabel : nearest.displayName
        return TrailListItem(id: sorted.count == 1 ? "t\(ids)" : "g\(ids)",
                             name: name,
                             sections: sorted.map(\.trail),
                             distanceMeters: sorted[0].distance)
    }

    /// What makes two unnamed sections the same path: the card title they
    /// would get and who may use them. Access is part of it so a group's
    /// "allows bikes" is never an average of pieces that disagree.
    private struct UnnamedKind: Hashable {
        let label: String
        let allowsFoot: Bool
        let allowsBike: Bool
    }

    /// Unnamed sections chained end to end within `unnamedJoinMeters`, per
    /// kind. Transitive: A–B and B–C make one group even when A and C are far
    /// apart, which is the whole point for a path split at every driveway.
    private static func unnamedGroups(_ entries: [(trail: TrailFeature, distance: Double)]) -> [[(trail: TrailFeature, distance: Double)]] {
        var byKind: [UnnamedKind: [(trail: TrailFeature, distance: Double)]] = [:]
        var kindOrder: [UnnamedKind] = []
        for entry in entries {
            let kind = UnnamedKind(label: entry.trail.pathKindLabel,
                                   allowsFoot: entry.trail.allowsFoot, allowsBike: entry.trail.allowsBike)
            if byKind[kind] == nil { kindOrder.append(kind) }
            byKind[kind, default: []].append(entry)
        }
        var result: [[(trail: TrailFeature, distance: Double)]] = []
        for kind in kindOrder {
            let members = byKind[kind] ?? []
            // Decode each polyline once, not once per pair. By index, not id:
            // ids are only unique within one pack.
            let ends: [[CLLocationCoordinate2D]] = members.map {
                let coords = $0.trail.coordinates
                return coords.isEmpty ? [] : [coords[0], coords[coords.count - 1]]
            }
            result += clusters(members) { endpointGapMeters(ends[$0], ends[$1]) <= unnamedJoinMeters }
        }
        return result
    }

    /// The shortest distance between any endpoint of one section and any of
    /// another; infinite when either has no geometry.
    static func endpointGapMeters(_ a: [CLLocationCoordinate2D], _ b: [CLLocationCoordinate2D]) -> Double {
        var best = Double.infinity
        for p in a {
            for q in b {
                let metersPerDegree = 111_320.0
                let x = (p.longitude - q.longitude) * metersPerDegree * max(0.01, cos(p.latitude * .pi / 180))
                let y = (p.latitude - q.latitude) * metersPerDegree
                best = min(best, (x * x + y * y).squareRoot())
            }
        }
        return best
    }

    /// Splits sections into clusters that are actually connected: connected
    /// components where an edge is `joined(i, j)` on indices into `entries` —
    /// boxes within the gap for named sections, touching endpoints for
    /// unnamed ones.
    private static func clusters(_ entries: [(trail: TrailFeature, distance: Double)],
                                 joined: (Int, Int) -> Bool) -> [[(trail: TrailFeature, distance: Double)]] {
        var parent = Array(entries.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in entries.indices {
            for j in entries.indices where j > i {
                if joined(i, j) {
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

    func refresh(near center: CLLocationCoordinate2D?, grouped: Bool, cycling: Bool, usesMiles: Bool,
                 includeShortPaths: Bool = false) {
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
            minLengthMeters: includeShortPaths ? nil : TrailFilters.minimumLengthMeters(usesMiles: usesMiles),
            maxLengthMeters: filters.shortOnly ? TrailFilters.shortThresholdMeters(usesMiles: usesMiles) : nil
        )
    }
}
