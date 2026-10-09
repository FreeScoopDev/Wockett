import CloudKit
import Foundation
import os

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

enum WockettCloud {
    /// The app's CloudKit container. (Older files still spell it out.)
    static let containerID = "iCloud.Scoops.PoCSquat"
}

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

/// One vote record as read back: the item it names, its record name, and the
/// iCloud user record that created it.
struct StoredVote: Equatable {
    let target: String
    let recordName: String
    let creator: String?
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

    /// Counts votes per item. A vote counts only when the iCloud user who
    /// created it is the voter its name says (CloudKit names your own records'
    /// creator `CKCurrentUserDefaultName`), so a client can't add votes under
    /// made-up names; each (item, voter) pair counts once; and a vote whose
    /// name doesn't match its item is not counted.
    static func tally(_ votes: [StoredVote], me: String?) -> VoteTally {
        var seen = Set<String>()
        var tally = VoteTally()
        for vote in votes {
            guard let voter = voter(fromRecordName: vote.recordName, target: vote.target),
                  vote.creator == voter || (vote.creator == CKCurrentUserDefaultName && voter == me),
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

    /// What to tell someone whose vote didn't save. Signed out of iCloud is
    /// its own answer: "check your connection" would send them the wrong way.
    static func failureMessage(_ error: Error, noun: String) -> String {
        if (error as? CKError)?.code == .notAuthenticated {
            return "Sign in to iCloud in the Settings app to give a \(noun)."
        }
        return "Couldn't save your \(noun). Check your connection and try again."
    }
}

// MARK: - On screen

/// Where this device remembers what it voted for. A seam: tests keep marks in
/// memory, because the real lists are app settings other code reads (the
/// "Wockett Giver" badge counts the voted-routes list), and a test writing
/// them races every test that reads them.
struct VoteMarks {
    var has: (CKRecord.ID) -> Bool
    var mark: (CKRecord.ID) -> Void
    var unmark: (CKRecord.ID) -> Void

    static var likes: VoteMarks {
        VoteMarks(has: { AchievementFeedService.shared.hasLiked(id: $0) },
                  mark: { AchievementFeedService.shared.markLiked(id: $0) },
                  unmark: { AchievementFeedService.shared.unmarkLiked(id: $0) })
    }
    static var wocketts: VoteMarks {
        VoteMarks(has: { CommunityRouteService.shared.hasVoted(for: $0) },
                  mark: { CommunityRouteService.shared.markVoted(for: $0) },
                  unmark: { CommunityRouteService.shared.unmarkVoted(for: $0) })
    }
}

/// A like or Wockett shows at once and is saved behind it. If saving fails,
/// it is taken back from the item with this id, wherever that item is now,
/// and never below 0: the list may have been refreshed or had a row removed
/// while the save was in flight, so its position can't be trusted (critic,
/// 2026-10-09), and a refreshed count never included the vote at all.
@MainActor
enum OptimisticVote {
    @discardableResult
    static func apply(id: CKRecord.ID,
                      change: @escaping (CKRecord.ID, Int) -> Void,
                      mark: @escaping (CKRecord.ID) -> Void,
                      unmark: @escaping (CKRecord.ID) -> Void,
                      save: @escaping (CKRecord.ID) async throws -> Void,
                      failed: @escaping (Error) -> Void) -> Task<Void, Never> {
        change(id, 1)
        mark(id)
        return Task {
            do {
                try await save(id)
            } catch {
                unmark(id)
                change(id, -1)
                failed(error)
            }
        }
    }

    /// Adds `delta` to the count of the item with `id`, if it is still listed,
    /// keeping the count at 0 or more.
    static func adjust<Item>(_ items: inout [Item], id: CKRecord.ID, by delta: Int,
                             idPath: KeyPath<Item, CKRecord.ID>, count: WritableKeyPath<Item, Int>) {
        guard let i = items.firstIndex(where: { $0[keyPath: idPath] == id }) else { return }
        items[i][keyPath: count] = max(0, items[i][keyPath: count] + delta)
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
    func votes(for targets: [String]) async throws -> [StoredVote]
}

final class CloudKitCommunityVoteStore: CommunityVoteStore {
    private let container = CKContainer(identifier: WockettCloud.containerID)
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

    func votes(for targets: [String]) async throws -> [StoredVote] {
        guard !targets.isEmpty else { return [] }
        let query = CKQuery(recordType: CommunityVotes.recordType,
                            predicate: NSPredicate(format: "targetRecordName IN %@", targets))
        var out: [StoredVote] = []
        func collect(_ results: [(CKRecord.ID, Result<CKRecord, Error>)]) {
            for (id, result) in results {
                if let record = try? result.get(), let target = record["targetRecordName"] as? String {
                    out.append(StoredVote(target: target, recordName: id.recordName,
                                          creator: record.creatorUserRecordID?.recordName))
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
    private let log = Logger(subsystem: "com.wockett.app", category: "CommunityVotes")
    /// How long counts may hold up a feed before it shows with 0s.
    private let tallyTimeout: Duration

    init(store: CommunityVoteStore, tallyTimeout: Duration = .seconds(6),
         notifications: NotificationCenter = .default) {
        self.store = store
        self.tallyTimeout = tallyTimeout
        // iOS doesn't restart the app when the iCloud account changes; a
        // remembered user would file the new person's votes under the old one.
        notifications.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cachedUser = nil }
        }
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
        guard !targets.isEmpty else { return VoteTally() }
        let store = self.store
        let timeout = tallyTimeout
        let votes: [StoredVote]?
        do {
            votes = try await withThrowingTaskGroup(of: [StoredVote]?.self) { group in
                group.addTask { try await store.votes(for: targets) }
                group.addTask { try await Task.sleep(for: timeout); return nil }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } catch {
            log.error("Vote counts unavailable: \(error.localizedDescription, privacy: .public)")
            return VoteTally()
        }
        guard let votes else {
            log.error("Vote counts timed out; showing 0s")
            return VoteTally()
        }
        return CommunityVotes.tally(votes, me: try? await me())
    }
}
