import CloudKit
import Foundation
import Observation
import OSLog

// MARK: - "Walkers say": published summaries of walker reports
//
// A `TrailFactSummary` is what Joe publishes from the staff dashboard once
// enough walkers agree on a trail and a fact: the trail key, the fact, the
// winning answer and how many walkers gave it (spec feat/trail-walker-reports,
// criteria 5 to 7). World-readable, and the only walker data a phone reads:
// never a `TrailFactReport`. The trail detail fetches them by trail key when
// it opens, keeps them for offline use, and asks again at most once a day.
// A summary Joe withdraws disappears at the next fetch. Keyed by trail key
// only: a trail re-keyed by a pack rebuild loses its summaries.

/// One published summary, as the app keeps it.
struct WalkerFactSummary: Codable, Equatable {
    let trailKey: String
    let fact: WalkerFact
    let value: String
    let walkers: Int
    let computedAt: Date?
}

/// One "Walkers say" line: "Dogs on leash (4 walkers)".
struct WalkerFactLine: Equatable, Identifiable {
    var id: WalkerFact { fact }
    let fact: WalkerFact
    let text: String
    var symbol: WktSymbol { fact.symbol }
}

enum TrailFactSummaries {
    static let recordType = "TrailFactSummary"
    /// The dashboard's `MIN_AGREEING` (docs/staff/logic.js), pinned by a
    /// test: a summary with fewer agreeing walkers was never published by
    /// the rule, so it is not shown.
    static let minimumWalkers = 3

    /// A summary record as the app uses it, or nil for anything it can't
    /// trust: no key, an unknown or unpublished fact, an unknown value, a
    /// walker count that is missing, not a whole number or under the rule.
    /// Only a Moderator can write one, but a newer dashboard may publish a
    /// fact or value this version doesn't know: it is skipped, not guessed.
    static func summary(from record: CKRecord) -> WalkerFactSummary? {
        guard record.recordType == recordType,
              let key = record["trailKey"] as? String, !key.isEmpty,
              let factRaw = record["fact"] as? String, let fact = WalkerFact(rawValue: factRaw), fact.publishes,
              let value = record["value"] as? String, fact.knows(value),
              let number = record["walkers"] as? NSNumber,
              number.doubleValue == number.doubleValue.rounded(),
              number.intValue >= minimumWalkers else { return nil }
        return WalkerFactSummary(trailKey: key, fact: fact, value: value, walkers: number.intValue,
                                 computedAt: record["computedAt"] as? Date)
    }

    static func lineText(fact: WalkerFact, value: String, walkers: Int) -> String? {
        guard let label = fact.valueLabel(value) else { return nil }
        return "\(label) (\(walkers) walkers)"
    }

    /// The lines for a trail with these keys (its own key first), in the
    /// vocabulary's order, one per fact: the first key in `keys` that has a
    /// summary for the fact, the newest if a key somehow has two. Never a
    /// `liked` line, never a value outside the vocabulary.
    static func lines(forKeys keys: [String], in summaries: [WalkerFactSummary]) -> [WalkerFactLine] {
        WalkerFact.allCases.filter(\.publishes).compactMap { fact in
            for key in keys {
                let matching = summaries.filter { $0.trailKey == key && $0.fact == fact && fact.knows($0.value)
                    && $0.walkers >= minimumWalkers }
                guard let pick = matching.max(by: { ($0.computedAt ?? .distantPast) < ($1.computedAt ?? .distantPast) }),
                      let text = lineText(fact: fact, value: pick.value, walkers: pick.walkers) else { continue }
                return WalkerFactLine(fact: fact, text: text)
            }
            return nil
        }
    }

    /// A trail's keys, its own first (the one a report names), each once.
    static func keys(of item: TrailListItem) -> [String] {
        var seen = Set<String>()
        return item.sections.compactMap(\.trailKey).filter { seen.insert($0).inserted }
    }
}

/// Reads summaries, behind a protocol for tests.
protocol TrailFactSummaryStore: AnyObject {
    /// Every summary for these keys that decodes; the rest are skipped.
    func summaries(forKeys keys: [String]) async throws -> [WalkerFactSummary]
}

final class CloudKitTrailFactSummaryStore: TrailFactSummaryStore {
    private let db = CKContainer(identifier: WockettCloud.containerID).publicCloudDatabase

