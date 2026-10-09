import Foundation
import CloudKit
import MapKit

// MARK: - Shared Route Model

struct SharedRoute: Identifiable {
    let id: CKRecord.ID
    let name: String
    let waypoints: [WaypointCoord]
    let isLoop: Bool
    let distanceMeters: Double
    let difficulty: RouteDifficulty
    var wocketts: Int
    let authorName: String
    let createdAt: Date

    var distanceText: String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: distanceMeters)
    }

    var timeText: String {
        let mins = Int(distanceMeters / 1.4 / 60)
        return mins < 60 ? "\(mins) min" : "\(mins / 60)h \(mins % 60)m"
    }

    var estimatedSteps: Int { Int(distanceMeters / 0.762) }

    func toNavigableRoute() -> NavigableRoute {
        NavigableRoute(
            name: name,
            waypoints: waypoints.map { $0.clCoordinate },
            lapCount: 1,
            isLoop: isLoop,
            totalDistance: distanceMeters
        )
    }

    init?(record: CKRecord) {
        guard
            let name          = record["name"] as? String,
            let waypointsJSON = record["waypointsJSON"] as? String,
            let data          = waypointsJSON.data(using: .utf8),
            let waypoints     = try? JSONDecoder().decode([WaypointCoord].self, from: data),
            let distance      = record["distanceMeters"] as? Double
        else { return nil }

        self.id             = record.recordID
        self.name           = name
        self.waypoints      = waypoints
        self.isLoop         = (record["isLoop"] as? Int ?? 0) == 1
        self.distanceMeters = distance
        self.difficulty     = RouteDifficulty(rawValue: record["difficultyTag"] as? String ?? "") ?? .easy
        self.wocketts       = record["upvotes"] as? Int ?? 0
        self.authorName     = record["authorName"] as? String ?? "Anonymous"
        self.createdAt      = record.creationDate ?? Date()
    }
}

// MARK: - Community Route Service

final class CommunityRouteService {
    static let shared = CommunityRouteService()

    private let db         = CKContainer(identifier: WockettCloud.containerID).publicCloudDatabase
    private let recordType = "SharedRoute"
    private let votedKey      = "communityVotedRoutes"
    private let publishedKey  = "wkt_publishedRouteIds"

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
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let (results, _) = try await db.records(matching: query, resultsLimit: limit)
        var routes = results.compactMap { _, result -> SharedRoute? in
            guard let record = try? result.get() else { return nil }
            return SharedRoute(record: record)
        }
        .filter { !CommunityModerationStore.shared.shouldHide(id: $0.id, author: $0.authorName) }
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

    func publish(route: CustomRoute) async throws {
        try ContentFilter.validate(name: route.name)
        let waypointData  = try JSONEncoder().encode(route.waypoints)
        let waypointsJSON = String(data: waypointData, encoding: .utf8) ?? "[]"

        let record = CKRecord(recordType: recordType)
        record["name"]          = route.name
        record["waypointsJSON"] = waypointsJSON
        record["isLoop"]        = route.isLoop ? 1 : 0
        record["distanceMeters"] = route.totalDistance
        record["difficultyTag"] = difficultyTag(for: route.totalDistance)
        record["upvotes"]       = 0
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

    private func difficultyTag(for distanceMeters: Double) -> String {
        if distanceMeters < 2000 { return RouteDifficulty.easy.rawValue }
        if distanceMeters < 5000 { return RouteDifficulty.moderate.rawValue }
        return RouteDifficulty.hard.rawValue
    }
}
