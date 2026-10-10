import CloudKit
import CoreLocation
import CryptoKit
import Foundation
import Observation
import OSLog

// MARK: - Trail nominations and featured trails
//
// Walkers nominate a named trail they rate (`TrailNomination`, readable only
// by a Moderator); Joe features the best from the staff dashboard
// (`FeaturedTrail`, readable by everyone), and the Trails list shows them
// under "Featured near you" with his note. A trail is named by its pack
// `trailKey` (`nc:w123`, shared by all its pieces, stable across rebuilds
// while that way exists), plus its name and one point on it, so a featured
// trail still matches if a rebuild changes the key. Nobody's location is
// stored: the point is the trail's.

/// Which trail a nomination or a feature is about.
struct TrailRef: Codable, Equatable, Identifiable {
    var id: String { trailKey }
    let trailKey: String
    let trailName: String
    let region: String
    let latitude: Double
    let longitude: Double
    let lengthMeters: Double

    /// Whether `item` can be nominated: a named trail with a key. Cheap: no
    /// geometry is decoded, so a screen can ask on every render.
    static func canNominate(_ item: TrailListItem) -> Bool {
        item.hasName && item.sections.contains { $0.trailKey != nil }
    }

    /// The whole trail `item` belongs to, however the list showed it: every
    /// piece with its key (`wholeTrail`), so a row of one section and the
    /// grouped row describe the trail the same way. Nil for unnamed paths and
    /// packs without keys.
    init?(item: TrailListItem, wholeTrail: (String) -> [TrailFeature] = { _ in [] }) {
        guard Self.canNominate(item),
              let key = item.sections.lazy.compactMap(\.trailKey).first,
              let region = key.split(separator: ":").first.map(String.init) else { return nil }
        let whole = wholeTrail(key)
        let sections = whole.isEmpty ? item.sections : whole
        guard let longest = sections.max(by: { $0.lengthMeters < $1.lengthMeters }),
              let point = longest.coordinates.first else { return nil }
        self.init(trailKey: key, trailName: item.name, region: region, latitude: point.latitude,
                  longitude: point.longitude, lengthMeters: sections.reduce(0) { $0 + $1.lengthMeters })
    }

    init(trailKey: String, trailName: String, region: String, latitude: Double, longitude: Double, lengthMeters: Double) {
        self.trailKey = trailKey
        self.trailName = trailName
        self.region = region
        self.latitude = latitude
        self.longitude = longitude
        self.lengthMeters = lengthMeters
    }

    /// The fields both record types share.
    func write(to record: CKRecord) {
        record["trailKey"] = trailKey
        record["trailName"] = trailName
        record["region"] = region
        record["latitude"] = latitude
        record["longitude"] = longitude
        record["lengthMeters"] = lengthMeters
    }

    init?(record: CKRecord) {
        guard let key = record["trailKey"] as? String, !key.isEmpty,
              let name = record["trailName"] as? String,
              let latitude = record["latitude"] as? Double,
              let longitude = record["longitude"] as? Double else { return nil }
        self.init(trailKey: key, trailName: name, region: record["region"] as? String ?? "",
                  latitude: latitude, longitude: longitude, lengthMeters: record["lengthMeters"] as? Double ?? 0)
    }
}

// MARK: - Nominations

enum TrailNominations {
    static let recordType = "TrailNomination"
    static let noteLimit = 300

    /// `nomination.<hash>`: the same for one person and one trail on any of
    /// their devices, so CloudKit refuses a second (as reports and votes). A
    /// hash, so the dashboard can't read the nominator out of it. With no
    /// known nominator every nomination gets its own name.
    static func recordName(trailKey: String, nominator: String?) -> String {
        guard let nominator else { return "nomination.\(UUID().uuidString.lowercased())" }
        let digest = SHA256.hash(data: Data("\(trailKey)\n\(nominator)".utf8))
        return "nomination." + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func trimmedNote(_ note: String) -> String {
        String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(noteLimit))
    }

