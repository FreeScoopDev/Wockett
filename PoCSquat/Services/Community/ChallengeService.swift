import Foundation
import CloudKit

// MARK: - Challenge Goal Type

enum ChallengeGoalType: String, CaseIterable {
    case steps    = "steps"
    case distance = "distance"
    case pace     = "pace"
}

// MARK: - Formatting helpers (shared between service and view)

/// Whole units from 10 up, one decimal below. A goal rounds to the nearest
/// (the "13 mi" option is 20,921 m, 12.9997 mi, and truncating showed 12);
/// progress passes `.down` so it never reads as the goal before it is.
func challengeFormattedDistance(
    _ meters: Double,
    locale: Locale = .current,
    rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero
) -> String {
    let useMetric = locale.measurementSystem != .us
    let value = useMetric ? meters / 1000 : meters / 1609.34
    let unit = useMetric ? "km" : "mi"
    // Decide the branch on the value as shown, so 9.96 reads "10 mi", not "10.0 mi".
    let tenths = (value * 10).rounded(rule) / 10
    return tenths >= 10
        ? "\(Int(value.rounded(rule))) \(unit)"
        : String(format: "%.1f %@", tenths, unit)
}

func challengeFormattedPace(_ secsPerKm: Double, locale: Locale = .current) -> String {
    let useMetric = locale.measurementSystem != .us
    let displaySecs = useMetric ? secsPerKm : secsPerKm * 1.60934
    let unit = useMetric ? "/km" : "/mi"
    let mins = Int(displaySecs) / 60
    let secs = Int(displaySecs) % 60
    return String(format: "%d:%02d%@", mins, secs, unit)
}

// MARK: - Sync copy

