import Testing
import CoreLocation
import Foundation
@testable import PoCSquat

/// The Trails list in the Routes tab: grouping a trail's sections, the filter
/// chips, and the finder that runs them against a real pack.
///
/// The grouping cases come from real North Carolina data: inside ten miles of
/// downtown Raleigh, Walnut Creek Trail and Rocky Branch Trail are four rows
/// each, and generic names ("Main Trail") recur in unrelated parks.
@MainActor
struct TrailListTests {

    // MARK: Helpers

    private final class Marker {}

    /// A section of trail at `lat`/`lon`, `size` degrees across.
    private func section(_ id: Int64, _ name: String?, lat: Double = 35.78, lon: Double = -78.64,
                         size: Double = 0.002, length: Double = 1_000, surface: String? = nil,
                         dog: DogAccess = .unknown, provenance: DogAccessProvenance = .default,
                         bike: Bool = false, loop: Bool = false) -> TrailFeature {
        TrailFeature(id: id, sourceID: "osm", sourceRef: "w\(id)", name: name,
                     encodedPolyline: "", pointCount: 0, lengthMeters: length,
                     bounds: TrailBounds(minLatitude: lat, minLongitude: lon,
                                         maxLatitude: lat + size, maxLongitude: lon + size),
                     surface: surface, difficulty: nil,
                     dogAccess: dog, dogAccessProvenance: provenance,
                     allowsFoot: true, allowsBike: bike, allowsHorse: false, isLoop: loop)
    }

    private func ranked(_ trails: [TrailFeature], distances: [Double]? = nil) -> [(trail: TrailFeature, distance: Double)] {
        trails.enumerated().map { ($0.element, distances?[$0.offset] ?? Double($0.offset) * 100) }
    }

    // MARK: Grouping

