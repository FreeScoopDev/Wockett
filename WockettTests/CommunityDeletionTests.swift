import Testing
import CloudKit
import Foundation
@testable import PoCSquat

/// Deleting your own community content (2026-10-11): only yours, only after
/// asking, one record, and what the phone remembers about it cleared.
@MainActor
struct CommunityDeletionTests {

    private func defaults() -> UserDefaults {
        let name = "CommunityDeletionTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name) ?? .standard
        d.removePersistentDomain(forName: name)
        return d
    }

    private func store(_ d: UserDefaults, me: String? = "_me") -> CommunityModerationStore {
        CommunityModerationStore(defaults: d, myAccount: { me })
    }

    private final class FakeDeleter: CommunityRecordDeleter {
        var deleted: [CKRecord.ID] = []
        var error: Error?
        func delete(_ id: CKRecord.ID) async throws {
            deleted.append(id)
            if let error { throw error }
        }
    }

    @Test("Delete is offered on your own content only, signed in or out")
    func onlyYours() {
        let store = CommunityModerationStore(defaults: defaults(), myAccount: { "_me" })
        #expect(store.isMine(CommunityAuthor(name: "Me", account: CKCurrentUserDefaultName)))
        #expect(store.isMine(CommunityAuthor(name: "Me", account: "_me")))
        #expect(!store.isMine(CommunityAuthor(name: "Me", account: "_someoneElse")), "a namesake's isn't yours")
        #expect(!store.isMine(CommunityAuthor(name: "Me", account: nil)))
    }

    @Test("The confirmation says exactly what happens")
    func copy() {
        #expect(CommunityDeletion.confirmTitle == "Delete from Community?")
        #expect(CommunityDeletion.confirmMessage == "This removes it for everyone. Routes other people already saved stay with them.")
        #expect(CommunityDeletion.buttonTitle == "Delete from Community")
    }

    @Test("Success and an already-gone record are deleted; other errors say why")
    func outcomes() {
        #expect(CommunityDeletion.outcome(of: nil) == .deleted)
        #expect(CommunityDeletion.outcome(of: CKError(.unknownItem)) == .deleted)
        #expect(CommunityDeletion.outcome(of: CKError(.notAuthenticated)) == .failed("Sign in to iCloud in the Settings app to delete it."))
        #expect(CommunityDeletion.outcome(of: CKError(.permissionFailure)) == .failed("Only the account that shared it can delete it."))
        #expect(CommunityDeletion.outcome(of: CKError(.networkUnavailable)) == .failed("Couldn't delete it. Check your connection and try again."))
    }

    @Test("Deleting a route deletes that one record and forgets it was published")
    func route() async {
        let d = defaults()
        d.set(["r1", "r2"], forKey: CommunityRouteService.publishedKey)
        let deleter = FakeDeleter()
        let outcome = await CommunityDeletionRun.run(CommunityDeletionRequest(kind: .route, recordID: CKRecord.ID(recordName: "r1")),
                                                     deleter: deleter, defaults: d, moderation: store(d))
        #expect(outcome == .deleted)
        #expect(deleter.deleted.map(\.recordName) == ["r1"])
        #expect(d.stringArray(forKey: CommunityRouteService.publishedKey) == ["r2"])
    }

    @Test("Deleting your entry forgets that challenge was joined, and only that one")
    func entry() async {
        let d = defaults()
        d.set(["c1": "e1", "c2": "e2"], forKey: ChallengeService.joinedKey)
        let request = CommunityDeletionRequest(kind: .entry(challengeKey: "c1"), recordID: CKRecord.ID(recordName: "e1"))
        #expect(await CommunityDeletionRun.run(request, deleter: FakeDeleter(), defaults: d, moderation: store(d)) == .deleted)
        #expect(d.dictionary(forKey: ChallengeService.joinedKey) as? [String: String] == ["c2": "e2"])
    }

    @Test("A failed delete keeps everything as it was")
    func failureKeeps() async {
        let d = defaults()
        d.set(["r1"], forKey: CommunityRouteService.publishedKey)
        let deleter = FakeDeleter()
        deleter.error = CKError(.networkUnavailable)
        let outcome = await CommunityDeletionRun.run(CommunityDeletionRequest(kind: .route, recordID: CKRecord.ID(recordName: "r1")),
                                                     deleter: deleter, defaults: d, moderation: store(d))
        #expect(outcome == .failed("Couldn't delete it. Check your connection and try again."))
        #expect(d.stringArray(forKey: CommunityRouteService.publishedKey) == ["r1"])
    }

