import Foundation

// MARK: - Trail facts
//
// What the map data states about a trail beyond its length and tags: how hard
// the path is (`sac_scale`, the pack's `difficulty` column), how smooth it is,
// how well it is marked, wheelchair access, lighting and who maintains it
// (`tags_json`). The trail detail shows them in one card (spec
// feat/trail-detail-facts, confirmed by Joe 2026-10-15).
//
// Every fact is shown only when the data states it. Most trails state none of
// these (13-15% of North Carolina's rows carry each of the commonest), and
// that is correct: a hidden fact is better than a guessed one. Nothing here
// derives a difficulty from length, and nothing describes a current condition.
//
// A grouped trail is several pack rows. Where they disagree the cautious value
// wins, as the dog rule takes the strictest: the hardest path type, the
// roughest surface, the faintest marking. Wheelchair, lighting and maintainer
// are claims, not grades, so they appear only when every section that states
// one agrees.

enum TrailFacts {

    enum Kind: CaseIterable {
        case pathType
        case surface
        case marking
        case wheelchair
        case lit
        case maintainedBy
    }

    struct Fact: Hashable {
        let kind: Kind
        /// What the fact is about: "Surface".
        let label: String
        /// What the data says: "Uneven in places".
        let text: String
        let symbol: WktSymbol
    }

    /// Under the card, so a stated fact is never read as a live condition.
    static let caption = "From the trail's map data, not a current report"

    /// A maintainer's name longer than this is cut, with an ellipsis inside
    /// the limit (Joe, 2026-10-15).
    static let maintainerLimit = 60

    /// Every fact the data states about `item`, in display order. Empty when
    /// it states none, and the detail then shows no card at all.
    static func facts(for item: TrailListItem) -> [Fact] {
        let tags = item.sections.map(\.tags)
        var facts: [Fact] = []
        // Both the column and the row's own sac_scale: the pack builder fills
        // `difficulty` with the majority grade of the ways it merged into one
        // row, and `tags_json` with the first way's tags, so either can be the
        // harder one (critic run 1: Lower Piney Trail's column says hiking, its
        // tags mountain_hiking).
        if let text = pathType(item.sections.map(\.difficulty) + tags.map { $0["sac_scale"] }) {
            facts.append(Fact(kind: .pathType, label: "Path type", text: text, symbol: .hiking))
        }
        if let text = surface(tags.map { $0["smoothness"] }) {
            facts.append(Fact(kind: .surface, label: "Surface", text: text, symbol: .trailSurface))
        }
        if let text = marking(tags.map { $0["trail_visibility"] }) {
            facts.append(Fact(kind: .marking, label: "Marking", text: text, symbol: .trailMarking))
        }
        if let text = wheelchair(tags.map { $0["wheelchair"] }) {
            facts.append(Fact(kind: .wheelchair, label: "Access", text: text, symbol: .wheelchair))
        }
        if let text = lit(tags.map { $0["lit"] }) {
            facts.append(Fact(kind: .lit, label: "Lighting", text: text, symbol: .lit))
        }
        if let text = maintainer(tags.map { $0["operator"] }) {
            facts.append(Fact(kind: .maintainedBy, label: "Maintained by", text: text, symbol: .maintainer))
        }
        return facts
    }

    // MARK: Graded facts: the cautious value wins

    /// OSM `sac_scale`, easiest first. Values past `alpine_hiking` are rarer
    /// grades of the same thing and read the same.
    private static let pathTypeRank: [String: Int] = [
        "hiking": 1, "mountain_hiking": 2, "demanding_mountain_hiking": 3,
        "alpine_hiking": 4, "demanding_alpine_hiking": 5, "difficult_alpine_hiking": 6
    ]

    /// The hardest `sac_scale` any section states, in words.
    static func pathType(_ values: [String?]) -> String? {
        guard let rank = hardest(values, ranks: pathTypeRank) else { return nil }
        switch rank {
        case 1: return "Walking path"
        case 2: return "Rough mountain path"
        case 3: return "Steep, demanding path"
        default: return "Alpine route, experienced hikers"
        }
    }

    /// OSM `smoothness`, smoothest first. `very_horrible` is not in the spec's
    /// list; it sits between `horrible` and `impassable` on OSM's scale, so
    /// it reads "Rough", as `horrible` does.
    private static let smoothnessRank: [String: Int] = [
        "excellent": 1, "good": 2, "intermediate": 3, "bad": 4, "very_bad": 5,
        "horrible": 6, "very_horrible": 7, "impassable": 8
    ]

    /// The roughest `smoothness` any section states, in words.
    static func surface(_ values: [String?]) -> String? {
        guard let rank = hardest(values, ranks: smoothnessRank) else { return nil }
        switch rank {
        case ...2: return "Smooth"
        case 3: return "Uneven in places"
        case 4...7: return "Rough"
        default: return "May be impassable"
        }
    }

    private static let visibilityRank: [String: Int] = [
        "excellent": 1, "good": 1, "intermediate": 2, "bad": 2, "horrible": 2, "no": 2
    ]

    /// The faintest `trail_visibility` any section states, in words.
    static func marking(_ values: [String?]) -> String? {
        guard let rank = hardest(values, ranks: visibilityRank) else { return nil }
        return rank == 1 ? "Well marked" : "Faint or unmarked in places"
    }

    /// The highest rank among the values this table knows. A value it does
    /// not know adds nothing; it neither shows nor hides a fact.
    private static func hardest(_ values: [String?], ranks: [String: Int]) -> Int? {
        values.compactMap { normalized($0).flatMap { ranks[$0] } }.max()
    }

    // MARK: Claims: every section that states one must agree

    /// "Mapped as wheelchair accessible" only when every section that states
    /// `wheelchair` says `yes` or `designated` (a stronger yes). `no`,
    /// `limited` or anything else on any section shows nothing (Joe,
    /// 2026-10-15: post it only when the trail says yes).
    static func wheelchair(_ values: [String?]) -> String? {
        agreed(values, accepting: ["yes", "designated"]) ? "Mapped as wheelchair accessible" : nil
    }

    /// "Lit at night" only when every section that states `lit` says `yes`.
    static func lit(_ values: [String?]) -> String? {
        agreed(values, accepting: ["yes"]) ? "Lit at night" : nil
    }

    private static func agreed(_ values: [String?], accepting: Set<String>) -> Bool {
        let stated = values.compactMap(normalized)
        return !stated.isEmpty && stated.allSatisfy(accepting.contains)
    }

    /// The `operator` text, on one line and cut to `maintainerLimit`, when
    /// every section that states one names the same maintainer. Some rows
    /// carry a word that is not a name (`notNames`), so they show nothing
    /// rather than "Maintained by private".
    static func maintainer(_ values: [String?]) -> String? {
        let names = values.compactMap { value -> String? in
            guard let value else { return nil }
            let line = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return line.isEmpty ? nil : line
        }
        guard let first = names.first,
              names.allSatisfy({ $0.caseInsensitiveCompare(first) == .orderedSame }),
              !notNames.contains(first.lowercased()) else { return nil }
        guard first.count > maintainerLimit else { return first }
        let cut = first.prefix(maintainerLimit - 1).trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }

    /// `operator` values in the published packs that are not a maintainer's
    /// name: an access value or a placeholder (2026-10-15: `private` 45 rows
    /// in North Carolina, `no` 9 and `unknown` 1 elsewhere).
    static let notNames: Set<String> = ["private", "no", "none", "unknown", "yes"]

    /// Lowercased and trimmed; empty is not a value.
    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        return value
    }
}
