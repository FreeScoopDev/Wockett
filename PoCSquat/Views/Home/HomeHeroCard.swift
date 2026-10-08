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

/// A badge pinned on the Badges screen, shown in the streak row (up to two).
struct HomePinnedBadge: Identifiable {
    let id: String
    let name: String
    let emoji: String
    let progress: Double
    let earned: Bool
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
    /// Pinned on the Badges screen, whose hint promises them on Home. They went
    /// in the 2026-09-01 Home de-clutter while the pin kept saving.
    var pinnedBadges: [HomePinnedBadge] = []
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
                WktGoalRing(progress: progress) {
                    Text(WktPercent.text(progress))
                        .font(.wktHeading(20))
                        .foregroundColor(.earthCream)
                        .minimumScaleFactor(0.6)
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
                        Text(WktPercent.text(member.progress))
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
        .accessibilityLabel("\(member.name), \(WktPercent.value(member.progress)) percent of goal")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Streak

    private var streakFooter: some View {
        Button(action: onStreakTap) {
            HStack(spacing: 12) {
                streakText
                Spacer(minLength: 0)
                if !pinnedBadges.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(pinnedBadges) { badge in
                            WktBadgeRing(emoji: badge.emoji, progress: badge.progress,
                                         earned: badge.earned, size: 36)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(pinnedSummary)
        .accessibilityHint("Shows your badges")
    }

    private var pinnedSummary: String {
        guard !pinnedBadges.isEmpty else { return "" }
        let parts = pinnedBadges.map { badge in
            badge.earned ? "\(badge.name), earned"
                         : "\(badge.name), \(WktPercent.value(badge.progress)) percent"
        }
        return "Pinned badges: " + parts.joined(separator: "; ")
    }

    private var streakText: some View {
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
        }
    }

}