    /// The trail and the note; nothing about who nominated it.
    static func record(for trail: TrailRef, note: String, nominator: String?) -> CKRecord {
        let record = CKRecord(recordType: recordType,
                              recordID: CKRecord.ID(recordName: recordName(trailKey: trail.trailKey, nominator: nominator)))
        trail.write(to: record)
        record["note"] = trimmedNote(note)
        return record
    }

    enum Outcome: Equatable {
        case sent
        case alreadyNominated
        case failed(String)
    }

    static func outcome(of error: Error) -> Outcome {
        if let access = error as? CommunityAccessError { return .failed(access.message) }
        switch (error as? CKError)?.code {
        case .serverRecordChanged?: return .alreadyNominated
        case .notAuthenticated?: return .failed("Sign in to iCloud in the Settings app to nominate a trail.")
        default: return .failed("Couldn't send your nomination. Check your connection and try again.")
        }
    }
}

/// The CloudKit side of nominating, behind a protocol for tests.
protocol TrailNominationStore: AnyObject {
    func currentUserRecordName() async throws -> String
    func save(_ record: CKRecord) async throws
}

final class CloudKitTrailNominationStore: TrailNominationStore {
    private let container = CKContainer(identifier: WockettCloud.containerID)

    func currentUserRecordName() async throws -> String {
        try await container.userRecordID().recordName
    }

    func save(_ record: CKRecord) async throws {
        _ = try await container.publicCloudDatabase.save(record)
    }
}

@MainActor
enum TrailNominationSubmission {
    static let deadline: Duration = .seconds(15)

    static func submit(_ trail: TrailRef, note: String,
                       store: TrailNominationStore = CloudKitTrailNominationStore(),
                       canPost: @escaping () async throws -> Void = { try await SuspensionService.shared.ensureCanPost() },
                       knownNominator: @escaping () -> String? = { MyAccount.recordName },
                       deadline: Duration = deadline,
                       sleep: @escaping OptimisticVote.Sleep = { try await Task.sleep(for: $0) }) async -> TrailNominations.Outcome {
        do {
            try await canPost()
            let saved: Bool? = try await OptimisticVote.withDeadline(deadline, sleep: sleep) {
                let nominator = (try? await store.currentUserRecordName()) ?? knownNominator()
                try Task.checkCancellation()
                try await store.save(TrailNominations.record(for: trail, note: note, nominator: nominator))
                return true
            }
            return saved == nil ? .failed("Couldn't send your nomination. Check your connection and try again.") : .sent
        } catch {
            return TrailNominations.outcome(of: error)
        }
    }
}

// MARK: - Featured trails

/// A trail Joe features, with his note, until an optional end.
struct FeaturedTrail: Codable, Equatable {
    let trail: TrailRef
    let blurb: String
    let until: Date?

    func isActive(at now: Date) -> Bool {
        guard let until else { return true }
        return until > now
    }
}

enum FeaturedTrails {
    static let recordType = "FeaturedTrail"
    /// A rebuilt pack can give a trail a new key; the same name this close to
    /// the stored point is still that trail.
    static let nameMatchMeters: Double = 2_000

