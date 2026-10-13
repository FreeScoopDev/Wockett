import Testing
import CloudKit
import Foundation
@testable import PoCSquat

/// Blocks sync through the private iCloud database (audit 2026-10-12,
/// finding 15): merged as a union of people, newest change per person,
/// so a block made on one device reaches the other and an unblock sticks.
@MainActor
struct CommunityBlockListTests {

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)

    private func list(_ entries: [String: (Bool, Date)]) -> BlockList {
        var l = BlockList()
        for (key, value) in entries { l.set(key, blocked: value.0, at: value.1) }
        return l
    }

    private func defaults() -> UserDefaults {
        let name = "CommunityBlockListTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name) ?? .standard
        d.removePersistentDomain(forName: name)
        return d
    }

    private func store(_ d: UserDefaults, now: Date = Date(timeIntervalSince1970: 5_000)) -> CommunityModerationStore {
        CommunityModerationStore(defaults: d, myAccount: { "_me" }, notifications: NotificationCenter(), now: { now })
    }

    // MARK: Merge

    @Test("A block on either device is on both after a merge (union)")
    func union() {
        let phone = list(["account:_a": (true, t0)])
        let ipad = list(["account:_b": (true, t0), "name:WildMoss": (true, t1)])
        let merged = BlockList.merge(phone, ipad)
        #expect(merged.blockedKeys == ["account:_a", "account:_b", "name:WildMoss"])
        #expect(BlockList.merge(ipad, phone) == merged, "order doesn't matter")
    }

    @Test("An unblock newer than a block wins, whichever side it is on")
    func unblockWins() {
        let blocked = list(["account:_a": (true, t0)])
        let unblocked = list(["account:_a": (false, t1)])
        #expect(BlockList.merge(blocked, unblocked).blockedKeys == [])
        #expect(BlockList.merge(unblocked, blocked).blockedKeys == [])
    }

    @Test("A block newer than an unblock wins")
    func reblockWins() {
        let unblocked = list(["account:_a": (false, t0)])
        let blocked = list(["account:_a": (true, t1)])
        #expect(BlockList.merge(unblocked, blocked).blockedKeys == ["account:_a"])
        #expect(BlockList.merge(blocked, unblocked).blockedKeys == ["account:_a"])
    }

    @Test("On a tie the block wins")
    func tieBlocks() {
        let a = list(["account:_a": (true, t0)])
        let b = list(["account:_a": (false, t0)])
        #expect(BlockList.merge(a, b).blockedKeys == ["account:_a"])
        #expect(BlockList.merge(b, a).blockedKeys == ["account:_a"])
    }

    @Test("The list survives its JSON round trip")
    func roundTrip() throws {
        var l = list(["account:_a": (true, t0), "name:Moss": (false, t1)])
        l.set("account:_b", blocked: true, at: t1, label: "AmberElk")
        #expect(BlockList.decoded(try #require(l.encoded())) == l)
    }

    // MARK: Store

    @Test("Old UserDefaults blocks move into the list once, and the old lists go")
    func migrates() {
        let d = defaults()
        d.set(["_troll"], forKey: "communityBlockedAccounts")
        d.set(["GoldenHeron"], forKey: "communityBlockedAuthors")
        let s = store(d)
        #expect(s.blockList.blockedKeys == ["account:_troll", "name:GoldenHeron"])
        #expect(s.blockList.entries["account:_troll"]?.changedAt == Date(timeIntervalSince1970: 0))
        #expect(d.object(forKey: "communityBlockedAccounts") == nil)
        #expect(d.object(forKey: "communityBlockedAuthors") == nil)
        #expect(s.isBlocked(CommunityAuthor(name: "Anyone", account: "_troll")))
    }

    @Test("An unblock made anywhere beats a migrated block")
    func unblockBeatsMigrated() {
        let d = defaults()
        d.set(["_troll"], forKey: "communityBlockedAccounts")
        let s = store(d)
        let other = list(["account:_troll": (false, t0)])
        s.replaceBlockList(BlockList.merge(s.blockList, other))
        #expect(!s.isBlocked(CommunityAuthor(name: "Anyone", account: "_troll")))
    }

    @Test("Unblock un-hides and is kept as an entry, so a merge can't undo it")
    func unblockKept() {
        let d = defaults()
        let s = store(d, now: t1)
        var changes = 0
        s.onBlocksChanged = { changes += 1 }
        let troll = CommunityAuthor(name: "MistyOak", account: "_troll")
        s.block(troll)
        #expect(s.isBlocked(troll))
        s.unblock(key: "account:_troll")
        #expect(!s.isBlocked(troll))
        #expect(s.blockList.entries["account:_troll"] == BlockEntry(blocked: false, changedAt: t1, label: "MistyOak"))
        #expect(changes == 2, "each change syncs")
    }

    // MARK: Sync

    private final class FakeBackend: BlockListBackend {
        var stored: BlockList?
        /// Saved by "another device" just before our next save.
        var raceWith: BlockList?
        var saves = 0
        var failFetch = false
        func fetch() async throws -> BlockList? {
            if failFetch { throw CKError(.networkUnavailable) }
            return stored
        }
        func save(_ list: BlockList) async throws {
            saves += 1
            if let race = raceWith {
                raceWith = nil
                stored = race
                throw BlockListConflict(server: race)
            }
            stored = list
        }
    }

    @Test("Sync brings the other device's blocks here and sends this phone's there")
    func syncBothWays() async {
        let d = defaults()
        let s = store(d)
        s.block(CommunityAuthor(name: "Here", account: "_here"))
        let backend = FakeBackend()
        backend.stored = list(["account:_there": (true, t0)])
        let ok = await BlockListSync(backend: backend, moderation: s).sync().value
        #expect(ok)
        #expect(s.blockList.blockedKeys == ["account:_here", "account:_there"])
        #expect(backend.stored?.blockedKeys == ["account:_here", "account:_there"])
    }

    @Test("A save that loses a race merges the winner's copy and tries again")
    func conflictMerges() async {
        let d = defaults()
        let s = store(d)
        s.block(CommunityAuthor(name: "Here", account: "_here"))
        let backend = FakeBackend()
        backend.raceWith = list(["account:_racer": (true, t0)])
        #expect(await BlockListSync(backend: backend, moderation: s).sync().value)
        #expect(backend.saves == 2)
        #expect(backend.stored?.blockedKeys == ["account:_here", "account:_racer"])
        #expect(s.blockList.blockedKeys == ["account:_here", "account:_racer"])
    }

    @Test("A failed sync keeps every local block")
    func failureKeeps() async {
        let d = defaults()
        let s = store(d)
        s.block(CommunityAuthor(name: "Here", account: "_here"))
        let backend = FakeBackend()
        backend.failFetch = true
        #expect(await BlockListSync(backend: backend, moderation: s).sync().value == false)
        #expect(s.blockList.blockedKeys == ["account:_here"])
    }

    @Test("Nothing stored yet: the first sync uploads this phone's list")
    func firstUpload() async {
        let s = store(defaults())
        s.block(CommunityAuthor(name: "Here", account: "_here"))
        let backend = FakeBackend()
        #expect(await BlockListSync(backend: backend, moderation: s).sync().value)
        #expect(backend.stored?.blockedKeys == ["account:_here"])
    }
}
