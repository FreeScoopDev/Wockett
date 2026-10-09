import Testing
import CloudKit
import Foundation
@testable import PoCSquat

/// Likes and Wocketts as CommunityVote records (CommunityVotes.swift). CI has
/// no CloudKit, so the store is a fake: what is pinned here is the naming that
/// makes one vote per person, the counting, and what a failure does.
@MainActor
struct CommunityVotesTests {

    private final class FakeStore: CommunityVoteStore {
        var user = "_me"
        var userLookups = 0
        var saved: [(recordName: String, target: String, type: VoteTarget)] = []
        var saveError: Error?
        var stored: [StoredVote] = []
        var userError: Error?
        var readError: Error?

        func currentUserRecordName() async throws -> String {
            userLookups += 1
            if let userError { throw userError }
            return user
        }
        func saveVote(recordName: String, target: String, type: VoteTarget) async throws {
            if let saveError { throw saveError }
            saved.append((recordName, target, type))
        }
        func votes(for targets: [String]) async throws -> [StoredVote] {
            if let readError { throw readError }
            return stored.filter { targets.contains($0.target) }
        }
    }

    /// A vote as CloudKit returns it: created by the voter it names.
    private func vote(_ target: String, by voter: String, creator: String? = nil) -> StoredVote {
        StoredVote(target: target, recordName: CommunityVotes.recordName(target: target, voter: voter),
                   creator: creator ?? voter)
    }

    // MARK: Naming and counting

    @Test("A vote's name is built from the item and the voter, and read back")
    func naming() {
        let name = CommunityVotes.recordName(target: "ABC-123", voter: "_7f3e")
        #expect(name == "vote.ABC-123._7f3e")
        #expect(CommunityVotes.voter(fromRecordName: name, target: "ABC-123") == "_7f3e")
        #expect(CommunityVotes.voter(fromRecordName: name, target: "OTHER") == nil)
        #expect(CommunityVotes.voter(fromRecordName: "vote.ABC-123.", target: "ABC-123") == nil)
    }

    @Test("Counts votes per item, once per voter, and marks the ones that are mine")
    func tally() {
        let t = CommunityVotes.tally([
            vote("a", by: "_me"), vote("a", by: "_x"), vote("a", by: "_y"),
            vote("b", by: "_x"),
            vote("a", by: "_x"),                       // the same vote seen twice
            StoredVote(target: "c", recordName: "vote.a._z", creator: "_z"),     // names another item
            StoredVote(target: "c", recordName: "something-else", creator: "_z"),
        ], me: "_me")
        #expect(t.count(for: "a") == 3)
        #expect(t.count(for: "b") == 1)
        #expect(t.count(for: "c") == 0)
        #expect(t.mine == ["a"])
    }

    @Test("A vote counts only when its creator is the voter it names")
    func forgedVotesIgnored() {
        let t = CommunityVotes.tally([
            vote("a", by: "_x"),                             // honest
            vote("a", by: "_fake1", creator: "_attacker"),   // made-up name
            StoredVote(target: "a", recordName: "vote.a._fake2", creator: nil),   // creator unknown
        ], me: "_me")
        #expect(t.count(for: "a") == 1)
    }

    @Test("My own vote, which CloudKit returns with the default-owner creator, counts and is mine")
    func ownVoteReadBack() {
        let t = CommunityVotes.tally([vote("a", by: "_me", creator: CKCurrentUserDefaultName),
                                      vote("a", by: "_x", creator: CKCurrentUserDefaultName)], me: "_me")
        #expect(t.count(for: "a") == 1, "default owner only stands in for me")
        #expect(t.mine == ["a"])
    }

    @Test("My own votes still count, and are mine, when my user lookup failed")
    func ownVotesWithoutMe() {
        let t = CommunityVotes.tally([vote("a", by: "_me", creator: CKCurrentUserDefaultName),
                                      vote("a", by: "_x")], me: nil)
        #expect(t.count(for: "a") == 2)
        #expect(t.mine == ["a"])
    }

    @Test("Signed out: counts still show, and nothing is marked mine")
    func signedOutTally() async {
        let store = FakeStore()
        store.userError = CKError(.notAuthenticated)
        store.stored = [vote("r1", by: "_x"), vote("r1", by: "_y")]
        let t = await CommunityVoteService(store: store).tally(for: ["r1"])
        #expect(t.counts == ["r1": 2])
        #expect(t.mine.isEmpty)
        #expect(CommunityVotes.tally([vote("r1", by: "_x")], me: nil).mine.isEmpty)
    }

