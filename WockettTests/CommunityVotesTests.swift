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

    // MARK: Hub like, undone on failure

    @Test("A like that fails to save is taken back: count, mark and an error")
    func hubUndoesFailedLike() async throws {
        let record = CKRecord(recordType: "WocketAchievement", recordID: CKRecord.ID(recordName: "post-undo-\(UUID().uuidString)"))
        record["badgeName"] = "Trailblazer" as CKRecordValue
        record["badgeEmoji"] = "🥾" as CKRecordValue
        let post = try #require(AchievementPost(record: record))
        defer { AchievementFeedService.shared.unmarkLiked(id: post.id) }

        let model = CommunityHubModel()
        model.posts = [post]
        model.saveLike = { _ in throw CKError(.networkUnavailable) }

        model.markLiked(post)
        #expect(model.posts[0].likes == 1, "optimistic +1")
        #expect(AchievementFeedService.shared.hasLiked(id: post.id))

        await model.saveLikeOrUndo(post.id)
        #expect(model.posts[0].likes == 0)
        #expect(!AchievementFeedService.shared.hasLiked(id: post.id))
        #expect(model.likeError != nil)
    }

    @Test("A like that saves stays")
    func hubKeepsSavedLike() async throws {
        let record = CKRecord(recordType: "WocketAchievement", recordID: CKRecord.ID(recordName: "post-keep-\(UUID().uuidString)"))
        record["badgeName"] = "Trailblazer" as CKRecordValue
        record["badgeEmoji"] = "🥾" as CKRecordValue
        let post = try #require(AchievementPost(record: record))
        defer { AchievementFeedService.shared.unmarkLiked(id: post.id) }

        let model = CommunityHubModel()
        model.posts = [post]
        model.saveLike = { _ in }
        model.markLiked(post)
        await model.saveLikeOrUndo(post.id)
        #expect(model.posts[0].likes == 1)
        #expect(AchievementFeedService.shared.hasLiked(id: post.id))
        #expect(model.likeError == nil)
    }
}
