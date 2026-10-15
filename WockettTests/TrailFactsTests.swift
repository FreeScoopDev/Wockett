import Testing
import Foundation
import UIKit
@testable import PoCSquat

/// The trail detail's "Trail facts" card (spec feat/trail-detail-facts): what
/// the map data states, in words, and nothing it does not state. The values
/// are OSM's own vocabulary as the North Carolina pack carries it; the last
/// tests read real rows from that pack.
@MainActor
struct TrailFactsTests {

    // MARK: Helpers

    /// A pack row whose `tags_json` holds `tags`, as the builder writes it.
    private func section(_ id: Int64, difficulty: String? = nil, tags: [String: String] = [:]) -> TrailFeature {
        let json = String(data: (try? JSONSerialization.data(withJSONObject: tags, options: [.sortedKeys])) ?? Data(),
                          encoding: .utf8)
        return TrailFeature(id: id, sourceID: "osm", sourceRef: "w\(id)", name: "Test Trail",
                            encodedPolyline: "", pointCount: 0, lengthMeters: 1_000,
                            bounds: TrailBounds(minLatitude: 35.78, minLongitude: -78.64,
                                                maxLatitude: 35.782, maxLongitude: -78.638),
                            surface: nil, difficulty: difficulty,
                            dogAccess: .unknown, dogAccessProvenance: .default,
                            allowsFoot: true, allowsBike: false, allowsHorse: false, isLoop: false,
                            tagsJSON: json, trailKey: nil)
    }

    private func item(_ sections: [TrailFeature]) -> TrailListItem {
        TrailListItem(id: "t1", name: "Test Trail", sections: sections, distanceMeters: 0)
    }

    private func text(_ kind: TrailFacts.Kind, _ sections: [TrailFeature]) -> String? {
        TrailFacts.facts(for: item(sections)).first { $0.kind == kind }?.text
    }

    // MARK: Each mapping

    @Test("Path type from sac_scale, in Joe's confirmed wording", arguments: [
        ("hiking", "Walking path"),
        ("mountain_hiking", "Rough mountain path"),
        ("demanding_mountain_hiking", "Steep, demanding path"),
        ("alpine_hiking", "Alpine route, experienced hikers"),
        ("demanding_alpine_hiking", "Alpine route, experienced hikers"),
        ("difficult_alpine_hiking", "Alpine route, experienced hikers")
    ])
    func pathType(value: String, expected: String) {
        #expect(text(.pathType, [section(1, difficulty: value)]) == expected)
    }

    @Test("Surface from smoothness", arguments: [
        ("excellent", "Smooth"), ("good", "Smooth"),
        ("intermediate", "Uneven in places"),
        ("bad", "Rough"), ("very_bad", "Rough"), ("horrible", "Rough"), ("very_horrible", "Rough"),
        ("impassable", "May be impassable")
    ])
    func surface(value: String, expected: String) {
        #expect(text(.surface, [section(1, tags: ["smoothness": value])]) == expected)
    }

    @Test("Marking from trail_visibility", arguments: [
        ("excellent", "Well marked"), ("good", "Well marked"),
        ("intermediate", "Faint or unmarked in places"), ("bad", "Faint or unmarked in places"),
        ("horrible", "Faint or unmarked in places"), ("no", "Faint or unmarked in places")
    ])
    func marking(value: String, expected: String) {
        #expect(text(.marking, [section(1, tags: ["trail_visibility": value])]) == expected)
    }

    @Test("Wheelchair only on yes or designated; no, limited and anything else show nothing", arguments: [
        ("yes", true), ("designated", true), ("limited", false), ("no", false), ("unknown", false)
    ])
    func wheelchair(value: String, shown: Bool) {
        let fact = text(.wheelchair, [section(1, tags: ["wheelchair": value])])
        #expect(fact == (shown ? "Mapped as wheelchair accessible" : nil))
    }

    @Test("Lit only on yes", arguments: [("yes", true), ("no", false), ("24/7", false)])
    func lit(value: String, shown: Bool) {
        #expect(text(.lit, [section(1, tags: ["lit": value])]) == (shown ? "Lit at night" : nil))
    }