    func summaries(forKeys keys: [String]) async throws -> [WalkerFactSummary] {
        var out: [WalkerFactSummary] = []
        // A handful of keys per trail; chunked so a query stays small.
        for start in stride(from: 0, to: keys.count, by: 50) {
            let chunk = Array(keys[start..<min(start + 50, keys.count)])
            let query = CKQuery(recordType: TrailFactSummaries.recordType,
                                predicate: NSPredicate(format: "trailKey IN %@", chunk))
            var (results, cursor) = try await db.records(matching: query, resultsLimit: 200)
            out += results.compactMap { try? $0.1.get() }.compactMap(TrailFactSummaries.summary(from:))
            while let next = cursor {
                (results, cursor) = try await db.records(continuingMatchFrom: next, resultsLimit: 200)
                out += results.compactMap { try? $0.1.get() }.compactMap(TrailFactSummaries.summary(from:))
            }
        }
        return out
    }
}

final class NoTrailFactSummaryStore: TrailFactSummaryStore {
    func summaries(forKeys keys: [String]) async throws -> [WalkerFactSummary] { [] }
}

/// Keeps the summaries the trail details have asked for: per trail key, what
/// the last fetch said and when. Cached for offline use; a key is fetched
/// again only once its answer is a day old.
@Observable
final class TrailFactSummaryService {
    static let shared = TrailFactSummaryService(store: AppModelContainer.isRunningUnderTests
                                                ? NoTrailFactSummaryStore() : CloudKitTrailFactSummaryStore())

    static let refreshInterval: TimeInterval = 86_400
    static let retryAfterFailure: TimeInterval = 600
    static let cacheKey = "wkt_trailFactSummaries_v1"
    /// The newest this many trails are kept.
    static let cachedTrails = 300

    struct Entry: Codable, Equatable {
        let fetchedAt: Date
        let summaries: [WalkerFactSummary]
    }

    private(set) var entries: [String: Entry]

    @ObservationIgnored private let store: TrailFactSummaryStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let log = Logger(subsystem: "com.wockett.app", category: "TrailFactSummaries")

    init(store: TrailFactSummaryStore, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.defaults = defaults
        self.now = now
        self.entries = defaults.data(forKey: Self.cacheKey)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func lines(forKeys keys: [String]) -> [WalkerFactLine] {
        TrailFactSummaries.lines(forKeys: keys, in: keys.flatMap { entries[$0]?.summaries ?? [] })
    }

    /// The keys a fetch would ask for now: never fetched, or a day old, and
    /// not failed in the last few minutes or already being fetched.
    func staleKeys(_ keys: [String]) -> [String] {
        let time = now()
        return keys.filter { key in
            if inFlight.contains(key) { return false }
            if let failed = failedAt[key], time.timeIntervalSince(failed) < Self.retryAfterFailure { return false }
            guard let entry = entries[key] else { return true }
            return time.timeIntervalSince(entry.fetchedAt) >= Self.refreshInterval
        }
    }

    /// Fetches the stale ones among `keys`. Every key asked about gets an
    /// entry, empty when nothing is published, so a withdrawn summary goes.
    /// A failed fetch keeps what is cached.
    func refreshIfStale(keys: [String]) async {
        let wanted = staleKeys(keys)
        guard !wanted.isEmpty else { return }
        inFlight.formUnion(wanted)
        defer { inFlight.subtract(wanted) }
        do {
            let fetched = try await store.summaries(forKeys: wanted)
            let time = now()
            for key in wanted {
                entries[key] = Entry(fetchedAt: time, summaries: fetched.filter { $0.trailKey == key })
                failedAt[key] = nil
            }
            trimAndSave()
        } catch {
            // A detail closed mid-fetch cancels it: not a failure to wait out.
            if Task.isCancelled || error is CancellationError || (error as? CKError)?.code == .operationCancelled { return }
            log.error("Walker summaries unavailable: \(error.localizedDescription, privacy: .public)")
            let time = now()
            for key in wanted { failedAt[key] = time }
        }
    }

    private func trimAndSave() {
        if entries.count > Self.cachedTrails {
            let keep = entries.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(Self.cachedTrails)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.cacheKey) }
    }
}
