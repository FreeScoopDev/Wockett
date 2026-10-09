import Testing
import CloudKit
import Foundation
@testable import PoCSquat

/// Unique, random, anonymous community names (CommunityNames.swift), behind a
/// fake store that knows who holds each name: CI has no CloudKit.
@MainActor
struct CommunityNamesTests {

    /// Names held across "CloudKit", by account. Saving a name someone holds
    /// fails with an error the service must not trust (it asks the owner).
    private final class FakeCloud: CommunityNameStore {
        var me = "_me"
        var owners: [String: String] = [:]          // lowercased name → account
        var claimError: Error?                       // a failure before anything is saved
        var takenError: Error = CKError(.serverRecordChanged)   // what CloudKit says for a held name
        var loseReply = false                        // the save goes through, its answer doesn't
        var lookupMisses = false                     // the creator index hasn't caught up yet
        var oldest: String?                          // the account's oldest claim, when set
        var claims: [String] = []
        var lookups = 0
        var gates: [CheckedContinuation<Void, Never>] = []
        var holdClaims = false

        func currentUser() async throws -> String { me }
        func claimedName() async throws -> String? {
            lookups += 1
            if lookupMisses { return nil }
            if let oldest { return oldest }
            return owners.first { $0.value == me }.map { $0.key } .flatMap { key in names[key] }
        }
        var names: [String: String] = [:]           // lowercased → as shown
        func claim(_ name: String) async throws {
            claims.append(name)
            if holdClaims { await withCheckedContinuation { gates.append($0) } }
            if let claimError { throw claimError }
            let key = name.lowercased()
            if owners[key] != nil { throw takenError }
            owners[key] = me
            names[key] = name
            if loseReply { throw CKError(.networkFailure) }
        }
        func owner(of name: String) async throws -> String? {
            guard let owner = owners[name.lowercased()] else { return nil }
            return owner == me ? CKCurrentUserDefaultName : owner
        }
        func hold(_ name: String, by account: String) {
            owners[name.lowercased()] = account
            names[name.lowercased()] = name
        }
    }

    private func defaults(local: String? = nil) -> UserDefaults {
        let suite = "CommunityNamesTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite) ?? .standard
        d.removePersistentDomain(forName: suite)
        if let local { d.set(local, forKey: CommunityNameService.localKey) }
        return d
    }

    /// Names handed out in order, so tests know what comes next.
    private func names(_ list: [String]) -> () -> String {
        var queue = list
        return { queue.isEmpty ? "Spare\(UUID().uuidString.prefix(4))" : queue.removeFirst() }
    }

    // MARK: Generator

