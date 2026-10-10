import Testing
import CloudKit
import Foundation
@testable import PoCSquat

/// Account suspensions (2026-10-10): a moderator's `Suspension` record hides
/// the account's content for everyone else and stops it posting, until it
/// ends. The list comes from CloudKit at most every 10 minutes, and a load
/// never waits on it for more than 3 s.
@MainActor
struct CommunitySuspensionTests {

    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var tomorrow: Date { now.addingTimeInterval(86_400) }
    private var yesterday: Date { now.addingTimeInterval(-86_400) }

    private func store(me: String? = "_me") -> CommunityModerationStore {
        let name = "CommunitySuspensionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return CommunityModerationStore(defaults: defaults, myAccount: { me })
    }

    /// CloudKit without a network.
    private final class FakeSuspensions: CommunitySuspensionStore {
        var list: [Suspension] = []
        var error: Error?
        var hangs = false
        var calls = 0

        func suspensions() async throws -> [Suspension] {
            calls += 1
            if hangs { try await Task.sleep(for: .seconds(600)) }
            for _ in 0..<5 { await Task.yield() }   // a real fetch suspends
            if let error { throw error }
            return list
        }
    }

    /// A clock the test moves.
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func service(_ fake: FakeSuspensions, _ moderation: CommunityModerationStore, clock: Clock,
                         sleep: @escaping OptimisticVote.Sleep = { try await Task.sleep(for: $0) }) -> SuspensionService {
        SuspensionService(store: fake, moderation: moderation, now: { clock.now }, sleep: sleep)
    }

    // MARK: Record

    @Test("A Suspension record reads as its account and end, or permanent")
    func parsing() {
        let r = CKRecord(recordType: "Suspension", recordID: CKRecord.ID(recordName: "suspension._a"))
        r["accountRecordName"] = "_a"
        r["until"] = tomorrow
        #expect(CommunitySuspensions.suspension(from: r) == Suspension(account: "_a", until: tomorrow))
        r["until"] = nil
        #expect(CommunitySuspensions.suspension(from: r) == Suspension(account: "_a", until: nil))
        r["accountRecordName"] = ""
        #expect(CommunitySuspensions.suspension(from: r) == nil, "no account, nothing to suspend")
        #expect(CommunitySuspensions.recordName(account: "_a") == "suspension._a")
    }

    @Test("A suspension is in force until it ends; a permanent one always")
    func activity() {
        #expect(Suspension(account: "_a", until: tomorrow).isActive(at: now))
        #expect(!Suspension(account: "_a", until: yesterday).isActive(at: now))
        #expect(!Suspension(account: "_a", until: now).isActive(at: now), "ends at its time, not after")
        #expect(Suspension(account: "_a", until: nil).isActive(at: now))
    }

    // MARK: Hiding

    @Test("A suspended author's content is hidden; an ended suspension hides nothing")
    func hides() {
        let moderation = store()
        moderation.setSuspensions([Suspension(account: "_bad", until: tomorrow), Suspension(account: "_old", until: yesterday)])
        #expect(moderation.isSuspended(CommunityAuthor(name: "B", account: "_bad"), at: now))
        #expect(!moderation.isSuspended(CommunityAuthor(name: "O", account: "_old"), at: now))
        #expect(!moderation.isSuspended(CommunityAuthor(name: "N", account: nil), at: now))
        #expect(!moderation.isSuspended(CommunityAuthor(name: "G", account: "_good"), at: now))
    }

    @Test("Every list's filter hides a suspended author's items")
    func shouldHideIncludesSuspended() {
        let moderation = store()
        let id = CKRecord.ID(recordName: "post-1")
        let author = CommunityAuthor(name: "B", account: "_bad")
        #expect(!moderation.shouldHide(id: id, author: author))
        moderation.setSuspensions([Suspension(account: "_bad", until: nil)])
        #expect(moderation.shouldHide(id: id, author: author))
    }

    @Test("Your own content is never hidden from you, even while suspended")
    func notYourOwn() {
        let moderation = store(me: "_me")
        moderation.setSuspensions([Suspension(account: "_me", until: nil)])
        #expect(!moderation.isSuspended(CommunityAuthor(name: "Me", account: "_me"), at: now))
        #expect(!moderation.isSuspended(CommunityAuthor(name: "Me", account: CKCurrentUserDefaultName), at: now))
        #expect(moderation.mySuspension(at: now) != nil, "but you are told when you post")
    }

    @Test("The list is kept across launches, and redraws only when it changes")
    func persistedAndObserved() {
        let name = "CommunitySuspensionTests-p-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        let first = CommunityModerationStore(defaults: defaults, myAccount: { nil })
        first.setSuspensions([Suspension(account: "_bad", until: nil)])
        let revision = first.revision
        first.setSuspensions([Suspension(account: "_bad", until: nil)])
        #expect(first.revision == revision, "same list: no redraw")
        let relaunched = CommunityModerationStore(defaults: defaults, myAccount: { nil })
        #expect(relaunched.suspensions == [Suspension(account: "_bad", until: nil)], "offline after a relaunch still hides")
    }

    // MARK: Refresh

