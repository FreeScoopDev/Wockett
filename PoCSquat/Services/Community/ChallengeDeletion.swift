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
/// and deleted entries, but they still joined.
protocol ChallengeEntryLister: AnyObject {
    func entries(of challengeKey: String) async throws -> [ChallengeParticipant]
}

final class CloudKitChallengeEntryLister: ChallengeEntryLister {
    private let db = CKContainer(identifier: WockettCloud.containerID).publicCloudDatabase

    func entries(of challengeKey: String) async throws -> [ChallengeParticipant] {
        let query = CKQuery(recordType: "ChallengeEntry", predicate: NSPredicate(format: "challengeRecordName == %@", challengeKey))
        let (results, _) = try await db.records(matching: query, resultsLimit: 400)
        return results.compactMap { try? $0.1.get() }.compactMap { ChallengeParticipant(record: $0) }
    }
}

enum ChallengeDeletion {
    static let deleteTitle = "Delete this challenge?"
    static let deleteMessage = "This removes the challenge and your entry for everyone."
    static let requestTitle = "Ask to delete this challenge?"
    static let requestSent = "Request sent. The Wockett team will review it."
    static let requestAlreadySent = "You've asked already. The Wockett team will review it."
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

    @MainActor
    static func plan(for challenge: WalkChallenge, lister: ChallengeEntryLister = CloudKitChallengeEntryLister(),
                     moderation: CommunityModerationStore = .shared) async -> Plan {
        do {
            let others = othersJoined(try await lister.entries(of: challenge.id.recordName), moderation: moderation)
            return others == 0 ? .delete : .request(others: others)
        } catch {
            if (error as? CKError)?.code == .notAuthenticated {
                return .failed("Sign in to iCloud in the Settings app to delete it.")
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

    /// The request: a report on the challenge, reason "ownerRequest", one per
    /// person (the report record-name rule), nothing about you but CloudKit's
    /// own creator reference.
    static func requestRecord(for challenge: WalkChallenge, others: Int, requester: String?) -> CKRecord {
        var report = CommunityReport(challenge: challenge)
        report.note = "The person who created it asked to delete it. \(others) other \(others == 1 ? "person has" : "people have") joined."
        let record = CommunityReports.record(for: report, reporter: requester)
        record["reason"] = requestReason
        return record
    }

    enum RequestOutcome: Equatable {
        case sent
        case alreadySent
        case failed(String)
    }

    @MainActor
    static func request(_ challenge: WalkChallenge, others: Int,
                        store: CommunityReportStore = CloudKitCommunityReportStore(),
                        knownRequester: @escaping () -> String? = { MyAccount.recordName }) async -> RequestOutcome {
        do {
            let requester = (try? await store.currentUserRecordName()) ?? knownRequester()
            try await store.save(requestRecord(for: challenge, others: others, requester: requester))
            return .sent
        } catch {
            switch CommunityReports.outcome(of: error) {
            case .alreadyReported: return .alreadySent
            default:
                return (error as? CKError)?.code == .notAuthenticated
                    ? .failed("Sign in to iCloud in the Settings app to send it.")
                    : .failed("Couldn't send the request. Check your connection and try again.")
            }
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
                    case .failed(let text): prompt = .message(title: "Couldn't delete it", text: text)
                    }
                }
            }
            .alert(title, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { current in
                switch current {
                case .delete(let challenge):
                    Button("Delete", role: .destructive) {
                        Task {
                            switch await ChallengeDeletion.delete(challenge) {
                            case .deleted: onDeleted(challenge)
                            case .failed(let text): prompt = .message(title: "Couldn't delete it", text: text)
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
