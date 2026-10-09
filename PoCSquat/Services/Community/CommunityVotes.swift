import CloudKit
import Foundation
import os
import SwiftUI

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
    /// created it is the voter its name says, so a client can't add votes
    /// under made-up names. CloudKit gives your own records the creator
    /// `CKCurrentUserDefaultName`: those count as yours, checked against your
    /// name when it is known (a failed lookup must not drop your own votes).
    /// Each (item, voter) pair counts once; a vote whose name doesn't match
    /// its item is not counted.
    static func tally(_ votes: [StoredVote], me: String?) -> VoteTally {
        var seen = Set<String>()
        var tally = VoteTally()
        for vote in votes {
            guard let voter = voter(fromRecordName: vote.recordName, target: vote.target),
                  vote.creator == voter
                    || (vote.creator == CKCurrentUserDefaultName && (me == nil || voter == me)),
                  seen.insert("\(vote.target)\u{0}\(voter)").inserted else { continue }
            tally.counts[vote.target, default: 0] += 1
            if voter == me || vote.creator == CKCurrentUserDefaultName { tally.mine.insert(vote.target) }
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

/// A like or Wockett shows at once and is saved behind it; screens show an
/// item as voted while it is in `pending` or marked. The owner keeps
/// the ids still saving (`pending`): a refresh mid-save brings the server's
/// count, which can't include the vote yet, so `withPending` adds it back;
/// and a failed save takes back exactly the one it added, from the item with
/// this id wherever it is now (critic, 2026-10-09). One function for every screen.
@MainActor
enum OptimisticVote {
    @discardableResult
    static func vote<Owner: AnyObject, Item>(
        _ id: CKRecord.ID, on owner: Owner,
        list: ReferenceWritableKeyPath<Owner, [Item]>, pending: ReferenceWritableKeyPath<Owner, Set<String>>,
        idPath: KeyPath<Item, CKRecord.ID>, count: WritableKeyPath<Item, Int>, marks: VoteMarks,
        save: @escaping (CKRecord.ID) async throws -> Void,
        failed: @escaping (Error) -> Void
    ) -> Task<Void, Never>? {
        guard !marks.has(id), !owner[keyPath: pending].contains(id.recordName),
              let i = owner[keyPath: list].firstIndex(where: { $0[keyPath: idPath] == id }) else { return nil }
        owner[keyPath: list][i][keyPath: count] += 1
        owner[keyPath: pending].insert(id.recordName)
        return Task { [weak owner] in
            do {
                try await save(id)
                // Remembered only once saved: a mark written first outlives an
                // app killed mid-save, and the item would read voted for good.
                marks.mark(id)
                owner?[keyPath: pending].remove(id.recordName)
            } catch {
                if let owner, owner[keyPath: pending].remove(id.recordName) != nil,
                   let j = owner[keyPath: list].firstIndex(where: { $0[keyPath: idPath] == id }) {
                    owner[keyPath: list][j][keyPath: count] = max(0, owner[keyPath: list][j][keyPath: count] - 1)
                }
                failed(error)
            }
        }
    }

    /// A freshly fetched list with the votes still saving added back in,
    /// except where the fetch already counted this user's vote (`counted`:
    /// it reached the server before its reply did), so it isn't shown twice.
    static func withPending<Item>(_ items: [Item], pending: Set<String>, counted: (CKRecord.ID) -> Bool,
                                  idPath: KeyPath<Item, CKRecord.ID>, count: WritableKeyPath<Item, Int>) -> [Item] {
        guard !pending.isEmpty else { return items }
        return items.map { item in
            var item = item
            let id = item[keyPath: idPath]
            if pending.contains(id.recordName), !counted(id) { item[keyPath: count] += 1 }
            return item
        }
    }

    /// Runs `work`, giving up after `deadline`, or as soon as the caller is
    /// cancelled, without waiting for `work` to stop: nothing says a CloudKit
    /// query stops early when cancelled. The loser is cancelled.
    static func withDeadline<T>(_ deadline: Duration,
                                _ work: @escaping @MainActor () async throws -> T) async throws -> T? {
        try Task.checkCancellation()   // already cancelled: start nothing
        let race = DeadlineRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation(isolation: MainActor.shared) { (cont: CheckedContinuation<T?, Error>) in
                guard race.start(cont) else { return }   // cancelled before it began: nothing to run
                race.worker = Task { @MainActor in
                    do { race.finish(.success(try await work())) } catch { race.finish(.failure(error)) }
                }
                race.sleeper = Task { @MainActor in
                    guard (try? await Task.sleep(for: deadline)) != nil else { return }
                    race.finish(.success(nil))
                }
            }
        } onCancel: {
            Task { @MainActor in race.finish(.failure(CancellationError())) }
        }
    }
}

/// One `withDeadline` race: resumes its caller exactly once, with whichever
/// of the work, the deadline or a cancellation comes first, and cancels the rest.
@MainActor
private final class DeadlineRace<T> {
    private var continuation: CheckedContinuation<T?, Error>?
    private var early: Result<T?, Error>?
    private var decided = false
    var worker: Task<Void, Never>?
    var sleeper: Task<Void, Never>?

    /// False when the race was already decided (the caller was cancelled
    /// before it started): the caller has its answer and nothing should run.
    func start(_ cont: CheckedContinuation<T?, Error>) -> Bool {
        if let early { cont.resume(with: early); return false }
        continuation = cont
        return true
    }

    func finish(_ result: Result<T?, Error>) {
        guard !decided else { return }
        decided = true
        worker?.cancel()
        sleeper?.cancel()
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            early = result
        }
    }
}

