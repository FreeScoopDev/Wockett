import Foundation

// MARK: - Trail facts
//
// What the map data states about a trail beyond its length and tags: how hard
// the path is (`sac_scale`, the pack's `difficulty` column), how smooth it is,
// how well it is marked, wheelchair access, lighting, who maintains it and, on
// a cycleway, whether walkers share it (`tags_json`). The trail detail shows
// them in one card (spec feat/trail-detail-facts, confirmed by Joe 2026-10-15).
//
// Every fact is shown only when the data states it. Most trails state none of
// these, and that is correct: a hidden fact is better than a guessed one.
// Nothing here derives a difficulty from length, and nothing describes a
// current condition.
//
// A grouped trail is several pack rows (sections). Joe's rules (2026-10-15)
// weigh each section by its length in the trail:
// - A warning (rough, uneven, impassable, faint) shows when any section states
//   it; the worst one stated wins, bare when the sections at that grade cover
//   `mostOfTrail` of the length, otherwise "… in places".
// - A good thing (smooth, well marked) is bare only over `mostOfTrail`,
//   "… in places" from `somePlaces`, and not shown below that. A warning on
//   any section replaces it.
// - Path type is the hardest grade any section states; under `mostOfTrail`
//   it reads "Includes …".
// - Wheelchair, lighting and a cycleway's shared use are positive claims: shown
//   only when sections covering `mostOfTrail` say so and none says otherwise.
//   For shared use, foot=destination or permissive is not "otherwise" (Joe,
//   2026-10-15); foot=no and foot=private are.
// - Intermediate smoothness and marking always read "… in places"; the
//   easiest path grade, like a good thing, needs `somePlaces`.
// - The maintainer shows only when every section that names one agrees.
//
// Since pack builder 1.6.0 a section is often several OSM ways, and its flat
// tags are one way's. Where every section of the trail carries the builder's
// fact shares (`TrailFactShares`), the rules above run on how much of each
// section states each value instead, so "section" above reads "stretch the
// map data describes" (spec feat/trail-facts-from-shares, 2026-10-15). Where
// any section cannot say (a pack built before 1.6.0, unreadable shares), that
// fact keeps the per-section rule for the whole trail: a missing share is
// never read as "unstated".

enum TrailFacts {

    // MARK: Thresholds (Joe, 2026-10-15)

    /// Share of a trail's length that makes a fact true of the trail as a whole.
    static let mostOfTrail = 0.8
    /// Share below which a good thing is not shown at all.
    static let somePlaces = 0.25

    enum Kind: CaseIterable {
        case pathType
        case sharedUse
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

    // MARK: Wording, in one place so it is easy to change

    enum Wording {
        static let caption = "From the trail's map data, not a current report"

        /// Path type by grade (see `pathTypeRank`): bare, and when the
        /// hardest grade covers less than `mostOfTrail`.
        static func pathType(rank: Int, throughout: Bool) -> String {
            switch (rank, throughout) {
            case (...1, true): return "Walking path"
            case (...1, false): return "Walking path in places"
            case (2, true): return "Rough mountain path"
            case (2, false): return "Includes rough mountain path"
            case (3, true): return "Steep, demanding path"
            case (3, false): return "Includes steep, demanding path"
            case (_, true): return "Alpine route, experienced hikers"
            case (_, false): return "Includes alpine route, for experienced hikers"
            }
        }

        static let smooth = "Smooth"
        static let uneven = "Uneven"
        static let rough = "Rough"
        static let impassable = "May be impassable"
        static let wellMarked = "Well marked"
        static let faint = "Faint or unmarked"
        static let inPlaces = " in places"

        static let wheelchair = "Mapped as wheelchair accessible"
        static let lit = "Lit at night"
        /// On a cycleway, from the walker's side and from the rider's.
        static let sharedWithCyclists = "Shared with cyclists"
        static let sharedWithWalkers = "Shared with walkers"
    }

    static var caption: String { Wording.caption }

