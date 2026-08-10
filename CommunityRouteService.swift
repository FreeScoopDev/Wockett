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

    private let db         = CKContainer(identifier: "iCloud.Scoops.PoCSquat").publicCloudDatabase
    private let recordType = "SharedRoute"
    private let votedKey   = "communityVotedRoutes"
    private let usernameKey = "communityUsername"

    private let adjectives = [
        "Misty", "Golden", "Ancient", "Silent", "Swift", "Wild", "Calm",
        "Wandering", "Gentle", "Humble", "Mossy", "Amber", "Russet", "Dappled", "Sunlit"
    ]
    private let nouns = [
        "Oak", "Heron", "Fern", "Cedar", "Maple", "Wolf", "Falcon", "Birch",
        "Stone", "River", "Meadow", "Pine", "Hawk", "Willow", "Aspen", "Moss", "Elk", "Sage"
    ]

    init() {}

    // MARK: - Username

    var username: String {
        if let existing = UserDefaults.standard.string(forKey: usernameKey) { return existing }
        let generated = (adjectives.randomElement() ?? "Misty") + (nouns.randomElement() ?? "Oak")
        UserDefaults.standard.set(generated, forKey: usernameKey)
        return generated
    }

    // MARK: - Vote tracking (local device)

    func hasVoted(for id: CKRecord.ID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: votedKey) ?? []).contains(id.recordName)
    }

    func markVoted(for id: CKRecord.ID) {
        var voted = UserDefaults.standard.stringArray(forKey: votedKey) ?? []
        guard !voted.contains(id.recordName) else { return }
        voted.append(id.recordName)
        UserDefaults.standard.set(voted, forKey: votedKey)
    }

    // MARK: - Fetch

    // Fetches newest 30 routes, sorts by Wocketts client-side.
    // Uses creationDate (auto-indexed by CloudKit) to avoid needing a custom index.
    func fetchRoutes(limit: Int = 30) async throws -> [SharedRoute] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let (results, _) = try await db.records(matching: query, resultsLimit: limit)
        let routes = results.compactMap { _, result -> SharedRoute? in
            guard let record = try? result.get() else { return nil }
            return SharedRoute(record: record)
        }
        return routes.sorted { $0.wocketts > $1.wocketts }
    }

    // MARK: - Publish

    func publish(route: CustomRoute) async throws {
        let waypointData  = try JSONEncoder().encode(route.waypoints)
        let waypointsJSON = String(data: waypointData, encoding: .utf8) ?? "[]"

        let record = CKRecord(recordType: recordType)
        record["name"]          = route.name
        record["waypointsJSON"] = waypointsJSON
        record["isLoop"]        = route.isLoop ? 1 : 0
        record["distanceMeters"] = route.totalDistance
        record["difficultyTag"] = difficultyTag(for: route.totalDistance)
        record["upvotes"]       = 0
        record["authorName"]    = username

        _ = try await db.save(record)
    }

    // MARK: - Wockett

    func wockett(id: CKRecord.ID) async throws {
        let record  = try await db.record(for: id)
        let current = record["upvotes"] as? Int ?? 0
        record["upvotes"] = current + 1
        _ = try await db.save(record)
        markVoted(for: id)
    }

    // MARK: - Helpers

    private func difficultyTag(for distanceMeters: Double) -> String {
        if distanceMeters < 2000 { return RouteDifficulty.easy.rawValue }
        if distanceMeters < 5000 { return RouteDifficulty.moderate.rawValue }
        return RouteDifficulty.hard.rawValue
    }
}
