import CloudKit
import Foundation

// MARK: - Delete my community data
//
// Audit 2026-10-12, finding 15: you could delete your routes, posts, entries
// and challenges one at a time, but not your community name or your votes,
// and nothing deleted everything at once. Settings > Community > Delete my
// community data does, for the signed-in iCloud account.
//
// What is yours is found two ways and both are deleted: a query for every
// record of the type your account created (needs `___createdBy` QUERYABLE
// on the type, in cloudkit/schema.ckdb), and the records this phone already
// remembers creating, so those still go if the query fails.
//
// Only the public database. Your walks, pets, routes and the private share
// offset are private iCloud data and are never touched here.

/// One kind of public record you can create and this deletes.
enum CommunityDataKind: String, CaseIterable, Identifiable {
    case votes
    case posts
    case routes
    case entries
    case challenges
    case name

    var id: String { rawValue }

    var recordType: String {
        switch self {
        case .votes: return CommunityVotes.recordType
        case .posts: return "WocketAchievement"
        case .routes: return CommunityRouteService.recordType
        case .entries: return ChallengeService.entryType
        case .challenges: return "Challenge"
        case .name: return CommunityNames.recordType
        }
    }

    var title: String {
        switch self {
        case .votes: return "Likes and Wocketts"
        case .posts: return "Achievement posts"
        case .routes: return "Shared routes"
        case .entries: return "Challenge entries"
        case .challenges: return "Challenges you created"
        case .name: return "Community name"
        }
    }

    var progress: String { "Deleting \(title.lowercased())…" }
}

/// A public record type you create but cannot delete from the app.
struct UndeletableCommunityType: Equatable {
    let recordType: String
    let title: String
}

enum CommunityDataDeletion {
    /// What the delete covers, in the order it runs: entries before
    /// challenges, so your own entry doesn't count as someone else's, and the
    /// name last.
    static let kinds: [CommunityDataKind] = [.votes, .posts, .routes, .entries, .challenges, .name]

    /// Created with CREATE only: the schema gives the creator no READ or
    /// WRITE, so the app can neither find nor delete them. A moderator can.
    static let undeletable: [UndeletableCommunityType] = [
        UndeletableCommunityType(recordType: "CommunityReport", title: "Reports you sent"),
        UndeletableCommunityType(recordType: "TrailNomination", title: "Trail suggestions you sent")
    ]

    static let title = "Delete my community data"
    static let confirmTitle = "Delete all your community data?"
    static let confirmMessage = "This removes everything you shared in Community, for everyone: routes, posts, challenge entries, challenges only you are in, likes and Wocketts, and your community name. Your walks and pets stay. It can't be undone."
    static let explanation = "Deletes everything your iCloud account shared in Community. Your walks, pets and routes on this iPhone stay."
    static let undeletableNote = "Reports and trail suggestions you sent can't be deleted from the app: only the Wockett team can see them. Email us to have them removed."
    static let signInMessage = "Sign in to iCloud in the Settings app, then try again."
    /// How long one kind may take before it's reported as timed out.
    static let deadline: Duration = .seconds(30)

    /// The email for anything the app couldn't delete. Carries the account ID
    /// a moderator needs to find your records, which the app shows nowhere else.
    static func supportMailURL(account: String?) -> URL? {
        var body = "Please delete my Wockett community data."
        if let account { body += "\n\nMy community account ID: \(account)" }
        return SupportContact.mailURL(subject: "Delete my community data", body: body)
    }

    /// The records this phone remembers creating, for the kinds it tracks.
    static func remembered(_ kind: CommunityDataKind, me: String, defaults: UserDefaults) -> [CKRecord.ID] {
        let names: [String]
        switch kind {
        case .routes:
            names = defaults.stringArray(forKey: CommunityRouteService.publishedKey) ?? []
        case .entries:
            names = ((defaults.dictionary(forKey: ChallengeService.joinedKey) as? [String: String]) ?? [:]).values.sorted()
        case .votes:
            let targets = (defaults.stringArray(forKey: AchievementFeedService.likedKey) ?? [])
                        + (defaults.stringArray(forKey: CommunityRouteService.votedKey) ?? [])
            names = targets.map { CommunityVotes.recordName(target: $0, voter: me) }
        case .name:
            guard defaults.string(forKey: CommunityNameService.claimedOwnerKey) == me,
                  let claimed = defaults.string(forKey: CommunityNameService.claimedKey) else { return [] }
            names = [CommunityNames.recordName(for: claimed)]
        case .posts, .challenges:
            names = []
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }.map { CKRecord.ID(recordName: $0) }
    }

