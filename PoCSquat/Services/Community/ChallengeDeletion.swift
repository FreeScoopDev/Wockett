import CloudKit
import SwiftUI

// MARK: - Deleting a challenge you created
//
// Joe, 2026-10-11: a challenge only you are in is yours to delete; once
// others have joined, deleting it would take their progress with it, so you
// ask and a moderator removes it (the staff dashboard's Remove for everyone
// deletes the challenge and every entry). The ask is a CommunityReport on
// the challenge with reason "ownerRequest", so it lands in the dashboard's
// Reports queue with no new record type.

/// Every entry in a challenge, unfiltered: the leaderboard hides suspended
/// and deleted entries, but they still joined. `unreadable` counts entries
/// that couldn't be read or decoded: they are someone's too.
protocol ChallengeEntryLister: AnyObject {
    func entries(of challengeKey: String) async throws -> (entries: [ChallengeParticipant], unreadable: Int)
}

final class CloudKitChallengeEntryLister: ChallengeEntryLister {
    private let db = CKContainer(identifier: WockettCloud.containerID).publicCloudDatabase

    func entries(of challengeKey: String) async throws -> (entries: [ChallengeParticipant], unreadable: Int) {
        let query = CKQuery(recordType: "ChallengeEntry", predicate: NSPredicate(format: "challengeRecordName == %@", challengeKey))
        let (results, _) = try await db.records(matching: query, resultsLimit: 400)
        var entries: [ChallengeParticipant] = []
        var unreadable = 0
        for (_, result) in results {
            if let record = try? result.get(), let entry = ChallengeParticipant(record: record) {
                entries.append(entry)
            } else {
                unreadable += 1
            }
        }
        return (entries, unreadable)
    }
}

enum ChallengeDeletion {
    static let deleteTitle = "Delete this challenge?"
    static let deleteMessage = "This removes the challenge and your entry for everyone."
    static let requestTitle = "Ask to delete this challenge?"
    static let requestSent = "Request sent. The Wockett team will review it."
    static let requestAlreadySent = "You've asked today already. The Wockett team will review it."
    /// How long Delete waits on CloudKit before saying so.
    static let deadline: Duration = .seconds(15)
    static let timedOut = "That's taking too long. Check your connection and try again."
    /// The report reason the dashboard reads as "Owner asked to delete it".
    static let requestReason = "ownerRequest"

    static func requestMessage(others: Int) -> String {
        let who = others == 1 ? "1 other person has" : "\(others) other people have"
        return "\(who) joined, so the Wockett team removes it, with their entries. Send them a request?"
    }

    /// Entries made by anyone but you. An entry whose account is unknown
    /// counts as someone else's: when in doubt, ask rather than delete.
    static func othersJoined(_ entries: [ChallengeParticipant], moderation: CommunityModerationStore) -> Int {
        entries.filter { !moderation.isMine(CommunityAuthor(name: $0.displayName, account: $0.account)) }.count
    }

    /// What tapping Delete leads to.
    enum Plan: Equatable {
        case delete
        case request(others: Int)
        case failed(String)
    }

    /// Asked when Delete is tapped and again when it's confirmed: someone may
    /// have joined while the question was up.
    @MainActor
    static func plan(for challenge: WalkChallenge, lister: ChallengeEntryLister = CloudKitChallengeEntryLister(),
                     moderation: CommunityModerationStore = .shared,
                     sleep: @escaping OptimisticVote.Sleep = { try await Task.sleep(for: $0) }) async -> Plan {
        do {
            let found = try await OptimisticVote.withDeadline(deadline, sleep: sleep) {
                try await lister.entries(of: challenge.id.recordName)
            }
            guard let found else { return .failed(timedOut) }
            let others = othersJoined(found.entries, moderation: moderation) + found.unreadable
            return others == 0 ? .delete : .request(others: others)
        } catch {
            if (error as? CKError)?.code == .notAuthenticated {
                return .failed(CommunityDeletion.signInMessage)
            }
            return .failed("Couldn't check who has joined. Check your connection and try again.")
        }
    }

    /// Deletes the challenge, then your own entry if this phone tracks one
    /// (best effort: an entry left behind belongs to a challenge no list
    /// shows). Clears "joined" and marks the challenge deleted everywhere.
    @MainActor
    static func delete(_ challenge: WalkChallenge,
                       deleter: CommunityRecordDeleter = CloudKitCommunityRecordDeleter(),
                       defaults: UserDefaults = .standard,
                       moderation: CommunityModerationStore = .shared) async -> CommunityDeletion.Outcome {
        var failure: Error?
        do { try await deleter.delete(challenge.id) } catch { failure = error }
        let outcome = CommunityDeletion.outcome(of: failure)
        guard outcome == .deleted else { return outcome }
        let key = challenge.id.recordName
        if let entry = (defaults.dictionary(forKey: ChallengeService.joinedKey) as? [String: String])?[key] {
            try? await deleter.delete(CKRecord.ID(recordName: entry))
            moderation.markDeleted(CKRecord.ID(recordName: entry))
            CommunityDeletion.forget(CommunityDeletionRequest(kind: .entry(challengeKey: key), recordID: CKRecord.ID(recordName: entry)),
                                     defaults: defaults)
        }
        moderation.markDeleted(challenge.id)
        return .deleted
    }

