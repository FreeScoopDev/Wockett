import Foundation
import CloudKit
import MapKit

// MARK: - Shared Route Model

struct SharedRoute: Identifiable {
    /// Longest route a record may carry: 2,000 km, past any walk, run or ride
    /// the builder makes. `1e30` is finite and non-negative but traps the
    /// `Int` conversions below, so the cap is part of reading a record
    /// (2026-10-26 review, finding 3).
    static let maxDistanceMeters = 2_000_000.0

    let id: CKRecord.ID
    let name: String
    let waypoints: [WaypointCoord]
    let isLoop: Bool
    let distanceMeters: Double
    let difficulty: RouteDifficulty
    var wocketts: Int
    let authorName: String
    /// The account that created it (CloudKit's creator), for Block.
    let authorAccount: String?
    var author: CommunityAuthor { CommunityAuthor(name: authorName, account: authorAccount) }
    let createdAt: Date

    var distanceText: String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: distanceMeters)
    }

    var timeText: String {
        let mins = saturatingInt(distanceMeters / 1.4 / 60)
        return mins < 60 ? "\(mins) min" : "\(mins / 60)h \(mins % 60)m"
    }

    var estimatedSteps: Int { saturatingInt(distanceMeters / 0.762) }

    func toNavigableRoute() -> NavigableRoute {
        NavigableRoute(
            name: name,
            waypoints: waypoints.map { $0.clCoordinate },
            lapCount: 1,
            isLoop: isLoop,
            totalDistance: distanceMeters
        )
    }

    /// `creator` is a seam for tests (records built in a test have none).
    init?(record: CKRecord, creator: CKRecord.ID? = nil) {
        guard
            let name          = record["name"] as? String,
            let waypointsJSON = record["waypointsJSON"] as? String,
            let data          = waypointsJSON.data(using: .utf8),
            let decoded       = try? JSONDecoder().decode([WaypointCoord].self, from: data),
            let waypoints     = Self.validWaypoints(decoded),
            let distance      = record["distanceMeters"] as? Double,
            distance.isFinite, (0...Self.maxDistanceMeters).contains(distance)
        else { return nil }

        self.id             = record.recordID
        self.name           = name
        self.waypoints      = waypoints
        self.isLoop         = (record["isLoop"] as? Int ?? 0) == 1
        self.distanceMeters = distance
        self.difficulty     = RouteDifficulty(rawValue: record["difficultyTag"] as? String ?? "") ?? .easy
        self.wocketts       = record["upvotes"] as? Int ?? 0
        self.authorName     = record["authorName"] as? String ?? "Anonymous"
        self.authorAccount = CommunityAuthor.account(of: record, creator: creator)
        self.createdAt      = record.creationDate ?? Date()
    }

    /// A route anyone could have written: nil when it has more points than the
    /// app ever publishes (`SharedRouteTrim.maxPublishedPoints`), which would
    /// only slow a walk that starts it, and without any point that is not a
    /// real coordinate.
    static func validWaypoints(_ waypoints: [WaypointCoord]) -> [WaypointCoord]? {
        guard waypoints.count <= SharedRouteTrim.maxPublishedPoints else { return nil }
        return waypoints.filter {
            (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude)
        }
    }
}

// MARK: - Community Route Service

final class CommunityRouteService {
    static let shared = CommunityRouteService()

    private let db         = CKContainer(identifier: WockettCloud.containerID).publicCloudDatabase
    static let recordType = "SharedRoute"
    private var recordType: String { Self.recordType }
    /// Static: Delete my community data reads it (CommunityDataDeletion).
    static let votedKey = "communityVotedRoutes"
    private var votedKey: String { Self.votedKey }
    /// Static: deleting your route clears it (CommunityDeletion).
    static let publishedKey = "wkt_publishedRouteIds"
    private var publishedKey: String { Self.publishedKey }

    init() {}

    // MARK: - Username

    // MARK: - Vote tracking (local device)

    /// Every route this device marked as Wocketted.
    var votedIDs: [String] { UserDefaults.standard.stringArray(forKey: votedKey) ?? [] }