    /// Plain words for a CloudKit failure.
    static func message(for error: Error) -> String {
        switch (error as? CKError)?.code {
        case .notAuthenticated?: return signInMessage
        case .permissionFailure?: return "Only the account that shared it can delete it."
        default: return "Couldn't reach iCloud. Check your connection and try again."
        }
    }
}

// MARK: - Result

/// What happened to one kind.
struct CommunityDataKindResult: Equatable {
    let kind: CommunityDataKind
    var deleted = 0
    /// Challenges others joined: sent to the Wockett team to remove.
    var requested = 0
    var failures: [String] = []

    var summary: String {
        var parts: [String] = []
        if deleted > 0 { parts.append("\(deleted) deleted") }
        if requested > 0 {
            parts.append("\(requested) others had joined, so the Wockett team was asked to remove \(requested == 1 ? "it" : "them")")
        }
        if parts.isEmpty && failures.isEmpty { parts.append("nothing to delete") }
        return parts.joined(separator: "; ")
    }
}

struct CommunityDataDeletionReport: Equatable {
    var results: [CommunityDataKindResult] = []
    /// Set when nothing could start (signed out of iCloud).
    var stopped: String?

    var hasFailures: Bool { stopped != nil || results.contains { !$0.failures.isEmpty } }
}

// MARK: - Store seam

/// The public-database side, behind a protocol so the rules are tested
/// without a network or an iCloud account (CI has neither).
protocol CommunityDataStore: AnyObject {
    func currentUser() async throws -> String
    /// Every record of `type` that `account` created, all pages.
    func records(ofType type: String, createdBy account: String) async throws -> [CKRecord]
    /// Deletes `ids`; per record, nil when it's gone (or already was) and
    /// the error otherwise.
    func delete(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Error?]
}

final class CloudKitCommunityDataStore: CommunityDataStore {
    private let container = CKContainer(identifier: WockettCloud.containerID)
    private var db: CKDatabase { container.publicCloudDatabase }

    func currentUser() async throws -> String {
        try await container.userRecordID().recordName
    }

    func records(ofType type: String, createdBy account: String) async throws -> [CKRecord] {
        let me = CKRecord.Reference(recordID: CKRecord.ID(recordName: account), action: .none)
        let query = CKQuery(recordType: type, predicate: NSPredicate(format: "creatorUserRecordID == %@", me))
        var out: [CKRecord] = []
        var (results, cursor) = try await db.records(matching: query, resultsLimit: CKQueryOperation.maximumResults)
        out += results.compactMap { try? $0.1.get() }
        while let next = cursor {
            try Task.checkCancellation()
            (results, cursor) = try await db.records(continuingMatchFrom: next, resultsLimit: CKQueryOperation.maximumResults)
            out += results.compactMap { try? $0.1.get() }
        }
        return out
    }

    func delete(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Error?] {
        var out: [CKRecord.ID: Error?] = [:]
        // CloudKit takes at most 400 records per request.
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start..<min(start + 400, ids.count)])
            let (_, deletes) = try await db.modifyRecords(saving: [], deleting: chunk, atomically: false)
            for (id, result) in deletes {
                switch result {
                case .success: out[id] = .some(nil)
                case .failure(let error): out[id] = .some(error)
                }
            }
        }
        return out
    }
}

// MARK: - Run

@MainActor
struct CommunityDataDeletionRun {
    var store: CommunityDataStore = CloudKitCommunityDataStore()
    var defaults: UserDefaults = .standard
    var moderation: CommunityModerationStore = .shared
    /// Whether a challenge can be deleted or must be asked for (others joined).
    var plan: (WalkChallenge) async -> ChallengeDeletion.Plan = { await ChallengeDeletion.plan(for: $0) }
    var request: (WalkChallenge, Int) async -> ChallengeDeletion.RequestOutcome = {
        await ChallengeDeletion.request($0, others: $1)
    }
    /// Called once the name claim is deleted.
    var nameDeleted: () -> Void = { CommunityNameService.shared.startOver() }
    var sleep: OptimisticVote.Sleep = { try await Task.sleep(for: $0) }
    var kinds: [CommunityDataKind] = CommunityDataDeletion.kinds

