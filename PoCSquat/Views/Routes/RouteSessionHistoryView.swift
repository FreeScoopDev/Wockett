import SwiftUI
import MapKit

// MARK: - Route Session History View
//
// Shows every WalkSession recorded against a specific CustomRoute, sorted
// newest-first. Sessions the user excluded from route stats are hidden.

struct RouteSessionHistoryView: View {
    let route: CustomRoute
    @ObservedObject var historyStore: WalkHistoryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showStartSheet = false
    @State private var didStart = false

    private var split: (shown: [WalkSession], hidden: Int) { RouteHistoryEmpty.split(historyStore.sessions, route: route.id) }
    private var sessions: [WalkSession] { split.shown }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            Group {
                // Scrolls only when the buttons would not fit (large text).
                if sessions.isEmpty { ViewThatFits(in: .vertical) { emptyState; ScrollView { emptyState } } } else { sessionList }
            }
        }
        .navigationTitle("Route History")
        .navigationBarTitleDisplayMode(.inline)
        // Back to the route once a session starts, not this empty list.
        .sheet(isPresented: $showStartSheet, onDismiss: { if didStart { dismiss() } }, content: { startSheet })
    }

    // The route's own activity, never a fixed "run": a route's history
    // said "Run" for walking routes until 2026-09-25, and "No Runs Yet" here.
    // Says why it is empty, and the way on. Start this route never begins
    // a session itself: the sheet's bar does, after a mode and a tap.
    private var emptyState: some View {
        VStack(spacing: WktSpacing.betweenSections) {
            let text = RouteHistoryEmpty.text(for: route, sessions: historyStore.sessions)
            WktEmptyState(symbol: .history, title: text.title, message: text.message)
            VStack(spacing: WktSpacing.betweenCards) {
                WktPrimaryButton(title: "Start this route", symbol: route.activityMode.wktSymbol) { showStartSheet = true }
                    .accessibilityIdentifier("history.startRoute")
                WktSecondaryButton(title: "Back to route") { dismiss() }
                    .accessibilityIdentifier("history.backToRoute")
            }
            .padding(.horizontal, WktSpacing.screen)
        }
    }

    private var startSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RouteStartBar(route: route, startID: "history.sheetStart", barID: "history.startSheet") {
                    didStart = true
                    showStartSheet = false
                }
            }
            .background(Color.earthBg.ignoresSafeArea())
            .navigationTitle(route.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showStartSheet = false }
                        .accessibilityIdentifier("history.startCancel")
                }
            }
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium])
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