    func hasVoted(for id: CKRecord.ID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: votedKey) ?? []).contains(id.recordName)
    }

    func markVoted(for id: CKRecord.ID) {
        var voted = UserDefaults.standard.stringArray(forKey: votedKey) ?? []
        guard !voted.contains(id.recordName) else { return }
        voted.append(id.recordName)
        UserDefaults.standard.set(voted, forKey: votedKey)
    }

    /// Undoes `markVoted` after a Wockett failed to save.
    func unmarkVoted(for id: CKRecord.ID) {
        let voted = (UserDefaults.standard.stringArray(forKey: votedKey) ?? []).filter { $0 != id.recordName }
        UserDefaults.standard.set(voted, forKey: votedKey)
    }

    // MARK: - Fetch

    // Fetches newest 30 routes, sorts by Wocketts client-side.
    // Uses creationDate (auto-indexed by CloudKit) to avoid needing a custom index.
    func fetchRoutes(limit: Int = 30) async throws -> [SharedRoute] {
        // Suspended accounts are hidden by the filter below: have the list current.
        await SuspensionService.shared.refreshIfStale()
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let (results, _) = try await db.records(matching: query, resultsLimit: limit)
        var routes = results.compactMap { _, result -> SharedRoute? in
            guard let record = try? result.get() else { return nil }
            return SharedRoute(record: record)
        }
        .filter { !CommunityModerationStore.shared.shouldHide(id: $0.id, author: $0.author) }
        // Wocketts are CommunityVote records (CommunityVotes.swift), not the
        // route's own `upvotes` field, which only its author could ever change.
        let tally = await CommunityVoteService.shared.tally(for: routes.map(\.id.recordName))
        // Cancelled (the screen went away): a tally that gave up is all 0s, not real counts.
        try Task.checkCancellation()
        for i in routes.indices {
            routes[i].wocketts = tally.count(for: routes[i].id.recordName)
            if tally.mine.contains(routes[i].id.recordName) { markVoted(for: routes[i].id) }
        }
        return routes.sorted { $0.wocketts > $1.wocketts }
    }

    // MARK: - Publish

    /// Publishes `trimmed` under `name`: the path the share screen already
    /// prepared and drew (`ShareReview`), not a fresh trim, so what goes
    /// public is what the user saw. The route the user keeps is not changed.
    func publish(name: String, trimmed: SharedRouteTrim.Trimmed) async throws {
        try ContentFilter.validate(name: name)
        let record = try Self.record(name: name, trimmed: trimmed)
        try await SuspensionService.shared.ensureCanPost()
        record["authorName"]    = try await CommunityNameService.shared.claimedName()

        let saved = try await db.save(record)
        // Track published route ID so we can fetch received wocketts later
        var published = UserDefaults.standard.stringArray(forKey: publishedKey) ?? []
        published.append(saved.recordID.recordName)
        UserDefaults.standard.set(published, forKey: publishedKey)
        UserDefaults.standard.set(true, forKey: "wkt_customRouteShared")
    }

    // MARK: - Received Wocketts

    /// Counts the Wocketts (votes) on every route the current user has published. 0 when votes can't be read.
    func fetchReceivedWocketts() async -> Int {
        let ids = UserDefaults.standard.stringArray(forKey: publishedKey) ?? []
        guard !ids.isEmpty else { return 0 }
        let tally = await CommunityVoteService.shared.tally(for: ids)
        return ids.reduce(0) { $0 + tally.count(for: $1) }
    }

    // MARK: - Wockett

    func wockett(id: CKRecord.ID) async throws {
        try await CommunityVoteService.shared.vote(for: id.recordName, type: .route)
        markVoted(for: id)
    }

    // MARK: - Helpers

    /// The public record for `route`, before its author is added: the path
    /// `SharedRouteTrim.prepare` gives, its length, and whether it is a loop
    /// (never, with the ends hidden). Throws `SharedRouteTrim.CannotShareError`
    /// for a route that can't be shared, including when `hideEnds` is on and
    /// `offset` is nil.
    static func record(for route: CustomRoute, hideEnds: Bool, offset: SharePrivacyOffset?) throws -> CKRecord {
        let outcome = SharedRouteTrim.prepare(route, hideEnds: hideEnds, offset: offset)
        guard case .trimmed(let trimmed) = outcome else { throw SharedRouteTrim.CannotShareError(outcome: outcome) }
        return try record(name: route.name, trimmed: trimmed)
    }

    /// The public record for an already prepared path, before its author is added.
    static func record(name: String, trimmed: SharedRouteTrim.Trimmed) throws -> CKRecord {
        let distance = trimmed.keptMeters
        let waypointData = try JSONEncoder().encode(trimmed.waypoints)

        let record = CKRecord(recordType: recordType)
        record["name"]           = name
        record["waypointsJSON"]  = String(data: waypointData, encoding: .utf8) ?? "[]"
        record["isLoop"]         = trimmed.isLoop ? 1 : 0
        record["distanceMeters"] = distance
        record["difficultyTag"]  = difficultyTag(for: distance)
        record["upvotes"]        = 0
        return record
    }

    private static func difficultyTag(for distanceMeters: Double) -> String {
        if distanceMeters < 2000 { return RouteDifficulty.easy.rawValue }
        if distanceMeters < 5000 { return RouteDifficulty.moderate.rawValue }
        return RouteDifficulty.hard.rawValue
    }
}

extension SharedRoute: CommunityModerated {}

/// What a share screen publishes through; tests record it instead of CloudKit.
protocol SharedRoutePublishing {
    func publish(name: String, trimmed: SharedRouteTrim.Trimmed) async throws
}

extension CommunityRouteService: SharedRoutePublishing {}
