import Testing
import CloudKit
import Foundation
@testable import PoCSquat

/// Block keys on the account CloudKit stamps on a record, not on the display
/// name, which two people can share and anyone can write (CommunityModeration).
/// Your own content is never blockable and never hidden by a block.
@MainActor
struct CommunityBlockTests {

    private struct Fixture {
        let store: CommunityModerationStore
        let defaults: UserDefaults
        var blockedNames: [String] { defaults.stringArray(forKey: "communityBlockedAuthors") ?? [] }
        var blockedAccounts: [String] { defaults.stringArray(forKey: "communityBlockedAccounts") ?? [] }
    }

    private func fixture(names: [String] = [], accounts: [String] = [], me: String? = nil) -> Fixture {
        let suite = "CommunityBlockTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        if !names.isEmpty { defaults.set(names, forKey: "communityBlockedAuthors") }
        if !accounts.isEmpty { defaults.set(accounts, forKey: "communityBlockedAccounts") }
        return Fixture(store: CommunityModerationStore(defaults: defaults, myAccount: { me }), defaults: defaults)
    }

    private let anyID = CKRecord.ID(recordName: "item")
    private let meSignedIn = CommunityAuthor(name: "AmberElk", account: CKCurrentUserDefaultName)

    // MARK: Accounts, not names

    @Test("Blocking an account hides it under any name")
    func accountUnderAnyName() {
        let f = fixture()
        f.store.block(CommunityAuthor(name: "MistyOak", account: "_troll"))
        #expect(f.blockedAccounts == ["_troll"])
        #expect(f.store.shouldHide(id: anyID, author: CommunityAuthor(name: "SwiftFalcon", account: "_troll")), "renamed")
    }

    @Test("A namesake on another account is not hidden")
    func namesakeNotHidden() {
        let f = fixture()
        f.store.block(CommunityAuthor(name: "MistyOak", account: "_troll"))
        #expect(!f.store.shouldHide(id: anyID, author: CommunityAuthor(name: "MistyOak", account: "_someoneElse")))
    }

    @Test("Blocks made by name before accounts keep working")
    func legacyNameBlocks() {
        let f = fixture(names: ["GoldenHeron"])
        #expect(f.store.shouldHide(id: anyID, author: CommunityAuthor(name: "GoldenHeron", account: "_any")))
        #expect(!f.store.shouldHide(id: anyID, author: CommunityAuthor(name: "CalmPine", account: "_any")))
    }

    @Test("An author with no known account is blocked by name")
    func unknownAccountFallsBack() {
        let f = fixture()
        f.store.block(CommunityAuthor(name: "WildMoss", account: nil))
        #expect(f.blockedNames == ["WildMoss"])
        #expect(f.store.shouldHide(id: anyID, author: CommunityAuthor(name: "WildMoss", account: nil)))
    }

    // MARK: Never yourself (each guard on its own)

    @Test("Blocking yourself stores nothing")
    func blockSelfStoresNothing() {
        let f = fixture()
        f.store.block(meSignedIn)
        #expect(f.blockedAccounts.isEmpty)
        #expect(f.blockedNames.isEmpty)
    }

    @Test("Your content isn't hidden even if your account got onto the block list")
    func ownAccountOnListNotHidden() {
        let f = fixture(accounts: [CKCurrentUserDefaultName])
        #expect(!f.store.shouldHide(id: anyID, author: meSignedIn))
    }

    @Test("An old name block matching your own name doesn't hide your content")
    func ownNameOnOldListNotHidden() {
        let f = fixture(names: ["AmberElk"])          // Block used to be offered on your own posts
        #expect(!f.store.shouldHide(id: anyID, author: meSignedIn))
        #expect(f.store.shouldHide(id: anyID, author: CommunityAuthor(name: "AmberElk", account: "_namesake")),
                "an old name block still covers a namesake, as before")
    }

    @Test("Signed out, your content comes back under your real ID: still yours")
    func signedOutStillMine() {
        let meSignedOut = CommunityAuthor(name: "AmberElk", account: "_real")
        let f = fixture(accounts: ["_real"], me: "_real")
        #expect(f.store.isMine(meSignedOut))
        #expect(!f.store.shouldHide(id: anyID, author: meSignedOut))
        let g = fixture(me: "_real")
        g.store.block(meSignedOut)
        #expect(g.blockedAccounts.isEmpty)
    }

    // MARK: The account comes off the record

    private func record(_ type: String, _ fields: [String: CKRecordValue]) -> CKRecord {
        let r = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: "\(type)-\(UUID().uuidString)"))
        for (k, v) in fields { r[k] = v }
        return r
    }

    @Test("Routes, posts and challenges carry their creator's account")
    func modelsCarryAccount() throws {
        let creator = CKRecord.ID(recordName: "_creator")
        let route = try #require(SharedRoute(record: record("SharedRoute", [
            "name": "Loop" as CKRecordValue, "waypointsJSON": "[]" as CKRecordValue,
            "distanceMeters": 1000.0 as CKRecordValue, "authorName": "MistyOak" as CKRecordValue]), creator: creator))
        let post = try #require(AchievementPost(record: record("WocketAchievement", [
            "badgeName": "Trailblazer" as CKRecordValue, "badgeEmoji": "🥾" as CKRecordValue,
            "authorName": "MistyOak" as CKRecordValue]), creator: creator))
        let challenge = try #require(WalkChallenge(record: record("Challenge", [
            "title": "10k" as CKRecordValue, "startDate": Date() as CKRecordValue,
            "endDate": Date().addingTimeInterval(86_400) as CKRecordValue,
            "goalSteps": 10_000 as CKRecordValue, "authorName": "MistyOak" as CKRecordValue]), creator: creator))
        for author in [route.author, post.author, challenge.author] {
            #expect(author == CommunityAuthor(name: "MistyOak", account: "_creator"))
        }
    }

    // MARK: Run 2

    private func route(_ name: String, account: String) throws -> SharedRoute {
        let r = record("SharedRoute", ["name": name as CKRecordValue, "waypointsJSON": "[]" as CKRecordValue,
                                       "distanceMeters": 1000.0 as CKRecordValue, "authorName": "Someone" as CKRecordValue])
        return try #require(SharedRoute(record: r, creator: CKRecord.ID(recordName: account)))
    }

    @Test("A block made anywhere hides that author's routes in the app-wide route list")
    func routesModelHidesBlocked() throws {
        let f = fixture()
        let model = CommunityRoutesModel()
        model.moderation = f.store
        let theirs = try route("Theirs", account: "_troll"), other = try route("Other", account: "_ok")
        model.routes = [theirs, other]
        f.store.block(theirs.author)                    // blocked from a post elsewhere
        #expect(model.visibleRoutes.map(\.id) == [other.id])
        model.dropHidden()
        #expect(model.routes.map(\.id) == [other.id])
    }

    @Test("An iCloud account change forgets and refreshes the saved ID, and redraws")
    func accountChangeRefreshes() async {
        let center = NotificationCenter()
        var refreshed = 0
        let suite = "CommunityBlockTests-\(UUID().uuidString)"
        let store = CommunityModerationStore(defaults: UserDefaults(suiteName: suite) ?? .standard,
                                             myAccount: { nil }, notifications: center,
                                             onAccountChange: { refreshed += 1 })
        let before = store.revision
        center.post(name: .CKAccountChanged, object: nil)
        #expect(store.revision > before, "screens that decided 'yours' redraw at once")
        for _ in 0..<1_000 where refreshed == 0 { await Task.yield() }
        #expect(refreshed == 1)
    }
}