    @Test("Names are Adjective + Noun + two digits")
    func format() {
        for _ in 0..<200 {
            let name = CommunityNames.random()
            #expect(name.wholeMatch(of: /[A-Z][a-z]+[A-Z][a-z]+[1-9][0-9]/) != nil, "\(name)")
            if let n = Int(name.suffix(2)) { #expect(CommunityNames.numbers.contains(n), "\(name)") }
        }
    }

    @Test("No name ends in a number that reads as sexual or as a hate code")
    func numbersAreClean() {
        for bad in [14, 18, 28, 69, 88] { #expect(!CommunityNames.numbers.contains(bad), "\(bad)") }
        #expect(CommunityNames.numbers.count == 85)
    }

    @Test("The word lists have no repeats and share no word (no FernFern42)")
    func listsDisjoint() {
        let a = CommunityNames.adjectives, n = CommunityNames.nouns
        #expect(Set(a).count == a.count)
        #expect(Set(n).count == n.count)
        #expect(Set(a).isDisjoint(with: n))
        #expect(a.count * n.count * CommunityNames.numbers.count == 136_000)
    }

    @Test("No word, alone or run together with any other, contains a blocked term")
    func wordsAreClean() {
        let blocked = ["fuck", "shit", "bitch", "cunt", "bastard", "dick", "piss", "cock", "pussy",
                       "whore", "slut", "nigger", "faggot", "retard", "asshole", "ass", "cum", "tit", "fag"]
        for a in CommunityNames.adjectives {
            #expect((try? ContentFilter.validate(name: a)) != nil, "\(a)")
            for n in CommunityNames.nouns {
                let joined = "\(a)\(n)".lowercased()
                #expect((try? ContentFilter.validate(name: "\(a) \(n)")) != nil, "\(a) \(n)")
                for term in blocked {
                    #expect(!joined.contains(term), "\(a)\(n) contains \(term)")
                }
            }
        }
    }

    @Test("A name's record ignores letter case, so MistyOak42 and mistyoak42 are one name")
    func recordNameIgnoresCase() {
        #expect(CommunityNames.recordName(for: "MistyOak42") == CommunityNames.recordName(for: "mistyoak42"))
    }

    // MARK: Claiming

    @Test("An existing user keeps their name when it is free")
    func keepsFreeExistingName() async throws {
        let cloud = FakeCloud()
        let service = CommunityNameService(store: cloud, defaults: defaults(local: "MistyOak"), makeName: names(["SunnyFox42"]))
        #expect(try await service.claimedName() == "MistyOak")
        #expect(cloud.claims == ["MistyOak"])
    }

    @Test("A name someone else holds is replaced by a fresh one")
    func takenNameReplaced() async throws {
        let cloud = FakeCloud()
        cloud.hold("MistyOak", by: "_other")
        let service = CommunityNameService(store: cloud, defaults: defaults(local: "MistyOak"), makeName: names(["SunnyFox42"]))
        #expect(try await service.claimedName() == "SunnyFox42")
        #expect(cloud.claims == ["MistyOak", "SunnyFox42"])
        #expect(service.displayName == "SunnyFox42")
    }

    @Test("Whatever error the save gives, a name someone else holds counts as taken")
    func takenWhateverTheError() async throws {
        let cloud = FakeCloud()
        cloud.hold("MistyOak", by: "_other")
        cloud.takenError = CKError(.permissionFailure)   // not the code the app might expect
        let service = CommunityNameService(store: cloud, defaults: defaults(local: "MistyOak"), makeName: names(["SunnyFox42"]))
        #expect(try await service.claimedName() == "SunnyFox42", "moved on from the held name")
    }

    @Test("A save that went through but whose answer was lost keeps that name: one name, not two")
    func lostReplyKeepsName() async throws {
        let cloud = FakeCloud()
        cloud.loseReply = true
        cloud.lookupMisses = true
        let service = CommunityNameService(store: cloud, defaults: defaults(local: "MistyOak"), makeName: names(["SunnyFox42"]))
        #expect(try await service.claimedName() == "MistyOak")
        #expect(cloud.owners.filter { $0.value == "_me" }.count == 1)
    }

    @Test("Another of my devices claimed the same name a moment ago: it's mine, keep it")
    func myOtherDeviceClaimedIt() async throws {
        let cloud = FakeCloud()
        cloud.hold("MistyOak", by: "_me")
        cloud.lookupMisses = true                    // the index hasn't caught up
        let service = CommunityNameService(store: cloud, defaults: defaults(local: "MistyOak"), makeName: names(["SunnyFox42"]))
        #expect(try await service.claimedName() == "MistyOak")
    }

    @Test("Two writes at once share one claim", .timeLimit(.minutes(1)))
    func concurrentWritesShareClaim() async throws {
        let cloud = FakeCloud()
        cloud.holdClaims = true
        let service = CommunityNameService(store: cloud, defaults: defaults(local: "MistyOak"), makeName: names(["SunnyFox42"]))
        async let first = service.claimedName()
        async let second = service.claimedName()
        // Let both writes reach the store, then release whatever is waiting.
        for _ in 0..<10_000 { await Task.yield() }
        cloud.holdClaims = false
        cloud.gates.forEach { $0.resume() }
        cloud.gates.removeAll()
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(cloud.claims == ["MistyOak"])
    }

    @Test("After 10 taken names it gives up, remembers nothing, and the write doesn't happen")
    func givesUp() async {
        let cloud = FakeCloud()
        for i in 0..<20 { cloud.hold("Taken\(i)", by: "_other") }
        let d = defaults(local: "Taken0")
        let service = CommunityNameService(store: cloud, defaults: d, makeName: names((1..<20).map { "Taken\($0)" }))
        await #expect(throws: CommunityNameService.NameError.self) { try await service.claimedName() }
        #expect(cloud.claims.count == CommunityNameService.maxTries)
        #expect(d.string(forKey: CommunityNameService.claimedKey) == nil)
    }

    @Test("A network failure is reported, not taken for a taken name, and remembers nothing")
    func networkFailure() async {
        let cloud = FakeCloud()
        cloud.claimError = CKError(.networkUnavailable)
        let d = defaults()
        let service = CommunityNameService(store: cloud, defaults: d, makeName: names(["SunnyFox42"]))
        await #expect(throws: CKError.self) { try await service.claimedName() }
        #expect(cloud.claims.count == 1, "no second name tried")
        #expect(d.string(forKey: CommunityNameService.claimedKey) == nil)
    }

    @Test("A name this account already holds (another device) is used, not a new one")
    func adoptsExistingClaim() async throws {
        let cloud = FakeCloud()
        cloud.hold("CalmOwl17", by: "_me")
        let service = CommunityNameService(store: cloud, defaults: defaults(local: "MistyOak"), makeName: names(["SunnyFox42"]))
        #expect(try await service.claimedName() == "CalmOwl17")
        #expect(cloud.claims.isEmpty)
        #expect(service.displayName == "CalmOwl17")
    }

    @Test("Once claimed, later writes don't look the name up again")
    func remembered() async throws {
        let cloud = FakeCloud()
        let service = CommunityNameService(store: cloud, defaults: defaults(), makeName: names(["SunnyFox42"]))
        _ = try await service.claimedName()
        _ = try await service.claimedName()
        #expect(cloud.lookups == 1)
        #expect(cloud.claims.count == 1)
    }

    @Test("Another iCloud account on this phone, even with no notice, never posts under the old name")
    func accountSwitchWhileClosed() async throws {
        let cloud = FakeCloud()
        let d = defaults()
        _ = try await CommunityNameService(store: cloud, defaults: d, makeName: names(["SunnyFox42"])).claimedName()
        cloud.me = "_newOwner"                         // switched while Wockett wasn't running: no notification
        let service = CommunityNameService(store: cloud, defaults: d, makeName: names(["QuietLark33"]))
        await service.refreshDisplayName()
        #expect(service.displayName != "SunnyFox42", "the old account's name isn't shown either")
        let name = try await service.claimedName()
        #expect(name == "QuietLark33")
        #expect(cloud.owners["quietlark33"] == "_newOwner")
    }

    // MARK: "Posting as"

    @Test("The shown name is replaced, without claiming, when someone else holds it")
    func refreshShowsRealName() async {
        let cloud = FakeCloud()
        cloud.hold("MistyOak", by: "_other")
        let service = CommunityNameService(store: cloud, defaults: defaults(local: "MistyOak"), makeName: names(["SunnyFox42"]))
        await service.refreshDisplayName()
        #expect(service.displayName == "SunnyFox42")
        #expect(cloud.claims.isEmpty)
    }

    @Test("The shown name becomes this account's existing name")
    func refreshAdoptsExisting() async {
        let cloud = FakeCloud()
        cloud.hold("CalmOwl17", by: "_me")
        let service = CommunityNameService(store: cloud, defaults: defaults(local: "MistyOak"), makeName: names(["SunnyFox42"]))
        await service.refreshDisplayName()
        #expect(service.displayName == "CalmOwl17")
        #expect(cloud.claims.isEmpty)
    }

    @Test("Two of my devices that claimed different names settle on the oldest")
    func devicesSettleOnOldest() async throws {
        let cloud = FakeCloud()
        let d = defaults(local: "MistyOak")
        let service = CommunityNameService(store: cloud, defaults: d, makeName: names([]))
        cloud.lookupMisses = true
        _ = try await service.claimedName()                 // this device: MistyOak
        cloud.oldest = "CalmOwl17"                          // the other device's, claimed first
        cloud.lookupMisses = false
        await service.refreshDisplayName()
        #expect(service.displayName == "CalmOwl17")
    }
}
