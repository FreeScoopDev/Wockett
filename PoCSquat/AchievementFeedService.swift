import Foundation
import CloudKit

// MARK: - Achievement Post Model

struct AchievementPost: Identifiable {
    let id: CKRecord.ID
    let badgeName: String
    let badgeEmoji: String
    let authorName: String
    let message: String
    let createdAt: Date
    var likes: Int

    init?(record: CKRecord) {
        guard
            let badgeName  = record["badgeName"]  as? String,
            let badgeEmoji = record["badgeEmoji"] as? String
        else { return nil }

        self.id         = record.recordID
        self.badgeName  = badgeName
        self.badgeEmoji = badgeEmoji
        self.authorName = record["authorName"] as? String ?? "Anonymous"
        self.message    = record["message"]    as? String ?? ""
        self.createdAt  = record.creationDate  ?? Date()
        self.likes      = record["likes"]      as? Int    ?? 0
    }
}

// MARK: - Achievement Feed Service

// CloudKit record type: "WocketAchievement"
// Fields: badgeName (String), badgeEmoji (String), authorName (String),
//         message (String), likes (Int64)
// IMPORTANT: Deploy this schema to CloudKit Production via the CloudKit Console
//            before it will work on real devices.

final class AchievementFeedService {
    static let shared = AchievementFeedService()

    private let db         = CKContainer(identifier: "iCloud.Scoops.PoCSquat").publicCloudDatabase
    private let recordType = "WocketAchievement"
    private let likedKey   = "achievementLikedIds"

    private init() {}

    // MARK: - Username (shared key with CommunityRouteService)

    var username: String {
        UserDefaults.standard.string(forKey: "communityUsername")
            ?? CommunityRouteService.shared.username
    }

    // MARK: - Like tracking (local device)

    func hasLiked(id: CKRecord.ID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: likedKey) ?? []).contains(id.recordName)
    }

    func markLiked(id: CKRecord.ID) {
        var liked = UserDefaults.standard.stringArray(forKey: likedKey) ?? []
        guard !liked.contains(id.recordName) else { return }
        liked.append(id.recordName)
        UserDefaults.standard.set(liked, forKey: likedKey)
    }

    // MARK: - Fetch

    func fetchPosts(limit: Int = 40) async throws -> [AchievementPost] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let (results, _) = try await db.records(matching: query, resultsLimit: limit)
        return results.compactMap { _, result -> AchievementPost? in
            guard let record = try? result.get() else { return nil }
            return AchievementPost(record: record)
        }
    }

    // MARK: - Post

    func post(badgeName: String, badgeEmoji: String, message: String) async throws {
        let record = CKRecord(recordType: recordType)
        record["badgeName"]  = badgeName
        record["badgeEmoji"] = badgeEmoji
        record["authorName"] = username
        record["message"]    = message.trimmingCharacters(in: .whitespacesAndNewlines)
        record["likes"]      = 0
        _ = try await db.save(record)
    }

    // MARK: - Like

    func like(id: CKRecord.ID) async throws {
        let record  = try await db.record(for: id)
        let current = record["likes"] as? Int ?? 0
        record["likes"] = current + 1
        _ = try await db.save(record)
        markLiked(id: id)
    }
}