    @Test("Maintained by is the operator text, on one line")
    func maintainer() {
        #expect(text(.maintainedBy, [section(1, tags: ["operator": "US Forest Service"])]) == "US Forest Service")
        #expect(text(.maintainedBy, [section(1, tags: ["operator": "  Duke Forest /\nDuke University "])])
                == "Duke Forest / Duke University")
    }

    @Test("A maintainer name longer than 60 characters is cut to 60, ellipsis included")
    func maintainerTrimmed() throws {
        let long = "North Carolina Department of Natural and Cultural Resources Division of Parks"
        let shown = try #require(text(.maintainedBy, [section(1, tags: ["operator": long])]))
        #expect(shown.count == 60, "Joe's 60, written out: not read from the constant under test")
        #expect(shown.hasSuffix("…"))
        #expect(shown.hasPrefix("North Carolina Department of Natural and Cultural"))
        let exact = String(repeating: "a", count: 60)
        #expect(text(.maintainedBy, [section(1, tags: ["operator": exact])]) == exact, "60 is not cut")
        let over = String(repeating: "b", count: 61)
        #expect(text(.maintainedBy, [section(1, tags: ["operator": over])]) == String(repeating: "b", count: 59) + "…",
                "61 is cut")
    }

    @Test("An operator that is not a name (private, no, unknown, as the published packs carry) shows nothing",
          arguments: ["private", "Private", "no", "unknown", "none", "yes"])
    func notANameOperator(value: String) {
        #expect(text(.maintainedBy, [section(1, tags: ["operator": value])]) == nil)
    }

    @Test("Path type takes the harder of the difficulty column and the row's own sac_scale")
    func pathTypeFromBothSources() {
        // The builder writes the merged ways' majority grade to the column and
        // the first way's tags to tags_json; either can be the harder one.
        #expect(text(.pathType, [section(1, difficulty: "hiking", tags: ["sac_scale": "mountain_hiking"])])
                == "Rough mountain path")
        #expect(text(.pathType, [section(1, difficulty: "mountain_hiking", tags: ["sac_scale": "hiking"])])
                == "Rough mountain path")
        #expect(text(.pathType, [section(1, tags: ["sac_scale": "hiking"])]) == "Walking path")
    }

    @Test("Values are read regardless of case and stray spaces")
    func normalizes() {
        #expect(text(.pathType, [section(1, difficulty: " Mountain_Hiking ")]) == "Rough mountain path")
        #expect(text(.wheelchair, [section(1, tags: ["wheelchair": "YES"])]) != nil)
    }

    // MARK: Unknown values and no data

    @Test("Unknown or unexpected values show nothing, never a guess")
    func unknownValues() {
        let row = section(1, difficulty: "strenuous",
                          tags: ["smoothness": "medium", "trail_visibility": "ok", "wheelchair": "",
                                 "lit": "", "operator": "   ", "incline": "15%", "access": "yes"])
        #expect(TrailFacts.facts(for: item([row])).isEmpty)
    }

    @Test("No facts, no card: a row with only the everyday tags gives an empty list")
    func noFacts() {
        let row = section(1, tags: ["highway": "path", "surface": "ground", "foot": "designated"])
        #expect(TrailFacts.facts(for: item([row])).isEmpty)
        #expect(TrailFacts.facts(for: item([section(2)])).isEmpty, "no tags_json at all")
    }

    @Test("Length never becomes a difficulty: a long trail with no sac_scale has no path type")
    func noInventedDifficulty() {
        let long = TrailListItem(id: "t1", name: "Long", sections: (1...30).map { section($0) }, distanceMeters: 0)
        #expect(TrailFacts.facts(for: long).isEmpty)
    }

    @Test("Facts come in a fixed order: path type, surface, marking, access, lighting, maintainer")
    func order() {
        let row = section(1, difficulty: "hiking",
                          tags: ["operator": "Cary", "lit": "yes", "wheelchair": "yes",
                                 "trail_visibility": "good", "smoothness": "good"])
        #expect(TrailFacts.facts(for: item([row])).map(\.kind) == TrailFacts.Kind.allCases)
    }

    // MARK: Grouped trails

    @Test("Across sections the hardest path type, the roughest surface and the faintest marking win")
    func cautiousValueWins() {
        let easy = section(1, difficulty: "hiking", tags: ["smoothness": "excellent", "trail_visibility": "excellent"])
        let hard = section(2, difficulty: "demanding_mountain_hiking",
                           tags: ["smoothness": "bad", "trail_visibility": "intermediate"])
        let silent = section(3)
        for order in [[easy, hard, silent], [silent, hard, easy], [hard, easy, silent]] {
            #expect(text(.pathType, order) == "Steep, demanding path")
            #expect(text(.surface, order) == "Rough")
            #expect(text(.marking, order) == "Faint or unmarked in places")
        }
    }

    @Test("A graded fact appears when only one section states it")
    func oneSectionStates() {
        #expect(text(.surface, [section(1), section(2, tags: ["smoothness": "intermediate"]), section(3)])
                == "Uneven in places")
    }

    @Test("Wheelchair and lit need every section that states one to agree")
    func agreementRule() {
        // Sections that say nothing do not block it.
        #expect(text(.wheelchair, [section(1, tags: ["wheelchair": "yes"]), section(2),
                                   section(3, tags: ["wheelchair": "designated"])]) != nil)
        #expect(text(.lit, [section(1, tags: ["lit": "yes"]), section(2)]) == "Lit at night")
        // One section that says otherwise does.
        #expect(text(.wheelchair, [section(1, tags: ["wheelchair": "yes"]),
                                   section(2, tags: ["wheelchair": "limited"])]) == nil)
        #expect(text(.lit, [section(1, tags: ["lit": "yes"]), section(2, tags: ["lit": "no"])]) == nil)
    }

    @Test("Maintained by appears only when every section that names one names the same one")
    func maintainerAgreement() {
        #expect(text(.maintainedBy, [section(1, tags: ["operator": "Cary"]), section(2),
                                     section(3, tags: ["operator": "cary"])]) == "Cary")
        #expect(text(.maintainedBy, [section(1, tags: ["operator": "Nantahala Hiking Club"]),
                                     section(2, tags: ["operator": "Smoky Mountain Hiking Club"])]) == nil)
    }

    // MARK: Real rows

    @Test("Real-shaped rows: two Appalachian Trail sections as the NC pack stores them")
    func realShapedRows() {
        // tags_json of NC pack rows w27437755 and w1215900855, verbatim.
        let a = TrailFeature.tags(fromJSON: #"{"bicycle":"no","foot":"designated","highway":"footway","horse":"no","merged_ways":7,"operator":"Nantahala Hiking Club","sac_scale":"mountain_hiking","smoothness":"intermediate","surface":"paving_stones","trail_visibility":"excellent","wheelchair":"limited"}"#)
        let b = TrailFeature.tags(fromJSON: #"{"bicycle":"no","foot":"designated","highway":"path","horse":"no","merged_ways":7,"operator":"Smoky Mountain Hiking Club","sac_scale":"mountain_hiking","surface":"ground","trail_visibility":"excellent","wheelchair":"no"}"#)
        let one = TrailFacts.facts(for: item([section(1, difficulty: "mountain_hiking", tags: a)]))
        #expect(one.map(\.text) == ["Rough mountain path", "Uneven in places", "Well marked", "Nantahala Hiking Club"])
        let both = TrailFacts.facts(for: item([section(1, difficulty: "mountain_hiking", tags: a),
                                               section(2, difficulty: "mountain_hiking", tags: b)]))
        #expect(both.map(\.text) == ["Rough mountain path", "Uneven in places", "Well marked"],
                "two clubs: no maintainer; limited and no: no wheelchair line")
    }

    @Test("The bundled NC pack: Strollway and the Appalachian Trail, read through the real source")
    func bundledPack() throws {
        let url = try #require(Bundle.main.url(forResource: "nc", withExtension: "wktpack"))
        let source = try BundledTrailSource(url: url)

        let strollway = try source.trails(key: "nc:w1424032424")
        #expect(strollway.count == 2)
        #expect(TrailFacts.facts(for: item(strollway)).map(\.text)
                == ["Smooth", "Well marked", "Mapped as wheelchair accessible", "Lit at night"])

        // Lower Piney Trail: the column says hiking, the row's sac_scale says
        // mountain_hiking (two merged ways, one of each in OSM).
        let piney = try source.trails(key: "nc:w171710443")
        #expect(piney.first?.difficulty == "hiking")
        #expect(TrailFacts.facts(for: item(piney)).first { $0.kind == .pathType }?.text == "Rough mountain path")

        // Six sections, three hiking clubs, wheelchair limited / yes / no.
        let appalachian = try source.trails(key: "nc:w120342541")
        #expect(appalachian.count == 6)
        #expect(TrailFacts.facts(for: item(appalachian)).map(\.text)
                == ["Rough mountain path", "Uneven in places", "Well marked"])
    }

    @Test("Every fact's icon exists in SF Symbols")
    func symbolsExist() {
        for symbol in [WktSymbol.hiking, .trailSurface, .trailMarking, .wheelchair, .lit, .maintainer] {
            #expect(UIImage(systemName: symbol.name) != nil, "\(symbol.name)")
        }
    }
}
