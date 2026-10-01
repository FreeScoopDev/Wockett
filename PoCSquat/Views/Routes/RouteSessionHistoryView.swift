import SwiftUI
import MapKit

// MARK: - Route Session History View
//
// Shows every WalkSession recorded against a specific CustomRoute, sorted
// newest-first. Sessions the user excluded from route stats are hidden.

struct RouteSessionHistoryView: View {
    let route: CustomRoute
    @ObservedObject var historyStore: WalkHistoryStore

    private var sessions: [WalkSession] {
        historyStore.sessions
            .filter { $0.customRouteId == route.id && $0.countsTowardRouteStats && !$0.flaggedPossibleVehicle }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            Group {
                if sessions.isEmpty { emptyState } else { sessionList }
            }
        }
        .navigationTitle("Route History")
        .navigationBarTitleDisplayMode(.inline)
    }

    // The route's own activity, never a fixed "run": a route's history
    // said "Run" for walking routes until 2026-09-25, and "No Runs Yet" here.
    private var emptyState: some View {
        WktEmptyState(symbol: .history,
                      title: "No \(route.activityMode.noun)s yet",
                      message: "Finish a \(route.activityMode.noun) on \"\(route.name)\" to see your history here")
    }

    private var sessionList: some View {
        List {
            ForEach(sessions) { session in
                RouteSessionRow(session: session)
                    .listRowBackground(Color.earthCard)
                    .listRowSeparatorTint(Color.earthTrack)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Route Session Row

struct RouteSessionRow: View {
    let session: WalkSession

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 14) {
            WktIconBadge(symbol: (ActivityMode(rawValue: session.activityType) ?? .walking).wktSymbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.dateFmt.string(from: session.date))
                    .font(.wktRowTitle).foregroundColor(.earthCream)
                HStack(spacing: 10) {
                    Label { Text(session.distanceText) }    icon: { Image(wkt: .distance).wktIcon(.inline, tint: .earthMuted) }
                    Label { Text(session.timeText) }        icon: { Image(wkt: .time).wktIcon(.inline, tint: .earthMuted) }
                    Label { Text(session.paceOrSpeedText) } icon: { Image(wkt: .pace).wktIcon(.inline, tint: .earthMuted) }
                }
                .font(.wktLabel).foregroundColor(.earthMuted)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}