    /// The request: a report on the challenge, reason "ownerRequest", under a
    /// random name like every report, nothing about you but CloudKit's own
    /// creator reference. The dashboard checks that creator against the
    /// challenge's before calling it the owner's.
    static func requestRecord(for challenge: WalkChallenge, others: Int) -> CKRecord {
        var report = CommunityReport(challenge: challenge)
        report.note = "The person who created it asked to delete it. \(others) other \(others == 1 ? "person has" : "people have") joined."
        let record = CommunityReports.record(for: report)
        record["reason"] = requestReason
        return record
    }

    /// One request per challenge per day from this phone (so asking again
    /// after a moderator dismissed it still reaches the queue): the person's
    /// own day, not UTC's, since "today" means their today.
    static func requestEntry(for challenge: WalkChallenge, on day: Date, timeZone: TimeZone) -> String {
        let stamp = day.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
        return CommunityReportLedger.requestEntry(challenge: challenge.id.recordName, day: stamp)
    }

    enum RequestOutcome: Equatable {
        case sent
        case alreadySent
        case failed(String)
    }

    @MainActor
    static func request(_ challenge: WalkChallenge, others: Int,
                        store: CommunityReportStore = CloudKitCommunityReportStore(),
                        ledger: CommunityReportLedger = CommunityReportLedger(),
                        on day: Date = Date(), timeZone: TimeZone = .current,
                        sleep: @escaping OptimisticVote.Sleep = { try await Task.sleep(for: $0) }) async -> RequestOutcome {
        let entry = requestEntry(for: challenge, on: day, timeZone: timeZone)
        if ledger.contains(entry) { return .alreadySent }
        do {
            let saved: Bool? = try await OptimisticVote.withDeadline(deadline, sleep: sleep) {
                try await store.save(requestRecord(for: challenge, others: others))
                return true
            }
            guard saved != nil else { return .failed(timedOut) }
            ledger.record(entry)
            return .sent
        } catch {
            return (error as? CKError)?.code == .notAuthenticated
                ? .failed("Sign in to iCloud in the Settings app to send it.")
                : .failed("Couldn't send the request. Check your connection and try again.")
        }
    }
}

// MARK: - View

extension View {
    /// Delete (or ask to delete) `challenge`: works out which, asks, does it,
    /// and calls `onDeleted` once the challenge is gone.
    func challengeDeleting(_ challenge: Binding<WalkChallenge?>, onDeleted: @escaping (WalkChallenge) -> Void) -> some View {
        modifier(ChallengeDeletionModifier(request: challenge, onDeleted: onDeleted))
    }
}

private struct ChallengeDeletionModifier: ViewModifier {
    @Binding var request: WalkChallenge?
    let onDeleted: (WalkChallenge) -> Void

    private enum Prompt: Identifiable {
        case delete(WalkChallenge)
        case request(WalkChallenge, others: Int)
        case message(title: String, text: String)

        var id: String {
            switch self {
            case .delete(let c): return "d-\(c.id.recordName)"
            case .request(let c, _): return "r-\(c.id.recordName)"
            case .message(let title, let text): return "m-\(title)-\(text)"
            }
        }
    }

    @State private var prompt: Prompt?

    func body(content: Content) -> some View {
        content
            .onChange(of: request?.id) { _, id in
                guard id != nil, let challenge = request else { return }
                request = nil
                Task {
                    switch await ChallengeDeletion.plan(for: challenge) {
                    case .delete: prompt = .delete(challenge)
                    case .request(let others): prompt = .request(challenge, others: others)
                    case .failed(let text): prompt = .message(title: CommunityDeletion.failedTitle, text: text)
                    }
                }
            }
            .alert(title, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { current in
                switch current {
                case .delete(let challenge):
                    Button("Delete", role: .destructive) {
                        Task {
                            // Ask again: someone may have joined while this was up.
                            switch await ChallengeDeletion.plan(for: challenge) {
                            case .request(let others):
                                prompt = .request(challenge, others: others)
                                return
                            case .failed(let text):
                                prompt = .message(title: CommunityDeletion.failedTitle, text: text)
                                return
                            case .delete:
                                break
                            }
                            switch await ChallengeDeletion.delete(challenge) {
                            case .deleted: onDeleted(challenge)
                            case .failed(let text): prompt = .message(title: CommunityDeletion.failedTitle, text: text)
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                case .request(let challenge, let others):
                    Button("Send Request") {
                        Task {
                            switch await ChallengeDeletion.request(challenge, others: others) {
                            case .sent: prompt = .message(title: "Request sent", text: ChallengeDeletion.requestSent)
                            case .alreadySent: prompt = .message(title: "Request sent", text: ChallengeDeletion.requestAlreadySent)
                            case .failed(let text): prompt = .message(title: "Couldn't send it", text: text)
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                case .message:
                    Button("OK", role: .cancel) {}
                }
            } message: { current in
                switch current {
                case .delete: Text(ChallengeDeletion.deleteMessage)
                case .request(_, let others): Text(ChallengeDeletion.requestMessage(others: others))
                case .message(_, let text): Text(text)
                }
            }
    }

    private var title: String {
        switch prompt {
        case .delete?: return ChallengeDeletion.deleteTitle
        case .request?: return ChallengeDeletion.requestTitle
        case .message(let title, _)?: return title
        case nil: return ""
        }
    }
}
