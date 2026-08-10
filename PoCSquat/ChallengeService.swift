import Foundation
import CloudKit
import HealthKit

// MARK: - Walk Challenge Model

struct WalkChallenge: Identifiable {
    let id: CKRecord.ID
    let title: String
    let emoji: String
    let goalSteps: Int
    let startDate: Date
    let endDate: Date
    let authorName: String

    var isActive: Bool { Date() >= startDate && Date() <= endDate }

    var timeRemainingText: String {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: endDate).day ?? 0
        if days > 1  { return "\(days) days left" }
        if days == 1 { return "1 day left" }
        let hrs = Calendar.current.dateComponents([.hour], from: Date(), to: endDate).hour ?? 0
        return hrs > 0 ? "\(hrs)h left" : "Ending soon"
    }

    var durationDays: Int {
        max(1, Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 1)
    }

    func progress(for steps: Int) -> Double {
        min(1.0, Double(steps) / Double(max(1, goalSteps)))
    }

    var goalText: String {
        if goalSteps >= 1_000_000 { return String(format: "%.1fM steps", Double(goalSteps) / 1_000_000) }
        if goalSteps >= 10_000    { return "\(goalSteps / 1_000)K steps" }
        return "\(goalSteps) steps"
    }

    init?(record: CKRecord) {
        guard
            let title     = record["title"]     as? String,
            let goalSteps = record["goalSteps"] as? Int,
            let startDate = record["startDate"] as? Date,
            let endDate   = record["endDate"]   as? Date
        else { return nil }
        self.id         = record.recordID
        self.title      = title
        self.emoji      = record["emoji"]      as? String ?? "🏆"
        self.goalSteps  = goalSteps
        self.startDate  = startDate
        self.endDate    = endDate
        self.authorName = record["authorName"] as? String ?? "Anonymous"
    }
}

// MARK: - Challenge Participant Model

struct ChallengeParticipant: Identifiable {
    let id: CKRecord.ID
    let displayName: String
    var steps: Int
    let deviceID: String
    let joinedAt: Date

    var isCurrentDevice: Bool { deviceID == ChallengeService.shared.deviceID }

    init?(record: CKRecord) {
        guard
            let displayName = record["displayName"] as? String,
            let steps       = record["steps"]       as? Int,
            let deviceID    = record["deviceID"]    as? String
        else { return nil }
        self.id          = record.recordID
        self.displayName = displayName
        self.steps       = steps
        self.deviceID    = deviceID
        self.joinedAt    = record.creationDate ?? Date()
    }
}

// MARK: - Challenge Service

// CloudKit schema — deploy to Production in CloudKit Console before going live.
//
// Record type: "Challenge"
//   title       String
//   emoji       String
//   goalSteps   Int64
//   startDate   Date/Time
//   endDate     Date/Time   ← add queryable index on this field
//   authorName  String
//
// Record type: "ChallengeEntry"
//   challengeRecordName  String  ← add queryable index
//   displayName          String
//   steps                Int64
//   deviceID             String  ← add queryable index

final class ChallengeService {
    static let shared = ChallengeService()
    private init() {}

    private let db             = CKContainer(identifier: "iCloud.Scoops.PoCSquat").publicCloudDatabase
    private let challengeType  = "Challenge"
    private let entryType      = "ChallengeEntry"
    private let joinedKey      = "wkt_joinedChallengeEntries_v1"  // [challengeRecordName: entryRecordName]

    // Stable per-device identifier — never changes, never contains PII.
    var deviceID: String {
        if let v = UserDefaults.standard.string(forKey: "wkt_deviceID") { return v }
        let v = UUID().uuidString
        UserDefaults.standard.set(v, forKey: "wkt_deviceID")
        return v
    }

    var username: String { CommunityRouteService.shared.username }

    // MARK: - Fetch

    func fetchActiveChallenges() async throws -> [WalkChallenge] {
        let pred  = NSPredicate(format: "endDate >= %@", Date() as CVarArg)
        let query = CKQuery(recordType: challengeType, predicate: pred)
        query.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: true)]
        let (results, _) = try await db.records(matching: query, resultsLimit: 40)
        return results.compactMap { _, r -> WalkChallenge? in
            guard let rec = try? r.get() else { return nil }
            return WalkChallenge(record: rec)
        }
    }

    func fetchLeaderboard(for challenge: WalkChallenge) async throws -> [ChallengeParticipant] {
        let pred  = NSPredicate(format: "challengeRecordName == %@", challenge.id.recordName)
        let query = CKQuery(recordType: entryType, predicate: pred)
        query.sortDescriptors = [NSSortDescriptor(key: "steps", ascending: false)]
        let (results, _) = try await db.records(matching: query, resultsLimit: 100)
        return results.compactMap { _, r -> ChallengeParticipant? in
            guard let rec = try? r.get() else { return nil }
            return ChallengeParticipant(record: rec)
        }
        .sorted { $0.steps > $1.steps }
    }

    // MARK: - Create

    func createChallenge(title: String, emoji: String, goalSteps: Int, durationDays: Int) async throws {
        let cal   = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end   = cal.date(byAdding: .day, value: durationDays, to: start)!

        let record            = CKRecord(recordType: challengeType)
        record["title"]       = title
        record["emoji"]       = emoji
        record["goalSteps"]   = goalSteps
        record["startDate"]   = start
        record["endDate"]     = end
        record["authorName"]  = username
        _ = try await db.save(record)
    }

    // MARK: - Join / update progress

    func hasJoined(_ challenge: WalkChallenge) -> Bool {
        joinedEntries[challenge.id.recordName] != nil
    }

    func joinOrUpdate(_ challenge: WalkChallenge, steps: Int) async throws {
        let key = challenge.id.recordName
        if let existingName = joinedEntries[key] {
            let record        = try await db.record(for: CKRecord.ID(recordName: existingName))
            record["steps"]   = steps
            _ = try await db.save(record)
        } else {
            let record                      = CKRecord(recordType: entryType)
            record["challengeRecordName"]   = key
            record["displayName"]           = username
            record["steps"]                 = steps
            record["deviceID"]              = deviceID
            let saved = try await db.save(record)
            storeJoin(challengeKey: key, entryName: saved.recordID.recordName)
        }
    }

    // MARK: - HealthKit step fetch for challenge window

    func fetchSteps(for challenge: WalkChallenge) async -> Int {
        guard HKHealthStore.isHealthDataAvailable() else { return 0 }
        let store = HKHealthStore()
        let pred  = HKQuery.predicateForSamples(
            withStart: challenge.startDate,
            end: min(challenge.endDate, Date())
        )
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(
                quantityType: HKQuantityType(.stepCount),
                quantitySamplePredicate: pred,
                options: .cumulativeSum
            ) { _, result, _ in
                cont.resume(returning: Int(result?.sumQuantity()?.doubleValue(for: .count()) ?? 0))
            }
            store.execute(q)
        }
    }

    // MARK: - Persistence helpers

    private var joinedEntries: [String: String] {
        UserDefaults.standard.dictionary(forKey: joinedKey) as? [String: String] ?? [:]
    }

    private func storeJoin(challengeKey: String, entryName: String) {
        var d = joinedEntries
        d[challengeKey] = entryName
        UserDefaults.standard.set(d, forKey: joinedKey)
    }
}

// Swift doesn't have a built-in min for Date — add one here to avoid ambiguity.
private func min(_ a: Date, _ b: Date) -> Date { a < b ? a : b }
