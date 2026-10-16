import CloudKit
import CryptoKit
import Foundation
import Observation
import OSLog

// MARK: - My contributions (Trails Phase 2, Feature C, the app half)
//
// A walker who nominates a trail used to hear nothing back: `TrailNomination`
// is readable only by a Moderator, so not even their own phone can read it.
// Now every nomination carries a random claim token (spec
// feat/contribution-status, confirmed by Joe 2026-10-16). The phone keeps
// the token, on this phone only (no SwiftData property, no private-database
// record: a reinstall loses the list, accepted by Joe). When Joe features
// the trail, the staff dashboard writes a world-readable `ContributionStatus`
// named `status.<sha256(token)>`, holding only the kind, the status, the
// trail's key and name and when. Only the phone and Moderators know the
// token, so nobody else can work out which status is whose, and the record
// holds no account and no token. The phone fetches its own statuses by name,
// at most daily and whenever My contributions opens, and says so once: a
// banner on the Trails list and one local notification. No remote push.

// MARK: Vocabulary

/// What a `ContributionStatus` may say, mirrored exactly from
/// `docs/staff/contribution-status.js`, the one place it is written down.
/// `ContributionStatusTests` reads that file and fails if the two differ.
/// Change the JS file first, then this. There is no negative status, and
/// there must never be one (Joe, 2026-10-16): a nomination that is not
/// featured simply stays Sent.
enum ContributionKind: String, CaseIterable, Codable {
    case nomination
    /// Feature B (suggest a missing trail). Not sent by this version; here
    /// so the vocabulary matches the dashboard's.
    case suggestion

    var label: String {
        switch self {
        case .nomination: return "Nomination"
        case .suggestion: return "Suggestion"
        }
    }

    /// The kind's statuses, key and label, in the dashboard's order.
    /// Case-sensitive.
    var statuses: [(key: String, label: String)] {
        switch self {
        case .nomination: return [("featured", "Featured")]
        case .suggestion: return [("added", "Added")]
        }
    }

    /// The label for one of this kind's statuses, or nil for anything else
    /// (another kind's status, a different case, a status a newer dashboard
    /// added).
    func statusLabel(_ status: String) -> String? {
        statuses.first { $0.key == status }?.label
    }
}

enum ContributionStatuses {
    static let recordType = "ContributionStatus"
    /// `STATUS_RECORD_PREFIX` in contribution-status.js.
    static let recordPrefix = "status."
    /// What the phone knows by itself: the team has the contribution.
    static let sentLabel = "Sent"
    /// Only these are asked for: nothing else the record might grow.
    static let fields = ["kind", "status", "trailKey", "trailName", "decidedAt"]

    /// A fresh claim token: a random UUID, as written (upper case). The
    /// dashboard accepts either case; the name below hashes exactly this text.
    nonisolated static func newClaimToken() -> String {
        UUID().uuidString
    }