extension View {
    /// The one "Like not saved" alert, shown while `error` is set.
    func likeErrorAlert(_ error: Binding<String?>) -> some View {
        alert("Like not saved", isPresented: Binding(get: { error.wrappedValue != nil },
                                                     set: { if !$0 { error.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error.wrappedValue ?? "")
        }
    }
}

/// A list of achievement posts that can be liked: the community feed and the
/// hub share this one like path.
@MainActor
protocol PostLiking: AnyObject {
    var posts: [AchievementPost] { get set }
    var pendingVotes: Set<String> { get set }
    var likeError: String? { get set }
    var saveLike: (CKRecord.ID) async throws -> Void { get }
    var likeMarks: VoteMarks { get }
}

extension PostLiking {
    /// Likes the post at once and saves it; see OptimisticVote.vote.
    @discardableResult
    func like(_ id: CKRecord.ID) -> Task<Void, Never>? {
        OptimisticVote.vote(id, on: self, list: \.posts, pending: \.pendingVotes, idPath: \.id, count: \.likes,
                            marks: likeMarks, save: saveLike,
                            failed: { [weak self] in self?.likeError = CommunityVotes.failureMessage($0, noun: "like") })
    }

    /// Shows freshly fetched posts, keeping likes that are still saving.
    func show(_ fetched: [AchievementPost]) {
        posts = OptimisticVote.withPending(fetched, pending: pendingVotes, counted: likeMarks.has,
                                           idPath: \.id, count: \.likes)
    }

    /// Liked: saved and remembered, or still saving.
    func isLiked(_ id: CKRecord.ID) -> Bool {
        likeMarks.has(id) || pendingVotes.contains(id.recordName)
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
        // At most 100 items per query: "Wocketts received" asks about every
        // route the user ever published, a list that only grows.
        var all: [StoredVote] = []
        for start in stride(from: 0, to: targets.count, by: 100) {
            try Task.checkCancellation()
            all += try await votes(inChunk: Array(targets[start..<min(start + 100, targets.count)]))
        }
        return all
    }

    private func votes(inChunk targets: [String]) async throws -> [StoredVote] {
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
            try Task.checkCancellation()
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
        do {
            let result = try await OptimisticVote.withDeadline(tallyTimeout) { [store] in
                let votes = try await store.votes(for: targets)
                return CommunityVotes.tally(votes, me: try? await self.me())
            }
            guard let result else {
                log.error("Vote counts timed out; showing 0s")
                return VoteTally()
            }
            return result
        } catch {
            log.error("Vote counts unavailable: \(error.localizedDescription, privacy: .public)")
            return VoteTally()
        }
    }
}

// MARK: - Catching up old marks

/// Before votes existed, every like and Wockett was marked on the phone and
/// then failed to save for anyone but the author, so existing installs hold
/// marks with no vote behind them. Trusted as they are, those items would show
/// as voted, with the button disabled, and never count (critic, 2026-10-09).
/// This sends a vote for each mark, once. Sending is safe to repeat: a vote
/// that already exists counts as success. Any failure (signed out, offline)
/// leaves it to try again next time; the marks stay, since the Wockett Giver
/// badge counts them.
@MainActor
enum UnsentVoteCatchUp {
    static let doneKey = "wkt_votes_catchUp_v1"
    private static var running = false

    static func runIfNeeded(service: CommunityVoteService? = nil,
                            likes: [String]? = nil, wocketts: [String]? = nil,
                            defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: doneKey), !running else { return }
        running = true
        defer { running = false }
        let service = service ?? .shared
        let jobs = (likes ?? AchievementFeedService.shared.likedIDs).map { ($0, VoteTarget.post) }
                 + (wocketts ?? CommunityRouteService.shared.votedIDs).map { ($0, VoteTarget.route) }
        for (id, type) in jobs {
            do {
                try await service.vote(for: id, type: type)
            } catch {
                return   // try again next time; the rest would fail the same way
            }
        }
        defaults.set(true, forKey: doneKey)
    }
}
