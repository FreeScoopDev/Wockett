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
// endpoints, not boxes, and only where exactly two pieces meet (`TrailChain`):
// a simple chain of pieces is one card, a junction is not joined through. The
// first cut joined any two endpoints within 30 m and turned UNC's campus into
// one 255-section, 19.8 km "Paved Footpath" and downtown Raleigh's plaza into
// a 164 x 164 m mesh; it also joined the two sides of a road and counted the
// path twice.

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
    /// Whether the row is a named trail rather than a path titled by what it
    /// is. Sections of a group share a name or share having none.
    var hasName: Bool { sections.first?.hasName ?? false }
    /// A named trail whose name comes from the map data, not one derived from
    /// a road. The Community tab's "Trails near you" marks rows "Official",
    /// so it lists only these.
    var isOfficial: Bool { sections.first?.hasOwnName ?? false }
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

    /// Unnamed sections of one kind join where they chain end to end within
    /// this distance (`TrailChain.joinMeters`, see there).
    static let unnamedJoinMeters = TrailChain.joinMeters

    /// Builds list rows from pack rows ranked by distance (nearest first).
    /// `maxLengthMeters` drops rows whose shown length is longer.
    ///
    /// `wholeTrail`, when given, returns every piece of a keyed section's
    /// trail (`TrailDataSource.trails(key:)`). A grouped row then shows the
    /// whole trail and its full length, not only the pieces the search
    /// reached (2026-10-08). It runs before the length filters, so they judge
    /// the length the card shows.
    static func items(from ranked: [(trail: TrailFeature, distance: Double)],
                      grouped: Bool,
                      minLengthMeters: Double? = nil,
                      maxLengthMeters: Double? = nil,
                      wholeTrail: ((TrailFeature) -> [TrailFeature])? = nil) -> [TrailListItem] {
        var items: [TrailListItem]
        if grouped {
            items = groups(from: ranked)
            if let wholeTrail { items = items.map { completed($0, wholeTrail) } }
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

    /// Neighbouring state packs both carry a path that crosses the state line
    /// (Geofabrik extracts keep whole ways). Same upstream object, same trail:
    /// keep the first, which in a ranked list is the nearest.
    static func withoutDuplicates(_ ranked: [(trail: TrailFeature, distance: Double)])
        -> [(trail: TrailFeature, distance: Double)] {
        var seen = Set<String>()
        return ranked.filter { seen.insert("\($0.trail.sourceID):\($0.trail.sourceRef)").inserted }
    }

    /// A grouped row with every piece of its trail: the ones the search found,
    /// nearest first, then the rest of the trail. Rows without a trail key
    /// (unnamed paths, older packs) are returned as they are.
    private static func completed(_ item: TrailListItem,
                                  _ wholeTrail: (TrailFeature) -> [TrailFeature]) -> TrailListItem {
        guard let keyed = item.sections.first(where: { $0.trailKey != nil }) else { return item }
        let have = Set(item.sections.map { "\($0.sourceID):\($0.sourceRef)" })
        let rest = wholeTrail(keyed)
            .filter { !have.contains("\($0.sourceID):\($0.sourceRef)") }
            .sorted { $0.sourceRef < $1.sourceRef }
        guard !rest.isEmpty else { return item }
        return TrailListItem(id: item.id, name: item.name, sections: item.sections + rest,
                             distanceMeters: item.distanceMeters)
    }

    private static func groups(from ranked: [(trail: TrailFeature, distance: Double)]) -> [TrailListItem] {
        var result: [TrailListItem] = []
        var byName: [String: [(trail: TrailFeature, distance: Double)]] = [:]
        var nameOrder: [String] = []
        var byTrailKey: [String: [(trail: TrailFeature, distance: Double)]] = [:]
        var keyOrder: [String] = []
        var unnamed: [(trail: TrailFeature, distance: Double)] = []
        for entry in ranked {
            guard let raw = entry.trail.name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                unnamed.append(entry)
                continue
            }
            // A trail key is the pack builder's grouping over the whole region,
            // the same rule as below (one name, pieces within 400 m) but not
            // limited to what the search reached; prefer it when present.
            if let key = entry.trail.trailKey {
                if byTrailKey[key] == nil { keyOrder.append(key) }
                byTrailKey[key, default: []].append(entry)
                continue
            }
            let key = raw.lowercased()
            if byName[key] == nil { nameOrder.append(key) }
            byName[key, default: []].append(entry)
        }
        for key in keyOrder {
            result.append(item(for: byTrailKey[key] ?? []))
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

    /// Unnamed sections chained end to end (`TrailChain.links`), per kind.
    /// Transitive: A–B and B–C make one group even when A and C are far
    /// apart, which is the whole point for a path split at every driveway.
    /// Every link joins two endpoints that have no other partner, so a group
    /// is always a simple line or ring, never a network.
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
            var linked = Set<[Int]>()
            for link in TrailChain.links(members.map(\.trail.coordinates), within: unnamedJoinMeters) {
                linked.insert([min(link.a, link.b), max(link.a, link.b)])
            }
            result += clusters(members) { linked.contains([$0, $1]) }
        }
        return result
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
        let x = dLon * TrailGeometry.metersPerDegree * max(0.01, cos(midLat * .pi / 180))
        let y = dLat * TrailGeometry.metersPerDegree
        return (x * x + y * y).squareRoot()
    }
}

