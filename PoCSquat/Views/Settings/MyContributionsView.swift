import SwiftUI

// MARK: - My contributions
//
// Settings > Community > My contributions, and the nomination thank-you's
// "My contributions" button: each trail this phone nominated, when, and
// Sent or Featured (spec feat/contribution-status, criterion 4). The Trails
// banner is `ContributionFeaturedBanner` in TrailPickViews.swift. Asks
// CloudKit every time it opens and on pull to refresh.

struct MyContributionsView: View {
    var service: ContributionService = .shared

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            List {
                if service.contributions.isEmpty {
                    WktEmptyState(symbol: .trailPick, title: ContributionMessages.emptyTitle,
                                  message: ContributionMessages.emptyMessage)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("contributions.empty")
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(service.contributions) { item in
                            ContributionRow(item: item)
                                .listRowBackground(Color.earthCard)
                        }
                    } footer: {
                        Text(ContributionMessages.footer)
                            .font(.wktLabel).foregroundColor(.earthMuted)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await service.refresh() }
        }
        .navigationTitle(ContributionMessages.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("contributions.root")
        .task { await service.refresh() }
    }
}

/// The trail, the day it was sent, and its status as a chip.
private struct ContributionRow: View {
    let item: Contribution

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.trailName)
                    .font(.wktRowTitle)
                    .foregroundColor(.earthCream)
                Text("Nominated \(item.sentAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.wktLabel)
                    .foregroundColor(.earthMuted)
            }
            Spacer(minLength: 8)
            WktStatusChip(text: item.statusLabel, dot: item.hasStatus ? .earthGreen : .earthMuted)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("contributions.row")
    }
}