    /// A maintainer's name longer than this is cut, with an ellipsis inside
    /// the limit (Joe, 2026-10-15).
    static let maintainerLimit = 60

    /// One section's say on a fact: its value and its length in the trail.
    typealias Stated = (value: String?, meters: Double)

    /// Every fact the data states about `item`, in display order, as seen in
    /// `activityMode`. Empty when it states none, and the detail then shows no
    /// card at all.
    static func facts(for item: TrailListItem, activityMode: ActivityMode = .walking) -> [Fact] {
        let tags = item.sections.map(\.tags)
        let meters = item.sections.map(\.lengthMeters)
        let shares = item.sections.map(\.factShares)
        /// Every section's stretches for `key` from its fact shares, or nil
        /// when any section cannot say (the per-section rule then decides).
        func fromShares(_ key: String) -> [Stated]? {
            var stretches: [Stated] = []
            for (section, reading) in zip(item.sections, shares) {
                guard let pieces = TrailFactShares.pieces(of: key, reading: reading, lengthMeters: section.lengthMeters,
                                                          packStatesShares: section.packHasFactShares == true)
                else { return nil }
                stretches += pieces
            }
            return stretches
        }
        func stated(_ key: String) -> [Stated] {
            fromShares(key) ?? zip(tags.map { $0[key] }, meters).map { ($0, $1) }
        }

        var facts: [Fact] = []
        if item.isBikePath {
            // A cycleway's grade is the walker's scale and read as "no bikes"
            // beside the Bike path chip (Joe, 2026-10-15): say who shares it.
            if let text = sharedUse(stated("foot"), activityMode: activityMode) {
                facts.append(Fact(kind: .sharedUse, label: "Shared use", text: text,
                                  symbol: activityMode == .cycling ? .walk : .ride))
            }
        } else {
            // The shares when every section has them: they say how much of
            // the trail is at each grade. Otherwise both the column and the
            // row's own sac_scale: the pack builder fills `difficulty` with the
            // majority grade of the ways it merged into one row, and
            // `tags_json` with the first way's tags, so either can be the
            // harder one (critic run 1: Lower Piney Trail).
            let grades: [Stated] = fromShares("sac_scale") ?? item.sections.indices.map { i in
                (harder(item.sections[i].difficulty, tags[i]["sac_scale"]), meters[i])
            }
            if let text = pathType(grades) {
                facts.append(Fact(kind: .pathType, label: "Path type", text: text, symbol: .hiking))
            }
        }
        if let text = surface(stated("smoothness")) {
            facts.append(Fact(kind: .surface, label: "Surface", text: text, symbol: .trailSurface))
        }
        if let text = marking(stated("trail_visibility")) {
            facts.append(Fact(kind: .marking, label: "Marking", text: text, symbol: .trailMarking))
        }
        if let text = wheelchair(stated("wheelchair")) {
            facts.append(Fact(kind: .wheelchair, label: "Access", text: text, symbol: .wheelchair))
        }
        if let text = lit(stated("lit")) {
            facts.append(Fact(kind: .lit, label: "Lighting", text: text, symbol: .lit))
        }
        let operators = fromShares("operator").map { $0.map(\.value) } ?? tags.map { $0["operator"] }
        if let text = maintainer(operators) {
            facts.append(Fact(kind: .maintainedBy, label: "Maintained by", text: text, symbol: .maintainer))
        }
        return facts
    }

    // MARK: Length shares

    /// The share of the trail's length whose value passes `test`. Sections of
    /// no length (a test row) count equally rather than dividing by zero.
    static func share(_ sections: [Stated], where test: (String) -> Bool) -> Double {
        let total = sections.reduce(0) { $0 + max(0, $1.meters) }
        guard !sections.isEmpty else { return 0 }
        if total <= 0 {
            return Double(sections.filter { normalized($0.value).map(test) ?? false }.count) / Double(sections.count)
        }
        let hit = sections.reduce(0) { $0 + (normalized($1.value).map(test) ?? false ? max(0, $1.meters) : 0) }
        return hit / total
    }