// MARK: - Chains

/// Pieces of one path that meet end to end, as OSM leaves a path split at
/// every driveway: which pieces link, and the single line they make.
///
/// A link is made only where exactly two pieces meet — the rule the pack
/// builder uses for named ways. An endpoint joins another piece only when
/// that piece is the one and only piece with an endpoint within
/// `joinMeters`, and the same holds from the other side. At a junction
/// (three or more ends together: a "+", a "T", a campus grid) nothing is
/// joined, so linked pieces are always a simple line or ring. Two more guards:
/// each endpoint takes part in one link at most, and a link that doubles back
/// on itself (turning more than 135°) is refused, which is what two sides of
/// a road ending at the same corner look like.
enum TrailChain {

    /// Pieces that meet share an OSM node, but the pack drops ways under
    /// 30 m (`min_length_m`) — the driveway and road crossings along a side
    /// path — so real neighbours sit up to ~30 m apart. Measured on the NC
    /// pack along Duck Road (2026-09-26): gaps of 0–27 m between consecutive
    /// pieces; at 15 m the longest chain was 3 pieces, at 30 m it is 30
    /// pieces, 6.6 km.
    static let joinMeters = 30.0
    /// cos(135°): a join turning back more sharply than this is refused.
    static let maxTurnCosine = -0.7071

    /// Piece `a`'s end `aEnd` joins piece `b`'s end `bEnd`; end 0 is a line's
    /// first coordinate, 1 its last.
    struct Link: Hashable {
        let a: Int, aEnd: Int, b: Int, bEnd: Int
    }

    private struct End {
        let line: Int
        let end: Int
        let point: CLLocationCoordinate2D
    }

    /// The links between `lines`, each at most once.
    static func links(_ lines: [[CLLocationCoordinate2D]], within: Double = joinMeters) -> [Link] {
        var ends: [End] = []
        for (i, line) in lines.enumerated() where line.count >= 2 {
            ends.append(End(line: i, end: 0, point: line[0]))
            ends.append(End(line: i, end: 1, point: line[line.count - 1]))
        }
        // near[k]: the other pieces' endpoints within reach of endpoint k.
        var near = [[Int]](repeating: [], count: ends.count)
        for k in ends.indices {
            for m in ends.indices where m > k && ends[m].line != ends[k].line
                && TrailGeometry.meters(ends[k].point, ends[m].point) <= within {
                near[k].append(m)
                near[m].append(k)
            }
        }
        func partnerLines(_ k: Int) -> Set<Int> { Set(near[k].map { ends[$0].line }) }

        var used = Set<Int>()
        var result: [Link] = []
        for k in ends.indices where !used.contains(k) {
            let partners = partnerLines(k)
            guard partners.count == 1, let other = partners.first, other > ends[k].line,
                  let m = near[k].filter({ !used.contains($0) }).min(by: {
                      TrailGeometry.meters(ends[k].point, ends[$0].point) < TrailGeometry.meters(ends[k].point, ends[$1].point)
                  }),
                  partnerLines(m) == [ends[k].line],
                  !doublesBack(lines[ends[k].line], at: ends[k].end, into: lines[other], at: ends[m].end)
            else { continue }
            used.insert(k)
            used.insert(m)
            result.append(Link(a: ends[k].line, aEnd: ends[k].end, b: other, bEnd: ends[m].end))
        }
        return result
    }