    @Test("Fetched at most every 10 minutes")
    func refreshInterval() async {
        let fake = FakeSuspensions()
        fake.list = [Suspension(account: "_bad", until: nil)]
        let moderation = store()
        let clock = Clock(now)
        let s = service(fake, moderation, clock: clock)
        await s.refreshIfStale()
        #expect(moderation.suspensions == fake.list)
        clock.now = now.addingTimeInterval(599)
        await s.refreshIfStale()
        #expect(fake.calls == 1)
        clock.now = now.addingTimeInterval(600)
        await s.refreshIfStale()
        #expect(fake.calls == 2)
    }

    @Test("Loads at the same moment share one fetch")
    func coalesced() async {
        let fake = FakeSuspensions()
        let s = service(fake, store(), clock: Clock(now))
        async let a: Void = s.refreshIfStale()
        async let b: Void = s.refreshIfStale()
        _ = await (a, b)
        #expect(fake.calls == 1)
    }

    @Test("A failed fetch keeps the list held, never throws, and retries after a minute")
    func failureKeepsList() async {
        let fake = FakeSuspensions()
        let moderation = store()
        moderation.setSuspensions([Suspension(account: "_bad", until: nil)])
        fake.error = CKError(.networkUnavailable)
        let clock = Clock(now)
        let s = service(fake, moderation, clock: clock)
        await s.refreshIfStale()
        #expect(moderation.suspensions == [Suspension(account: "_bad", until: nil)])
        clock.now = now.addingTimeInterval(59)
        await s.refreshIfStale()
        #expect(fake.calls == 1)
        clock.now = now.addingTimeInterval(60)
        await s.refreshIfStale()
        #expect(fake.calls == 2)
    }

    @Test("A load waits for the list no longer than the deadline, then uses the one held")
    func deadline() async {
        let fake = FakeSuspensions()
        fake.hangs = true
        let moderation = store()
        moderation.setSuspensions([Suspension(account: "_bad", until: nil)])
        var waited: Duration?
        let s = service(fake, moderation, clock: Clock(now), sleep: { waited = $0 })
        await s.refreshIfStale()
        #expect(waited == .seconds(3))
        #expect(moderation.suspensions == [Suspension(account: "_bad", until: nil)])
    }

    // MARK: Posting

    @Test("A suspended account can't post, and is told until when")
    func suspendedCantPost() async {
        let fake = FakeSuspensions()
        fake.list = [Suspension(account: "_me", until: tomorrow)]
        let s = service(fake, store(me: "_me"), clock: Clock(now))
        await #expect(throws: CommunityAccessError.suspended(until: tomorrow)) { try await s.ensureCanPost() }
    }

    @Test("Permanent says no date; ended, someone else's, or an unknown account may post")
    func postingCases() async throws {
        let permanent = FakeSuspensions()
        permanent.list = [Suspension(account: "_me", until: nil)]
        await #expect(throws: CommunityAccessError.suspended(until: nil)) {
            try await service(permanent, store(me: "_me"), clock: Clock(now)).ensureCanPost()
        }
        let ended = FakeSuspensions()
        ended.list = [Suspension(account: "_me", until: yesterday), Suspension(account: "_other", until: nil)]
        try await service(ended, store(me: "_me"), clock: Clock(now)).ensureCanPost()
        let unknown = FakeSuspensions()
        unknown.list = [Suspension(account: "_me", until: nil)]
        try await service(unknown, store(me: nil), clock: Clock(now)).ensureCanPost()
    }

    @Test("The message says until when, and that walking still works")
    func messages() {
        let dated = CommunityAccessError.suspended(until: tomorrow).message
        #expect(dated.hasPrefix("Your community access is paused until "))
        #expect(dated.hasSuffix("You can still walk and track as usual."))
        #expect(CommunityAccessError.suspended(until: nil).message
                == "Your community access is paused. You can still walk and track as usual.")
    }

    // MARK: Leaderboards

    @Test("Leaderboards drop suspended accounts' entries, most steps first")
    func leaderboard() throws {
        func entry(_ name: String, _ steps: Int, _ account: String) throws -> ChallengeParticipant {
            let r = CKRecord(recordType: "ChallengeEntry", recordID: CKRecord.ID(recordName: "e-\(name)"))
            r["displayName"] = name
            r["steps"] = steps
            r["deviceID"] = "d-\(name)"
            return try #require(ChallengeParticipant(record: r, creator: CKRecord.ID(recordName: account)))
        }
        let moderation = store()
        moderation.setSuspensions([Suspension(account: "_bad", until: nil)])
        let list = [try entry("A", 100, "_a"), try entry("Bad", 999, "_bad"), try entry("C", 300, "_c")]
        #expect(ChallengeService.visible(list, moderation: moderation, now: now).map(\.displayName) == ["C", "A"])
    }

    // MARK: Votes

    private final class FakeVotes: CommunityVoteStore {
        var saved = 0
        func currentUserRecordName() async throws -> String { "_me" }
        func saveVote(recordName: String, target: String, type: VoteTarget) async throws { saved += 1 }
        func votes(for targets: [String]) async throws -> [StoredVote] { [] }
    }

    @Test("A suspended account's Wockett isn't saved, and says why")
    func votesRefused() async {
        let votes = FakeVotes()
        let service = CommunityVoteService(store: votes, canVote: { throw CommunityAccessError.suspended(until: nil) })
        await #expect(throws: CommunityAccessError.self) { try await service.vote(for: "r1", type: .route) }
        #expect(votes.saved == 0)
        #expect(CommunityVotes.failureMessage(CommunityAccessError.suspended(until: nil), noun: "Wockett")
                == CommunityAccessError.suspended(until: nil).message)
    }
}
