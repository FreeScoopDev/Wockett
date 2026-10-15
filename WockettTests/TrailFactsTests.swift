import Testing
import Foundation
import UIKit
@testable import PoCSquat

/// The trail detail's "Trail facts" card (spec feat/trail-detail-facts): what
/// the map data states, in words, and nothing it does not state. The values
/// are OSM's own vocabulary as the published packs carry it; the last tests
/// read real rows from the bundled North Carolina pack.
@MainActor
struct TrailFactsTests {

    // MARK: Helpers

    /// A pack row `length` metres long whose `tags_json` holds `tags`, as the
    /// builder writes it.
    private func section(_ id: Int64, difficulty: String? = nil, length: Double = 1_000,
                         tags: [String: String] = [:]) -> TrailFeature {
        let json = String(data: (try? JSONSerialization.data(withJSONObject: tags, options: [.sortedKeys])) ?? Data(),
                          encoding: .utf8)
        return TrailFeature(id: id, sourceID: "osm", sourceRef: "w\(id)", name: "Test Trail",
                            encodedPolyline: "", pointCount: 0, lengthMeters: length,
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

    private func text(_ kind: TrailFacts.Kind, _ sections: [TrailFeature],
                      mode: ActivityMode = .walking) -> String? {
        TrailFacts.facts(for: item(sections), activityMode: mode).first { $0.kind == kind }?.text
    }

    // MARK: Each mapping, on a single section (the whole trail)

    @Test("Path type from sac_scale, in Joe's confirmed wording", arguments: [
        ("strolling", "Walking path"),
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
        ("intermediate", "Faint or unmarked in places"), ("bad", "Faint or unmarked"),
        ("horrible", "Faint or unmarked"), ("no", "Faint or unmarked")
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
        #expect(text(.maintainedBy, [section(1, tags: ["operator": "Cary"])]) == "Cary", "4 characters is a name")
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

    @Test("An operator that says nothing about who maintains the trail shows nothing (Joe, 2026-10-15)",
          arguments: ["private", "Private", "no", "unknown", "none", "yes",
                      "btc", "ctc", "SVT", "TVA", "NS",        // codes under 4 characters, as in MA, TN, NC
                      "bctc", "mrwa",                          // short all-lowercase codes
                      "1234", "--", "#3"])                     // no letters
    func notDescriptiveOperator(value: String) {
        #expect(text(.maintainedBy, [section(1, tags: ["operator": value])]) == nil)
    }

    @Test("Real operator values: MA's btc and ctc rows show nothing, a long agency name stays")
    func realOperatorRows() {
        // tags_json of ma-v1 rows, verbatim.
        let btc = TrailFeature.tags(fromJSON: #"{"bridged_gaps":1,"foot":"yes","highway":"path","merged_ways":12,"operator":"btc","sac_scale":"hiking","surface":"dirt"}"#)
        let ctc = TrailFeature.tags(fromJSON: #"{"foot":"yes","highway":"path","merged_ways":2,"operator":"ctc"}"#)
        #expect(text(.maintainedBy, [section(1, tags: btc)]) == nil)
        #expect(text(.maintainedBy, [section(1, tags: ctc)]) == nil)
        #expect(text(.maintainedBy, [section(1, tags: ["operator": "Massachusetts Department of Conservation and Recreation"])])
                == "Massachusetts Department of Conservation and Recreation")
    }

    @Test("Values are read regardless of case and stray spaces")
    func normalizes() {
        #expect(text(.pathType, [section(1, difficulty: " Mountain_Hiking ")]) == "Rough mountain path")
        #expect(text(.wheelchair, [section(1, tags: ["wheelchair": "YES"])]) != nil)
    }

    @Test("Path type takes the harder of the difficulty column and the row's own sac_scale")
    func pathTypeFromBothSources() {
        #expect(text(.pathType, [section(1, difficulty: "hiking", tags: ["sac_scale": "mountain_hiking"])])
                == "Rough mountain path")
        #expect(text(.pathType, [section(1, difficulty: "mountain_hiking", tags: ["sac_scale": "hiking"])])
                == "Rough mountain path")
        #expect(text(.pathType, [section(1, tags: ["sac_scale": "hiking"])]) == "Walking path")
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

    @Test("Order, labels, icons and caption, written out (test-auditor: not read from the code under test)")
    func orderLabelsIconsCaption() {
        let row = section(1, difficulty: "hiking",
                          tags: ["operator": "Cary", "lit": "yes", "wheelchair": "yes",
                                 "trail_visibility": "good", "smoothness": "good"])
        let facts = TrailFacts.facts(for: item([row]))
        #expect(facts.map(\.kind) == [.pathType, .surface, .marking, .wheelchair, .lit, .maintainedBy])
        #expect(facts.map(\.label) == ["Path type", "Surface", "Marking", "Access", "Lighting", "Maintained by"])
        #expect(facts.map(\.symbol) == [.hiking, .trailSurface, .trailMarking, .wheelchair, .lit, .maintainer])
        #expect(TrailFacts.caption == "From the trail's map data, not a current report")

        let bike = section(2, tags: ["highway": "cycleway", "foot": "yes", "smoothness": "good"])
        let walking = TrailFacts.facts(for: item([bike]), activityMode: .walking)
        #expect(walking.map(\.kind) == [.sharedUse, .surface])
        #expect(walking.first?.label == "Shared use")
        #expect(walking.first?.symbol == .ride)
        #expect(TrailFacts.facts(for: item([bike]), activityMode: .cycling).first?.symbol == .walk)
    }

    @Test("Lit shows only on yes, not OSM's other lit values", arguments: [
        "automatic", "limited", "sunset-sunrise", "interval", "disused"
    ])
    func litOtherValues(value: String) {
        #expect(text(.lit, [section(1, tags: ["lit": value])]) == nil)
    }

    @Test("Padded values still count; an empty value is silence, not a yes")
    func paddedAndEmptyValues() {
        #expect(text(.lit, [section(1, tags: ["lit": " Yes "])]) == "Lit at night")
        #expect(text(.wheelchair, [section(1, tags: ["wheelchair": " designated"])]) != nil)
        #expect(text(.lit, [section(1, length: 800, tags: ["lit": "yes"]), section(2, length: 200, tags: ["lit": "  "])])
                == "Lit at night")
        #expect(text(.lit, [section(1, length: 500, tags: ["lit": "yes"]), section(2, length: 500, tags: ["lit": ""])])
                == nil)
    }

    @Test("A cut that lands on a space drops the space before the ellipsis")
    func cutOnSpace() {
        let name = String(repeating: "a", count: 58) + " " + String(repeating: "b", count: 10)
        #expect(text(.maintainedBy, [section(1, tags: ["operator": name])]) == String(repeating: "a", count: 58) + "…")
    }

    // MARK: Length-weighted rules (Joe, 2026-10-15)

    @Test("The thresholds are Joe's 80% and 25%")
    func thresholds() {
        #expect(TrailFacts.mostOfTrail == 0.8)
        #expect(TrailFacts.somePlaces == 0.25)
    }

    @Test("A good thing is bare at exactly 80% of the length, 'in places' just under")
    func goodAtEightyPercent() {
        let smooth = ["smoothness": "good"], marked = ["trail_visibility": "excellent"]
        #expect(text(.surface, [section(1, length: 800, tags: smooth), section(2, length: 200)]) == "Smooth")
        #expect(text(.surface, [section(1, length: 799, tags: smooth), section(2, length: 201)]) == "Smooth in places")
        #expect(text(.marking, [section(1, length: 800, tags: marked), section(2, length: 200)]) == "Well marked")
        #expect(text(.marking, [section(1, length: 799, tags: marked), section(2, length: 201)])
                == "Well marked in places")
    }

    @Test("A good thing shows 'in places' at exactly 25% and nothing just under")
    func goodAtTwentyFivePercent() {
        let smooth = ["smoothness": "excellent"]
        #expect(text(.surface, [section(1, length: 250, tags: smooth), section(2, length: 750)]) == "Smooth in places")
        #expect(text(.surface, [section(1, length: 249, tags: smooth), section(2, length: 751)]) == nil)
        let marked = ["trail_visibility": "good"]
        #expect(text(.marking, [section(1, length: 250, tags: marked), section(2, length: 750)])
                == "Well marked in places")
        #expect(text(.marking, [section(1, length: 249, tags: marked), section(2, length: 751)]) == nil)
    }

