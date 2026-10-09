import Testing
import CloudKit
import Foundation
@testable import PoCSquat

/// Block keys on the account CloudKit stamps on a record, not on the display
/// name, which two people can share and anyone can write (CommunityModeration).
@MainActor
struct CommunityBlockTests {

    private func store(names: [String] = []) -> CommunityModerationStore {
        let suite = "CommunityBlockTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        if !names.isEmpty { defaults.set(names, forKey: "communityBlockedAuthors") }
        return CommunityModerationStore(defaults: defaults)
    }

    private let anyID = CKRecord.ID(recordName: "item")

    @Test("Blocking an account hides it under any name")
    func accountUnderAnyName() {
        let s = store()
        s.block(CommunityAuthor(name: "MistyOak", account: "_troll"))
        #expect(s.shouldHide(id: anyID, author: CommunityAuthor(name: "MistyOak", account: "_troll")))
        #expect(s.shouldHide(id: anyID, author: CommunityAuthor(name: "SwiftFalcon", account: "_troll")), "renamed")
    }

    @Test("A namesake on another account is not hidden")
    func namesakeNotHidden() {
        let s = store()
        s.block(CommunityAuthor(name: "MistyOak", account: "_troll"))
        #expect(!s.shouldHide(id: anyID, author: CommunityAuthor(name: "MistyOak", account: "_someoneElse")))
    }

    @Test("Blocks made by name before accounts keep working")
    func legacyNameBlocks() {
        let s = store(names: ["GoldenHeron"])
        #expect(s.shouldHide(id: anyID, author: CommunityAuthor(name: "GoldenHeron", account: "_any")))
        #expect(!s.shouldHide(id: anyID, author: CommunityAuthor(name: "CalmPine", account: "_any")))
    }

    @Test("An author with no known account is blocked by name")
    func unknownAccountFallsBack() {
        let s = store()
        s.block(CommunityAuthor(name: "WildMoss", account: nil))
        #expect(s.shouldHide(id: anyID, author: CommunityAuthor(name: "WildMoss", account: nil)))
    }

    @Test("You can't block yourself, and your own content is never hidden by an account block")
    func neverSelf() {
        let me = CommunityAuthor(name: "AmberElk", account: CKCurrentUserDefaultName)
        #expect(me.isMe)
        let s = store()
        s.block(me)
        #expect(!s.shouldHide(id: anyID, author: me))
        #expect(!s.shouldHide(id: anyID, author: CommunityAuthor(name: "Someone", account: "_x")))
    }
}