    @Test("Only CloudKit's 'already exists' answer means already voted")
    func alreadyVoted() {
        #expect(CommunityVotes.isAlreadyVoted(CKError(.serverRecordChanged)))
        #expect(!CommunityVotes.isAlreadyVoted(CKError(.networkUnavailable)))
        #expect(!CommunityVotes.isAlreadyVoted(CKError(.permissionFailure)))
    }

    // MARK: Service

    @Test("Voting saves one record named for the item and this user")
    func voteSaves() async throws {
        let store = FakeStore()
        let service = CommunityVoteService(store: store)
        try await service.vote(for: "route-1", type: .route)
        try await service.vote(for: "post-2", type: .post)
        #expect(store.saved.map(\.recordName) == ["vote.route-1._me", "vote.post-2._me"])
        #expect(store.saved.map(\.type) == [.route, .post])
        #expect(store.saved.map(\.target) == ["route-1", "post-2"], "the field the vote query matches on")
        #expect(store.userLookups == 1, "the user is looked up once, then remembered")
    }

    @Test("Voting again for the same item is not an error")
    func voteTwice() async throws {
        let store = FakeStore()
        store.saveError = CKError(.serverRecordChanged)
        try await CommunityVoteService(store: store).vote(for: "route-1", type: .route)
    }