    /// Deletes every kind in turn, telling `progress` which is running.
    func run(progress: (CommunityDataKind) -> Void = { _ in }) async -> CommunityDataDeletionReport {
        let me: String
        do {
            me = try await store.currentUser()
        } catch {
            return CommunityDataDeletionReport(stopped: (error as? CKError)?.code == .notAuthenticated
                                               ? CommunityDataDeletion.signInMessage
                                               : CommunityDataDeletion.message(for: error))
        }
        var report = CommunityDataDeletionReport()
        for kind in kinds {
            progress(kind)
            let result: CommunityDataKindResult?
            do {
                result = try await OptimisticVote.withDeadline(CommunityDataDeletion.deadline, sleep: sleep) {
                    await self.delete(kind, me: me)
                }
            } catch {
                result = nil
            }
            report.results.append(result ?? CommunityDataKindResult(
                kind: kind, failures: ["That took too long. Check your connection and try again."]))
        }
        // Votes are gone; the one-time catch-up must never send them again.
        defaults.set(true, forKey: UnsentVoteCatchUp.doneKey)
        return report
    }

    private func delete(_ kind: CommunityDataKind, me: String) async -> CommunityDataKindResult {
        var result = CommunityDataKindResult(kind: kind)
        var found: [CKRecord] = []
        do {
            found = try await store.records(ofType: kind.recordType, createdBy: me)
        } catch {
            result.failures.append("Couldn't look them all up (\(CommunityDataDeletion.message(for: error))) Any this iPhone remembers were still deleted.")
        }
        var ids = found.map(\.recordID)
        for id in CommunityDataDeletion.remembered(kind, me: me, defaults: defaults) where !ids.contains(id) {
            ids.append(id)
        }

        if kind == .challenges {
            ids = await sortChallenges(found, into: &result)
        }
        guard !ids.isEmpty else { return result }

        let outcomes: [CKRecord.ID: Error?]
        do {
            outcomes = try await store.delete(ids)
        } catch {
            result.failures.append(CommunityDataDeletion.message(for: error))
            return result
        }
        let queried = Set(found.map(\.recordID))
        var gone: [CKRecord.ID] = []
        for id in ids {
            guard let outcome = outcomes[id] else {
                result.failures.append(CommunityDataDeletion.message(for: CKError(.networkFailure)))
                continue
            }
            if let error = outcome {
                if (error as? CKError)?.code == .unknownItem {
                    // Already gone. Counted only if the query had found it: a
                    // remembered vote name may never have been saved at all.
                    gone.append(id)
                    if queried.contains(id) { result.deleted += 1 }
                } else {
                    result.failures.append(CommunityDataDeletion.message(for: error))
                }
            } else {
                gone.append(id)
                result.deleted += 1
            }
        }
        var seen = Set<String>()
        result.failures = result.failures.filter { seen.insert($0).inserted }
        forget(gone, kind: kind)
        return result
    }

    /// Challenges only you are in are returned to delete; one others joined
    /// gets the owner request instead (Joe, 2026-10-11) and is left alone.
    private func sortChallenges(_ records: [CKRecord], into result: inout CommunityDataKindResult) async -> [CKRecord.ID] {
        var toDelete: [CKRecord.ID] = []
        for record in records {
            guard let challenge = WalkChallenge(record: record) else {
                toDelete.append(record.recordID)   // unreadable, but yours: nothing to show anyone
                continue
            }
            switch await plan(challenge) {
            case .delete:
                toDelete.append(challenge.id)
            case .request(let others):
                switch await request(challenge, others) {
                case .sent, .alreadySent: result.requested += 1
                case .failed(let text): result.failures.append(text)
                }
            case .failed(let text):
                result.failures.append(text)
            }
        }
        return toDelete
    }

    /// Clears what this phone remembers about records now gone, and drops
    /// them from every list at once.
    private func forget(_ gone: [CKRecord.ID], kind: CommunityDataKind) {
        guard !gone.isEmpty else { return }
        for id in gone where kind != .votes && kind != .name {
            moderation.markDeleted(id)
        }
        switch kind {
        case .routes:
            for id in gone { CommunityDeletion.forget(CommunityDeletionRequest(kind: .route, recordID: id), defaults: defaults) }
        case .entries:
            let joined = (defaults.dictionary(forKey: ChallengeService.joinedKey) as? [String: String]) ?? [:]
            let names = Set(gone.map(\.recordName))
            for (challenge, entry) in joined where names.contains(entry) {
                CommunityDeletion.forget(CommunityDeletionRequest(kind: .entry(challengeKey: challenge),
                                                                  recordID: CKRecord.ID(recordName: entry)),
                                         defaults: defaults)
            }
        case .name:
            nameDeleted()
        case .votes, .posts, .challenges:
            // Vote marks stay: the Wockett Giver badge counts them.
            break
        }
    }
}
