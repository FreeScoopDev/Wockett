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
        .navigationTitle("Run History")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(wkt: .history)
                .font(.system(size: 64)).foregroundColor(.earthMuted.opacity(0.4))
            Text("No Runs Yet")
                .font(.headline).foregroundColor(.earthCream)
            Text("Complete a walk on \"\(route.name)\" to see your history here")
                .font(.subheadline).foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var sessionList: some View {
        List {
            ForEach(sessions) { session in
                RouteSessionRow(session: session)
                    .listRowBackground(Color.earthCard)
                    .listRowSeparatorTint(Color.earthMuted.opacity(0.2))
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
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.earthGreen.opacity(0.15))
                    .frame(width: 46, height: 46)
                Image(systemName: ActivityMode(rawValue: session.activityType)?.icon ?? "figure.walk")
                    .foregroundColor(.earthGreen)
                    .font(.system(size: 18, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.dateFmt.string(from: session.date))
                    .font(.subheadline.bold()).foregroundColor(.earthCream)
                HStack(spacing: 10) {
                    Label { Text(session.distanceText) }    icon: { Image(wkt: .distance).wktIcon(.inline, tint: .earthMuted) }
                    Label { Text(session.timeText) }        icon: { Image(wkt: .time).wktIcon(.inline, tint: .earthMuted) }
                    Label { Text(session.paceOrSpeedText) } icon: { Image(wkt: .pace).wktIcon(.inline, tint: .earthMuted) }
                }
                .font(.footnote).foregroundColor(.earthMuted)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}