    /// `status.` + the lowercase hex SHA-256 of the token's exact UTF-8 text,
    /// nothing else hashed in: the dashboard's `contributionStatusName`.
    /// Nothing public (a trail key, an account) goes in, so nobody without
    /// the token can work it out.
    nonisolated static func recordName(claimToken: String) -> String {
        recordPrefix + SHA256.hash(data: Data(claimToken.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The status a record gives `contribution`, or nil for anything this
    /// version can't trust: another type under the name, another name, a
    /// kind or status outside the vocabulary (or not each other's), another
    /// kind than the contribution's, another trail than the one nominated.
    /// Only a Moderator can write one, but a newer dashboard may say
    /// something this version doesn't know: it is ignored, and the row stays
    /// Sent, never guessed. `decidedAt` is not read: featuring again keeps or
    /// moves it, and it is not a reason to say anything twice.
    static func status(from record: CKRecord, for contribution: Contribution) -> String? {
        guard record.recordType == recordType,
              record.recordID.recordName == recordName(claimToken: contribution.claimToken),
              let kindRaw = record["kind"] as? String, kindRaw == contribution.kind,
              let kind = ContributionKind(rawValue: kindRaw),
              let status = record["status"] as? String, kind.statusLabel(status) != nil,
              let key = record["trailKey"] as? String, key == contribution.trailKey else { return nil }
        return status
    }
}

// MARK: What the phone keeps

/// One contribution this phone sent, and what it has learned about it.
struct Contribution: Codable, Equatable, Identifiable {
    var id: String { claimToken }
    let claimToken: String
    /// A `ContributionKind` raw value. A string, so a list written by a
    /// newer version with a kind this one lacks still loads.
    let kind: String
    let trailKey: String
    let trailName: String
    let sentAt: Date
    /// The status the last answer gave (a vocabulary key), or nil: Sent.
    /// Back to nil if Joe withdraws the feature.
    var status: String?
    /// When this phone first saw a status. Never cleared: what makes each
    /// contribution announce itself once.
    var reachedAt: Date?
    /// The Trails banner has shown it.
    var bannerShown = false
    /// The local notification has been handed to the system for it.
    var notified = false

    init(claimToken: String, kind: ContributionKind, trailKey: String, trailName: String, sentAt: Date) {
        self.claimToken = claimToken
        self.kind = kind.rawValue
        self.trailKey = trailKey
        self.trailName = trailName
        self.sentAt = sentAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claimToken = try c.decode(String.self, forKey: .claimToken)
        kind = try c.decode(String.self, forKey: .kind)
        trailKey = try c.decode(String.self, forKey: .trailKey)
        trailName = try c.decode(String.self, forKey: .trailName)
        sentAt = try c.decode(Date.self, forKey: .sentAt)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        reachedAt = try c.decodeIfPresent(Date.self, forKey: .reachedAt)
        bannerShown = try c.decodeIfPresent(Bool.self, forKey: .bannerShown) ?? false
        notified = try c.decodeIfPresent(Bool.self, forKey: .notified) ?? false
    }

    var contributionKind: ContributionKind? { ContributionKind(rawValue: kind) }

    /// The row's status: the vocabulary's label, else Sent. Never anything
    /// negative: there is nothing negative to show.
    var statusLabel: String {
        status.flatMap { contributionKind?.statusLabel($0) } ?? ContributionStatuses.sentLabel
    }

    var hasStatus: Bool { status.flatMap { contributionKind?.statusLabel($0) } != nil }
}

/// The list in UserDefaults, as JSON. One unreadable entry is dropped, not
/// the whole list.
struct ContributionLedger {
    static let key = "wkt_contributions_v1"
    var defaults: UserDefaults = .standard

    private struct Lossy: Decodable {
        let value: Contribution?
        init(from decoder: Decoder) throws { value = try? Contribution(from: decoder) }
    }

    func load() -> [Contribution] {
        guard let data = defaults.data(forKey: Self.key),
              let list = try? JSONDecoder().decode([Lossy].self, from: data) else { return [] }
        return list.compactMap(\.value)
    }

    func save(_ list: [Contribution]) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.key) }
    }
}

// MARK: Copy

enum ContributionMessages {
    static let screenTitle = "My contributions"
    static let emptyTitle = "No contributions yet"
    static let emptyMessage = "Nominate a trail you love from its page in Trails. The Wockett team reads every nomination, and the best show up as Featured for walkers nearby. Yours will be listed here, and if it is featured you will see it here."
    static let footer = "Sent means the Wockett team has it. This list is kept on this iPhone only, so nominations sent before this version, or from another device, aren't in it."
    static let thanksDetail = "The Wockett team reads every nomination. If it is featured you will see it here, in My contributions."
    static let alreadyDetail = "Thanks. One nomination per trail is plenty. If it is featured you will see it in My contributions."

    /// "Your nomination of Lake Loop is now Featured". Nil when there is
    /// nothing to say.
    static func banner(for list: [Contribution]) -> String? {
        headline(for: list)
    }

    /// The local notification: one, however many became featured at once.
    static func notification(for list: [Contribution]) -> (title: String, body: String)? {
        guard let text = headline(for: list) else { return nil }
        return (list.count == 1 ? "Your nomination is Featured" : "Your nominations are Featured",
                text + ". Walkers nearby see it in Trails. Thanks for the tip.")
    }