/// The line under a challenge's sync button: where its total comes from and
/// that it is public. Steps used to be Apple Health's; since 1.16 every goal
/// counts walks recorded in Wockett (2026-10-12 audit, finding 2).
enum ChallengeSyncCopy {
    static func footnote(for goalType: ChallengeGoalType) -> String {
        let counted: String
        switch goalType {
        case .steps:    counted = "the steps of walks and runs you recorded in Wockett"
        case .distance: counted = "the distance of activities you recorded in Wockett"
        case .pace:     counted = "activities you recorded in Wockett"
        }
        return "Counts \(counted) since the challenge began, not Apple Health. "
            + "Your total and display name show on the public leaderboard."
    }
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
    /// The account that created it (CloudKit's creator), for Block.
    let authorAccount: String?
    var author: CommunityAuthor { CommunityAuthor(name: authorName, account: authorAccount) }

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
            return "\(formattedDistanceProgress(value)) / \(challengeFormattedDistance(goalDistanceMeters))"
        case .pace:
            let noun = activityFilter == "running" ? "run" : "session"
            return "\(value) / \(goalSessionCount) qualifying \(noun)\(goalSessionCount == 1 ? "" : "s")"
        }
    }

    func leaderboardDisplay(for value: Int) -> String {
        switch goalType {
        case .steps:    return value.formatted()
        case .distance: return formattedDistanceProgress(value)
        case .pace:
            let noun = activityFilter == "running" ? "run" : "session"
            return "\(value) \(noun)\(value == 1 ? "" : "s")"
        }
    }

    /// Progress rounds down until the goal is reached, so 12.6 of 13 mi is not
    /// "13 mi / 13 mi"; from then on it rounds like the goal, so 20,921 m reads "13 mi".
    func formattedDistanceProgress(_ meters: Int, locale: Locale = .current) -> String {
        let reached = Double(meters) >= goalDistanceMeters
        return challengeFormattedDistance(Double(meters), locale: locale,
                                          rule: reached ? .toNearestOrAwayFromZero : .down)
    }

    // Returns the value to write into ChallengeEntry.steps, from walks recorded in Wockett.
    //   .steps    → steps of those walks and runs (pedometer count, or distance / 0.762 m
    //               before 1.7); rides never count, and any activity filter is ignored: the
    //               create sheet never offers one for steps, but kept a leftover from another
    //               goal type, so a stray "cycling" would have pinned everyone at 0. Not Apple
    //               Health: the total is public (2026-10-12 audit, finding 2).
    //   .distance → total metres walked/run (flaggedPossibleVehicle excluded)
    //   .pace     → count of sessions where pace beat the goalPaceSecsPerKm threshold
    func localProgressValue(from sessions: [WalkSession]) -> Int {
        let inWindow = sessions.filter {
            $0.date >= startDate &&
            $0.date <= endDate &&
            !$0.flaggedPossibleVehicle
        }
        let window = inWindow.filter { activityFilter == nil || $0.activityType == activityFilter }
        switch goalType {
        case .steps:
            return inWindow
                .filter { $0.activityType != ActivityMode.cycling.rawValue }
                .reduce(0) { $0 + $1.estimatedSteps }
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

    /// `creator` is a seam for tests (records built in a test have none).
    init?(record: CKRecord, creator: CKRecord.ID? = nil) {
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
        self.authorAccount = CommunityAuthor.account(of: record, creator: creator)

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
    /// The per-install ID entries carried before 1.16; the placeholder "-" on newer ones.
    let deviceID:    String
    let joinedAt:    Date
    /// The account that created the entry (CloudKit's creator), for suspensions.
    let account:     String?

    /// Your own entry: on this install's leaderboard as "You", and your rank.
    var isCurrentDevice: Bool {
        isMine(moderation: .shared, joinedEntryNames: ChallengeService.shared.joinedEntryNames,
               legacyDeviceID: ChallengeService.shared.legacyDeviceID)
    }

    /// Yours when CloudKit says your account created it (the check every
    /// community type uses), when it is the entry this install joined with, or,
    /// for an entry written before 1.16, when it carries the device ID this
    /// install stored then. `deviceID` is no longer written (audit finding 22).
    func isMine(moderation: CommunityModerationStore, joinedEntryNames: Set<String>,
                legacyDeviceID: String?) -> Bool {
        if moderation.isMine(CommunityAuthor(name: displayName, account: account)) { return true }
        if joinedEntryNames.contains(id.recordName) { return true }
        guard !deviceID.isEmpty, let legacyDeviceID else { return false }
        return deviceID == legacyDeviceID
    }

    /// `creator` is a seam for tests (records built in a test have none).
    init?(record: CKRecord, creator: CKRecord.ID? = nil) {
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
        self.account     = CommunityAuthor.account(of: record, creator: creator)
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
//                                (all from walks recorded in Wockett since 1.16, never Apple Health)
//   deviceID             String  "-" since 1.16. Still written, because 1.14 and 1.15 drop an
//                                entry without it; an entry's old value is cleared on its next sync.

final class ChallengeService {
    static let shared = ChallengeService()
    private init() {}

    private let db            = CKContainer(identifier: "iCloud.Scoops.PoCSquat").publicCloudDatabase
    private let challengeType = "Challenge"
    static let entryType      = "ChallengeEntry"
    private var entryType: String { Self.entryType }
    /// [challengeRecordName: entryRecordName]. Static: deleting your entry clears it (CommunityDeletion).
    static let joinedKey = "wkt_joinedChallengeEntries_v1"
    private var joinedKey: String { Self.joinedKey }

    /// The per-install ID that 1.14 and 1.15 wrote on every entry, if this
    /// install made one. Read only, to recognise those older entries as
    /// yours; nothing creates one any more, and nothing publishes it.
    var legacyDeviceID: String? { UserDefaults.standard.string(forKey: Self.legacyDeviceIDKey) }
    static let legacyDeviceIDKey = "wkt_deviceID"

    /// What every entry's `deviceID` holds since 1.16: the same placeholder on
    /// every install, so it identifies nobody. The field stays because 1.14 and
    /// 1.15 skip an entry that lacks it; a placeholder rather than "" so the
    /// field can't come back from the server as absent.
    static let publishedDeviceID = "-"

    // MARK: - Fetch

    func fetchActiveChallenges() async throws -> [WalkChallenge] {
        // Suspended accounts are hidden by the filter below: have the list current.
        await SuspensionService.shared.refreshIfStale()
        let pred  = NSPredicate(format: "endDate >= %@", Date() as CVarArg)
        let query = CKQuery(recordType: challengeType, predicate: pred)
        query.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: true)]
        let (results, _) = try await db.records(matching: query, resultsLimit: 40)
        return results.compactMap { _, r -> WalkChallenge? in
            guard let rec = try? r.get() else { return nil }
            return WalkChallenge(record: rec)
        }
        .filter { !CommunityModerationStore.shared.shouldHide(id: $0.id, author: $0.author) }
    }

    /// One challenge by record name, for a challenge link. Nil when it does not
    /// exist, has ended, or is one the list would hide (blocked, suspended,
    /// deleted), so a link never opens what Community → Challenges keeps out.
    func fetchChallenge(recordName: String) async throws -> WalkChallenge? {
        guard ChallengeLink.isValid(recordName) else { return nil }
        await SuspensionService.shared.refreshIfStale()
        let record: CKRecord
        do {
            record = try await db.record(for: CKRecord.ID(recordName: recordName))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        return Self.linkable(record, moderation: .shared)
    }

    /// The challenge a link may open: a Challenge record that is still running
    /// and not one the list hides (reported, deleted, blocked, suspended).
    /// `creator` and `now` are seams for tests.
    static func linkable(_ record: CKRecord, creator: CKRecord.ID? = nil, now: Date = Date(),
                         moderation: CommunityModerationStore) -> WalkChallenge? {
        guard record.recordType == "Challenge",
              let challenge = WalkChallenge(record: record, creator: creator),
              challenge.endDate >= now,
              !moderation.shouldHide(id: challenge.id, author: challenge.author)
        else { return nil }
        return challenge
    }

    func fetchLeaderboard(for challenge: WalkChallenge) async throws -> [ChallengeParticipant] {
        // Suspended accounts are hidden by the filter below: have the list current.
        await SuspensionService.shared.refreshIfStale()
        let pred  = NSPredicate(format: "challengeRecordName == %@", challenge.id.recordName)
        let query = CKQuery(recordType: entryType, predicate: pred)
        query.sortDescriptors = [NSSortDescriptor(key: "steps", ascending: false)]
        let (results, _) = try await db.records(matching: query, resultsLimit: 100)
        let participants = results.compactMap { _, r -> ChallengeParticipant? in
            guard let rec = try? r.get() else { return nil }
            return ChallengeParticipant(record: rec)
        }
        return Self.visible(participants, moderation: .shared)
    }

    /// A leaderboard without the entries of accounts you blocked or a
    /// moderator suspended, or ones you deleted, most steps first. Block was
    /// missing until 2026-10-12: someone you blocked vanished from every
    /// Community list but still sat on your challenge's leaderboard. Your own
    /// entry is never hidden (both checks exclude your own content).
    static func visible(_ participants: [ChallengeParticipant], moderation: CommunityModerationStore,
                        now: Date = Date()) -> [ChallengeParticipant] {
        participants
            .filter {
                let author = CommunityAuthor(name: $0.displayName, account: $0.account)
                return !moderation.isBlocked(author) && !moderation.isSuspended(author, at: now)
            }
            .filter { !moderation.isDeleted($0.id) }
            .sorted { $0.steps > $1.steps }
    }

    // MARK: - Create

    /// Saves a new challenge and returns it as saved, so the list can show it
    /// before CloudKit's query index catches up (see `withJustCreated`).
    @discardableResult
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
    ) async throws -> WalkChallenge? {
        try ContentFilter.validate(name: title)
        try await SuspensionService.shared.ensureCanPost()
        let cal   = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: durationDays, to: start) else { return nil }
        let record           = CKRecord(recordType: challengeType)
        record["title"]      = title
        record["emoji"]      = emoji
        record["goalType"]   = goalType.rawValue
        record["startDate"]  = start
        record["endDate"]    = end
        record["authorName"] = try await CommunityNameService.shared.claimedName()
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
        return WalkChallenge(record: try await db.save(record))
    }

    /// The list as fetched, plus challenges this screen just created that the
    /// fetch left out. CloudKit's query index takes a few seconds to include a
    /// new record, so the reload after "Create Challenge" usually misses it
    /// (Joe, 2026-10-12: it showed only after leaving and reopening the list).
    /// Ended ones drop out; order is the query's, start date first.
    static func withJustCreated(_ fetched: [WalkChallenge], justCreated: [WalkChallenge],
                                now: Date = Date()) -> [WalkChallenge] {
        let missing = justCreated.filter { new in
            new.endDate >= now && !fetched.contains { $0.id == new.id }
        }
        guard !missing.isEmpty else { return fetched }
        return (fetched + missing).sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Join / update progress

    func hasJoined(_ challenge: WalkChallenge) -> Bool {
        joinedEntries[challenge.id.recordName] != nil
    }

    func joinOrUpdate(_ challenge: WalkChallenge, steps: Int) async throws {
        let key = challenge.id.recordName
        if let existingName = joinedEntries[key] {
            let record = try await db.record(for: CKRecord.ID(recordName: existingName))
            _ = try await db.save(Self.updated(record, steps: steps))
        } else {
            // Joining is posting; updating steps on an entry already there
            // isn't blocked (it is hidden anyway while suspended).
            try await SuspensionService.shared.ensureCanPost()
            let record = Self.entryRecord(challengeKey: key,
                                          displayName: try await CommunityNameService.shared.claimedName(),
                                          steps: steps)
            let saved = try await db.save(record)
            storeJoin(challengeKey: key, entryName: saved.recordID.recordName)
        }
    }

    /// An existing entry with a new total. An entry from 1.14 or 1.15 also
    /// loses the device ID it was published with.
    static func updated(_ record: CKRecord, steps: Int) -> CKRecord {
        record["steps"]    = steps
        record["deviceID"] = publishedDeviceID
        return record
    }

    /// A new leaderboard entry: the challenge, your display name and your
    /// total, and the placeholder `deviceID` (see `publishedDeviceID`).
    static func entryRecord(challengeKey: String, displayName: String, steps: Int) -> CKRecord {
        let record                    = CKRecord(recordType: entryType)
        record["challengeRecordName"] = challengeKey
        record["displayName"]         = displayName
        record["steps"]               = steps
        record["deviceID"]            = publishedDeviceID
        return record
    }

    // MARK: - Persistence helpers

    private var joinedEntries: [String: String] {
        UserDefaults.standard.dictionary(forKey: joinedKey) as? [String: String] ?? [:]
    }

    /// The record names of the entries this install joined with.
    var joinedEntryNames: Set<String> { Set(joinedEntries.values) }

    private func storeJoin(challengeKey: String, entryName: String) {
        var d = joinedEntries
        d[challengeKey] = entryName
        UserDefaults.standard.set(d, forKey: joinedKey)
    }
}

extension WalkChallenge: CommunityModerated {}