    /// The one line `lines` make when every piece is linked into a single
    /// chain or ring: pieces in order, each turned to run the same way, the
    /// join point not repeated. Nil when they are not one simple chain.
    static func stitch(_ lines: [[CLLocationCoordinate2D]],
                       within: Double = joinMeters) -> (path: [CLLocationCoordinate2D], isClosed: Bool)? {
        guard lines.count >= 2, lines.allSatisfy({ $0.count >= 2 }) else { return nil }
        let all = links(lines, within: within)
        guard all.count == lines.count - 1 || all.count == lines.count else { return nil }
        var next: [Int: (line: Int, end: Int)] = [:]    // key: line * 2 + end
        for link in all {
            next[link.a * 2 + link.aEnd] = (link.b, link.bEnd)
            next[link.b * 2 + link.bEnd] = (link.a, link.aEnd)
        }
        let isClosed = all.count == lines.count
        // A line starts at a piece end with no link; a ring anywhere.
        var start = (line: 0, end: 0)
        if !isClosed {
            guard let free = (0..<lines.count * 2).first(where: { next[$0] == nil }) else { return nil }
            start = (free / 2, free % 2)
        }
        var path: [CLLocationCoordinate2D] = []
        var visited = Set<Int>()
        var current: (line: Int, end: Int)? = start
        while let piece = current, !visited.contains(piece.line) {
            visited.insert(piece.line)
            let coords: [CLLocationCoordinate2D] = piece.end == 0 ? lines[piece.line] : lines[piece.line].reversed()
            if let last = path.last, TrailGeometry.meters(last, coords[0]) < 1 {
                path += coords.dropFirst()
            } else {
                path += coords
            }
            current = next[piece.line * 2 + (1 - piece.end)]
        }
        guard visited.count == lines.count else { return nil }
        return (path, isClosed)
    }

    /// Whether going from `a` out through its end `aEnd` into `b` at its end
    /// `bEnd` turns back by more than 135°.
    private static func doublesBack(_ a: [CLLocationCoordinate2D], at aEnd: Int,
                                    into b: [CLLocationCoordinate2D], at bEnd: Int) -> Bool {
        let p = aEnd == 0 ? a[0] : a[a.count - 1]
        let q = bEnd == 0 ? b[0] : b[b.count - 1]
        let before = inward(a, from: aEnd), after = inward(b, from: bEnd)
        let cosLat = cos(p.latitude * .pi / 180)
        let v1 = ((p.longitude - before.longitude) * cosLat, p.latitude - before.latitude)
        let v2 = ((after.longitude - q.longitude) * cosLat, after.latitude - q.latitude)
        let n1 = (v1.0 * v1.0 + v1.1 * v1.1).squareRoot(), n2 = (v2.0 * v2.0 + v2.1 * v2.1).squareRoot()
        guard n1 > 0, n2 > 0 else { return false }
        return (v1.0 * v2.0 + v1.1 * v2.1) / (n1 * n2) < maxTurnCosine
    }

    /// The first vertex at least 10 m in from `end`, or the far end: the
    /// direction a piece has as it reaches that end, not a GPS-noise wiggle.
    private static func inward(_ line: [CLLocationCoordinate2D], from end: Int) -> CLLocationCoordinate2D {
        let ordered: [CLLocationCoordinate2D] = end == 0 ? line : line.reversed()
        return ordered.dropFirst().first { TrailGeometry.meters(ordered[0], $0) >= 10 } ?? ordered[ordered.count - 1]
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
        ranked = TrailListBuilder.withoutDuplicates(ranked)
        let library = self.library
        items = TrailListBuilder.items(
            from: Array(ranked.prefix(Self.sectionLimit)),
            grouped: grouped,
            minLengthMeters: includeShortPaths ? nil : TrailFilters.minimumLengthMeters(usesMiles: usesMiles),
            maxLengthMeters: filters.shortOnly ? TrailFilters.shortThresholdMeters(usesMiles: usesMiles) : nil,
            wholeTrail: { section in
                // The key starts with the region ("nc:w123"), naming the pack it came from.
                guard let key = section.trailKey,
                      let region = key.split(separator: ":").first,
                      let source = library.source(for: String(region)) else { return [] }
                return (try? source.trails(key: key)) ?? []
            }
        )
    }
}