    private static func headline(for list: [Contribution]) -> String? {
        let shown = list.filter(\.hasStatus)
        guard let first = shown.first else { return nil }
        if shown.count == 1 {
            return "Your \((first.contributionKind ?? .nomination).label.lowercased()) of \(first.trailName) is now \(first.statusLabel)"
        }
        let names = ListFormatter.localizedString(byJoining: shown.map(\.trailName))
        return "Your nominations of \(names) are now Featured"
    }
}

// MARK: Fetching statuses

/// What one name's fetch said: the record, or no record (Sent).
enum ContributionStatusLookup: Equatable {
    case found(CKRecord)
    case missing

    static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.missing, .missing): return true
        case let (.found(x), .found(y)): return x.recordID == y.recordID
        default: return false
        }
    }
}

/// Reads statuses by record name, behind a protocol so tests never reach
/// CloudKit. Reads only: the app never writes a `ContributionStatus`, and a
/// fetch by name cannot create the type.
protocol ContributionStatusStore: AnyObject {
    /// Each name with an answer: the record, or `.missing` when CloudKit has
    /// none. A name that failed on its own is left out (what is cached
    /// stays). Throws when the whole fetch failed.
    func lookup(names: [String]) async throws -> [String: ContributionStatusLookup]
}

final class CloudKitContributionStatusStore: ContributionStatusStore {
    private let db = CKContainer(identifier: WockettCloud.containerID).publicCloudDatabase
    /// CloudKit takes up to 400 IDs in one fetch.
    static let batch = 200

    func lookup(names: [String]) async throws -> [String: ContributionStatusLookup] {
        var out: [String: ContributionStatusLookup] = [:]
        for start in stride(from: 0, to: names.count, by: Self.batch) {
            let ids = names[start..<min(start + Self.batch, names.count)].map { CKRecord.ID(recordName: $0) }
            let results = try await db.records(for: ids, desiredKeys: ContributionStatuses.fields)
            for (id, result) in results {
                switch result {
                case .success(let record): out[id.recordName] = .found(record)
                case .failure(let error):
                    if (error as? CKError)?.code == .unknownItem { out[id.recordName] = .missing }
                }
            }
        }
        return out
    }
}

/// Stands in under tests (unit and UI), so nothing a test does reaches
/// CloudKit.
final class NoContributionStatusStore: ContributionStatusStore {
    func lookup(names: [String]) async throws -> [String: ContributionStatusLookup] { [:] }
}

// MARK: Service

/// The contributions this phone sent and what it knows of them: kept in
/// UserDefaults, refreshed at most daily (and whenever My contributions
/// opens), each announced once by the Trails banner and once by a local
/// notification from the background-refresh task.
@Observable
final class ContributionService {
    static let shared = ContributionService(store: defaultStore())

    /// The app's store: never the CloudKit one under tests (unit or UI).
    static func defaultStore() -> ContributionStatusStore {
        AppModelContainer.isRunningUnderTests ? NoContributionStatusStore() : CloudKitContributionStatusStore()
    }

    static let refreshInterval: TimeInterval = 86_400
    static let retryAfterFailure: TimeInterval = 600
    static let lastFetchKey = "wkt_contributions_lastFetch"

    /// Newest first.
    private(set) var contributions: [Contribution]
    private(set) var isRefreshing = false

    @ObservationIgnored private let store: ContributionStatusStore
    @ObservationIgnored private let ledger: ContributionLedger
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var failedAt: Date?
    @ObservationIgnored private var inFlight: Task<Bool, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.wockett.app", category: "Contributions")

    init(store: ContributionStatusStore, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.defaults = defaults
        self.ledger = ContributionLedger(defaults: defaults)
        self.now = now
        self.contributions = ledger.load()
    }

    /// When the last fetch worked.
    var lastFetch: Date? { defaults.object(forKey: Self.lastFetchKey) as? Date }

    /// This phone already sent a nomination for the trail: it isn't sent
    /// again (one per person per trail, as far as this phone can know).
    func hasNominated(_ trailKey: String) -> Bool {
        contributions.contains { $0.kind == ContributionKind.nomination.rawValue && $0.trailKey == trailKey }
    }

    /// A contribution reached CloudKit: keep its token.
    func noteSent(_ contribution: Contribution) {
        contributions.removeAll { $0.claimToken == contribution.claimToken }
        contributions.insert(contribution, at: 0)
        ledger.save(contributions)
    }