    @Test("A warning shows on any section; bare from 80% of the length, else 'in places'")
    func warnings() {
        let rough = ["smoothness": "bad"]
        #expect(text(.surface, [section(1, length: 800, tags: rough), section(2, length: 200)]) == "Rough")
        #expect(text(.surface, [section(1, length: 799, tags: rough), section(2, length: 201)]) == "Rough in places")
        #expect(text(.surface, [section(1, length: 10, tags: rough), section(2, length: 990)]) == "Rough in places",
                "a warning on 1% of the trail still shows")
        #expect(text(.surface, [section(1, length: 100, tags: ["smoothness": "intermediate"]), section(2, length: 900)])
                == "Uneven in places")
        #expect(text(.surface, [section(1, length: 100, tags: ["smoothness": "impassable"]), section(2, length: 900)])
                == "May be impassable in places")
        #expect(text(.marking, [section(1, length: 100, tags: ["trail_visibility": "no"]), section(2, length: 900)])
                == "Faint or unmarked in places")
        #expect(text(.marking, [section(1, length: 900, tags: ["trail_visibility": "bad"]), section(2, length: 100)])
                == "Faint or unmarked")
    }

    @Test("Smooth and rough sections together: the warning replaces the good word")
    func mixedSmoothAndRough() {
        let mixed = [section(1, length: 900, tags: ["smoothness": "excellent"]),
                     section(2, length: 100, tags: ["smoothness": "horrible"])]
        #expect(text(.surface, mixed) == "Rough in places")
        let marking = [section(1, length: 850, tags: ["trail_visibility": "excellent"]),
                       section(2, length: 150, tags: ["trail_visibility": "intermediate"])]
        #expect(text(.marking, marking) == "Faint or unmarked in places")
    }

    @Test("The worst warning wins, worded by how much of the length is at that grade")
    func worstWarningWins() {
        let sections = [section(1, length: 500, tags: ["smoothness": "intermediate"]),
                        section(2, length: 300, tags: ["smoothness": "bad"]),
                        section(3, length: 200, tags: ["smoothness": "impassable"])]
        #expect(text(.surface, sections) == "May be impassable in places")
        // Rough on 60% plus impassable on 20%: impassable, the worst grade,
        // covers 20%, so "in places" though rough-or-worse is 80%.
        #expect(text(.surface, [section(1, length: 600, tags: ["smoothness": "bad"]),
                                section(2, length: 200, tags: ["smoothness": "impassable"]),
                                section(3, length: 200, tags: ["smoothness": "good"])])
                == "May be impassable in places")
        #expect(text(.surface, [section(1, length: 500, tags: ["smoothness": "intermediate"]),
                                section(2, length: 300, tags: ["smoothness": "bad"]),
                                section(3, length: 200, tags: ["smoothness": "good"])])
                == "Rough in places")
    }

    @Test("Path type is the hardest grade; under 80% of the length it reads 'Includes …'")
    func pathTypeByLength() {
        let hard = section(1, difficulty: "mountain_hiking", length: 800)
        let easy = section(2, difficulty: "hiking", length: 200)
        #expect(text(.pathType, [hard, easy]) == "Rough mountain path")
        #expect(text(.pathType, [section(1, difficulty: "mountain_hiking", length: 799),
                                 section(2, difficulty: "hiking", length: 201)]) == "Includes rough mountain path")
        #expect(text(.pathType, [section(1, difficulty: "demanding_mountain_hiking", length: 100), section(2, length: 900)])
                == "Includes steep, demanding path")
        #expect(text(.pathType, [section(1, difficulty: "alpine_hiking", length: 100), section(2, length: 900)])
                == "Includes alpine route, for experienced hikers")
        #expect(text(.pathType, [section(1, difficulty: "hiking", length: 250), section(2, length: 750)])
                == "Walking path in places")
        #expect(text(.pathType, [section(1, difficulty: "hiking", length: 249), section(2, length: 751)]) == nil,
                "the easiest grade, like a good thing, needs 25% (critic run 3)")
    }

    @Test("Wheelchair and lit need sections covering 80% of the length to say yes")
    func positiveClaimsByLength() {
        #expect(text(.wheelchair, [section(1, length: 800, tags: ["wheelchair": "yes"]),
                                   section(2, length: 200)]) != nil, "80% yes, the rest silent")
        #expect(text(.wheelchair, [section(1, length: 900, tags: ["wheelchair": "yes"]),
                                   section(2, length: 100, tags: ["wheelchair": "no"])]) == nil,
                "an explicit no is never outvoted (critic run 3)")
        #expect(text(.wheelchair, [section(1, length: 900, tags: ["wheelchair": "designated"]),
                                   section(2, length: 100, tags: ["wheelchair": "limited"])]) == nil)
        #expect(text(.lit, [section(1, length: 950, tags: ["lit": "yes"]), section(2, length: 50, tags: ["lit": "no"])])
                == nil)
        #expect(text(.wheelchair, [section(1, length: 799, tags: ["wheelchair": "designated"]),
                                   section(2, length: 201)]) == nil, "silence counts against a claim")
        #expect(text(.lit, [section(1, length: 800, tags: ["lit": "yes"]), section(2, length: 200)]) == "Lit at night")
        #expect(text(.lit, [section(1, length: 799, tags: ["lit": "yes"]), section(2, length: 201, tags: ["lit": "yes "])])
                == "Lit at night", "both say yes: 100%")
        #expect(text(.lit, [section(1, length: 799, tags: ["lit": "yes"]), section(2, length: 201, tags: ["lit": "no"])])
                == nil)
    }

    @Test("Maintained by appears only when every section that names one names the same one")
    func maintainerAgreement() {
        #expect(text(.maintainedBy, [section(1, tags: ["operator": "Cary Parks"]), section(2),
                                     section(3, tags: ["operator": "cary parks"])]) == "Cary Parks")
        #expect(text(.maintainedBy, [section(1, tags: ["operator": "Nantahala Hiking Club"]),
                                     section(2, tags: ["operator": "Smoky Mountain Hiking Club"])]) == nil)
    }

    // MARK: Cycleways (Joe, 2026-10-15)

    private func cycleway(_ id: Int64, length: Double = 1_000, foot: String? = nil,
                          difficulty: String? = "hiking") -> TrailFeature {
        var tags = ["highway": "cycleway"]
        if let foot { tags["foot"] = foot }
        return section(id, difficulty: difficulty, length: length, tags: tags)
    }

    @Test("A cycleway shows no path type, and says who it is shared with from the foot tag, by mode",
          arguments: [(ActivityMode.walking, "Shared with cyclists"), (.running, "Shared with cyclists"),
                      (.cycling, "Shared with walkers")])
    func cyclewaySharedUse(mode: ActivityMode, expected: String) {
        for foot in ["yes", "designated"] {
            #expect(text(.pathType, [cycleway(1, foot: foot)], mode: mode) == nil)
            #expect(text(.sharedUse, [cycleway(1, foot: foot)], mode: mode) == expected)
        }
    }

    @Test("A cycleway with no foot tag, or another value, says nothing about walkers", arguments: [
        ActivityMode.walking, .cycling
    ])
    func cyclewayWithoutFoot(mode: ActivityMode) {
        for foot in [nil, "no", "permissive", "use_sidepath"] as [String?] {
            let facts = TrailFacts.facts(for: item([cycleway(1, foot: foot)]), activityMode: mode)
            #expect(facts.isEmpty, "foot=\(foot ?? "absent")")
        }
    }

    @Test("Shared use on a grouped cycleway needs 80% of the length to say so")
    func cyclewaySharedUseByLength() {
        #expect(text(.sharedUse, [cycleway(1, length: 800, foot: "designated"), cycleway(2, length: 200)])
                == "Shared with cyclists")
        #expect(text(.sharedUse, [cycleway(1, length: 799, foot: "designated"), cycleway(2, length: 201)]) == nil)
        #expect(text(.sharedUse, [cycleway(1, length: 900, foot: "designated"), cycleway(2, length: 100, foot: "no")])
                == nil, "foot=no on any section vetoes it")
    }

    @Test("A trail that is only partly cycleway keeps its path type")
    func partCyclewayKeepsPathType() {
        let sections = [cycleway(1, foot: "designated"), section(2, difficulty: "hiking", tags: ["highway": "path"])]
        #expect(text(.pathType, sections) == "Walking path")
        #expect(text(.sharedUse, sections) == nil)
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

    // The bundled pack carries fact shares since builder 1.6.0 (spec
    // feat/trail-facts-from-shares), so these read every way's facts by
    // length, not each row's first way. Expectations re-derived from the
    // rules on the rebuilt pack, 2026-10-15; the ones that changed say so.
    @Test("The bundled NC pack, read through the real source, under the length rules")
    func bundledPack() throws {
        let url = try #require(Bundle.main.url(forResource: "nc", withExtension: "wktpack"))
        let source = try BundledTrailSource(url: url)

        // Two sections that agree on everything.
        let strollway = try source.trails(key: "nc:w1424032424")
        #expect(strollway.count == 2)
        #expect(TrailFacts.facts(for: item(strollway)).map(\.text)
                == ["Smooth", "Well marked", "Mapped as wheelchair accessible", "Lit at night"])

        // Walnut Creek Trail, a cycleway: excellent smoothness under 25% of
        // 14.5 km, so no surface line. Walkers are designated on nearly all
        // of it, but one way (54 m of row w130332179) says foot=destination,
        // and a positive claim yields to any stretch saying otherwise: no
        // "Shared with cyclists" (it showed from the flat tags before 1.6.0).
        let walnut = try source.trails(key: "nc:w130332179")
        #expect(walnut.count == 16)
        #expect(TrailFacts.facts(for: item(walnut)).isEmpty)

        // Lower Piney Trail: the column says hiking, the row's sac_scale says
        // mountain_hiking (two merged ways). The shares say mountain_hiking
        // on 12% of it: "Includes …" (was "Rough mountain path").
        let piney = try source.trails(key: "nc:w171710443")
        #expect(piney.first?.difficulty == "hiking")
        #expect(TrailFacts.facts(for: item(piney)).first { $0.kind == .pathType }?.text == "Includes rough mountain path")

        // Appalachian Trail, six sections, 143 km: mountain_hiking on part of
        // it, bad smoothness stated on some ways (was "Uneven in places" from
        // one row's flat intermediate), excellent marking on part, several
        // hiking clubs.
        let appalachian = try source.trails(key: "nc:w120342541")
        #expect(appalachian.count == 6)
        #expect(TrailFacts.facts(for: item(appalachian)).map(\.text)
                == ["Includes rough mountain path", "Rough in places", "Well marked in places"])

        // Thermal Belt Rail Trail: a cycleway with sac_scale=hiking and
        // foot=designated. No "Walking path" beside its Bike path chip.
        let thermal = try source.trails(key: "nc:w1033873881")
        #expect(TrailFacts.facts(for: item(thermal), activityMode: .walking).map(\.text)
                == ["Shared with cyclists", "Smooth", "Well marked", "Mapped as wheelchair accessible"])
        #expect(TrailFacts.facts(for: item(thermal), activityMode: .cycling).first?.text == "Shared with walkers")

        // Little Rock Trail: a cycleway whose longest row's first way has no
        // foot tag. Its other ways say designated or yes, over 80% of the
        // trail and nothing else stated: "Shared with cyclists" (was nothing).
        let littleRock = try source.trails(key: "nc:w1086215060")
        #expect(TrailFacts.facts(for: item(littleRock)).map(\.text) == ["Shared with cyclists"])

        // Tanawha Trail: wheelchair=designated on 84% of 20 km of mountain
        // path, wheelchair=no on the rest. Never "accessible" (critic run 3).
        let tanawha = try source.trails(key: "nc:w1075221863")
        #expect(!tanawha.isEmpty)
        #expect(TrailFacts.facts(for: item(tanawha)).contains { $0.kind == .wheelchair } == false)

        // Bolin Creek Trail: lit=yes on 88%, lit=no on three sections.
        let bolin = try source.trails(key: "nc:w1197735362")
        #expect(!bolin.isEmpty)
        #expect(TrailFacts.facts(for: item(bolin)).contains { $0.kind == .lit } == false)
    }

    @Test("Every fact's icon exists in SF Symbols")
    func symbolsExist() {
        for symbol in [WktSymbol.hiking, .trailSurface, .trailMarking, .wheelchair, .lit, .maintainer, .walk, .ride] {
            #expect(UIImage(systemName: symbol.name) != nil, "\(symbol.name)")
        }
    }
}
