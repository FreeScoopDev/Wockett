import Foundation

// MARK: - Fact shares
//
// Pack builder 1.6.0 (#241) writes, inside a row's `tags_json`, how much of
// the row's length states each value of the facts the Trail facts card shows:
//
//   "facts": {"v": 1,
//             "shares": {"sac_scale": {"hiking": 0.879, "mountain_hiking": 0.121}},
//             "worst": {"sac_scale": "mountain_hiking"}, "best": {"sac_scale": "hiking"}}
//
// Before, a row joined from several OSM ways kept the first way's tags, so a
// 21.8 km Appalachian Trail row said `sac_scale=hiking` because 0.9% of it
// did. A share times the row's `length_m` is metres, so `TrailFacts` can add
// up every section of a trail and word each fact from how much of the whole
// trail states it (spec feat/trail-facts-from-shares, Joe 2026-10-15).
//
// Per tag the shares sum to 1; the part no way states is "unstated". A tag no
// way states is left out, and a row stating none of them has no `facts`. In
// a pack whose meta says `fact_shares=1`, a row without `facts` therefore
// states none of these facts; in an older pack it only means the builder did
// not count, and the card keeps its per-section rule.
//
// Read tolerantly: anything that is not exactly this shape (another format
// version, a share outside 0...1, shares that do not add up to 1) is
// `.invalid`, which reads as "no shares" and never as a claim. `worst` and
// `best` are not read: the shares already say both.

struct TrailFactShares: Hashable {

    /// The `facts` format this build reads (the builder's `FACTS_FORMAT`).
    static let format = 1
    /// How far one tag's shares may miss 1 before they are refused. The
    /// builder writes thousandths that sum to exactly 1; this only absorbs
    /// floating-point addition.
    static let sumTolerance = 0.005
    /// The share of a row no way states a value for.
    static let unstated = "unstated"

    /// Tag → value → fraction of the row's length, `unstated` included.
    let shares: [String: [String: Double]]

    /// What a row's `facts` object amounts to.
    enum Reading: Hashable {
        /// The row carries no `facts`.
        case absent
        /// It carries one this build cannot trust: no shares.
        case invalid
        case valid(TrailFactShares)
    }

    /// Reads the `facts` object out of a row's `tags_json`.
    static func read(fromJSON json: String?) -> Reading {
        guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .absent }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .invalid }
        guard let raw = object["facts"] else { return .absent }
        guard let facts = raw as? [String: Any],
              let version = number(facts["v"]), version == Double(format),
              let rawShares = facts["shares"] as? [String: Any], !rawShares.isEmpty else { return .invalid }
        var shares: [String: [String: Double]] = [:]
        for (tag, rawValues) in rawShares {
            guard let values = rawValues as? [String: Any], !values.isEmpty else { return .invalid }
            var parsed: [String: Double] = [:]
            for (value, rawShare) in values {
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let share = number(rawShare), share.isFinite, share > 0, share <= 1 else { return .invalid }
                parsed[value] = share
            }
            guard abs(parsed.values.reduce(0, +) - 1) <= sumTolerance else { return .invalid }
            shares[tag] = parsed
        }
        return .valid(TrailFactShares(shares: shares))
    }

    /// A JSON number as a Double; a JSON `true`/`false` (which Foundation
    /// also hands over as an NSNumber) and anything else is nil.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// One row's say on `tag` as pieces of its length: each stated value with
    /// its metres, and nil for the unstated part. Nil when the row cannot say
    /// how much of it states the fact: an older pack (`packStatesShares`
    /// false and no `facts`), unreadable shares, or no usable length. A row
    /// with valid shares that leave `tag` out states it nowhere, and so does
    /// a row without `facts` in a pack that writes them wherever a row states
    /// one.
    static func pieces(of tag: String, reading: Reading, lengthMeters: Double,
                       packStatesShares: Bool) -> [(value: String?, meters: Double)]? {
        guard lengthMeters.isFinite, lengthMeters > 0 else { return nil }
        switch reading {
        case .valid(let facts):
            guard let values = facts.shares[tag] else { return [(nil, lengthMeters)] }
            return values.sorted { $0.key < $1.key }.map { value, share in
                (value == unstated ? nil : value, share * lengthMeters)
            }
        case .absent:
            return packStatesShares ? [(nil, lengthMeters)] : nil
        case .invalid:
            return nil
        }
    }
}

extension TrailFeature {
    /// The row's `facts` (pack builder 1.6.0), parsed on each call like
    /// `tags`: only the trail detail's facts card asks for it.
    var factShares: TrailFactShares.Reading { TrailFactShares.read(fromJSON: tagsJSON) }
}