    /// Whether a daily refresh is due: something to ask about, a day since
    /// the last answer, and not failed in the last few minutes.
    var isDue: Bool {
        guard !contributions.isEmpty else { return false }
        let time = now()
        if let failedAt, time.timeIntervalSince(failedAt) < Self.retryAfterFailure { return false }
        guard let lastFetch else { return true }
        return time.timeIntervalSince(lastFetch) >= Self.refreshInterval
    }

    /// The daily refresh (Trails list, background task).
    @discardableResult
    func refreshIfDue() async -> Bool {
        guard isDue else { return false }
        return await refresh()
    }

    /// Asks CloudKit about every contribution now (My contributions opening,
    /// pull to refresh). Joins a refresh already running. True when it worked.
    @discardableResult
    func refresh() async -> Bool {
        guard !contributions.isEmpty else { return false }
        if let inFlight { return await inFlight.value }
        let task = Task { await self.fetch() }
        inFlight = task
        isRefreshing = true
        let worked = await task.value
        inFlight = nil
        isRefreshing = false
        return worked
    }

    private func fetch() async -> Bool {
        let names = Dictionary(contributions.map { (ContributionStatuses.recordName(claimToken: $0.claimToken), $0.claimToken) },
                               uniquingKeysWith: { first, _ in first })
        do {
            let answers = try await store.lookup(names: Array(names.keys))
            apply(answers)
            defaults.set(now(), forKey: Self.lastFetchKey)
            failedAt = nil
            return true
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? CKError)?.code == .operationCancelled { return false }
            log.error("Contribution statuses unavailable: \(error.localizedDescription, privacy: .public)")
            failedAt = now()
            return false
        }
    }

    /// Applies answers to the list as it is now (a nomination sent mid-fetch
    /// keeps its place). A record names a status, or nothing: Sent. A name
    /// with no answer keeps what was cached.
    private func apply(_ answers: [String: ContributionStatusLookup]) {
        let time = now()
        var changed = false
        for index in contributions.indices {
            var item = contributions[index]
            switch answers[ContributionStatuses.recordName(claimToken: item.claimToken)] {
            case .found(let record)?: item.status = ContributionStatuses.status(from: record, for: item)
            case .missing?: item.status = nil
            case nil: continue
            }
            if item.hasStatus, item.reachedAt == nil { item.reachedAt = time }
            if item != contributions[index] {
                contributions[index] = item
                changed = true
            }
        }
        if changed { ledger.save(contributions) }
    }

    // MARK: Saying so, once each

    /// The contributions the Trails banner should announce, now marked as
    /// shown: a second call returns none of them. Featured at the moment and
    /// never bannered before.
    func takeBanner() -> [Contribution] {
        let due = contributions.filter { $0.hasStatus && !$0.bannerShown }
        guard !due.isEmpty else { return [] }
        let ids = Set(due.map(\.claimToken))
        for index in contributions.indices where ids.contains(contributions[index].claimToken) {
            contributions[index].bannerShown = true
        }
        ledger.save(contributions)
        return due
    }

    /// The contributions a notification would announce: featured now, never
    /// notified, and not already seen on the banner (opening the app said
    /// it first).
    var notificationDue: [Contribution] {
        contributions.filter { $0.hasStatus && !$0.notified && !$0.bannerShown }
    }

    /// The background-refresh task's step: the daily refresh, then one local
    /// notification for whatever became featured, through `NotificationService`
    /// (which drops it when the person has notifications off; quiet delivery
    /// counts). Marked notified only once the system took it, so a phone
    /// with notifications off still gets the banner. Returns how many it told.
    @discardableResult
    func backgroundCheck(notifications: NotificationService) async -> Int {
        await refreshIfDue()
        let due = notificationDue
        guard let message = ContributionMessages.notification(for: due) else { return 0 }
        let scheduled = await notifications.schedule(.contributionFeatured, title: message.title, body: message.body,
                                                     trigger: nil)
        guard scheduled else { return 0 }
        let ids = Set(due.map(\.claimToken))
        for index in contributions.indices where ids.contains(contributions[index].claimToken) {
            contributions[index].notified = true
        }
        ledger.save(contributions)
        return due.count
    }
}
