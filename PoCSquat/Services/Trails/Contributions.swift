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
    nonisolated static let recordPrefix = "status."
    /// What the phone knows by itself: the team has the contribution.
    static let sentLabel = "Sent"
    /// Only what the decode reads is asked for (`ContributionStatus` also
    /// holds `trailName` and `decidedAt`; the row shows the name as nominated,
    /// and `decidedAt` is never a reason to say anything again).
    static let fields = ["kind", "status", "trailKey"]

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

    /// One name's fetch result: a record, no record (`unknownItem`: Sent), or
    /// nil for any other error, so a transient failure keeps what is cached
    /// rather than turning Featured back into Sent.
    static func answer(_ result: Result<CKRecord, Error>) -> ContributionStatusLookup? {
        switch result {
        case .success(let record): return .found(record)
        case .failure(let error): return (error as? CKError)?.code == .unknownItem ? .missing : nil
        }
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
    /// The Trails banner has shown it. Never cleared: with `notified`, what
    /// makes each contribution announce itself once.
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
    static let footer = "Sent means the Wockett team has it. This list is kept on this device only (and in its backups), so nominations sent before this version, or from another device, aren't in it."
    static let thanksDetail = "The Wockett team reads every nomination. If it is featured you will see it here, in My contributions."
    static let alreadyDetail = "Thanks. One nomination per trail is plenty. If it is featured you will see it in My contributions."

    /// Under the banner's headline.
    static let thanks = "Thanks for the tip."

    /// "Your nomination of Lake Loop was featured by the Wockett team". Past
    /// tense on purpose: a feature can end before the person reads it, and
    /// this stays true. Nil when there is nothing to say.
    static func banner(for list: [Contribution]) -> String? {
        headline(for: list)
    }

    /// The local notification: one, however many were featured at once.
    static func notification(for list: [Contribution]) -> (title: String, body: String)? {
        let shown = list.filter(\.hasStatus)
        guard let text = headline(for: shown) else { return nil }
        let kinds = Set(shown.map(\.kind))
        let noun: String
        if kinds.count == 1, let kind = shown.first?.contributionKind {
            noun = kind.label.lowercased() + (shown.count == 1 ? "" : "s")
        } else {
            noun = "contributions"
        }
        let verb = shown.count == 1 ? "was" : "were"
        let status = kinds.count == 1 ? (shown.first?.statusLabel.lowercased() ?? "featured") : "taken up"
        return ("Your \(noun) \(verb) \(status)", text + ". " + thanks)
    }

    /// One sentence for any number of contributions, worded from the
    /// vocabulary: "Your nominations of A and B were featured by the Wockett
    /// team"; mixed kinds (once Feature B adds suggestions) say
    /// "contributions".
    private static func headline(for list: [Contribution]) -> String? {
        let shown = list.filter(\.hasStatus)
        guard let first = shown.first else { return nil }
        let names = ListFormatter.localizedString(byJoining: shown.map(\.trailName))
        let kinds = Set(shown.map(\.kind))
        guard kinds.count == 1, let kind = first.contributionKind else {
            return "Your contributions for \(names) were taken up by the Wockett team"
        }
        let noun = kind.label.lowercased() + (shown.count == 1 ? "" : "s")
        let verb = shown.count == 1 ? "was" : "were"
        return "Your \(noun) of \(names) \(verb) \(first.statusLabel.lowercased()) by the Wockett team"
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
                if let answer = ContributionStatuses.answer(result) { out[id.recordName] = answer }
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
    /// A fetch that takes longer gives up (and counts as failed), so a hung
    /// CloudKit call can't hold the background task or a screen's refresh.
    nonisolated static let fetchDeadline: Duration = .seconds(10)

    /// Newest first.
    private(set) var contributions: [Contribution]

    @ObservationIgnored private let store: ContributionStatusStore
    @ObservationIgnored private let ledger: ContributionLedger
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: OptimisticVote.Sleep
    @ObservationIgnored private var failedAt: Date?
    @ObservationIgnored private var inFlight: Task<Bool, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.wockett.app", category: "Contributions")

    init(store: ContributionStatusStore, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         sleep: @escaping OptimisticVote.Sleep = { try await Task.sleep(for: $0) }) {
        self.store = store
        self.defaults = defaults
        self.ledger = ContributionLedger(defaults: defaults)
        self.now = now
        self.sleep = sleep
        self.contributions = ledger.load()
    }

    /// Whether this service reads a stand-in store (always, under tests).
    var storeIsLocal: Bool { store is NoContributionStatusStore }

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
        let worked = await task.value
        inFlight = nil
        return worked
    }

    private func fetch() async -> Bool {
        let names = Dictionary(contributions.map { (ContributionStatuses.recordName(claimToken: $0.claimToken), $0.claimToken) },
                               uniquingKeysWith: { first, _ in first })
        let store = store
        let wanted = Array(names.keys)
        do {
            guard let answers = try await OptimisticVote.withDeadline(Self.fetchDeadline, sleep: sleep, {
                try await store.lookup(names: wanted)
            }) else {
                log.error("Contribution statuses: no answer in time")
                failedAt = now()
                return false
            }
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
        var changed = false
        for index in contributions.indices {
            var item = contributions[index]
            switch answers[ContributionStatuses.recordName(claimToken: item.claimToken)] {
            case .found(let record)?: item.status = ContributionStatuses.status(from: record, for: item)
            case .missing?: item.status = nil
            case nil: continue
            }
            if item != contributions[index] {
                contributions[index] = item
                changed = true
            }
        }
        if changed { ledger.save(contributions) }
    }

    // MARK: Saying so, once each

    /// What the Trails list does when it opens: the daily refresh, then
    /// whatever is newly featured, taken (marked shown) for its banner.
    func bannerAfterRefresh() async -> [Contribution] {
        await refreshIfDue()
        return takeBanner()
    }

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
