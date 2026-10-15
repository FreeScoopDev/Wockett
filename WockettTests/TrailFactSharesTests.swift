import Testing
import Foundation
@testable import PoCSquat

/// The Trail facts card reading the pack builder's fact shares (spec
/// feat/trail-facts-from-shares): how much of the WHOLE trail states each
/// value, instead of one OSM way's flat tags per section. Joe's rules and
/// thresholds are unchanged; `TrailFactsTests` covers them. Expected wording
/// below is worked out from those rules in the comments, not read from the
/// code under test.
@MainActor
struct TrailFactSharesTests {

    // MARK: Helpers

    /// A pack row with `tags_json` exactly `json`, from a pack whose meta does
    /// (`packShares: true`) or does not (nil, an older pack) say `fact_shares=1`.
    private func row(_ id: Int64, length: Double, difficulty: String? = nil, json: String?,
                     packShares: Bool? = true, key: String? = nil) -> TrailFeature {
        TrailFeature(id: id, sourceID: "osm", sourceRef: "w\(id)", name: "Test Trail",
                     encodedPolyline: "", pointCount: 0, lengthMeters: length,
                     bounds: TrailBounds(minLatitude: 35.78, minLongitude: -78.64,
                                         maxLatitude: 35.782, maxLongitude: -78.638),
                     surface: nil, difficulty: difficulty,
                     dogAccess: .unknown, dogAccessProvenance: .default,
                     allowsFoot: true, allowsBike: false, allowsHorse: false, isLoop: false,
                     tagsJSON: json, trailKey: key, packHasFactShares: packShares)
    }

    private func texts(_ sections: [TrailFeature], mode: ActivityMode = .walking) -> [String] {
        TrailFacts.facts(for: TrailListItem(id: "t1", name: "Test Trail", sections: sections, distanceMeters: 0),
                         activityMode: mode).map(\.text)
    }

    private func surface(_ sections: [TrailFeature]) -> String? {
        TrailFacts.facts(for: TrailListItem(id: "t1", name: "Test Trail", sections: sections, distanceMeters: 0))
            .first { $0.kind == .surface }?.text
    }