    @Test("A record already gone still clears the bookkeeping")
    func goneClears() async {
        let d = defaults()
        d.set(["r1"], forKey: CommunityRouteService.publishedKey)
        let deleter = FakeDeleter()
        deleter.error = CKError(.unknownItem)
        _ = await CommunityDeletionRun.run(CommunityDeletionRequest(kind: .route, recordID: CKRecord.ID(recordName: "r1")),
                                           deleter: deleter, defaults: d, moderation: store(d))
        #expect(d.stringArray(forKey: CommunityRouteService.publishedKey) == [])
    }

    // MARK: Critic run 1

    @Test("Delete is offered by the button's own rule: yours only")
    func offered() {
        let s = store(defaults())
        #expect(CommunityDeletion.isOffered(for: CommunityAuthor(name: "Me", account: "_me"), store: s))
        #expect(!CommunityDeletion.isOffered(for: CommunityAuthor(name: "Other", account: "_other"), store: s))
        #expect(!CommunityDeletion.isOffered(for: CommunityAuthor(name: "Me", account: nil), store: s))
    }

    @Test("Deleting an older entry of yours keeps the one this phone tracks")
    func staleEntryKeepsJoin() async {
        let d = defaults()
        d.set(["c1": "e2"], forKey: ChallengeService.joinedKey)
        let request = CommunityDeletionRequest(kind: .entry(challengeKey: "c1"), recordID: CKRecord.ID(recordName: "e1"))
        #expect(await CommunityDeletionRun.run(request, deleter: FakeDeleter(), defaults: d, moderation: store(d)) == .deleted)
        #expect(d.dictionary(forKey: ChallengeService.joinedKey) as? [String: String] == ["c1": "e2"])
    }

    @Test("A deleted item leaves every list at once, the hub's too")
    func deletedLeavesLists() async throws {
        let d = defaults()
        let moderation = store(d)
        let rec = CKRecord(recordType: "WocketAchievement", recordID: CKRecord.ID(recordName: "post-\(UUID().uuidString)"))
        rec["badgeName"] = "Trailblazer"
        rec["badgeEmoji"] = "🥾"
        let post = try #require(AchievementPost(record: rec))
        let model = CommunityHubModel()
        model.moderation = moderation
        model.posts = [post]
        #expect(model.visiblePosts.count == 1)
        _ = await CommunityDeletionRun.run(CommunityDeletionRequest(kind: .post, recordID: post.id),
                                           deleter: FakeDeleter(), defaults: d, moderation: moderation)
        #expect(model.visiblePosts.isEmpty)
    }

    @Test("A failed delete leaves the item in the lists")
    func failedStaysListed() async {
        let d = defaults()
        let moderation = store(d)
        let deleter = FakeDeleter()
        deleter.error = CKError(.networkUnavailable)
        let id = CKRecord.ID(recordName: "r9")
        _ = await CommunityDeletionRun.run(CommunityDeletionRequest(kind: .route, recordID: id), deleter: deleter, defaults: d, moderation: moderation)
        #expect(!moderation.isDeleted(id))
    }

    @Test("The hub stops showing your challenge once you've deleted your entry")
    func hubDropsLeftChallenge() throws {
        let rec = CKRecord(recordType: "Challenge", recordID: CKRecord.ID(recordName: "c-\(UUID().uuidString)"))
        rec["title"] = "10k a day"
        rec["startDate"] = Date()
        rec["endDate"] = Date().addingTimeInterval(86_400)
        rec["goalSteps"] = 10_000
        rec["authorName"] = "QuietPine"
        let challenge = try #require(WalkChallenge(record: rec))
        let model = CommunityHubModel()
        model.moderation = store(defaults())
        var joined = true
        model.isJoined = { _ in joined }
        model.yourChallenge = challenge
        #expect(model.visibleYourChallenge != nil)
        joined = false
        #expect(model.visibleYourChallenge == nil)
        #expect(model.visibleStanding == nil)
    }

    @Test("A deleted entry stays off the leaderboard if CloudKit still returns it")
    func leaderboardDropsDeleted() throws {
        let d = defaults()
        let moderation = store(d)
        let r = CKRecord(recordType: "ChallengeEntry", recordID: CKRecord.ID(recordName: "e1"))
        r["displayName"] = "Me"
        r["steps"] = 100
        r["deviceID"] = "d1"
        let entry = try #require(ChallengeParticipant(record: r, creator: CKRecord.ID(recordName: "_me")))
        moderation.markDeleted(entry.id)
        #expect(ChallengeService.visible([entry], moderation: moderation).isEmpty)
    }
}