    @Test("Touching sections of one trail become one row with the total length and the nearest distance")
    func groupsTouchingSections() {
        let rows = ranked([
            section(1, "Walnut Creek Trail", lon: -78.640, length: 1_800),
            section(2, "Walnut Creek Trail", lon: -78.638, length: 3_500),
            section(3, "Walnut Creek Trail", lon: -78.636, length: 1_700)
        ], distances: [2_400, 900, 3_100])
        let items = TrailListBuilder.items(from: rows, grouped: true)
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.isGroup)
        #expect(item.lengthMeters == 7_000)
        #expect(item.distanceMeters == 900)
        #expect(item.sections.map(\.id) == [2, 1, 3], "sections are nearest first")
        #expect(item.name == "Walnut Creek Trail")
    }

    @Test("The same name in two places far apart stays two rows")
    func sameNameFarApartStaysSeparate() {
        let rows = ranked([
            section(1, "Main Trail", lat: 35.78),
            section(2, "Main Trail", lat: 35.90)    // ~13 km north
        ])
        let items = TrailListBuilder.items(from: rows, grouped: true)
        #expect(items.count == 2)
        #expect(items.allSatisfy { !$0.isGroup })
    }

    @Test("Names group regardless of case and surrounding spaces")
    func nameMatchingIgnoresCase() {
        let rows = ranked([section(1, "Rocky Branch Trail"), section(2, " rocky branch trail ")])
        #expect(TrailListBuilder.items(from: rows, grouped: true).count == 1)
    }

    // MARK: Unnamed sections

    /// Google's polyline encoding at precision 5, as in `TrailWalkTests`.
    private func encode(_ coords: [CLLocationCoordinate2D]) -> String {
        var out = ""
        var lastLat = 0, lastLon = 0
        for c in coords {
            let lat = Int((c.latitude * 1e5).rounded()), lon = Int((c.longitude * 1e5).rounded())
            for delta in [lat - lastLat, lon - lastLon] {
                var v = delta < 0 ? ~(delta << 1) : (delta << 1)
                while v >= 0x20 {
                    out.append(Character(UnicodeScalar(UInt8((0x20 | (v & 0x1f)) + 63))))
                    v >>= 5
                }
                out.append(Character(UnicodeScalar(UInt8(v + 63))))
            }
            lastLat = lat; lastLon = lon
        }
        return out
    }

    /// Metres east along the Duck Road side path (36.10 N), in degrees of longitude.
    private let duckLat = 36.10
    private func east(_ meters: Double) -> Double { -75.717 + meters / (111_320 * cos(36.10 * .pi / 180)) }

    /// A straight piece of path along 36.10 N from `from` to `to` metres east —
    /// the shape OSM gives a side path split at every driveway.
    private func piece(_ id: Int64, from: Double, to: Double, name: String? = nil,
                       surface: String? = "asphalt", tags: [String: String] = ["highway": "cycleway", "bicycle": "designated"],
                       foot: Bool = true, bike: Bool = true) -> TrailFeature {
        let coords = [CLLocationCoordinate2D(latitude: duckLat, longitude: east(from)),
                      CLLocationCoordinate2D(latitude: duckLat, longitude: east(to))]
        return TrailFeature(id: id, sourceID: "osm", sourceRef: "w\(id)", name: name,
                            encodedPolyline: encode(coords), pointCount: 2, lengthMeters: abs(to - from),
                            bounds: TrailBounds(minLatitude: duckLat, minLongitude: min(east(from), east(to)),
                                                maxLatitude: duckLat, maxLongitude: max(east(from), east(to))),
                            surface: surface, difficulty: nil, dogAccess: .unknown, dogAccessProvenance: .default,
                            allowsFoot: foot, allowsBike: bike, allowsHorse: false, isLoop: false, tags: tags)
    }

    @Test("A chain of touching unnamed pieces of one path is one row, named for what it is")
    func unnamedChainGroups() {
        // Gaps of 0, 20 and 25 m: the pack drops the crossings between pieces.
        let pieces = [piece(1, from: 0, to: 100), piece(2, from: 100, to: 300),
                      piece(3, from: 320, to: 500), piece(4, from: 525, to: 700)]
        let items = TrailListBuilder.items(from: ranked(pieces, distances: [300, 50, 400, 600]), grouped: true)
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.isGroup)
        #expect(item.name == "Paved Bike Path")
        #expect(item.lengthMeters == 655)
        #expect(item.distanceMeters == 50)
        #expect(item.sections.map(\.id) == [2, 1, 3, 4], "nearest first")
        #expect(item.id == "g1-2-3-4")
        #expect(TrailText.summary(for: item).contains("4 sections"))
        // Transitive: the two ends of the chain are nowhere near each other.
        let firstEnds = pieces[0].coordinates, lastEnds = pieces[3].coordinates
        #expect(TrailListBuilder.endpointGapMeters(firstEnds, lastEnds) > 400)
    }

    @Test("A gap wider than the join distance keeps two rows")
    func unnamedGapSplits() {
        let gap = TrailListBuilder.unnamedJoinMeters + 10
        let rows = ranked([piece(1, from: 0, to: 200), piece(2, from: 200 + gap, to: 400)])
        let items = TrailListBuilder.items(from: rows, grouped: true)
        #expect(items.count == 2)
        #expect(items.allSatisfy { !$0.isGroup && $0.name == "Paved Bike Path" })
    }

    @Test("Touching unnamed pieces of different kinds stay apart: paved/unpaved, bike/foot, access")
    func unnamedKindsStayApart() {
        let paved = piece(1, from: 0, to: 200)
        let unpaved = piece(2, from: 200, to: 400, surface: "gravel")
        #expect(TrailListBuilder.items(from: ranked([paved, unpaved]), grouped: true).map(\.name)
                == ["Paved Bike Path", "Unpaved Bike Path"])

        let footway = piece(3, from: 200, to: 400, tags: ["highway": "footway"], bike: false)
        #expect(TrailListBuilder.items(from: ranked([paved, footway]), grouped: true).count == 2)

        // Same title, different access: bike rules must not be averaged.
        let pathBikes = piece(4, from: 0, to: 200, tags: ["highway": "path"], bike: true)
        let pathNoBikes = piece(5, from: 200, to: 400, tags: ["highway": "path"], bike: false)
        #expect(pathBikes.pathKindLabel == pathNoBikes.pathKindLabel)
        #expect(TrailListBuilder.items(from: ranked([pathBikes, pathNoBikes]), grouped: true).count == 2)
    }

    @Test("Named sections never join unnamed ones, and still group by name as before")
    func namedGroupingUnchanged() {
        let rows = ranked([
            piece(1, from: 0, to: 200, name: "Duck Trail"),
            piece(2, from: 200, to: 400),
            piece(3, from: 900, to: 1_100, name: "Duck Trail"),   // 700 m past piece 1
            piece(4, from: 400, to: 600)
        ])
        let items = TrailListBuilder.items(from: rows, grouped: true)
        // Named: 1 and 3 are 700 m apart, over the 400 m join, so two rows even
        // though unnamed pieces bridge them. Unnamed 2 and 4 chain.
        #expect(items.filter { $0.name == "Duck Trail" }.count == 2)
        #expect(items.filter { $0.name == "Paved Bike Path" }.map { $0.sections.map(\.id) } == [[2, 4]])

        // A builder-derived name is a name like any other.
        let derived = ranked([
            piece(5, from: 0, to: 200, name: "Duck Road Path", tags: ["highway": "cycleway", "name_source": "derived"]),
            piece(6, from: 300, to: 500, name: "Duck Road Path", tags: ["highway": "cycleway", "name_source": "derived"])
        ])
        let named = TrailListBuilder.items(from: derived, grouped: true)
        #expect(named.map(\.name) == ["Duck Road Path"])
        #expect(named[0].isGroup, "joined by name within 400 m, not by endpoints")
    }

    @Test("Unnamed sections with no geometry never group")
    func unnamedWithoutGeometry() {
        let rows = ranked([section(1, nil), section(2, nil), section(3, "")])
        let items = TrailListBuilder.items(from: rows, grouped: true)
        #expect(items.count == 3)
        #expect(items.map(\.name) == ["Unnamed Trail", "Unnamed Trail", "Unnamed Trail"])
    }

    @Test("'List sections separately' lists every unnamed piece on its own")
    func unnamedSeparately() {
        let rows = ranked([piece(1, from: 0, to: 100), piece(2, from: 100, to: 300), piece(3, from: 300, to: 500)])
        let items = TrailListBuilder.items(from: rows, grouped: false)
        #expect(items.map(\.id) == ["t1", "t2", "t3"])
        #expect(items.allSatisfy { $0.name == "Paved Bike Path" })
    }

    @Test("The short-path cutoff judges an unnamed chain on its total")
    func unnamedShortCutoffOnTotal() {
        let min = TrailFilters.minimumLengthMeters(usesMiles: true)   // 402 m
        let rows = ranked([piece(1, from: 0, to: 150), piece(2, from: 150, to: 300), piece(3, from: 300, to: 450)])
        let grouped = TrailListBuilder.items(from: rows, grouped: true, minLengthMeters: min)
        #expect(grouped.count == 1 && grouped[0].lengthMeters == 450, "450 m in total clears 0.25 mi")
        #expect(TrailListBuilder.items(from: rows, grouped: false, minLengthMeters: min).isEmpty,
                "each 150 m piece on its own does not")
    }

    @Test("Unnamed labels say what the path is")
    func unnamedLabels() {
        func label(_ surface: String?, _ highway: String?, bicycle: String? = nil, loop: Bool = false) -> String {
            TrailFeature.unnamedLabel(surface: surface, highway: highway, bicycle: bicycle, isLoop: loop)
        }
        #expect(label("asphalt", "cycleway") == "Paved Bike Path")
        #expect(label("paved", "path", bicycle: "designated") == "Paved Bike Path")
        #expect(label("asphalt", "path", bicycle: "yes") == "Paved Path", "allowed is not designated")
        #expect(label("gravel", "cycleway") == "Unpaved Bike Path")
        #expect(label(nil, "cycleway") == "Bike Path")
        #expect(label(nil, "footway") == "Footpath")
        #expect(label("concrete", "footway") == "Paved Footpath")
        #expect(label("dirt", "track") == "Unpaved Track")
        #expect(label("ground", "path") == "Unpaved Path")
        #expect(label("ground", nil) == "Unpaved Path")
        #expect(label("wood", "footway") == "Boardwalk")
        #expect(label("ground", "bridleway") == "Unpaved Bridle Path")
        #expect(label(nil, "path") == "Unnamed Trail", "'Path' alone would read as a placeholder")
        #expect(label(nil, nil) == "Unnamed Trail")
        #expect(label("metal", "path") == "Unnamed Trail", "an unknown surface is not guessed")
        #expect(label("ASPHALT", "Cycleway") == "Paved Bike Path")
        #expect(label("asphalt", "path", loop: true) == "Paved Loop")
        #expect(label("wood", "footway", loop: true) == "Boardwalk Loop")
        #expect(label("asphalt", "cycleway", loop: true) == "Paved Bike Loop")
        #expect(label(nil, "cycleway", loop: true) == "Bike Loop")
        #expect(label(nil, "footway", loop: true) == "Unnamed Loop")
    }

    @Test("A named row keeps its name; blank names are not names")
    func displayNameUsesName() {
        #expect(piece(1, from: 0, to: 100, name: "Duck Trail").displayName == "Duck Trail")
        #expect(piece(2, from: 0, to: 100, name: "  ").displayName == "Paved Bike Path")
    }

    @Test("With grouping off, every section is its own row")
    func separateSections() {
        let rows = ranked([section(1, "Walnut Creek Trail"), section(2, "Walnut Creek Trail")])
        let items = TrailListBuilder.items(from: rows, grouped: false)
        #expect(items.count == 2)
        #expect(items.map(\.id) == ["t1", "t2"])
    }

    @Test("A row's id is the same whatever order its sections arrive in")
    func stableGroupId() {
        let a = TrailListBuilder.items(from: ranked([section(1, "X"), section(2, "X")], distances: [1, 2]), grouped: true)
        let b = TrailListBuilder.items(from: ranked([section(1, "X"), section(2, "X")], distances: [2, 1]), grouped: true)
        #expect(a[0].id == b[0].id)
    }

    @Test("Rows are ordered by distance to their nearest section")
    func orderedByDistance() {
        let rows = ranked([section(1, "Far", lat: 35.70), section(2, "Near", lat: 35.80)], distances: [5_000, 200])
        #expect(TrailListBuilder.items(from: rows, grouped: true).map(\.name) == ["Near", "Far"])
    }

    // MARK: Length filter

    @Test("The length limit applies to the length the card shows: the group's total when grouped")
    func lengthLimitUsesShownLength() {
        let rows = ranked([
            section(1, "Walnut Creek Trail", lon: -78.640, length: 2_000),
            section(2, "Walnut Creek Trail", lon: -78.638, length: 2_000)
        ])
        let limit = TrailFilters.shortThresholdMeters(usesMiles: true)
        #expect(TrailListBuilder.items(from: rows, grouped: true, maxLengthMeters: limit).isEmpty,
                "4 km in total is not 'under 2 mi'")
        #expect(TrailListBuilder.items(from: rows, grouped: false, maxLengthMeters: limit).count == 2,
                "each 2 km section is")
    }

    @Test("Rows under a quarter mile are hidden, judged on the grouped total")
    func minimumLength() {
        let min = TrailFilters.minimumLengthMeters(usesMiles: true)
        let rows = ranked([
            section(1, "Morgan Drive", lat: 35.70, length: 150),                  // a cemetery drive
            section(2, "Rocky Branch Trail", lon: -78.640, length: 300),          // short piece...
            section(3, "Rocky Branch Trail", lon: -78.638, length: 300)           // ...of a longer trail
        ])
        let grouped = TrailListBuilder.items(from: rows, grouped: true, minLengthMeters: min)
        #expect(grouped.map(\.name) == ["Rocky Branch Trail"], "600 m in total clears 0.25 mi; 150 m does not")
        #expect(TrailListBuilder.items(from: rows, grouped: false, minLengthMeters: min).isEmpty,
                "listed separately, each section is judged on its own")
        #expect(TrailListBuilder.items(from: rows, grouped: true, minLengthMeters: nil).count == 2,
                "with short paths shown, nothing is dropped")
    }

    // MARK: Row properties

    @Test("Surface shows only when every section that states one agrees")
    func surfaceAgreement() {
        func item(_ surfaces: [String?]) -> TrailListItem {
            TrailListItem(id: "x", name: "x",
                          sections: surfaces.enumerated().map { section(Int64($0.offset), "x", surface: $0.element) },
                          distanceMeters: 0)
        }
        #expect(item(["asphalt", "concrete"]).surfaceKind == .paved)
        #expect(item(["gravel", nil, "dirt"]).surfaceKind == .unpaved)
        #expect(item(["asphalt", "gravel"]).surfaceKind == nil)
        #expect(item(["wood"]).surfaceKind == nil, "a boardwalk is neither")
        #expect(item([nil]).surfaceKind == nil)
    }

    @Test("Dog rule: only tagged values count, and the strictest one wins")
    func dogRule() {
        func item(_ rules: [(DogAccess, DogAccessProvenance)]) -> TrailListItem {
            TrailListItem(id: "x", name: "x",
                          sections: rules.enumerated().map {
                              section(Int64($0.offset), "x", dog: $0.element.0, provenance: $0.element.1)
                          },
                          distanceMeters: 0)
        }
        #expect(item([(.leashRequired, .tagged)]).confidentDogAccess == .leashRequired)
        #expect(item([(.leashRequired, .tagged), (.notPermitted, .tagged)]).confidentDogAccess == .notPermitted)
        #expect(item([(.offLeashAllowed, .tagged), (.leashRequired, .tagged)]).confidentDogAccess == .leashRequired)
        #expect(item([(.notPermitted, .inferred)]).confidentDogAccess == nil, "an inferred rule is never shown as fact")
        #expect(item([(.unknown, .default)]).confidentDogAccess == nil)
    }

    @Test("Only a single section can be a loop; bikes only when every section allows them")
    func loopAndBike() {
        let one = TrailListItem(id: "a", name: "a", sections: [section(1, "a", bike: true, loop: true)], distanceMeters: 0)
        #expect(one.isLoop && one.allowsBike)
        let two = TrailListItem(id: "b", name: "b",
                                sections: [section(1, "b", bike: true, loop: true), section(2, "b", bike: false, loop: true)],
                                distanceMeters: 0)
        #expect(!two.isLoop)
        #expect(!two.allowsBike)
    }

    // MARK: Filters → query

    @Test("'Hide no-dog trails' removes only 'no dogs', never the unknowns")
    func hideNoDogsKeepsUnknown() {
        var filters = TrailFilters()
        filters.hideNoDogs = true
        let dog = filters.query(cycling: false).dogAccess
        #expect(dog == [.offLeashAllowed, .leashRequired, .unknown])
        #expect(TrailFilters().query(cycling: false).dogAccess == nil)
    }

    @Test("Cycling asks for bike-legal trails; surface chips map to OSM values")
    func queryMapping() {
        #expect(TrailFilters().query(cycling: true).allowsBike == true)
        #expect(TrailFilters().query(cycling: false).allowsBike == nil)
        var filters = TrailFilters()
        filters.surface = .paved
        filters.loopsOnly = true
        let q = filters.query(cycling: false)
        #expect(q.surfaces?.contains("asphalt") == true)
        #expect(q.surfaces?.contains("gravel") == false)
        #expect(q.loopsOnly)
    }

    // MARK: Finder against the fixture pack

    private func fixtureLibrary() throws -> TrailPackLibrary {
        let url = try #require(Bundle(for: Marker.self).url(forResource: "fixture", withExtension: "wktpack"))
        let library = TrailPackLibrary(registry: TrailAttributionRegistry())
        try #require(library.open(url: url, region: "fixture") != nil)
        return library
    }

    /// Fixture trails near Raleigh (see TrailPackTests): 1 Lake Loop (leash,
    /// loop), 2 Riverside Greenway (leash, bike), 3 Dog Park Path (off-leash),
    /// 4 unnamed (no dogs, inferred), 6 unnamed; 5 Far Ridge is ~20 km north,
    /// outside the ten-mile radius.
    private let raleigh = CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64)

    @Test("The finder searches ten miles, nearest first, and leaves out the far trail")
    func finderRadius() throws {
        let finder = TrailFinder(library: try fixtureLibrary())
        finder.refresh(near: raleigh, grouped: true, cycling: false, usesMiles: true, includeShortPaths: true)
        let ids = finder.items.flatMap { $0.sections.map(\.id) }
        #expect(!ids.contains(5), "Far Ridge Trail is outside ten miles")
        #expect(ids.contains(1) && ids.contains(2) && ids.contains(3))
        let distances = finder.items.map(\.distanceMeters)
        #expect(distances == distances.sorted())
        #expect(finder.failure == nil)
    }

    @Test("Filters reach the pack: loops, no-dog hiding, cycling")
    func finderFilters() throws {
        let finder = TrailFinder(library: try fixtureLibrary())
        finder.filters.loopsOnly = true
        finder.refresh(near: raleigh, grouped: true, cycling: false, usesMiles: true)
        #expect(finder.items.flatMap { $0.sections.map(\.id) } == [1])

        finder.filters = TrailFilters()
        finder.filters.hideNoDogs = true
        finder.refresh(near: raleigh, grouped: true, cycling: false, usesMiles: true)
        #expect(!finder.items.flatMap { $0.sections.map(\.id) }.contains(4))

        finder.filters = TrailFilters()
        finder.refresh(near: raleigh, grouped: true, cycling: true, usesMiles: true)
        #expect(finder.items.flatMap { $0.sections.map(\.id) } == [2], "only Riverside Greenway allows bikes")
    }

    @Test("Short paths are hidden by default and shown on request")
    func finderShortPaths() throws {
        let finder = TrailFinder(library: try fixtureLibrary())
        finder.refresh(near: raleigh, grouped: true, cycling: false, usesMiles: true)
        let hidden = finder.items.flatMap { $0.sections.map(\.id) }
        #expect(!hidden.contains(3) && !hidden.contains(6), "Dog Park Path (220 m) and the 120 m path are under 0.25 mi")
        #expect(hidden.contains(1) && hidden.contains(2))

        finder.refresh(near: raleigh, grouped: true, cycling: false, usesMiles: true, includeShortPaths: true)
        let shown = finder.items.flatMap { $0.sections.map(\.id) }
        #expect(shown.contains(3) && shown.contains(6))
    }

    @Test("No location means no rows and no error")
    func finderWithoutLocation() throws {
        let finder = TrailFinder(library: try fixtureLibrary())
        finder.refresh(near: nil, grouped: true, cycling: false, usesMiles: true)
        #expect(finder.items.isEmpty)
        #expect(finder.failure == nil)
        #expect(finder.hasSearched)
    }
}