    @Test("Any other save failure is reported")
    func voteFails() async {
        let store = FakeStore()
        store.saveError = CKError(.networkUnavailable)
        await #expect(throws: CKError.self) {
            try await CommunityVoteService(store: store).vote(for: "route-1", type: .route)
        }
    }

    @Test("Counts come from the store, with mine marked")
    func serviceTally() async {
        let store = FakeStore()
        store.stored = [vote("r1", by: "_me"), vote("r1", by: "_x"), vote("r2", by: "_x")]
        let t = await CommunityVoteService(store: store).tally(for: ["r1", "r2", "r3"])
        #expect(t.counts == ["r1": 2, "r2": 1])
        #expect(t.mine == ["r1"])
    }

    @Test("When votes can't be read, every count is 0 and nothing throws")
    func tallyFails() async {
        let store = FakeStore()
        store.stored = [vote("r1", by: "_x")]
        store.readError = CKError(.unknownItem)    // Production before the vote type is deployed
        let t = await CommunityVoteService(store: store).tally(for: ["r1"])
        #expect(t == VoteTally())
    }

    @Test("A changed iCloud account is looked up again, so votes go under the new person")
    func accountChangeResetsUser() async throws {
        let store = FakeStore()
        let center = NotificationCenter()
        let service = CommunityVoteService(store: store, notifications: center)
        try await service.vote(for: "r", type: .route)
        store.user = "_someoneElse"
        center.post(name: .CKAccountChanged, object: nil)
        try await service.vote(for: "r", type: .route)
        #expect(store.saved.map(\.recordName) == ["vote.r._me", "vote.r._someoneElse"])
    }

    @Test("Counts that take too long give up, even when the query ignores cancellation", .timeLimit(.minutes(1)))
    func tallyTimesOut() async {
        /// Like a CloudKit call that doesn't stop when cancelled: answers after 30 s, whatever happens.
        final class StubbornStore: CommunityVoteStore {
            func currentUserRecordName() async throws -> String { "_me" }
            func saveVote(recordName: String, target: String, type: VoteTarget) async throws {}
            func votes(for targets: [String]) async throws -> [StoredVote] {
                await withCheckedContinuation { cont in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 30) { cont.resume() }
                }
                return []
            }
        }
        let started = ContinuousClock.now
        let t = await CommunityVoteService(store: StubbornStore(), tallyTimeout: .milliseconds(200)).tally(for: ["r"])
        #expect(t == VoteTally())
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("Signed out of iCloud gets its own message, not 'check your connection'")
    func failureMessages() {
        #expect(CommunityVotes.failureMessage(CKError(.notAuthenticated), noun: "like").contains("Sign in to iCloud"))
        #expect(CommunityVotes.failureMessage(CKError(.networkUnavailable), noun: "Wockett")
                == "Couldn't save your Wockett. Check your connection and try again.")
    }

    // MARK: Hub like and route Wockett, through the code the screens call

    /// Marks kept in memory, never in the app's settings.
    private final class MemoryMarks {
        var ids = Set<String>()
        var marks: VoteMarks {
            VoteMarks(has: { [unowned self] in ids.contains($0.recordName) },
                      mark: { [unowned self] in ids.insert($0.recordName) },
                      unmark: { [unowned self] in ids.remove($0.recordName) })
        }
    }

    private func post(_ name: String) throws -> AchievementPost {
        let record = CKRecord(recordType: "WocketAchievement", recordID: CKRecord.ID(recordName: "\(name)-\(UUID().uuidString)"))
        record["badgeName"] = "Trailblazer" as CKRecordValue
        record["badgeEmoji"] = "🥾" as CKRecordValue
        return try #require(AchievementPost(record: record))
    }

    private func route(_ name: String) throws -> SharedRoute {
        let record = CKRecord(recordType: "SharedRoute", recordID: CKRecord.ID(recordName: "\(name)-\(UUID().uuidString)"))
        record["name"] = "Lake loop" as CKRecordValue
        record["waypointsJSON"] = "[]" as CKRecordValue
        record["distanceMeters"] = 2400.0 as CKRecordValue
        return try #require(SharedRoute(record: record))
    }

    @Test("A hub like that fails is taken back: count, mark and a message")
    func hubUndoesFailedLike() async throws {
        let p = try post("post-undo")
        let marks = MemoryMarks()
        let model = CommunityHubModel()
        model.likeMarks = marks.marks
        model.posts = [p]
        model.saveLike = { _ in throw CKError(.networkUnavailable) }
        let save = model.markLiked(p)
        #expect(model.posts[0].likes == 1, "shows at once")
        await save?.value
        #expect(model.posts[0].likes == 0)
        #expect(!marks.ids.contains(p.id.recordName))
        #expect(model.likeError == "Couldn't save your like. Check your connection and try again.")
    }

    @Test("A hub like that saves stays")
    func hubKeepsSavedLike() async throws {
        let p = try post("post-keep")
        let marks = MemoryMarks()
        let model = CommunityHubModel()
        model.likeMarks = marks.marks
        model.posts = [p]
        model.saveLike = { _ in }
        await model.markLiked(p)?.value
        #expect(model.posts[0].likes == 1)
        #expect(marks.ids.contains(p.id.recordName))
        #expect(model.likeError == nil)
    }

    @Test("A Wockett that fails is taken back from its route, wherever it moved")
    func wockettUndone() async throws {
        let a = try route("route-a"), b = try route("route-b")
        let marks = MemoryMarks()
        let model = CommunityRoutesModel()
        model.wockettMarks = marks.marks
        model.routes = [a, b]
        var release: CheckedContinuation<Void, Never>?
        model.saveWockett = { _ in
            await withCheckedContinuation { release = $0 }
            throw CKError(.networkUnavailable)
        }
        let save = model.wockett(b.id)
        #expect(model.routes[1].wocketts == 1)
        model.routes.removeFirst()                        // a refresh or a hide moved b up mid-save
        // Bounded: if the save is never started, fail instead of waiting forever.
        for _ in 0..<10_000 where release == nil { await Task.yield() }
        guard let release else { Issue.record("the Wockett's save was never started"); return }
        release.resume()
        await save?.value
        #expect(model.routes.map(\.wocketts) == [0])
        #expect(!marks.ids.contains(b.id.recordName))
        #expect(model.wocketError == "Couldn't save your Wockett. Check your connection and try again.")
    }

    @Test("A Wockett that saves stays")
    func wockettKept() async throws {
        let r = try route("route-keep")
        let marks = MemoryMarks()
        let model = CommunityRoutesModel()
        model.wockettMarks = marks.marks
        model.routes = [r]
        model.saveWockett = { _ in }
        await model.wockett(r.id)?.value
        #expect(model.routes[0].wocketts == 1)
        #expect(marks.ids.contains(r.id.recordName))
        #expect(model.wocketError == nil)
    }

    @Test("The feed's likes go the same way: shown at once, taken back by id on failure")
    func feedUndoesFailedLike() async throws {
        let a = try post("post-a"), b = try post("post-b")
        let marks = MemoryMarks()
        let feed = AchievementFeedModel()
        feed.likeMarks = marks.marks
        feed.posts = [a, b]
        feed.saveLike = { _ in throw CKError(.networkUnavailable) }
        let save = feed.like(b.id)
        #expect(feed.posts.map(\.likes) == [0, 1])
        await save?.value
        #expect(feed.posts.map(\.likes) == [0, 0], "b taken back, a untouched")
        #expect(marks.ids.isEmpty)
        #expect(feed.likeError != nil)
    }

    @Test("A failed Wockett leaves a refreshed count alone: the server's count never had it")
    func failedVoteAfterRefresh() async throws {
        let r = try route("route-refresh")
        let marks = MemoryMarks()
        let model = CommunityRoutesModel()
        model.wockettMarks = marks.marks
        model.routes = [r]
        var release: CheckedContinuation<Void, Never>?
        model.saveWockett = { _ in
            await withCheckedContinuation { release = $0 }
            throw CKError(.networkUnavailable)
        }
        let save = model.wockett(r.id)
        #expect(model.routes[0].wocketts == 1)
        var fresh = r
        fresh.wocketts = 3                                 // a refresh landed: the server's count, without mine
        model.show([fresh])
        #expect(model.routes[0].wocketts == 4, "mine is added back while it saves")
        for _ in 0..<10_000 where release == nil { await Task.yield() }
        guard let release else { Issue.record("the save was never started"); return }
        release.resume()
        await save?.value
        #expect(model.routes[0].wocketts == 3, "exactly mine taken back, nobody else's")
        #expect(model.wocketError != nil)
    }

    @Test("A Wockett that saves after a refresh keeps showing")
    func savedVoteAfterRefresh() async throws {
        let r = try route("route-refresh-ok")
        let marks = MemoryMarks()
        let model = CommunityRoutesModel()
        model.wockettMarks = marks.marks
        model.routes = [r]
        var release: CheckedContinuation<Void, Never>?
        model.saveWockett = { _ in await withCheckedContinuation { release = $0 } }
        let save = model.wockett(r.id)
        var fresh = r
        fresh.wocketts = 3
        model.show([fresh])
        for _ in 0..<10_000 where release == nil { await Task.yield() }
        guard let release else { Issue.record("the save was never started"); return }
        release.resume()
        await save?.value
        #expect(model.routes[0].wocketts == 4)
        #expect(model.pendingVotes.isEmpty)
        model.show([fresh])                                 // the next refresh no longer adds it
        #expect(model.routes[0].wocketts == 3)
    }

    // MARK: Catching up old marks

    private func throwawayDefaults() -> UserDefaults {
        let name = "CommunityVotesTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name) ?? .standard
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Old marks get a real vote each, once")
    func catchUpSendsOnce() async {
        let store = FakeStore()
        let defaults = throwawayDefaults()
        let service = CommunityVoteService(store: store)
        await UnsentVoteCatchUp.runIfNeeded(service: service, likes: ["post-x"], wocketts: ["route-y"], defaults: defaults)
        #expect(store.saved.map(\.recordName) == ["vote.post-x._me", "vote.route-y._me"])
        #expect(store.saved.map(\.type) == [.post, .route])
        await UnsentVoteCatchUp.runIfNeeded(service: service, likes: ["post-x"], wocketts: ["route-y"], defaults: defaults)
        #expect(store.saved.count == 2, "done once, not again")
    }

    @Test("A catch-up that fails tries again next time")
    func catchUpRetries() async {
        let store = FakeStore()
        store.userError = CKError(.notAuthenticated)
        let defaults = throwawayDefaults()
        await UnsentVoteCatchUp.runIfNeeded(service: CommunityVoteService(store: store), likes: ["post-x"], wocketts: [], defaults: defaults)
        #expect(store.saved.isEmpty)
        store.userError = nil
        await UnsentVoteCatchUp.runIfNeeded(service: CommunityVoteService(store: store), likes: ["post-x"], wocketts: [], defaults: defaults)
        #expect(store.saved.map(\.recordName) == ["vote.post-x._me"])
    }

    // MARK: Deadline

    @Test("A cancelled caller stops waiting at once", .timeLimit(.minutes(1)))
    func deadlineHonoursCancellation() async {
        let started = ContinuousClock.now
        let waiter = Task { @MainActor in
            try? await OptimisticVote.withDeadline(.seconds(30)) { () async throws -> Int in
                try await Task.sleep(for: .seconds(30)); return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        _ = await waiter.value
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("Work that finishes after the deadline is ignored, not answered twice", .timeLimit(.minutes(1)))
    func lateWorkIgnored() async {
        var gate: CheckedContinuation<Void, Never>?
        let result = try? await OptimisticVote.withDeadline(.milliseconds(50)) { () async -> Int in
            await withCheckedContinuation { gate = $0 }
            return 7
        }
        #expect(result == .some(nil), "the deadline answered")
        gate?.resume()                                     // the work finishes late; a second resume would trap
        for _ in 0..<1_000 { await Task.yield() }
    }
}
