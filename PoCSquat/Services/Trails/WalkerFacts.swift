import CloudKit
import Foundation
import OSLog

// MARK: - Walker reports (Trails Phase 2, Feature A)
//
// After a hike or a walk on a trail, the summary asks a few one-tap questions
// about the trail (spec feat/trail-walker-reports, confirmed by Joe
// 2026-10-15). Each answer is one `TrailFactReport`: the trail's key and
// region, the question and the answer. No name, no free text, no location,
// and the walk itself is never sent. Reports are readable only by a
// Moderator (cloudkit/schema.ckdb): phones never read them. Joe publishes a
// `TrailFactSummary` from the staff dashboard once enough walkers agree, and
// that is all other phones ever see (`TrailFactSummaries`).

// MARK: Vocabulary

/// What a walker can report, mirrored exactly from `docs/staff/walker-facts.js`,
/// the one place the vocabulary is written down: fact and value keys, labels
/// and which facts are published. `WalkerFactsTests` reads that file and fails
/// if the two differ. Change the JS file first, then this.
enum WalkerFact: String, CaseIterable, Codable {
    case dogs
    case stroller
    case wheelchair
    case surface
    /// Collected and counted in the dashboard only: never shown in the app
    /// and never published (Joe, 2026-10-15).
    case liked

    /// The value keys, in the dashboard's order. Case-sensitive.
    var values: [String] {
        switch self {
        case .dogs: return ["leashRequired", "offLeashOK", "noDogs"]
        case .stroller, .wheelchair: return ["yes", "no"]
        case .surface: return ["paved", "packedDirt", "rockyOrRooty"]
        case .liked: return ["up", "down"]
        }
    }

    /// The fact's label in walker-facts.js.
    var label: String {
        switch self {
        case .dogs: return "Dogs"
        case .stroller: return "Stroller OK"
        case .wheelchair: return "Wheelchair OK"
        case .surface: return "Surface"
        case .liked: return "How was it?"
        }
    }

    /// Whether a `TrailFactSummary` is ever published (and shown) for it.
    var publishes: Bool { self != .liked }

    /// A value's label in walker-facts.js: what a "Walkers say" line reads,
    /// "Dogs on leash". Nil for a value outside the vocabulary.
    func valueLabel(_ value: String) -> String? {
        switch (self, value) {
        case (.dogs, "leashRequired"): return "Dogs on leash"
        case (.dogs, "offLeashOK"): return "Dogs off leash OK"
        case (.dogs, "noDogs"): return "No dogs"
        case (.stroller, "yes"): return "Stroller OK"
        case (.stroller, "no"): return "Not for strollers"
        case (.wheelchair, "yes"): return "Wheelchair OK"
        case (.wheelchair, "no"): return "Not for wheelchairs"
        case (.surface, "paved"): return "Paved"
        case (.surface, "packedDirt"): return "Packed dirt"
        case (.surface, "rockyOrRooty"): return "Rocky or rooty"
        case (.liked, "up"): return "Thumbs up"
        case (.liked, "down"): return "Thumbs down"
        default: return nil
        }
    }

    func knows(_ value: String) -> Bool { values.contains(value) }

    // App-only wording for the post-walk card (not part of the vocabulary).

    var question: String {
        switch self {
        case .dogs: return "Dogs?"
        case .stroller: return "Good for a stroller?"
        case .wheelchair: return "Good for a wheelchair?"
        case .surface: return "Surface underfoot?"
        case .liked: return "How was it?"
        }
    }

    /// A chip's text: short, because the question says what it is about.
    func chipTitle(_ value: String) -> String {
        switch (self, value) {
        case (.dogs, "leashRequired"): return "On leash"
        case (.dogs, "offLeashOK"): return "Off leash OK"
        case (.stroller, "yes"), (.wheelchair, "yes"): return "Yes"
        case (.stroller, "no"), (.wheelchair, "no"): return "No"
        default: return valueLabel(value) ?? value
        }
    }