    // MARK: Path type

    /// OSM `sac_scale`, easiest first. `strolling` (a newer, easier grade)
    /// reads as a walking path (Joe, 2026-10-15). Values past `alpine_hiking`
    /// are rarer grades of the same thing and read the same.
    static let pathTypeRank: [String: Int] = [
        "strolling": 1, "hiking": 1, "mountain_hiking": 2, "demanding_mountain_hiking": 3,
        "alpine_hiking": 4, "demanding_alpine_hiking": 5, "difficult_alpine_hiking": 6
    ]

    /// The harder of two `sac_scale` values, or whichever is known.
    private static func harder(_ a: String?, _ b: String?) -> String? {
        let ra = normalized(a).flatMap { pathTypeRank[$0] } ?? 0
        let rb = normalized(b).flatMap { pathTypeRank[$0] } ?? 0
        if ra == 0 && rb == 0 { return nil }
        return ra >= rb ? normalized(a) : normalized(b)
    }

    /// The hardest grade any section states; "Includes …" when that grade
    /// covers less than `mostOfTrail` of the length.
    static func pathType(_ sections: [Stated]) -> String? {
        guard let hardest = sections.compactMap({ normalized($0.value).flatMap { pathTypeRank[$0] } }).max()
        else { return nil }
        let covered = share(sections) { (pathTypeRank[$0] ?? 0) >= hardest }
        // The easiest grade is a good thing, not a warning: like "Smooth", it
        // needs `somePlaces` (critic run 3: one hiking section in sixteen
        // read "Walking path in places").
        if hardest <= 1 && covered < somePlaces { return nil }
        return Wording.pathType(rank: hardest, throughout: covered >= mostOfTrail)
    }

    // MARK: Graded facts: a warning anywhere, a good thing over most of it

    /// OSM `smoothness`, smoothest first. `very_horrible` sits between
    /// `horrible` and `impassable` on OSM's scale and reads "Rough".
    static let smoothnessRank: [String: Int] = [
        "excellent": 1, "good": 1, "intermediate": 2, "bad": 3, "very_bad": 3,
        "horrible": 3, "very_horrible": 3, "impassable": 4
    ]

    static func surface(_ sections: [Stated]) -> String? {
        graded(sections, ranks: smoothnessRank, good: Wording.smooth,
               warnings: [2: Wording.uneven, 3: Wording.rough, 4: Wording.impassable], partialOnly: [2])
    }

    /// `intermediate` is OSM's "mostly visible, sometimes need for
    /// orientation", milder than bad, horrible or no.
    static let visibilityRank: [String: Int] = [
        "excellent": 1, "good": 1, "intermediate": 2, "bad": 3, "horrible": 3, "no": 3
    ]

    static func marking(_ sections: [Stated]) -> String? {
        graded(sections, ranks: visibilityRank, good: Wording.wellMarked,
               warnings: [2: Wording.faint, 3: Wording.faint], partialOnly: [2])
    }

    /// Rank 1 is the good value; higher ranks are warnings. The worst warning
    /// any section states wins, bare when it covers `mostOfTrail`; a grade
    /// in `partialOnly` (intermediate, "uneven in places" by its own OSM
    /// meaning) always reads "in places" (critic run 3).
    /// With no warning, the good value is bare over `mostOfTrail`, "in places"
    /// from `somePlaces`, and nothing below. A value the table does not know
    /// adds nothing.
    private static func graded(_ sections: [Stated], ranks: [String: Int], good: String,
                               warnings: [Int: String], partialOnly: Set<Int> = []) -> String? {
        let known = sections.compactMap { normalized($0.value).flatMap { ranks[$0] } }
        guard let worst = known.max() else { return nil }
        if worst > 1, let word = warnings[worst] {
            let covered = share(sections) { ranks[$0] == worst }
            return covered >= mostOfTrail && !partialOnly.contains(worst) ? word : word + Wording.inPlaces
        }
        let covered = share(sections) { ranks[$0] == 1 }
        if covered >= mostOfTrail { return good }
        if covered >= somePlaces { return good + Wording.inPlaces }
        return nil
    }

