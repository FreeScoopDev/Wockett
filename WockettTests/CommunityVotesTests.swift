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
        var stored: [(target: String, recordName: String)] = []
        var readError: Error?

        func currentUserRecordName() async throws -> String { userLookups += 1; return user }
        func saveVote(recordName: String, target: String, type: VoteTarget) async throws {
            if let saveError { throw saveError }
            saved.append((recordName, target, type))
        }
        func votes(for targets: [String]) async throws -> [(target: String, recordName: String)] {
            if let readError { throw readError }
            return stored.filter { targets.contains($0.target) }
        }
    }

    private func vote(_ target: String, by voter: String) -> (target: String, recordName: String) {
        (target, CommunityVotes.recordName(target: target, voter: voter))
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
            ("c", "vote.a._z"),                        // names another item: not a vote for c
            ("c", "something-else"),
        ], me: "_me")
        #expect(t.count(for: "a") == 3)
        #expect(t.count(for: "b") == 1)
        #expect(t.count(for: "c") == 0)
        #expect(t.mine == ["a"])
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

    @Test("Counts that take too long give up, so the feed still shows")
    func tallyTimesOut() async {
        final class SlowStore: CommunityVoteStore {
            func currentUserRecordName() async throws -> String { "_me" }
            func saveVote(recordName: String, target: String, type: VoteTarget) async throws {}
            func votes(for targets: [String]) async throws -> [(target: String, recordName: String)] {
                try await Task.sleep(for: .seconds(30))
                return [("r", "vote.r._x")]
            }
        }
        let started = ContinuousClock.now
        let t = await CommunityVoteService(store: SlowStore(), tallyTimeout: .milliseconds(200)).tally(for: ["r"])
        #expect(t == VoteTally())
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("Signed out of iCloud gets its own message, not 'check your connection'")
    func failureMessages() {
        #expect(CommunityVotes.failureMessage(CKError(.notAuthenticated), noun: "like").contains("Sign in to iCloud"))
        #expect(CommunityVotes.failureMessage(CKError(.networkUnavailable), noun: "Wockett")
                == "Couldn't save your Wockett. Check your connection and try again.")
    }

    // MARK: Taking a vote back

    private struct Row { let id: CKRecord.ID; var count: Int }
    private func rid(_ s: String) -> CKRecord.ID { CKRecord.ID(recordName: s) }

    @Test("Taking a vote back finds the item by id, even after the list changed")
    func adjustById() {
        var rows = [Row(id: rid("a"), count: 3), Row(id: rid("b"), count: 5), Row(id: rid("c"), count: 1)]
        rows.remove(at: 0)                                  // a row above was hidden mid-save
        OptimisticVote.adjust(&rows, id: rid("b"), by: -1, idPath: \.id, count: \.count)
        #expect(rows.map(\.count) == [4, 1], "b taken back, c untouched")
        OptimisticVote.adjust(&rows, id: rid("gone"), by: -1, idPath: \.id, count: \.count)
        #expect(rows.map(\.count) == [4, 1], "an item no longer listed is left alone, nothing traps")
    }

    @Test("A count never goes below 0 (a refresh never included the failed vote)")
    func adjustClamps() {
        var rows = [Row(id: rid("a"), count: 0)]
        OptimisticVote.adjust(&rows, id: rid("a"), by: -1, idPath: \.id, count: \.count)
        #expect(rows[0].count == 0)
    }

    // MARK: Hub like and route Wockett, through the code the screens call

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
        defer { AchievementFeedService.shared.unmarkLiked(id: p.id) }
        let model = CommunityHubModel()
        model.posts = [p]
        model.saveLike = { _ in throw CKError(.networkUnavailable) }
        let save = model.markLiked(p)
        #expect(model.posts[0].likes == 1, "shows at once")
        await save?.value
        #expect(model.posts[0].likes == 0)
        #expect(!AchievementFeedService.shared.hasLiked(id: p.id))
        #expect(model.likeError == "Couldn't save your like. Check your connection and try again.")
    }

    @Test("A hub like that saves stays")
    func hubKeepsSavedLike() async throws {
        let p = try post("post-keep")
        defer { AchievementFeedService.shared.unmarkLiked(id: p.id) }
        let model = CommunityHubModel()
        model.posts = [p]
        model.saveLike = { _ in }
        await model.markLiked(p)?.value
        #expect(model.posts[0].likes == 1)
        #expect(AchievementFeedService.shared.hasLiked(id: p.id))
        #expect(model.likeError == nil)
    }

    @Test("A Wockett that fails is taken back from its route, wherever it moved")
    func wockettUndone() async throws {
        let a = try route("route-a"), b = try route("route-b")
        defer { CommunityRouteService.shared.unmarkVoted(for: b.id) }
        let model = CommunityRoutesModel()
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
        #expect(!CommunityRouteService.shared.hasVoted(for: b.id))
        #expect(model.wocketError == "Couldn't save your Wockett. Check your connection and try again.")
    }

    @Test("A Wockett that saves stays")
    func wockettKept() async throws {
        let r = try route("route-keep")
        defer { CommunityRouteService.shared.unmarkVoted(for: r.id) }
        let model = CommunityRoutesModel()
        model.routes = [r]
        model.saveWockett = { _ in }
        await model.wockett(r.id)?.value
        #expect(model.routes[0].wocketts == 1)
        #expect(CommunityRouteService.shared.hasVoted(for: r.id))
        #expect(model.wocketError == nil)
    }
}
