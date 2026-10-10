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
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var phase: Phase = .writing

    enum Phase: Equatable {
        case writing
        case sending
        case done(TrailNominations.Outcome)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                switch phase {
                case .writing, .sending: form
                case .done(.sent): answer(.success, "Thanks for the tip.",
                                          "The Wockett team reads every nomination. The best show up as Featured for walkers nearby.")
                case .done(.alreadyNominated): answer(.success, "You've nominated this trail already.",
                                                      "Thanks. One nomination per trail is plenty.")
                case .done(.failed(let message)): answer(.warning, "Couldn't send it", message)
                }
            }
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

    private func answer(_ symbol: WktSymbol, _ title: String, _ detail: String) -> some View {
        WktResultView(symbol: symbol, title: title, detail: detail) { dismiss() }
    }

    private func send() {
        phase = .sending
        let trail = trail
        let note = note
        Task { phase = .done(await TrailNominationSubmission.submit(trail, note: note)) }
    }
}

// MARK: - Featured

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
