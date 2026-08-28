import Foundation
import CloudKit
import HealthKit

// MARK: - Challenge Goal Type

enum ChallengeGoalType: String, CaseIterable {
    case steps    = "steps"
    case distance = "distance"
    case pace     = "pace"
}

// MARK: - Formatting helpers (shared between service and view)

func challengeFormattedDistance(_ meters: Double) -> String {
    let useMetric = Locale.current.measurementSystem != .us
    if useMetric {
        let km = meters / 1000
        return km >= 10 ? "\(Int(km)) km" : String(format: "%.1f km", km)
    } else {
        let mi = meters / 1609.34
        return mi >= 10 ? "\(Int(mi)) mi" : String(format: "%.1f mi", mi)
    }
}

func challengeFormattedPace(_ secsPerKm: Double) -> String {
    let useMetric = Locale.current.measurementSystem != .us
    let displaySecs = useMetric ? secsPerKm : secsPerKm * 1.60934
    let unit = useMetric ? "/km" : "/mi"
    let mins = Int(displaySecs) / 60
    let secs = Int(displaySecs) % 60
    return String(format: "%d:%02d%@", mins, secs, unit)
}

// MARK: - Walk Challenge Model

struct WalkChallenge: Identifiable {
    let id:           CKRecord.ID
    let title:        String
    let emoji:        String
    let goalType:     ChallengeGoalType
    let activityFilter:     String?    // nil = any; "walking" | "running" | "cycling"
    let goalSteps:          Int        // .steps goals
    let goalDistanceMeters: Double     // .distance goals (metres)
    let goalPaceSecsPerKm:  Double     // .pace goals — sessions below this threshold qualify
    let goalSessionCount:   Int        // .pace goals — how many qualifying sessions needed
    let startDate:    Date
    let endDate:      Date
    let authorName:   String

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

    var goalText: String {
        switch goalType {
        case .steps:
            if goalSteps >= 1_000_000 { return String(format: "%.1fM steps", Double(goalSteps) / 1_000_000) }
            if goalSteps >= 10_000    { return "\(goalSteps / 1_000)K steps" }
            return "\(goalSteps) steps"
        case .distance:
            let dist = challengeFormattedDistance(goalDistanceMeters)
            switch activityFilter {
            case "running": return "Run \(dist)"
            case "walking": return "Walk \(dist)"
            case "cycling": return "Bike \(dist)"
            default: return dist
            }
        case .pace:
            return "\(goalSessionCount)× under \(challengeFormattedPace(goalPaceSecsPerKm))"
        }
    }

    var activityFilterLabel: String {
        switch activityFilter {
        case "running": return "Running only"
        case "walking": return "Walking only"
        case "cycling": return "Biking only"
        default: return "Any activity"
        }
    }

    func progress(for value: Int) -> Double {
        switch goalType {
        case .steps:    return min(1.0, Double(value) / Double(max(1, goalSteps)))
        case .distance: return min(1.0, Double(value) / max(1.0, goalDistanceMeters))
        case .pace:     return min(1.0, Double(value) / Double(max(1, goalSessionCount)))
        }
    }

    func progressDisplay(for value: Int) -> String {
        switch goalType {
        case .steps:
            return "\(value.formatted()) / \(goalSteps.formatted()) steps"
        case .distance:
            return "\(challengeFormattedDistance(Double(value))) / \(challengeFormattedDistance(goalDistanceMeters))"
        case .pace:
            let noun = activityFilter == "running" ? "run" : "session"
            return "\(value) / \(goalSessionCount) qualifying \(noun)\(goalSessionCount == 1 ? "" : "s")"
        }
    }

    func leaderboardDisplay(for value: Int) -> String {
        switch goalType {
        case .steps:    return value.formatted()
        case .distance: return challengeFormattedDistance(Double(value))
        case .pace:
            let noun = activityFilter == "running" ? "run" : "session"
            return "\(value) \(noun)\(value == 1 ? "" : "s")"
        }
    }

    // Returns the value to write into ChallengeEntry.steps for non-step goals.
    //   .distance → total metres walked/run (flaggedPossibleVehicle excluded)
    //   .pace     → count of sessions where pace beat the goalPaceSecsPerKm threshold
    func localProgressValue(from sessions: [WalkSession]) -> Int {
        let window = sessions.filter {
            $0.date >= startDate &&
            $0.date <= endDate &&
            !$0.flaggedPossibleVehicle &&
            (activityFilter == nil || $0.activityType == activityFilter)
        }
        switch goalType {
        case .steps: return 0
        case .distance:
            return Int(window.reduce(0.0) { $0 + $1.totalDistance })
        case .pace:
            return window.filter {
                $0.totalDistance > 200 &&
                $0.elapsedTime > 0 &&
                ($0.elapsedTime / ($0.totalDistance / 1000)) < goalPaceSecsPerKm
            }.count
        }
    }

