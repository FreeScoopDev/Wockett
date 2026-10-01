import SwiftUI

// MARK: - Home hero card
//
// Everything about today in one card (2026-09-30 redesign): the date and the
// status chips, the step ring, the crew, and the streak line. It replaces the
// rotating tagline in the navigation bar, the stat card, THE CREW card and the
// dog on the progress track, which said the same things four times over.

/// One pet's row in the hero card.
struct HomeCrewMember: Identifiable {
    let id: UUID
    let name: String
    let progress: Double
}

struct HomeHeroCard<Chips: View>: View {
    let steps: Int
    let goal: Int
    let progress: Double
    /// "3.3 mi to go", or nil once the goal is reached.
    let remainingText: String?
    let streak: Int
    /// A line from `BannerStore`, shown beside the streak.
    let quote: String
    let crew: [HomeCrewMember]
    var onStepsTap: () -> Void
    var onPetTap: (UUID) -> Void
    var onManageCrew: () -> Void
    var onStreakTap: () -> Void
    @ViewBuilder let chips: () -> Chips

    var body: some View {
        VStack(alignment: .leading, spacing: WktSpacing.cardPadding) {
            header
            stepsRow
            WktDivider()
            crewSection
            WktDivider()
            streakFooter
        }
        .wktCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.statCard")
    }

    // MARK: Header

    private var header: some View {
        // The chips drop below the date when they do not fit beside it:
        // "Weather unavailable" on a small phone, or large Dynamic Type.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center) {
                dateTitle
                Spacer(minLength: 8)
                HStack(spacing: 6) { chips() }
            }
            VStack(alignment: .leading, spacing: 10) {
                dateTitle
                HStack(spacing: 6) { chips() }
            }
        }
    }

    private var dateTitle: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Today")
                .font(.wktCardTitle)
                .foregroundColor(.earthCream)
                .accessibilityAddTraits(.isHeader)
            Text(Date.now, format: .dateTime.weekday(.wide))
                .font(.wktBodyText)
                .foregroundColor(.earthMuted)
        }
        .fixedSize()
    }

    // MARK: Steps

    private var stepsRow: some View {
        Button(action: onStepsTap) {
            HStack(spacing: WktSpacing.cardPadding) {
                ZStack {
                    Circle()
                        .stroke(Color.earthTrack, lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.earthOrange, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.6), value: progress)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.wktHeading(20))
                        .foregroundColor(.earthCream)
                        .minimumScaleFactor(0.6)
                        .padding(14)
                }
                .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Steps today")
                        .font(.wktLabel)
                        .foregroundColor(.earthMuted)
                    Text(steps.formatted())
                        .font(.wktMetric)
                        .foregroundColor(.earthCream)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("of \(goal.formatted())")
                        .font(.wktBodyText)
                        .foregroundColor(.earthMuted)
                    if let remainingText {
                        Text(remainingText)
                            .font(.wktBodyText)
                            .foregroundColor(.earthOrange)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        Text("Goal reached")
                            .font(.wktBodyText)
                            .foregroundColor(.earthGreen)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows your step details")
    }

    // MARK: Crew

    private var crewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Crew")
                    .font(.wktLabel)
                    .foregroundColor(.earthMuted)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !crew.isEmpty {
                    Button("Manage", action: onManageCrew)
                        .font(.wktLabel)
                        .foregroundColor(.earthGreen)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home.manageCrew")
                }
            }
            if crew.isEmpty {
                Button(action: onManageCrew) {
                    HStack(spacing: 12) {
                        WktIconBadge(symbol: .add)
                        Text("Add your dog")
                            .font(.wktRowTitle)
                            .foregroundColor(.earthCream)
                        Spacer()
                        Image(wkt: .chevronRight)
                            .wktIcon(.inline, tint: .earthMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                ForEach(crew) { member in
                    crewRow(member)
                }
            }
        }
    }

    private func crewRow(_ member: HomeCrewMember) -> some View {
        Button { onPetTap(member.id) } label: {
            HStack(spacing: 12) {
                WktIconBadge(symbol: .pets)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(member.name)
                            .font(.wktRowTitle)
                            .foregroundColor(.earthCream)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int((member.progress * 100).rounded()))%")
                            .font(.wktLabel)
                            .foregroundColor(.earthMuted)
                    }
                    WktProgressBar(value: member.progress, tint: .earthGreen, height: 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(member.name), \(Int((member.progress * 100).rounded())) percent of goal")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Streak

    private var streakFooter: some View {
        Button(action: onStreakTap) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(wkt: .calories)
                    .wktIcon(.inline, tint: .earthOrange, filled: streak > 0)
                VStack(alignment: .leading, spacing: 2) {
                    if streak > 0 {
                        Text("\(streak)-day streak")
                            .font(.wktRowTitle)
                            .foregroundColor(.earthCream)
                        Text(quote)
                            .font(.wktBodyText)
                            .foregroundColor(.earthMuted)
                    } else {
                        Text("\(quote) Walk today to start a streak.")
                            .font(.wktBodyText)
                            .foregroundColor(.earthMuted)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows your badges")
    }

}