    // MARK: Positive claims: most of the trail must say so

    /// "Mapped as wheelchair accessible" when sections covering `mostOfTrail`
    /// say `yes` or `designated` (a stronger yes) and none says otherwise.
    static func wheelchair(_ sections: [Stated]) -> String? {
        claimed(sections, accepting: ["yes", "designated"]) ? Wording.wheelchair : nil
    }

    /// "Lit at night" when sections covering `mostOfTrail` say `lit=yes` and
    /// none says otherwise.
    static func lit(_ sections: [Stated]) -> String? {
        claimed(sections, accepting: ["yes"]) ? Wording.lit : nil
    }

    /// On a cycleway: who else uses it, from the `foot` tag, under the same
    /// rule. No tag, or anything else, says nothing about walkers.
    static func sharedUse(_ sections: [Stated], activityMode: ActivityMode) -> String? {
        guard claimed(sections, accepting: ["yes", "designated"], neutral: footNeutral) else { return nil }
        return activityMode == .cycling ? Wording.sharedWithWalkers : Wording.sharedWithCyclists
    }

    /// `foot` values that let walkers on with a condition: neither a yes
    /// toward the 80% nor a "says otherwise" that vetoes the shared-use line
    /// (Joe, 2026-10-15: Walnut Creek Trail lost it over 54 m of
    /// foot=destination). `no`, `private` and anything else still veto.
    static let footNeutral: Set<String> = ["destination", "permissive"]

    /// A positive claim needs sections covering `mostOfTrail` to make it, and
    /// no section to state anything else: 80% is a floor, not a vote that
    /// outweighs an explicit "no" (critic run 3: Tanawha Trail, wheelchair
    /// designated on 84% and no on the rest). A `neutral` value neither
    /// makes the claim nor vetoes it.
    private static func claimed(_ sections: [Stated], accepting: Set<String>, neutral: Set<String> = []) -> Bool {
        let contradicted = sections.contains {
            normalized($0.value).map { !accepting.contains($0) && !neutral.contains($0) } ?? false
        }
        return !contradicted && share(sections, where: accepting.contains) >= mostOfTrail
    }

    // MARK: Maintainer

    /// The `operator` text, on one line and cut to `maintainerLimit`, when
    /// every section that states one names the same maintainer, and the name
    /// says something (`isDescriptive`).
    static func maintainer(_ values: [String?]) -> String? {
        let names = values.compactMap { value -> String? in
            guard let value else { return nil }
            let line = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return line.isEmpty ? nil : line
        }
        guard let first = names.first,
              names.allSatisfy({ $0.caseInsensitiveCompare(first) == .orderedSame }),
              isDescriptive(first) else { return nil }
        guard first.count > maintainerLimit else { return first }
        let cut = first.prefix(maintainerLimit - 1).trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }

    /// `operator` values in the published packs that are not a maintainer's
    /// name: an access value or a placeholder (`private` 45 rows in North
    /// Carolina, `no` 9 and `unknown` 1 elsewhere, 2026-10-15).
    static let notNames: Set<String> = ["private", "no", "none", "unknown", "yes"]

    /// Whether an operator value tells a reader who maintains the trail (Joe,
    /// 2026-10-15): not a placeholder, at least 4 characters ("btc", "TVA"
    /// are codes), not a short all-lowercase code ("bctc"), and not only
    /// digits and punctuation.
    static func isDescriptive(_ name: String) -> Bool {
        let lower = name.lowercased()
        if notNames.contains(lower) { return false }
        if name.count < 4 { return false }
        if !name.contains(where: \.isLetter) { return false }
        let isShortLowercaseCode = name.count <= 5 && !name.contains(" ")
            && name.allSatisfy { $0.isLowercase || $0.isNumber }
        return !isShortLowercaseCode
    }

    /// Lowercased and trimmed; empty is not a value.
    static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        return value
    }
}
