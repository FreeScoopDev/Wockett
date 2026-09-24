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

    @Test("Unnamed trails never group, even when they touch")
    func unnamedNeverGroups() {
        let rows = ranked([section(1, nil), section(2, nil), section(3, "")])
        let items = TrailListBuilder.items(from: rows, grouped: true)
        #expect(items.count == 3)
        #expect(items.map(\.name) == ["Unnamed Trail", "Unnamed Trail", "Unnamed Trail"])
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
