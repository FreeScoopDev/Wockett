import CloudKit
import Foundation
import OSLog

// MARK: - Community suspensions
//
// A moderator suspends an account from the staff dashboard (wockett.app/staff)
// by writing a public `Suspension` record named `suspension.<account>`: the
// account's user record name and, unless permanent, when it ends. Every phone
// reads the list, so the account's posts, routes, challenges and leaderboard
// entries are hidden for everyone else (CommunityModerationStore.shouldHide),
// and the suspended person's own phone refuses to post (`ensureCanPost`).
// Nothing about why: the reason stays in the Moderator-only ModerationAction.
//
// Only a Moderator can create one (schema: READ _world; READ, CREATE, WRITE
// Moderator). There is no server, so a modified client could still write
// records; every other phone hides them anyway.

/// One suspended account. `until` nil means permanent.
struct Suspension: Codable, Equatable {
    let account: String
    let until: Date?

    func isActive(at now: Date) -> Bool {
        guard let until else { return true }
        return until > now
    }
}

enum CommunitySuspensions {
    static let recordType = "Suspension"

    static func recordName(account: String) -> String { "suspension.\(account)" }

    /// A Suspension record as the app uses it; nil without an account.
    static func suspension(from record: CKRecord) -> Suspension? {
        guard let account = record["accountRecordName"] as? String, !account.isEmpty else { return nil }
        return Suspension(account: account, until: record["until"] as? Date)
    }
}

/// What a suspended person is told when they try to post, share, create,
/// join or give a Wockett. Screens show `message` instead of their usual
/// "check your connection".
enum CommunityAccessError: LocalizedError, Equatable {
    case suspended(until: Date?)

    var errorDescription: String? { message }

    var message: String {
        switch self {
        case .suspended(let until?):
            let date = until.formatted(date: .abbreviated, time: .omitted)
            return "Your community access is paused until \(date). You can still walk and track as usual."
        case .suspended(nil):
            return "Your community access is paused. You can still walk and track as usual."
        }
    }
}

// MARK: - Store seam

/// The CloudKit side, behind a protocol so the rules are tested without a
/// network or an iCloud account (CI has neither).
protocol CommunitySuspensionStore: AnyObject {
    /// Every Suspension record, ended ones included.
    func suspensions() async throws -> [Suspension]
}

final class CloudKitCommunitySuspensionStore: CommunitySuspensionStore {
    private let db = CKContainer(identifier: WockettCloud.containerID).publicCloudDatabase

    func suspensions() async throws -> [Suspension] {
        let query = CKQuery(recordType: CommunitySuspensions.recordType, predicate: NSPredicate(value: true))
        let (results, _) = try await db.records(matching: query, desiredKeys: ["accountRecordName", "until"],
                                                resultsLimit: 400)
        return results.compactMap { try? $0.1.get() }.compactMap(CommunitySuspensions.suspension(from:))
    }
}

/// Under unit and UI tests: no suspensions, and no CloudKit.
final class NoCommunitySuspensionStore: CommunitySuspensionStore {
    func suspensions() async throws -> [Suspension] { [] }
}

// MARK: - Service

/// Keeps the moderation store's suspension list fresh, and refuses posting
/// from a suspended account.
final class SuspensionService {
    static let shared = AppModelContainer.isRunningUnderTests
        ? SuspensionService(store: NoCommunitySuspensionStore(), refreshAccount: {})
        : SuspensionService(store: CloudKitCommunitySuspensionStore())

    /// At most this often from CloudKit; community loads in between use the list held.
    static let refreshInterval: TimeInterval = 600
    /// After a failed fetch, try again this much sooner than a full interval.
    static let retryAfterFailure: TimeInterval = 60
    /// The longest a community load waits for the list before using the one held.
    static let deadline: Duration = .seconds(3)

    private let store: CommunitySuspensionStore
    private let moderation: CommunityModerationStore
    private let now: () -> Date
    private let sleep: OptimisticVote.Sleep
    /// Looks up this phone's own account when it isn't known yet (a fresh install).
    private let refreshAccount: () async -> Void
    private let log = Logger(subsystem: "com.wockett.app", category: "Suspensions")
    /// When the next fetch is due; nil fetches now.
    private(set) var nextRefresh: Date?
    private var inFlight: Task<Void, Never>?

    init(store: CommunitySuspensionStore,
         moderation: CommunityModerationStore = .shared,
         now: @escaping () -> Date = Date.init,
         sleep: @escaping OptimisticVote.Sleep = { try await Task.sleep(for: $0) },
         refreshAccount: @escaping () async -> Void = { await MyAccount.refresh() }) {
        self.store = store
        self.moderation = moderation
        self.now = now
        self.sleep = sleep
        self.refreshAccount = refreshAccount
    }

    /// Starts a fetch if one is due, and waits for it at most `deadline`;
    /// never throws. The fetch itself runs to the end in its own task, so a
    /// slow one still updates the list when it lands, for the next load.
    /// Calls while a fetch runs wait on that one.
    func refreshIfStale() async {
        if inFlight == nil {
            if let nextRefresh, now() < nextRefresh { return }
            inFlight = Task { await self.fetch() }
        }
        guard let task = inFlight else { return }
        let finished = try? await OptimisticVote.withDeadline(Self.deadline, sleep: sleep) {
            await task.value
            return true
        }
        if finished == nil { log.error("Suspension list slow; this load uses the one held") }
    }

    private func fetch() async {
        defer { inFlight = nil }
        do {
            moderation.setSuspensions(try await store.suspensions())
            nextRefresh = now().addingTimeInterval(Self.refreshInterval)
        } catch {
            // Offline, signed out, or Production without the type: keep the
            // list held. A load never fails over this.
            log.error("Suspension list unavailable: \(error.localizedDescription, privacy: .public)")
            nextRefresh = now().addingTimeInterval(Self.retryAfterFailure)
        }
    }

    /// Throws `CommunityAccessError.suspended` when this account is suspended
    /// now. An own account still unknown after a lookup is allowed.
    func ensureCanPost() async throws {
        await refreshIfStale()
        // A fresh install doesn't know its own account until Community is
        // opened; posting from elsewhere must not skip the check.
        if !moderation.knowsMyAccount { await refreshAccount() }
        if let mine = moderation.mySuspension(at: now()) {
            throw CommunityAccessError.suspended(until: mine.until)
        }
    }
}