    /// The icon on a "Walkers say" line. `liked` is never shown.
    var symbol: WktSymbol {
        switch self {
        case .dogs: return .pets
        case .stroller: return .stroller
        case .wheelchair: return .wheelchair
        case .surface: return .trailSurface
        case .liked: return .trailPick
        }
    }
}

// MARK: Reports

enum TrailFactReports {
    static let recordType = "TrailFactReport"

    /// `report.<random UUID>`. Not a hash of (trail, fact, account), as the
    /// spec first had it (critic run 1 on PR 2): every input to that hash is
    /// public (the account id is the creator on every public record a person
    /// made, trail keys are in the packs), so anyone could compute the name
    /// for someone else and try to save it; CloudKit refusing the duplicate
    /// would tell them that person reported on that trail, a location history
    /// read without read access. A random name tells nothing. One answer per
    /// person still holds where it matters: the dashboard counts each creator
    /// once per trail and fact (PR 1 decisions), and this phone asks about a
    /// trail once and locks each answered question.
    static func recordName() -> String {
        "report." + UUID().uuidString.lowercased()
    }

    /// The record for one answer: `trailKey`, `region`, `fact` and `value`,
    /// and nothing else. Not `TrailRef.write(to:)`: that adds the name and a
    /// point. Nil for a value outside the vocabulary.
    static func record(trail: TrailRef, fact: WalkerFact, value: String) -> CKRecord? {
        guard fact.knows(value), !trail.trailKey.isEmpty else { return nil }
        let record = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: recordName()))
        record["trailKey"] = trail.trailKey
        record["region"] = trail.region
        record["fact"] = fact.rawValue
        record["value"] = value
        return record
    }

    enum Outcome: Equatable {
        case sent
        /// CloudKit refused a record name it already has. Unlikely with random
        /// names; kept so a duplicate save is never shown as a network error.
        case alreadyAnswered
        case failed(String)
    }

    static let signInMessage = "Sign in to iCloud in the Settings app to answer."
    static let failedMessage = "Couldn't send your answer. Check your connection and try again."
    static let schemaMissingMessage = "This test build won't send trail answers until the walker-reports schema is in CloudKit Development."

    static func outcome(of error: Error) -> Outcome {
        if let access = error as? CommunityAccessError { return .failed(access.message) }
        if error is TrailFactReportSchemaMissing { return .failed(schemaMissingMessage) }
        switch (error as? CKError)?.code {
        case .serverRecordChanged?: return .alreadyAnswered
        case .notAuthenticated?: return .failed(signInMessage)
        default: return .failed(failedMessage)
        }
    }

    /// Debug builds only: whether the probe (a query for `TrailFactReport`)
    /// shows the type already exists in this environment, so a save cannot
    /// create it. A Debug build's first save of an unknown type creates it
    /// in Development with CloudKit's default grants, which let everyone
    /// read reports (critic run 1 on PR 1). Allowed only when the query
    /// worked, or was refused for permission (the type exists and only a
    /// Moderator may read it); anything else, including "did not find record
    /// type", is refused. Fails closed: it costs only a Debug build's answer.
    nonisolated static func debugSaveAllowed(probeError: Error?) -> Bool {
        guard let probeError else { return true }
        return (probeError as? CKError)?.code == .permissionFailure
    }

    /// A Debug build's save: probe once, save only if the probe allows it,
    /// and return whether the probe has passed, so later saves skip it (a
    /// value, not `inout`: two quick taps save at once, and an `inout` on
    /// the store's property across a suspension would trap). A
    /// probe that failed for the network rethrows that error (the usual
    /// "check your connection"); any other refusal is
    /// `TrailFactReportSchemaMissing`. Either way nothing is saved.
    static func guardedSave(checked: Bool,
                            probe: () async throws -> Void,
                            save: () async throws -> Void) async throws -> Bool {
        if !checked {
            var probeError: Error?
            do { try await probe() } catch { probeError = error }
            guard debugSaveAllowed(probeError: probeError) else {
                let transient: [CKError.Code] = [.networkUnavailable, .networkFailure, .serviceUnavailable,
                                                 .requestRateLimited, .zoneBusy]
                if let code = (probeError as? CKError)?.code, transient.contains(code), let probeError { throw probeError }
                throw TrailFactReportSchemaMissing()
            }
        }
        try await save()
        return true
    }
}