    static func featured(from record: CKRecord) -> FeaturedTrail? {
        guard let trail = TrailRef(record: record) else { return nil }
        let blurb = (record["blurb"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return FeaturedTrail(trail: trail, blurb: blurb, until: record["until"] as? Date)
    }

    /// The feature in force for `item`, if any: by key, else by the same name
    /// within `nameMatchMeters` of the stored point.
    static func match(_ item: TrailListItem, in list: [FeaturedTrail], at now: Date) -> FeaturedTrail? {
        let active = list.filter { $0.isActive(at: now) }
        guard !active.isEmpty, item.hasName else { return nil }
        let keys = Set(item.sections.compactMap(\.trailKey))
        if let byKey = active.first(where: { keys.contains($0.trail.trailKey) }) { return byKey }
        let name = normalized(item.name)
        for feature in active where normalized(feature.trail.trailName) == name {
            let point = CLLocation(latitude: feature.trail.latitude, longitude: feature.trail.longitude)
            let near = item.sections.contains { section in
                section.coordinates.contains {
                    CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: point) <= nameMatchMeters
                }
            }
            if near { return feature }
        }
        return nil
    }

    /// The featured items among `items`, in list order, each feature once:
    /// with sections listed separately every piece of a featured trail
    /// matches, and only the first (nearest) is shown. The active list and
    /// its names are worked out once, not per row, and geometry is decoded
    /// only for a row whose name a feature shares.
    static func featuredItems(_ items: [TrailListItem], in list: [FeaturedTrail], at now: Date) -> [(item: TrailListItem, feature: FeaturedTrail)] {
        let active = list.filter { $0.isActive(at: now) }
        guard !active.isEmpty else { return [] }
        let names = Set(active.map { normalized($0.trail.trailName) })
        let keys = Set(active.map(\.trail.trailKey))
        var shown = Set<String>()
        var out: [(item: TrailListItem, feature: FeaturedTrail)] = []
        for item in items where item.hasName {
            let hasKey = item.sections.contains { $0.trailKey.map(keys.contains) ?? false }
            guard hasKey || names.contains(normalized(item.name)),
                  let feature = match(item, in: active, at: now),
                  shown.insert(feature.trail.trailKey).inserted else { continue }
            out.append((item, feature))
        }
        return out
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

protocol FeaturedTrailStore: AnyObject {
    func featured() async throws -> [FeaturedTrail]
}

final class CloudKitFeaturedTrailStore: FeaturedTrailStore {
    private let db = CKContainer(identifier: WockettCloud.containerID).publicCloudDatabase

    func featured() async throws -> [FeaturedTrail] {
        let query = CKQuery(recordType: FeaturedTrails.recordType, predicate: NSPredicate(value: true))
        let (results, _) = try await db.records(matching: query, resultsLimit: 400)
        return results.compactMap { try? $0.1.get() }.compactMap(FeaturedTrails.featured(from:))
    }
}

final class NoFeaturedTrailStore: FeaturedTrailStore {
    func featured() async throws -> [FeaturedTrail] { [] }
}

/// Keeps the featured list: fetched at most every 30 minutes, a list waits
/// for it at most 3 s (a slower fetch still lands for next time), cached for
/// offline use.
@Observable
final class FeaturedTrailService {
    static let shared = FeaturedTrailService(store: AppModelContainer.isRunningUnderTests
                                             ? NoFeaturedTrailStore() : CloudKitFeaturedTrailStore())

    static let refreshInterval: TimeInterval = 1_800
    static let retryAfterFailure: TimeInterval = 60
    static let deadline: Duration = .seconds(3)
    static let cacheKey = "wkt_featuredTrails_v1"

    private(set) var list: [FeaturedTrail]

    @ObservationIgnored private let store: FeaturedTrailStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: OptimisticVote.Sleep
    @ObservationIgnored private let log = Logger(subsystem: "com.wockett.app", category: "FeaturedTrails")
    @ObservationIgnored private(set) var nextRefresh: Date?
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    init(store: FeaturedTrailStore, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         sleep: @escaping OptimisticVote.Sleep = { try await Task.sleep(for: $0) }) {
        self.store = store
        self.defaults = defaults
        self.now = now
        self.sleep = sleep
        self.list = defaults.data(forKey: Self.cacheKey)
            .flatMap { try? JSONDecoder().decode([FeaturedTrail].self, from: $0) } ?? []
    }

    func refreshIfStale() async {
        if inFlight == nil {
            if let nextRefresh, now() < nextRefresh { return }
            inFlight = Task { await self.fetch() }
        }
        guard let task = inFlight else { return }
        let finished = try? await OptimisticVote.withDeadline(Self.deadline, sleep: sleep) {
            await task.value
            return true
        }
        if finished == nil { log.error("Featured trails slow; the list uses the ones held") }
    }

    private func fetch() async {
        defer { inFlight = nil }
        do {
            let fetched = try await store.featured()
            if fetched != list {
                list = fetched
                if let data = try? JSONEncoder().encode(fetched) { defaults.set(data, forKey: Self.cacheKey) }
            }
            nextRefresh = now().addingTimeInterval(Self.refreshInterval)
        } catch {
            log.error("Featured trails unavailable: \(error.localizedDescription, privacy: .public)")
            nextRefresh = now().addingTimeInterval(Self.retryAfterFailure)
        }
    }
}
