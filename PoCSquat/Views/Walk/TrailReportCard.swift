import SwiftUI

// MARK: - "Help the next walker": the post-walk questions
//
// On the summary right after a walk on a named trail (never during a walk,
// never from history), within `TrailReportAskPolicy`'s limits. One question
// per fact, each optional; a tap on an answer sends it at once (one
// `TrailFactReport`). "Not now" closes the card before any answer and "Skip"
// after one; "Don't ask again" turns the questions off, as the Settings
// switch does. The first answer ever gets a thank-you.

@MainActor
@Observable
final class TrailReportCardModel {
    enum AnswerState: Equatable {
        case sending(String)
        case sent(String)
        /// CloudKit already had this person's answer; which one isn't known.
        case alreadyAnswered
        case failed(String)
    }

    let trail: TrailRef
    /// The questions, in the vocabulary's order (all five, `liked` included:
    /// it is collected, just never shown back).
    let facts: [WalkerFact] = WalkerFact.allCases
    private(set) var states: [WalkerFact: AnswerState] = [:]
    private(set) var closed = false
    private(set) var showThanks = false

    @ObservationIgnored private let policy: TrailReportAskPolicy
    @ObservationIgnored private let send: (WalkerFact, String) async -> TrailFactReports.Outcome

    /// The card for a summary, or nil when the policy says not to ask.
    /// Records nothing: the ask counts once the card is seen (`markShown`).
    static func forSummary(trail: TrailRef?, session: WalkSession, justFinished: Bool, walkInProgress: Bool,
                           policy: TrailReportAskPolicy? = nil) -> TrailReportCardModel? {
        let policy = policy ?? TrailReportAskPolicy()
        guard let trail, policy.shouldAsk(trail: trail, session: session, justFinished: justFinished,
                                          walkInProgress: walkInProgress) else { return nil }
        return TrailReportCardModel(trail: trail, policy: policy)
    }

    @ObservationIgnored private var shown = false

    /// The card came into view or was used: the ask is spent, once.
    func markShown() {
        guard !shown else { return }
        shown = true
        policy.noteAsked(trail)
    }

    /// Nil arguments build the real ones here, on the main actor: a default
    /// argument is evaluated outside it.
    init(trail: TrailRef, policy: TrailReportAskPolicy? = nil,
         send: ((WalkerFact, String) async -> TrailFactReports.Outcome)? = nil) {
        self.trail = trail
        self.policy = policy ?? TrailReportAskPolicy()
        self.send = send ?? { [store = TrailFactReportSubmission.defaultStore()] fact, value in
            await TrailFactReportSubmission.submit(trail, fact: fact, value: value, store: store)
        }
    }

    /// Something reached CloudKit, so the close button reads "Skip".
    var hasAnswered: Bool {
        states.values.contains { if case .sent = $0 { return true }; return $0 == .alreadyAnswered }
    }

    var isComplete: Bool {
        facts.allSatisfy { fact in
            switch states[fact] {
            case .sent?, .alreadyAnswered?: return true
            default: return false
            }
        }
    }

    /// Whether the card still shows its questions.
    var asking: Bool { !closed && !isComplete }

    func selected(_ fact: WalkerFact) -> String? {
        switch states[fact] {
        case .sending(let value)?, .sent(let value)?: return value
        default: return nil
        }
    }

    /// Answers can't be changed once sent (CloudKit refuses a second), and
    /// one is in flight at a time per question.
    func canAnswer(_ fact: WalkerFact) -> Bool {
        switch states[fact] {
        case nil, .failed?: return !closed
        default: return false
        }
    }

    func error(for fact: WalkerFact) -> String? {
        if case .failed(let message)? = states[fact] { return message }
        if states[fact] == .alreadyAnswered { return "You answered this one before." }
        return nil
    }

    /// One tap: sends this answer.
    func answer(_ fact: WalkerFact, _ value: String) async {
        guard canAnswer(fact), fact.knows(value) else { return }
        markShown()
        states[fact] = .sending(value)
        switch await send(fact, value) {
        case .sent:
            states[fact] = .sent(value)
            if policy.noteAnswered(trail) { showThanks = true }
        case .alreadyAnswered:
            states[fact] = .alreadyAnswered
            policy.noteAnswered(trail, thank: false)
        case .failed(let message):
            states[fact] = .failed(message)
        }
    }

    /// "Not now" or "Skip": the card goes; the trail is not asked about again.
    func close() {
        markShown()
        closed = true
    }

    /// "Don't ask again": no more questions after any walk, until the
    /// Settings switch turns them back on.
    func stopAsking() {
        markShown()
        policy.asksOff = true
        closed = true
    }
}

struct TrailReportCard: View {
    @State var model: TrailReportCardModel
    /// "walk" or "hike", from the session's own wording.
    let noun: String
    @State private var termsGate = CommunityTermsGate()

    static let title = "Help the next walker"
    static let thanks = "Thanks! Your answers help the next walker. Others see only combined counts, once at least \(TrailFactSummaries.minimumWalkers) walkers agree."

    var body: some View {
        VStack(alignment: .leading, spacing: WktSpacing.betweenCards) {
            if model.showThanks {
                Label {
                    Text(Self.thanks).font(.wktBodyText).foregroundColor(.earthCream)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(wkt: .success).wktIcon(.row, tint: .earthGreen)
                }
                .wktCard()
                .accessibilityIdentifier("summary.trailReportThanks")
            }
            if model.asking {
                WktSection(title: Self.title) { questions }
            }
        }
        // The ask counts once half the card has been on screen.
        .onScrollVisibilityChange(threshold: 0.5) { visible in
            if visible { model.markShown() }
        }
        .communityTermsSheet($termsGate)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary.trailReport")
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A few taps about \(model.trail.trailName) after your \(noun). Each is optional, and other walkers never see your answer on its own.")
                .font(.wktBodyText)
                .foregroundColor(.earthMuted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.facts, id: \.self) { fact in
                VStack(alignment: .leading, spacing: 6) {
                    Text(fact.question)
                        .font(.wktLabel)
                        .foregroundColor(.earthCream)
                        .accessibilityAddTraits(.isHeader)
                    WktFlowRow {
                        ForEach(fact.values, id: \.self) { value in
                            WktChoiceChip(title: fact.chipTitle(value), selected: model.selected(fact) == value) {
                                termsGate.perform { Task { await model.answer(fact, value) } }
                            }
                            .disabled(!model.canAnswer(fact))
                            .accessibilityLabel("\(fact.question) \(fact.chipTitle(value))")
                            .accessibilityIdentifier("summary.trailReport.\(fact.rawValue).\(value)")
                        }
                    }
                    if let error = model.error(for: fact) {
                        Text(error).font(.wktLabel).foregroundColor(.earthMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                WktPillButton(title: model.hasAnswered ? "Skip" : "Not now", tint: .earthCream) { model.close() }
                    .accessibilityIdentifier("summary.trailReport.close")
                Spacer()
                Button("Don't ask again") { model.stopAsking() }
                    .font(.wktLabel)
                    .foregroundColor(.earthMuted)
                    .frame(minHeight: 44)
                    .accessibilityHint("Turns off these questions. Settings, Community can turn them back on.")
                    .accessibilityIdentifier("summary.trailReport.stop")
            }
        }
        .wktCard()
    }
}