    init?(record: CKRecord) {
        guard
            let title     = record["title"]     as? String,
            let startDate = record["startDate"] as? Date,
            let endDate   = record["endDate"]   as? Date
        else { return nil }

        self.id         = record.recordID
        self.title      = title
        self.emoji      = record["emoji"]      as? String ?? "🏆"
        self.startDate  = startDate
        self.endDate    = endDate
        self.authorName = record["authorName"] as? String ?? "Anonymous"

        // goalType absent on existing records → default to .steps (backward compat)
        let rawType = record["goalType"] as? String ?? ChallengeGoalType.steps.rawValue
        self.goalType       = ChallengeGoalType(rawValue: rawType) ?? .steps
        self.activityFilter = record["activityFilter"] as? String

        let gs = record["goalSteps"] as? Int ?? 0
        guard self.goalType != .steps || gs > 0 else { return nil }
        self.goalSteps = gs

        self.goalDistanceMeters = record["goalDistanceMeters"] as? Double ?? 0
        self.goalPaceSecsPerKm  = record["goalPaceSecsPerKm"]  as? Double ?? 0
        self.goalSessionCount   = record["goalSessionCount"]   as? Int    ?? 1
    }
}

// MARK: - Challenge Participant Model

struct ChallengeParticipant: Identifiable {
    let id:          CKRecord.ID
    let displayName: String
    var steps:       Int
    let deviceID:    String
    let joinedAt:    Date

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
//   title               String
//   emoji               String
//   goalSteps           Int64      (step challenges: goal count; others: 0)
//   startDate           Date/Time
//   endDate             Date/Time  ← queryable index required
//   authorName          String
//   goalType            String     NEW — nil/absent → "steps"; "distance"; "pace"
//   activityFilter      String     NEW — nil → any; "walking" | "running" | "cycling"
//   goalDistanceMeters  Double     NEW — target metres for .distance challenges
//   goalPaceSecsPerKm   Double     NEW — qualifying threshold (s/km) for .pace challenges
//   goalSessionCount    Int64      NEW — sessions needed for .pace challenges
//
// Migration: existing records have no goalType → init?(record:) defaults to .steps; no action needed.
//
// Record type: "ChallengeEntry"  (unchanged)
//   challengeRecordName  String  ← queryable index required
//   displayName          String
//   steps                Int64   step challenges: steps; distance: metres; pace: session count
//   deviceID             String  ← queryable index required

final class ChallengeService {
    static let shared = ChallengeService()
    private init() {}

    private let db            = CKContainer(identifier: "iCloud.Scoops.PoCSquat").publicCloudDatabase
    private let challengeType = "Challenge"
    private let entryType     = "ChallengeEntry"
    private let joinedKey     = "wkt_joinedChallengeEntries_v1"  // [challengeRecordName: entryRecordName]

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
        .filter { !CommunityModerationStore.shared.shouldHide(id: $0.id, author: $0.authorName) }
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

    func createChallenge(
        title: String,
        emoji: String,
        goalType: ChallengeGoalType,
        activityFilter: String?,
        goalSteps: Int,
        goalDistanceMeters: Double,
        goalPaceSecsPerKm: Double,
        goalSessionCount: Int,
        durationDays: Int
    ) async throws {
        try ContentFilter.validate(name: title)
        let cal   = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: durationDays, to: start) else { return }
        let record           = CKRecord(recordType: challengeType)
        record["title"]      = title
        record["emoji"]      = emoji
        record["goalType"]   = goalType.rawValue
        record["startDate"]  = start
        record["endDate"]    = end
        record["authorName"] = username
        if let filter = activityFilter { record["activityFilter"] = filter }
        switch goalType {
        case .steps:
            record["goalSteps"] = goalSteps
        case .distance:
            record["goalSteps"]          = 0
            record["goalDistanceMeters"] = goalDistanceMeters
        case .pace:
            record["goalSteps"]         = 0
            record["goalPaceSecsPerKm"] = goalPaceSecsPerKm
            record["goalSessionCount"]  = goalSessionCount
        }
        _ = try await db.save(record)
    }

    // MARK: - Join / update progress

    func hasJoined(_ challenge: WalkChallenge) -> Bool {
        joinedEntries[challenge.id.recordName] != nil
    }

    func joinOrUpdate(_ challenge: WalkChallenge, steps: Int) async throws {
        let key = challenge.id.recordName
        if let existingName = joinedEntries[key] {
            let record      = try await db.record(for: CKRecord.ID(recordName: existingName))
            record["steps"] = steps
            _ = try await db.save(record)
        } else {
            let record                    = CKRecord(recordType: entryType)
            record["challengeRecordName"] = key
            record["displayName"]         = username
            record["steps"]               = steps
            record["deviceID"]            = deviceID
            let saved = try await db.save(record)
            storeJoin(challengeKey: key, entryName: saved.recordID.recordName)
        }
    }

    // MARK: - HealthKit step fetch (step-type challenges only)

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