/// Thrown by a Debug build's store when `TrailFactReport` is not in the
/// container yet (`TrailFactReports.debugSaveAllowed`).
struct TrailFactReportSchemaMissing: Error {}

/// The CloudKit side of reporting, behind a protocol so tests never reach
/// iCloud (and so never create the type by accident).
protocol TrailFactReportStore: AnyObject {
    func currentUserRecordName() async throws -> String
    func save(_ record: CKRecord) async throws
}

final class CloudKitTrailFactReportStore: TrailFactReportStore {
    private let container = CKContainer(identifier: WockettCloud.containerID)
    private let log = Logger(subsystem: "com.wockett.app", category: "TrailFactReports")
    #if DEBUG
    private var schemaChecked = false
    #endif

    func currentUserRecordName() async throws -> String {
        try await container.userRecordID().recordName
    }

    func save(_ record: CKRecord) async throws {
        let db = container.publicCloudDatabase
        #if DEBUG
        let log = log
        schemaChecked = try await TrailFactReports.guardedSave(checked: schemaChecked, probe: {
            let query = CKQuery(recordType: TrailFactReports.recordType,
                                predicate: NSPredicate(format: "trailKey == %@", "schema-check"))
            do {
                _ = try await db.records(matching: query, resultsLimit: 1)
            } catch {
                log.error("TrailFactReport probe: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }, save: {
            _ = try await db.save(record)
        })
        #else
        _ = try await db.save(record)
        #endif
    }
}

/// Stands in under unit tests, so nothing a test does can reach CloudKit.
final class NoTrailFactReportStore: TrailFactReportStore {
    func currentUserRecordName() async throws -> String { throw CKError(.notAuthenticated) }
    func save(_ record: CKRecord) async throws { throw CKError(.notAuthenticated) }
}

@MainActor
enum TrailFactReportSubmission {
    nonisolated static let deadline: Duration = .seconds(15)
    /// A report is Community Content (terms patch T2), so the account must
    /// have agreed to the current Terms. Read by the default `canPost`.
    static let needsTerms = true

    /// The app's store: never the CloudKit one under unit tests.
    static func defaultStore() -> TrailFactReportStore {
        AppModelContainer.isRunningUnderTests ? NoTrailFactReportStore() : CloudKitTrailFactReportStore()
    }

    /// Sends one answer. The screen asks for the Terms first
    /// (`CommunityTermsGate`); `canPost` refuses a suspended account, and an
    /// action that skipped the gate. Needs a signed-in iCloud account (the
    /// dashboard counts each creator once); the account is not in the record.
    static func submit(_ trail: TrailRef, fact: WalkerFact, value: String,
                       store: TrailFactReportStore,
                       canPost: @escaping () async throws -> Void = { try await SuspensionService.shared.ensureCanPost(needsTerms: needsTerms) },
                       knownReporter: @escaping () -> String? = { MyAccount.recordName },
                       deadline: Duration = deadline,
                       sleep: @escaping OptimisticVote.Sleep = { try await Task.sleep(for: $0) }) async -> TrailFactReports.Outcome {
        do {
            try await canPost()
            let saved: Bool? = try await OptimisticVote.withDeadline(deadline, sleep: sleep) {
                guard ((try? await store.currentUserRecordName()) ?? knownReporter()) != nil else {
                    throw CKError(.notAuthenticated)
                }
                guard let record = TrailFactReports.record(trail: trail, fact: fact, value: value) else {
                    throw CKError(.invalidArguments)
                }
                try Task.checkCancellation()
                try await store.save(record)
                return true
            }
            return saved == nil ? .failed(TrailFactReports.failedMessage) : .sent
        } catch {
            return TrailFactReports.outcome(of: error)
        }
    }
}

// MARK: When to ask

/// Whether the summary asks about the trail (spec criterion 3): only on the
/// summary right after a walk on a trail ends, never during one, at most once
/// per trail and once a week overall, never for a trail already answered,
/// never after "Don't ask again". Kept in UserDefaults on this phone.
struct TrailReportAskPolicy {
    static let offKey = "wkt_trailReports_off"
    static let askedKey = "wkt_trailReports_askedTrails"
    static let answeredKey = "wkt_trailReports_answeredTrails"
    static let lastAskKey = "wkt_trailReports_lastAsk"
    static let thankedKey = "wkt_trailReports_thanked"

    /// One ask a week at most, whatever the trail.
    static let minimumGap: TimeInterval = 7 * 24 * 3_600
    /// A walk this short hardly saw the trail: no ask.
    static let minimumMeters: Double = 400
    /// The newest this many trails are remembered, so the lists stay small.
    static let rememberedTrails = 500

    var defaults: UserDefaults = .standard
    var now: () -> Date = Date.init

    /// "Don't ask again", from the card or the Settings switch.
    var asksOff: Bool {
        get { defaults.bool(forKey: Self.offKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.offKey) }
    }

    func hasAsked(_ trailKey: String) -> Bool {
        (defaults.stringArray(forKey: Self.askedKey) ?? []).contains(trailKey)
    }

    func hasAnswered(_ trailKey: String) -> Bool {
        (defaults.stringArray(forKey: Self.answeredKey) ?? []).contains(trailKey)
    }

    /// Whether to ask about `trail` on the summary of `session`.
    /// `justFinished` is false for a summary opened from history;
    /// `walkInProgress` is true while a walk is being recorded
    /// (`ActiveWalkStore.isWalkInProgress`).
    func shouldAsk(trail: TrailRef?, session: WalkSession, justFinished: Bool, walkInProgress: Bool) -> Bool {
        guard let trail, justFinished, !walkInProgress, !asksOff else { return false }
        guard ActivitySummaryContent.mode(of: session) == .walking,
              session.totalDistance >= Self.minimumMeters else { return false }
        guard !hasAsked(trail.trailKey), !hasAnswered(trail.trailKey) else { return false }
        if let last = defaults.object(forKey: Self.lastAskKey) as? Date,
           now().timeIntervalSince(last) < Self.minimumGap { return false }
        return true
    }

    /// The card was seen (scrolled into view, or used): this trail is not
    /// asked about again, and no other for a week. Not when the summary
    /// merely opened: the card may sit below the fold, and Done is always
    /// in reach (critic run 1 on PR 2).
    func noteAsked(_ trail: TrailRef) {
        remember(trail.trailKey, in: Self.askedKey)
        defaults.set(now(), forKey: Self.lastAskKey)
    }

    /// An answer reached CloudKit. True the first time ever, for the
    /// thank-you; `thank: false` records the trail without using that up.
    @discardableResult
    func noteAnswered(_ trail: TrailRef, thank: Bool = true) -> Bool {
        remember(trail.trailKey, in: Self.answeredKey)
        guard thank, !defaults.bool(forKey: Self.thankedKey) else { return false }
        defaults.set(true, forKey: Self.thankedKey)
        return true
    }

    private func remember(_ key: String, in listKey: String) {
        var list = (defaults.stringArray(forKey: listKey) ?? []).filter { $0 != key }
        list.append(key)
        defaults.set(Array(list.suffix(Self.rememberedTrails)), forKey: listKey)
    }
}