    /// `tags_json` with `flat` tags and, when given, smoothness shares.
    private func smoothJSON(flat: String? = nil, shares: String? = nil) -> String {
        var parts: [String] = []
        if let shares { parts.append(#""facts":{"shares":{"smoothness":{\#(shares)}},"v":1}"#) }
        parts.append(#""highway":"path""#)
        if let flat { parts.append(#""smoothness":"\#(flat)""#) }
        return "{" + parts.joined(separator: ",") + "}"
    }

    // MARK: 1. Tolerant decoding

    @Test("A well-formed facts object reads as its shares, unstated included")
    func decodesValid() throws {
        let reading = TrailFactShares.read(fromJSON: Self.lowerPiney)
        guard case .valid(let facts) = reading else { Issue.record("expected valid, got \(reading)"); return }
        #expect(facts.shares["sac_scale"] == ["hiking": 0.879, "mountain_hiking": 0.121])
        #expect(facts.shares["smoothness"] == ["bad": 1.0])
        #expect(facts.shares["operator"] == nil)
        let at = TrailFactShares.read(fromJSON: Self.appalachian)
        guard case .valid(let atFacts) = at else { Issue.record("expected valid, got \(at)"); return }
        #expect(atFacts.shares["sac_scale"]?["unstated"] == 0.001)
    }

    @Test("No facts object, no tags or empty tags: absent, not invalid", arguments: [
        nil, "", "  ", #"{"highway":"path","smoothness":"good"}"#, "{}"
    ] as [String?])
    func decodesAbsent(json: String?) {
        #expect(TrailFactShares.read(fromJSON: json) == .absent)
    }

    @Test("Anything not exactly format 1 with shares summing to 1 is invalid, never a crash", arguments: [
        "{not json",                                                            // unreadable tags_json
        #"["facts"]"#,                                                          // not an object
        #"{"facts":"lots"}"#,                                                   // facts not an object
        #"{"facts":{"shares":{"lit":{"yes":1.0}}}}"#,                           // no version
        #"{"facts":{"v":2,"shares":{"lit":{"yes":1.0}}}}"#,                     // another version
        #"{"facts":{"v":"1","shares":{"lit":{"yes":1.0}}}}"#,                   // version as text
        #"{"facts":{"v":true,"shares":{"lit":{"yes":1.0}}}}"#,                  // version as a boolean
        #"{"facts":{"v":1}}"#,                                                  // no shares
        #"{"facts":{"v":1,"shares":{}}}"#,                                      // empty shares
        #"{"facts":{"v":1,"shares":[0.5]}}"#,                                   // shares not an object
        #"{"facts":{"v":1,"shares":{"lit":{}}}}"#,                              // a tag with no values
        #"{"facts":{"v":1,"shares":{"lit":"yes"}}}"#,                           // a tag's values not an object
        #"{"facts":{"v":1,"shares":{"lit":{"yes":"1.0"}}}}"#,                   // a share as text
        #"{"facts":{"v":1,"shares":{"lit":{"yes":true}}}}"#,                    // a share as a boolean
        #"{"facts":{"v":1,"shares":{"lit":{"yes":0.9}}}}"#,                     // sums to 0.9
        #"{"facts":{"v":1,"shares":{"lit":{"yes":0.6,"no":0.5}}}}"#,            // sums to 1.1
        #"{"facts":{"v":1,"shares":{"lit":{"yes":1.0,"no":0.0}}}}"#,            // a zero share
        #"{"facts":{"v":1,"shares":{"lit":{"yes":1.2,"no":-0.2}}}}"#,           // outside 0...1, sums to 1
        #"{"facts":{"v":1,"shares":{"lit":{" ":1.0}}}}"#,                       // a blank value
        #"{"facts":{"v":1,"shares":{"lit":{"yes":1.0},"smoothness":{"good":0.5}}}}"#  // one bad tag spoils it
    ])
    func decodesInvalid(json: String) {
        #expect(TrailFactShares.read(fromJSON: json) == .invalid)
    }

    @Test("Shares may miss 1 by up to 0.005, not more", arguments: [
        ("0.496", true), ("0.504", true), ("0.494", false), ("0.506", false)
    ])
    func sumTolerance(other: String, valid: Bool) {
        // Two shares sum the same in either order: 0.5 + other is 0.996,
        // 1.004 (within 0.005 of 1) or 0.994, 1.006 (outside).
        let json = #"{"facts":{"v":1,"shares":{"smoothness":{"good":0.5,"bad":\#(other)}}}}"#
        #expect((TrailFactShares.read(fromJSON: json) != .invalid) == valid)
    }

    @Test("Invalid shares make no claim: the card falls back to the row's flat tags")
    func invalidSharesFallBack() {
        // Flat lit=yes on the whole row, as today's rule reads it; shares that
        // would say lit=no on 50% are malformed (sum 0.9) and ignored.
        let json = #"{"facts":{"v":1,"shares":{"lit":{"no":0.5,"yes":0.4}}},"lit":"yes"}"#
        #expect(texts([row(1, length: 1_000, json: json)]) == ["Lit at night"])
        // Version 2 likewise.
        let v2 = #"{"facts":{"v":2,"shares":{"lit":{"no":1.0}}},"lit":"yes"}"#
        #expect(texts([row(1, length: 1_000, json: v2)]) == ["Lit at night"])
    }

    // MARK: 2. Metres = share x length, summed over every section

    @Test("Each value's metres are its share times the section's length, added across sections")
    func sharesAreLengthWeighted() {
        // A: 1,000 m, excellent on 0.5 -> 500 m. B: 3,000 m, excellent on 1.0
        // -> 3,000 m. 3,500 / 4,000 = 0.875 >= 0.8: "Smooth".
        // (Averaging the two shares gives 0.75, "Smooth in places"; A alone
        // gives 0.5, "Smooth in places".)
        let a = row(1, length: 1_000, json: smoothJSON(flat: "excellent", shares: #""excellent":0.5,"unstated":0.5"#))
        let b = row(2, length: 3_000, json: smoothJSON(flat: "excellent", shares: #""excellent":1.0"#))
        #expect(surface([a, b]) == "Smooth")
        // The other way round: the long section is the half-stated one.
        // 1,000 + 1,500 = 2,500 / 4,000 = 0.625: "Smooth in places".
        let c = row(3, length: 1_000, json: smoothJSON(flat: "excellent", shares: #""excellent":1.0"#))
        let d = row(4, length: 3_000, json: smoothJSON(flat: "excellent", shares: #""excellent":0.5,"unstated":0.5"#))
        #expect(surface([c, d]) == "Smooth in places")
    }

    @Test("Thresholds apply to shares: a good thing bare at 80%, 'in places' from 25%")
    func thresholdsWithShares() {
        // One section, so the share IS the share of the trail.
        func one(_ shares: String) -> String? {
            surface([row(1, length: 1_000, json: smoothJSON(flat: "excellent", shares: shares))])
        }
        #expect(one(#""good":0.8,"unstated":0.2"#) == "Smooth")
        #expect(one(#""good":0.799,"unstated":0.201"#) == "Smooth in places")
        #expect(one(#""good":0.25,"unstated":0.75"#) == "Smooth in places")
        #expect(one(#""good":0.249,"unstated":0.751"#) == nil)
        // A warning: any share shows it; bare from 80%.
        #expect(one(#""bad":0.001,"good":0.999"#) == "Rough in places")
        #expect(one(#""bad":0.8,"unstated":0.2"#) == "Rough")
        #expect(one(#""bad":0.799,"unstated":0.201"#) == "Rough in places")
    }

    @Test("A tag the shares leave out is unstated on that whole section")
    func missingTagIsUnstated() {
        // A's shares say bad on all 1,000 m (its flat tag, one way's, says
        // good). B's shares say nothing about smoothness, so its 3,000 m are
        // unstated: bad on 1,000 / 4,000, "Rough in places". (Falling back to
        // the flat tags instead would read good on 0.25, "Smooth in places".)
        let a = row(1, length: 1_000, json: smoothJSON(flat: "good", shares: #""bad":1.0"#))
        let b = row(2, length: 3_000, json: #"{"facts":{"shares":{"foot":{"designated":1.0}},"v":1},"highway":"path"}"#)
        #expect(surface([a, b]) == "Rough in places")
    }

    @Test("A positive claim from shares is vetoed by any stretch stating otherwise")
    func vetoFromShares() {
        // lit=yes on 99.9%, lit=no on 0.1%: the floor is met, the veto holds.
        let json = #"{"facts":{"shares":{"lit":{"no":0.001,"yes":0.999}},"v":1},"lit":"yes"}"#
        #expect(texts([row(1, length: 1_000, json: json)]).contains("Lit at night") == false)
        let clean = #"{"facts":{"shares":{"lit":{"unstated":0.1,"yes":0.9}},"v":1},"lit":"yes"}"#
        #expect(texts([row(1, length: 1_000, json: clean)]) == ["Lit at night"])
    }

    @Test("Shared use from shares: foot=destination or permissive neither vetoes nor counts as yes; foot=no vetoes")
    func sharedUseConditionalFootFromShares() {
        func cycleway(_ foot: String) -> [String] {
            // Flat foot=designated everywhere: only the shares can say otherwise.
            texts([row(1, length: 1_000,
                       json: #"{"facts":{"shares":{"foot":{\#(foot)}},"v":1},"foot":"designated","highway":"cycleway"}"#)])
        }
        // Walnut Creek's shape: designated on nearly all, destination on a sliver.
        #expect(cycleway(#""designated":0.996,"destination":0.004"#) == ["Shared with cyclists"])
        #expect(cycleway(#""designated":0.9,"permissive":0.1"#) == ["Shared with cyclists"])
        // Under 80% yes/designated: the conditional part is not a yes.
        #expect(cycleway(#""designated":0.79,"destination":0.21"#).isEmpty)
        #expect(cycleway(#""permissive":1.0"#).isEmpty)
        // An explicit no, however short, still vetoes; so does private.
        #expect(cycleway(#""designated":0.996,"no":0.004"#).isEmpty)
        #expect(cycleway(#""designated":0.996,"private":0.004"#).isEmpty)
    }

    @Test("Maintainer from shares: one name everywhere stated shows, two names show nothing")
    func maintainerFromShares() {
        let one = #"{"facts":{"shares":{"operator":{"Town of Cary":0.6,"unstated":0.4}},"v":1},"operator":"Town of Cary"}"#
        #expect(texts([row(1, length: 1_000, json: one)]) == ["Town of Cary"])
        let two = #"{"facts":{"shares":{"operator":{"Town of Cary":0.999,"Wake County":0.001}},"v":1},"operator":"Town of Cary"}"#
        #expect(texts([row(1, length: 1_000, json: two)]).isEmpty)
        // One name in two casings agrees; the shown spelling is the first in
        // sorted order, the same on every run ("TOWN…" sorts before "Town…").
        let cased = #"{"facts":{"shares":{"operator":{"TOWN OF CARY":0.5,"Town of Cary":0.5}},"v":1}}"#
        #expect(texts([row(1, length: 1_000, json: cased)]) == ["TOWN OF CARY"])
    }

    // MARK: 2b. "All sections" is every row of the trail key

    @Test("A grouped list row carries every row of its trail key, and the facts read all of them")
    func groupedItemCarriesWholeTrail() throws {
        // The search reached only A (1,000 m, smooth throughout). The trail
        // key's other rows B and C (2,000 m each) state no smoothness.
        // Whole trail: 1,000 / 5,000 = 0.2 < 0.25, so no surface line. A
        // alone would say "Smooth".
        let a = row(1, length: 1_000, json: smoothJSON(flat: "excellent", shares: #""excellent":1.0"#), key: "nc:w1")
        let b = row(2, length: 2_000, json: #"{"facts":{"shares":{"foot":{"yes":1.0}},"v":1},"highway":"path"}"#,
                    key: "nc:w1")
        let c = row(3, length: 2_000, json: #"{"highway":"path"}"#, key: "nc:w1")
        let items = TrailListBuilder.items(from: [(a, 10)], grouped: true, wholeTrail: { _ in [a, b, c] })
        let item = try #require(items.first)
        #expect(item.sections.map(\.id) == [1, 2, 3])
        #expect(TrailFacts.facts(for: item).contains { $0.kind == .surface } == false)
        #expect(surface([a]) == "Smooth")
    }

    @Test("On the bundled pack, a search that reaches one Walnut Creek section lists all 16 of its rows")
    func groupedItemFromBundledPack() throws {
        let url = try #require(Bundle.main.url(forResource: "nc", withExtension: "wktpack"))
        let source = try BundledTrailSource(url: url)
        let near = try #require(try source.trail(sourceRef: "w275289168"))
        #expect(near.trailKey == "nc:w130332179")
        // The same closure shape TrailFinder passes (its library looks the
        // key up in the region's source).
        let items = TrailListBuilder.items(from: [(near, 0)], grouped: true, wholeTrail: { section in
            guard let key = section.trailKey else { return [] }
            return (try? source.trails(key: key)) ?? []
        })
        let item = try #require(items.first)
        #expect(item.sections.count == 16)
        #expect(Set(item.sections.map(\.sourceRef)).count == 16)
        #expect(TrailFacts.facts(for: item).map(\.text) == ["Shared with cyclists"],
                "as the bundledPack test reads the key directly")
    }

    // MARK: 4/5. Old packs, mixed trails, and "states nothing"

    @Test("A trail with one row from an older pack keeps the per-section rule for the whole trail")
    func mixedTrailFallsBack() {
        // A (new pack): flat smoothness=excellent, shares say excellent on
        // only 10%. B (older pack, no shares): flat smoothness=excellent.
        // Per-section rule: both flat tags excellent, 2,000 / 2,000: "Smooth".
        // (B read as unstated would give 100 / 2,000, nothing; A's shares
        // plus B's flat tag would give 1,100 / 2,000, "Smooth in places".)
        let a = row(1, length: 1_000, json: smoothJSON(flat: "excellent", shares: #""excellent":0.1,"unstated":0.9"#))
        let b = row(2, length: 1_000, json: smoothJSON(flat: "excellent"), packShares: nil)
        #expect(surface([a, b]) == "Smooth")
        #expect(surface([b, a]) == "Smooth", "order of sections does not matter")
        // The same with B's facts unreadable instead of absent.
        let broken = row(2, length: 1_000,
                         json: #"{"facts":{"v":1,"shares":{"smoothness":{"bad":0.5}}},"smoothness":"excellent"}"#)
        #expect(surface([a, broken]) == "Smooth")
        // Path type too: A's shares say mountain_hiking on 10%; the fallback
        // reads A's column (hiking) and B's sac_scale (hiking): "Walking path".
        let pa = row(5, length: 1_000, difficulty: "hiking",
                     json: #"{"facts":{"shares":{"sac_scale":{"hiking":0.9,"mountain_hiking":0.1}},"v":1},"highway":"path","sac_scale":"hiking"}"#)
        let pb = row(6, length: 1_000, json: #"{"highway":"path","sac_scale":"hiking"}"#, packShares: nil)
        #expect(texts([pa, pb]).first == "Walking path")
        #expect(texts([pa]).first == "Includes rough mountain path")
    }

    @Test("In a pack with fact_shares=1, a row without facts states none; in an older pack it falls back")
    func factSharesMetaDecides() {
        // A: 1,000 m, flat smoothness=excellent, shares excellent 0.3 and
        // bad 0.7. B: 3,000 m, no facts and no smoothness.
        // fact_shares=1: B is unstated. Worst stated is bad, 700 / 4,000:
        // "Rough in places".
        // Older pack: per-section rule, A's flat excellent 1,000 / 4,000 =
        // 0.25: "Smooth in places".
        let shares = #""bad":0.7,"excellent":0.3"#
        let newA = row(1, length: 1_000, json: smoothJSON(flat: "excellent", shares: shares), packShares: true)
        let newB = row(2, length: 3_000, json: #"{"highway":"path"}"#, packShares: true)
        #expect(surface([newA, newB]) == "Rough in places")
        let oldA = row(1, length: 1_000, json: smoothJSON(flat: "excellent", shares: shares), packShares: nil)
        let oldB = row(2, length: 3_000, json: #"{"highway":"path"}"#, packShares: nil)
        #expect(surface([oldA, oldB]) == "Smooth in places")
        let falseB = row(2, length: 3_000, json: #"{"highway":"path"}"#, packShares: false)
        #expect(surface([oldA, falseB]) == "Smooth in places")
    }

    @Test("A pack before 1.6.0 reads exactly as before: flat tags per section")
    func oldPackUnchanged() {
        // Same rows as `realShapedRows` in TrailFactsTests, from a pack
        // without shares.
        let json = #"{"bicycle":"no","foot":"designated","highway":"footway","horse":"no","merged_ways":7,"operator":"Nantahala Hiking Club","sac_scale":"mountain_hiking","smoothness":"intermediate","surface":"paving_stones","trail_visibility":"excellent","wheelchair":"limited"}"#
        #expect(texts([row(1, length: 27_544.2, difficulty: "mountain_hiking", json: json, packShares: nil)])
                == ["Rough mountain path", "Uneven in places", "Well marked", "Nantahala Hiking Club"])
    }

    @Test("A section of no length cannot weigh its shares: the per-section rule decides")
    func zeroLengthFallsBack() {
        let a = row(1, length: 0, json: smoothJSON(flat: "excellent", shares: #""excellent":0.1,"unstated":0.9"#))
        #expect(surface([a]) == "Smooth")
    }

    // MARK: 6. The #241 examples, as the rebuilt NC pack stores them

    // tags_json of NC rows w171710443, w120342541 and w1088975756 in the
    // bundled pack built by builder 1.6.0, verbatim.
    static let lowerPiney = #"{"bicycle":"no","dog":"leashed","facts":{"best":{"sac_scale":"hiking","smoothness":"bad","trail_visibility":"excellent"},"shares":{"foot":{"designated":1.0},"sac_scale":{"hiking":0.879,"mountain_hiking":0.121},"smoothness":{"bad":1.0},"trail_visibility":{"excellent":1.0},"wheelchair":{"no":1.0}},"v":1,"worst":{"sac_scale":"mountain_hiking","smoothness":"bad","trail_visibility":"excellent"}},"foot":"designated","highway":"path","horse":"no","merged_ways":2,"sac_scale":"mountain_hiking","smoothness":"bad","surface":"ground","trail_visibility":"excellent","wheelchair":"no"}"#
    static let appalachian = #"{"bicycle":"no","facts":{"best":{"sac_scale":"hiking","smoothness":"excellent","trail_visibility":"excellent"},"shares":{"foot":{"designated":1.0},"operator":{"Nantahala Hiking Club":0.001,"Smoky Mountain Hiking Club":0.999},"sac_scale":{"hiking":0.009,"mountain_hiking":0.99,"unstated":0.001},"smoothness":{"excellent":0.002,"unstated":0.998},"trail_visibility":{"excellent":0.999,"unstated":0.001},"wheelchair":{"limited":0.002,"no":0.001,"unstated":0.994,"yes":0.003}},"v":1,"worst":{"sac_scale":"mountain_hiking","smoothness":"excellent","trail_visibility":"excellent"}},"foot":"designated","highway":"footway","horse":"no","merged_ways":13,"operator":"Nantahala Hiking Club","sac_scale":"hiking","surface":"asphalt","trail_visibility":"excellent","wheelchair":"yes"}"#
    static let tobacco = #"{"bicycle":"designated","bridged_gaps":2,"facts":{"best":{"smoothness":"excellent"},"shares":{"foot":{"designated":0.994,"unstated":0.001,"yes":0.005},"lit":{"no":0.056,"unstated":0.926,"yes":0.018},"smoothness":{"excellent":0.02,"intermediate":0.046,"unstated":0.934}},"v":1,"worst":{"smoothness":"intermediate"}},"foot":"designated","highway":"cycleway","lit":"yes","merged_ways":44,"smoothness":"excellent","surface":"concrete"}"#

    /// The same row as an older pack stored it: identical but for `facts`.
    private func withoutFacts(_ json: String) throws -> String {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        object["facts"] = nil
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    @Test("Lower Piney Trail: hiking on 1,569 m, mountain_hiking on 216 m")
    func lowerPiney() throws {
        // sac_scale: hardest is mountain_hiking, 0.121 of 1,783 m < 0.8:
        // "Includes rough mountain path". smoothness bad on all of it:
        // "Rough". trail_visibility excellent on all: "Well marked".
        // wheelchair no: nothing. No operator.
        let new = row(1, length: 1_783.4, difficulty: "hiking", json: Self.lowerPiney)
        #expect(texts([new]) == ["Includes rough mountain path", "Rough", "Well marked"])
        // Before (no shares): the harder of the column (hiking) and the flat
        // tag (mountain_hiking) over the whole row.
        let old = row(1, length: 1_783.4, difficulty: "hiking", json: try withoutFacts(Self.lowerPiney), packShares: nil)
        #expect(texts([old]) == ["Rough mountain path", "Rough", "Well marked"])
    }

    @Test("Appalachian Trail row w120342541: flat sac_scale=hiking, which only 0.9% of its 21.8 km states")
    func appalachianRow() throws {
        // sac_scale: hardest mountain_hiking on 0.99 >= 0.8: "Rough mountain
        // path". smoothness excellent on 0.002 < 0.25: nothing. Marking
        // excellent on 0.999: "Well marked". wheelchair yes, limited and no
        // all stated: the veto holds, nothing. Two clubs: no maintainer.
        let new = row(1, length: 21_769.4, difficulty: "hiking", json: Self.appalachian)
        #expect(texts([new]) == ["Rough mountain path", "Well marked"])
        // Before: the first way's tags for all 21.8 km.
        let old = row(1, length: 21_769.4, difficulty: "hiking", json: try withoutFacts(Self.appalachian), packShares: nil)
        #expect(texts([old]) == ["Walking path", "Well marked", "Mapped as wheelchair accessible", "Nantahala Hiking Club"])
    }

    @Test("American Tobacco Trail row w1088975756: flat smoothness=excellent, which only 2% of its 24.6 km states")
    func tobaccoRow() throws {
        // A cycleway. foot designated or yes on 99.9%, nothing else stated:
        // "Shared with cyclists". smoothness: worst stated is intermediate
        // (4.6%), which always reads "in places": "Uneven in places". lit: no
        // on 5.6%, so never "Lit at night".
        let new = row(1, length: 24_605.4, json: Self.tobacco)
        #expect(texts([new]) == ["Shared with cyclists", "Uneven in places"])
        #expect(texts([new], mode: .cycling) == ["Shared with walkers", "Uneven in places"])
        let old = row(1, length: 24_605.4, json: try withoutFacts(Self.tobacco), packShares: nil)
        #expect(texts([old]) == ["Shared with cyclists", "Smooth", "Lit at night"])
    }

    @Test("The bundled pack says it carries fact shares, and every row's facts read as valid")
    func bundledPackMeta() throws {
        let url = try #require(Bundle.main.url(forResource: "nc", withExtension: "wktpack"))
        let source = try BundledTrailSource(url: url)
        #expect(source.hasFactShares)
        #expect(source.packInfo.builderVersion == "1.6.0")
        let piney = try source.trails(key: "nc:w171710443")
        #expect(piney.allSatisfy { $0.packHasFactShares == true })
        // Every row of a big box: valid shares or none, never unreadable.
        let rows = try source.trails(in: TrailBounds(minLatitude: 33, minLongitude: -85, maxLatitude: 37, maxLongitude: -75),
                                     limit: 10_000)
        #expect(rows.count == 6_354)
        #expect(rows.filter { $0.factShares == .invalid }.isEmpty)
        #expect(rows.filter { if case .valid = $0.factShares { true } else { false } }.count == 4_014)
    }
}
