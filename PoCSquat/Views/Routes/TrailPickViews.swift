import SwiftUI

// MARK: - Nominate

/// "Nominate this trail" on a named trail's detail screen. The trail is
/// worked out on tap, from every piece of it, not on every render.
struct TrailNominateButton: View {
    let item: TrailListItem
    var library: TrailPackLibrary = .shared
    @State private var trail: TrailRef?

    var body: some View {
        Button {
            let library = library
            trail = TrailRef(item: item) { library.trails(key: $0) }
        } label: {
            Label {
                Text("Nominate this trail")
            } icon: {
                Image(wkt: .trailPick).wktIcon(.inline, tint: .earthGreen)
            }
            .font(.wktBodyText)
            .foregroundColor(.earthGreen)
            .frame(minHeight: 44)
        }
        .accessibilityHint("Tell the Wockett team this trail is worth featuring")
        .accessibilityIdentifier("routes.nominateTrail")
        .sheet(item: $trail) { trail in
            TrailNominationSheet(trail: trail)
        }
    }
}

/// Why it's worth it (optional), Send, then the answer.
struct TrailNominationSheet: View {
    let trail: TrailRef
    let store: TrailNominationStore
    let contributions: ContributionService
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var phase: Phase
    @State private var showContributions = false

    /// A trail this device nominated already says so before anything is typed.
    init(trail: TrailRef, store: TrailNominationStore = CloudKitTrailNominationStore(),
         contributions: ContributionService = .shared) {
        self.trail = trail
        self.store = store
        self.contributions = contributions
        _phase = State(initialValue: Self.initialPhase(hasNominated: contributions.hasNominated(trail.trailKey)))
    }

    enum Phase: Equatable {
        case writing
        case sending
        case done(TrailNominations.Outcome)
    }

    /// Where the sheet starts: a trail this device nominated already says so
    /// before anything is typed.
    static func initialPhase(hasNominated: Bool) -> Phase {
        hasNominated ? .done(.alreadyNominated) : .writing
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                switch phase {
                case .writing, .sending: form
                case .done(.sent): answer(.success, ContributionMessages.thanks, ContributionMessages.thanksDetail, contributionsLink: true)
                case .done(.alreadyNominated): answer(.success, "You've nominated this trail already.",
                                                      ContributionMessages.alreadyDetail, contributionsLink: true)
                case .done(.failed(let message)): answer(.warning, "Couldn't send it", message)
                }
            }
            .navigationDestination(isPresented: $showContributions) { MyContributionsView(service: contributions) }
            .navigationTitle("Nominate a Trail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if phase == .writing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.foregroundColor(.earthMuted)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") { send() }.foregroundColor(.earthGreen)
                    }
                } else if phase == .sending {
                    ToolbarItem(placement: .confirmationAction) { ProgressView() }
                }
            }
        }
        .interactiveDismissDisabled(phase == .sending)
        .presentationDetents([.medium, .large])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routes.nominationSheet")
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(trail.trailName)
                    .font(.wktCardTitle)
                    .foregroundColor(.earthCream)
                WktSectionHeader(title: "What makes it great?")
                TextField("Optional", text: $note, axis: .vertical)
                    .accessibilityLabel("What makes it great?")
                    .lineLimit(3...6)
                    .font(.wktBodyText)
                    .foregroundColor(.earthCream)
                    .onChange(of: note) { _, value in
                        if value.count > TrailNominations.noteLimit { note = String(value.prefix(TrailNominations.noteLimit)) }
                    }
                    .wktCard()
                Text("\(note.count) of \(TrailNominations.noteLimit) characters. Your name and location aren't sent.")
                    .font(.wktLabel)
                    .foregroundColor(.earthMuted)
            }
            .padding(.horizontal, WktSpacing.screen)
            .padding(.vertical, 24)
        }
        .disabled(phase == .sending)
    }

    private func answer(_ symbol: WktSymbol, _ title: String, _ detail: String, contributionsLink: Bool = false) -> some View {
        WktResultView(symbol: symbol, title: title, detail: detail,
                      secondary: contributionsLink ? WktResultView.Secondary(title: ContributionMessages.screenTitle) { showContributions = true } : nil) {
            dismiss()
        }
    }

    private func send() {
        phase = .sending
        let trail = trail
        let note = note
        let store = store
        let contributions = contributions
        Task { phase = .done(await TrailNominationSubmission.submit(trail, note: note, store: store, contributions: contributions)) }
    }
}

// MARK: - Featured

/// "Your nomination of Lake Loop was featured by the Wockett team", once, at
/// the top of the Trails list (spec feat/contribution-status, criterion 5).
struct ContributionFeaturedBanner: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        WktBanner(symbol: .trailPick, tint: .earthGreen, title: text, detail: ContributionMessages.thanks) {
            WktPillButton(title: "OK", action: onClose)
        }
        .clipShape(RoundedRectangle.wktCard)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routes.contributionFeatured")
    }
}

/// A featured trail in the list: its card, with Joe's note under it.
struct FeaturedTrailCard: View {
    let item: TrailListItem
    let feature: FeaturedTrail
    let activityMode: ActivityMode
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TrailCard(item: item, activityMode: activityMode, onSelect: onSelect)
            if !feature.blurb.isEmpty {
                Label {
                    Text("Wockett pick: \(feature.blurb)")
                } icon: {
                    Image(wkt: .trailPick).wktIcon(.inline, tint: .earthGreen)
                }
                .font(.wktLabel)
                .foregroundColor(.earthMuted)
                .padding(.horizontal, 4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routes.featuredTrail")
    }
}
