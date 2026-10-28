import SwiftUI

// MARK: - Recent activity on Home (fix/home-start-first, 2026-10-28)
//
// Saved activities could only be reached through Health → Activity History.
// Home now lists the newest few, worded exactly as History words them
// (`ActivityRowText`), and each opens the summary History opens.
//
// Everything History lists is a candidate, as History shows it: indoor walks,
// zero-distance records, possibly-driven walks, and a pet's own credit entry
// ("Nala's Indoor Walk", `WalkSession.isPetCreditEntry`), which History lists
// as a row like any other.

/// The rows Home's Recent activity shows: the newest `limit` sessions by date.
struct HomeRecentActivity {
    static let limit = 3

    struct Row: Identifiable {
        let session: WalkSession
        let text: ActivityRowText
        var id: UUID { session.id }
    }

    let rows: [Row]

    /// Newest first by date. The store keeps sessions newest first by date
    /// when it loads, but `add` puts a new one on top whatever its date (a
    /// past walk logged today for last week), so the order is not trusted.
    /// Ties keep the store's order.
    init(sessions: [WalkSession], limit: Int = Self.limit,
         locale: Locale = .current, timeZone: TimeZone = .current) {
        let newest = sessions.enumerated()
            .sorted { lhs, rhs in
                lhs.element.date != rhs.element.date
                    ? lhs.element.date > rhs.element.date
                    : lhs.offset < rhs.offset
            }
            .prefix(max(0, limit))
        rows = newest.map { Row(session: $0.element, text: ActivityRowText($0.element, locale: locale, timeZone: timeZone)) }
    }

    /// Nothing saved: Home shows no section at all.
    var isEmpty: Bool { rows.isEmpty }
}

/// The rows on one card, a rule between each. Tapping one opens its summary.
struct HomeRecentActivityCard: View {
    let rows: [HomeRecentActivity.Row]
    let onOpen: (WalkSession) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { WktDivider() }
                Button { onOpen(row.session) } label: {
                    ActivityRowContent(text: row.text)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens the summary")
                .accessibilityIdentifier("home.recent.row")
            }
        }
        .padding(.horizontal, WktSpacing.cardPadding)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wktCardBackground()
        .accessibilityElement(children: .contain)
        // A new card whenever the rows change. Updated in place, the
        // accessibility tree kept the first row's button at the whole card's
        // frame, holding a row added later inside it, so VoiceOver and UI
        // tests read the new walk after the one it sits above (seen
        // 2026-10-28 after Log a Past Walk; the screen itself was right).
        .id(rows.map(\.id))
    }
}
