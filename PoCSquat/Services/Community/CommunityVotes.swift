import CloudKit
import Foundation

// MARK: - Community votes
//
// A like on an achievement post or a Wockett on a shared route is a small
// `CommunityVote` record in the public database, created by the voter.
// Until 2026-10-09 the app added one to a counter on the post or route record
// itself, but the public database lets only a record's creator write it, so
// every vote from anyone but the author failed (likes silently).
//
// One vote per person per item: the record name is built from the item and the
// voter's iCloud user record, so a second vote, from any of their devices, is
// the same record and CloudKit refuses it as already existing. That refusal is
// treated as success.
//
// Production needs the record type and a QUERYABLE index on
// `targetRecordName` (CloudKit Console) before a build with this ships.

enum VoteTarget: String {
    case post
    case route
}

/// Votes for a set of items: how many each has, and which this user voted for.
struct VoteTally: Equatable {
    var counts: [String: Int] = [:]
    var mine: Set<String> = []

    func count(for target: String) -> Int { counts[target] ?? 0 }
}

enum CommunityVotes {
    static let recordType = "CommunityVote"

    /// `vote.<item>.<voter>`. Both parts are CloudKit record names (a UUID and
    /// an `_`-prefixed hash), which contain no dots.
    static func recordName(target: String, voter: String) -> String {
        "vote.\(target).\(voter)"
    }

    /// The voter part of a vote's record name, or nil for a name not built by
    /// `recordName(target:voter:)`.
    static func voter(fromRecordName name: String, target: String) -> String? {
        let prefix = "vote.\(target)."
        guard name.hasPrefix(prefix) else { return nil }
        let voter = String(name.dropFirst(prefix.count))
        return voter.isEmpty ? nil : voter
    }

    /// Counts votes per item. Each (item, voter) pair counts once, however
    /// many times it appears; a vote whose name doesn't match its item is not
    /// counted, so a record can't vote for an item it doesn't name.
    static func tally(_ votes: [(target: String, recordName: String)], me: String?) -> VoteTally {
        var seen = Set<String>()
        var tally = VoteTally()
        for vote in votes {
            guard let voter = voter(fromRecordName: vote.recordName, target: vote.target),
                  seen.insert("\(vote.target)\u{0}\(voter)").inserted else { continue }
            tally.counts[vote.target, default: 0] += 1
            if voter == me { tally.mine.insert(vote.target) }
        }
        return tally
    }

    /// CloudKit's answer to saving a record name that already exists: this
    /// person has already voted for the item.
    static func isAlreadyVoted(_ error: Error) -> Bool {
        (error as? CKError)?.code == .serverRecordChanged
    }
}

// MARK: - Store seam

/// The CloudKit side, behind a protocol so the rules above are tested
/// without a network or an iCloud account (CI has neither).
protocol CommunityVoteStore: AnyObject {
    /// The iCloud user record name of whoever is signed in.
    func currentUserRecordName() async throws -> String
    /// Creates the vote record; throws CloudKit's error when it exists.
    func saveVote(recordName: String, target: String, type: VoteTarget) async throws
    /// Every vote naming one of `targets`, all pages.
    func votes(for targets: [String]) async throws -> [(target: String, recordName: String)]
}

final class CloudKitCommunityVoteStore: CommunityVoteStore {
    private let container = CKContainer(identifier: "iCloud.Scoops.PoCSquat")
    private var db: CKDatabase { container.publicCloudDatabase }

    func currentUserRecordName() async throws -> String {
        try await container.userRecordID().recordName
    }

    func saveVote(recordName: String, target: String, type: VoteTarget) async throws {
        let record = CKRecord(recordType: CommunityVotes.recordType, recordID: CKRecord.ID(recordName: recordName))
        record["targetRecordName"] = target
        record["targetType"] = type.rawValue
        _ = try await db.save(record)
    }

    func votes(for targets: [String]) async throws -> [(target: String, recordName: String)] {
        guard !targets.isEmpty else { return [] }
        let query = CKQuery(recordType: CommunityVotes.recordType,
                            predicate: NSPredicate(format: "targetRecordName IN %@", targets))
        var out: [(target: String, recordName: String)] = []
        func collect(_ results: [(CKRecord.ID, Result<CKRecord, Error>)]) {
            for (id, result) in results {
                if let record = try? result.get(), let target = record["targetRecordName"] as? String {
                    out.append((target, id.recordName))
                }
            }
        }
        var (results, cursor) = try await db.records(matching: query, desiredKeys: ["targetRecordName"],
                                                     resultsLimit: CKQueryOperation.maximumResults)
        collect(results)
        while let next = cursor {
            (results, cursor) = try await db.records(continuingMatchFrom: next, desiredKeys: ["targetRecordName"],
                                                     resultsLimit: CKQueryOperation.maximumResults)
            collect(results)
        }
        return out
    }
}

// MARK: - Service

final class CommunityVoteService {
    static let shared = CommunityVoteService(store: CloudKitCommunityVoteStore())

    private let store: CommunityVoteStore
    private var cachedUser: String?

    init(store: CommunityVoteStore) {
        self.store = store
    }

    private func me() async throws -> String {
        if let cachedUser { return cachedUser }
        let name = try await store.currentUserRecordName()
        cachedUser = name
        return name
    }

    /// Votes for `target`. Voting twice is not an error.
    func vote(for target: String, type: VoteTarget) async throws {
        let voter = try await me()
        do {
            try await store.saveVote(recordName: CommunityVotes.recordName(target: target, voter: voter),
                                     target: target, type: type)
        } catch where CommunityVotes.isAlreadyVoted(error) {
            return
        }
    }

    /// The votes for `targets`. Never throws: when votes can't be read (no
    /// network, not signed in, or Production without the vote type yet) every
    /// count is 0, so the feed or list still shows.
    func tally(for targets: [String]) async -> VoteTally {
        guard !targets.isEmpty, let votes = try? await store.votes(for: targets) else { return VoteTally() }
        return CommunityVotes.tally(votes, me: try? await me())
    }
}
