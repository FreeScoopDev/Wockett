import Testing
import CloudKit
import Foundation
@testable import PoCSquat

/// Unique, random, anonymous community names (CommunityNames.swift), behind a
/// fake store: CI has no CloudKit.
@MainActor
struct CommunityNamesTests {

    private final class FakeStore: CommunityNameStore {
        var held: String?
        var taken: Set<String> = []
        var claimError: Error?
        var lookups = 0
        var claims: [String] = []

        func claimedName() async throws -> String? { lookups += 1; return held }
        func claim(_ name: String) async throws {
            claims.append(name)
            if let claimError { throw claimError }
            if taken.contains(name.lowercased()) { throw CKError(.serverRecordChanged) }
            taken.insert(name.lowercased())
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
        }
        #expect(CommunityNames.adjectives.count * CommunityNames.nouns.count * 90 >= 140_000, "plenty of names")
    }

    @Test("No word, in any pairing, fails the community content filter")
    func wordsAreClean() {
        for a in CommunityNames.adjectives {
            for n in CommunityNames.nouns {
                #expect((try? ContentFilter.validate(name: "\(a)\(n)42")) != nil, "\(a)\(n)")
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
        let store = FakeStore()
        let d = defaults(local: "MistyOak")
        let name = try await CommunityNameService(store: store, defaults: d, makeName: names(["SunnyFox42"])).claimedName()
        #expect(name == "MistyOak")
        #expect(store.claims == ["MistyOak"])
    }

    @Test("A taken name is replaced by a fresh one")
    func takenNameReplaced() async throws {
        let store = FakeStore()
        store.taken = ["mistyoak"]
        let d = defaults(local: "MistyOak")
        let service = CommunityNameService(store: store, defaults: d, makeName: names(["SunnyFox42"]))
        let name = try await service.claimedName()
        #expect(name == "SunnyFox42")
        #expect(store.claims == ["MistyOak", "SunnyFox42"])
        #expect(service.displayName == "SunnyFox42", "shown from now on")
    }

    @Test("After 10 taken names it gives up, remembers nothing, and the write doesn't happen")
    func givesUp() async {
        let store = FakeStore()
        store.taken = Set((0..<20).map { "taken\($0)" })
        let d = defaults(local: "Taken0")
        let service = CommunityNameService(store: store, defaults: d, makeName: names((1..<20).map { "Taken\($0)" }))
        await #expect(throws: CommunityNameService.NameError.self) { try await service.claimedName() }
        #expect(store.claims.count == CommunityNameService.maxTries)
        #expect(d.string(forKey: CommunityNameService.claimedKey) == nil)
    }

    @Test("A name this account already holds (another device) is used, not a new one")
    func adoptsExistingClaim() async throws {
        let store = FakeStore()
        store.held = "CalmOwl17"
        let d = defaults(local: "MistyOak")
        let service = CommunityNameService(store: store, defaults: d, makeName: names(["SunnyFox42"]))
        #expect(try await service.claimedName() == "CalmOwl17")
        #expect(store.claims.isEmpty)
        #expect(service.displayName == "CalmOwl17")
    }

    @Test("Once claimed, later writes don't ask CloudKit again")
    func remembered() async throws {
        let store = FakeStore()
        let service = CommunityNameService(store: store, defaults: defaults(), makeName: names(["SunnyFox42"]))
        _ = try await service.claimedName()
        _ = try await service.claimedName()
        #expect(store.lookups == 1)
        #expect(store.claims.count == 1)
    }

    @Test("A different iCloud account looks its own name up again")
    func accountChangeForgets() async throws {
        let store = FakeStore()
        let center = NotificationCenter()
        let service = CommunityNameService(store: store, defaults: defaults(), makeName: names(["SunnyFox42"]),
                                           notifications: center)
        _ = try await service.claimedName()
        store.held = "QuietLark33"                         // the new account's own name
        center.post(name: .CKAccountChanged, object: nil)
        #expect(try await service.claimedName() == "QuietLark33")
    }

    @Test("A network failure is reported, not taken for a taken name, and remembers nothing")
    func networkFailure() async {
        let store = FakeStore()
        store.claimError = CKError(.networkUnavailable)
        let d = defaults()
        let service = CommunityNameService(store: store, defaults: d, makeName: names(["SunnyFox42"]))
        await #expect(throws: CKError.self) { try await service.claimedName() }
        #expect(store.claims.count == 1, "no second name tried")
        #expect(d.string(forKey: CommunityNameService.claimedKey) == nil)
    }
}
