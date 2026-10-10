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
    static let shared = SuspensionService(store: AppModelContainer.isRunningUnderTests
                                          ? NoCommunitySuspensionStore() : CloudKitCommunitySuspensionStore())

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
    private let log = Logger(subsystem: "com.wockett.app", category: "Suspensions")
    /// When the next fetch is due; nil fetches now.
    private(set) var nextRefresh: Date?
    private var inFlight: Task<Void, Never>?

    init(store: CommunitySuspensionStore,
         moderation: CommunityModerationStore = .shared,
         now: @escaping () -> Date = Date.init,
         sleep: @escaping OptimisticVote.Sleep = { try await Task.sleep(for: $0) }) {
        self.store = store
        self.moderation = moderation
        self.now = now
        self.sleep = sleep
    }

    /// Fetches the list if it is due, waiting at most `deadline`; never
    /// throws. Calls while a fetch runs wait for that one.
    func refreshIfStale() async {
        if let inFlight { return await inFlight.value }
        if let nextRefresh, now() < nextRefresh { return }
        let task = Task { await refresh() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func refresh() async {
        do {
            let list = try await OptimisticVote.withDeadline(Self.deadline, sleep: sleep) { [store] in
                try await store.suspensions()
            }
            guard let list else {
                log.error("Suspension list timed out; using the one held")
                nextRefresh = now().addingTimeInterval(Self.retryAfterFailure)
                return
            }
            moderation.setSuspensions(list)
            nextRefresh = now().addingTimeInterval(Self.refreshInterval)
        } catch {
            // Offline, signed out, or Production without the type: keep the
            // list held. A load never fails over this.
            log.error("Suspension list unavailable: \(error.localizedDescription, privacy: .public)")
            nextRefresh = now().addingTimeInterval(Self.retryAfterFailure)
        }
    }

    /// Throws `CommunityAccessError.suspended` when this account is suspended
    /// now. An unknown own account is allowed.
    func ensureCanPost() async throws {
        await refreshIfStale()
        if let mine = moderation.mySuspension(at: now()) {
            throw CommunityAccessError.suspended(until: mine.until)
        }
    }
}
