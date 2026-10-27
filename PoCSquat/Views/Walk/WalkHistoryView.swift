import SwiftUI
import MapKit
import UIKit

// MARK: - Walk History View

struct WalkHistoryView: View {
    @ObservedObject var store: WalkHistoryStore
    @EnvironmentObject var petStore: PetStore
    @Environment(\.dismiss) private var dismiss
    @State private var showManualEntry = false
    @State private var selectedSession: WalkSession?
    @State private var summarySession: WalkSession?
    @State private var showActiveSessionAlert = false

    private var totalWalks: Int { store.sessions.count }

    private var avgDistanceText: String {
        guard !store.sessions.isEmpty else { return "—" }
        let avg = store.sessions.reduce(0.0) { $0 + $1.totalDistance } / Double(store.sessions.count)
        return MKDistanceFormatter.abbreviated.string(fromDistance: avg)
    }

    private var avgDurationText: String {
        guard !store.sessions.isEmpty else { return "—" }
        let avg = store.sessions.reduce(0.0) { $0 + $1.elapsedTime } / Double(store.sessions.count)
        let mins = Int(avg) / 60
        return mins < 60 ? "\(mins)m" : "\(mins / 60)h \(mins % 60)m"
    }

    private var walksThisWeek: Int {
        // The calendar week so far, as Insights counts "This week".
        let now = Date()
        let week = InsightsSummary.calendarWeek(containing: now, calendar: .current)
        return store.sessions.filter { InsightsSummary.counts($0.date, in: week, now: now) }.count
    }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            Group {
                if store.sessions.isEmpty { emptyState } else { historyList }
            }
        }
        .navigationTitle("Activity History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showManualEntry = true
                } label: {
                    Image(wkt: .add).wktIcon(.inline, tint: .earthGreen)
                }
                .accessibilityLabel("Add activity")
            }
        }
        .alert("Walk Already Active", isPresented: $showActiveSessionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You have a walk in progress. Return to the home screen to resume or end it first.")
        }
        .sheet(isPresented: $showManualEntry) {
            ManualWalkEntrySheet { session in store.add(session) }
        }
        .sheet(item: $selectedSession) { session in
            WalkSessionDetailSheet(session: session, store: store)
        }
        .historySummaryCover(item: $summarySession, history: store.sessions)
    }

    private var emptyState: some View {
        // Activity-neutral: this list holds runs, rides and indoor walks too.
        WktEmptyState(symbol: .history, title: "No activities yet",
                      message: "Finish a walk, run or ride to build your history",
                      actionTitle: "Log a Past Walk") { showManualEntry = true }
    }

    private var statsHeader: some View {
        HStack(spacing: 0) {
            statCell("\(totalWalks)", "Total")
            columnDivider
            statCell(avgDistanceText, "Avg dist")
            columnDivider
            statCell(avgDurationText, "Avg time")
            columnDivider
            statCell("\(walksThisWeek)", "This week")
        }
        .wktCard(padding: 14)
        .padding(.horizontal, WktSpacing.screen)
        .padding(.vertical, 8)
    }

    private var columnDivider: some View {
        Rectangle().fill(Color.earthTrack).frame(width: 1, height: 36)
    }

    private func statCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.wktRowTitle.monospacedDigit()).foregroundColor(.earthCream)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.wktLabel).foregroundColor(.earthMuted)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var historyList: some View {
        List {
            Section {
                statsHeader
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(store.sessions) { session in
                WalkHistoryRow(session: session, onOpen: {
                    summarySession = session
                }, onWalkAgain: {
                    let nav = session.toNavigableRoute()
                    guard ActiveWalkStore.shared.beginSession(route: nav) != nil else {
                        showActiveSessionAlert = true
                        return
                    }
                    dismiss()
                }, onInfo: {
                    selectedSession = session
                })
                .listRowBackground(Color.earthCard)
                .listRowSeparatorTint(Color.earthTrack)
            }
            .onDelete { store.delete(at: $0) }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
    }
}

// MARK: - Walk Session Detail Sheet

struct WalkSessionDetailSheet: View {
    let session: WalkSession
    @ObservedObject var store: WalkHistoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var notes: String = ""
    @State private var selectedActivityType: String = ""
    @State private var showActivityShare = false

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .short; return f
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                        Text(Self.dateFmt.string(from: session.date))
                            .font(.wktBodyText).foregroundColor(.earthMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)

                        // The summary's own tiles, following the type chosen below.
                        ActivityStatTiles(session: sessionAsTyped)

                        WktSection(title: "Activity type") {
                            WktSegmentedPicker(selection: $selectedActivityType, options: [ActivityMode.walking, .running, .cycling, .stationary].map {
                                .init(value: $0.rawValue, title: $0.sessionLabel, symbol: $0.wktSymbol)
                            })
                        }

                        WktSection(title: "Notes") {
                            ZStack(alignment: .topLeading) {
                                if notes.isEmpty {
                                    Text("Add a note about this \(activityNoun)…")
                                        .font(.wktBodyText).foregroundColor(.earthMuted)
                                        .padding(.horizontal, 14).padding(.top, 12)
                                }
                                TextEditor(text: $notes)
                                    .foregroundColor(.earthCream)
                                    .font(.wktBodyText)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 88)
                                    .padding(.horizontal, 10)
                            }
                            .padding(.vertical, 4)
                            .wktCardBackground()
                        }

                        WktSecondaryButton(title: "Share this \(activityNoun)", symbol: .share) {
                            showActivityShare = true
                        }

                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, WktSpacing.screen)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(session.routeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        store.updateNotes(id: session.id, notes: notes)
                        store.updateActivityType(id: session.id, activityType: selectedActivityType)
                        dismiss()
                    }
                    .foregroundColor(.earthGreen)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .fontWeight(.semibold).foregroundColor(.earthGreen)
                }
            }
        }
        .sheet(isPresented: $showActivityShare) {
            ActivitySummaryShareSheet(session: sessionAsTyped, historyStore: store)
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            notes = session.notes
            selectedActivityType = session.activityType
        }
    }

    /// The walk with the type chosen below, so the tiles and Share follow it.
    private var sessionAsTyped: WalkSession {
        var typed = session
        if !selectedActivityType.isEmpty { typed.activityType = selectedActivityType }
        return typed
    }

    /// "walk", "hike", "run", "ride": the type chosen above, so the copy follows it.
    private var activityNoun: String {
        sessionAsTyped.wording.noun
    }
}

// MARK: - Manual Walk Entry Sheet

struct ManualWalkEntrySheet: View {
    /// Saves the walk; false when the write failed, and the sheet stays open.
    let onSave: (WalkSession) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var walkDate = Date()
    @State private var durationHours = 0
    @State private var durationMinutes = 30
    @State private var distanceText = ""
    @State private var stepCount = ""
    @State private var routeName = ""
    @State private var useSteps = false
    @State private var saveFailed = false

    // Kilometres on a metric phone, miles otherwise: the rule the goal editor
    // and every distance label use. Until 1.14 this form asked everyone for
    // kilometres and multiplied by 1000, so a US user typing their 3-mile
    // walk logged 3 km.
    private static var useMetric: Bool { Locale.current.measurementSystem == .metric }
    private static var unitWord: String { useMetric ? "Kilometres" : "Miles" }
    private static var unitHint: String { useMetric ? "Distance in km (e.g. 3.5)" : "Distance in miles (e.g. 2.5)" }

    /// The typed distance in metres, or nil when it is not a positive number.
    nonisolated static func meters(fromDistanceText text: String, useMetric: Bool) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value * (useMetric ? 1000 : 1609.344)
    }

    /// Steps typed instead of a distance, at the app's 0.762 m stride.
    nonisolated static func meters(fromStepsText text: String) -> Double? {
        guard let steps = Double(text.trimmingCharacters(in: .whitespaces)), steps > 0 else { return nil }
        return steps * 0.762
    }

    private var distanceMeters: Double? {
        useSteps
            ? Self.meters(fromStepsText: stepCount)
            : Self.meters(fromDistanceText: distanceText, useMetric: Self.useMetric)
    }

    private var isValid: Bool {
        let totalMins = durationHours * 60 + durationMinutes
        return totalMins > 0 && distanceMeters != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                        sectionCard("When") {
                            DatePicker("Date & Time", selection: $walkDate, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                                .foregroundColor(.earthCream)
                                .tint(.earthGreen)
                        }

                        sectionCard("Duration") {
                            HStack(spacing: 24) {
                                VStack(spacing: 4) {
                                    Text("\(durationHours)").font(.wktCardTitle).foregroundColor(.earthCream)
                                    Text("hours").font(.wktLabel).foregroundColor(.earthMuted)
                                    Stepper("", value: $durationHours, in: 0...23).labelsHidden()
                                }
                                VStack(spacing: 4) {
                                    Text("\(durationMinutes)").font(.wktCardTitle).foregroundColor(.earthCream)
                                    Text("minutes").font(.wktLabel).foregroundColor(.earthMuted)
                                    Stepper("", value: $durationMinutes, in: 0...59).labelsHidden()
                                }
                                Spacer()
                            }
                        }

                        sectionCard("Distance") {
                            VStack(spacing: 12) {
                                WktSegmentedPicker(selection: $useSteps, options: [
                                    .init(value: false, title: Self.unitWord, symbol: .distance),
                                    .init(value: true, title: "Steps", symbol: .steps)
                                ])

                                if useSteps {
                                    TextField("Approximate steps", text: $stepCount)
                                        .keyboardType(.numberPad)
                                        .foregroundColor(.earthCream)
                                        .font(.wktBodyText)
                                        .padding(12)
                                        .background(Color.earthRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                } else {
                                    TextField(Self.unitHint, text: $distanceText)
                                        .keyboardType(.decimalPad)
                                        .foregroundColor(.earthCream)
                                        .font(.wktBodyText)
                                        .padding(12)
                                        .background(Color.earthRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }

                                if let meters = distanceMeters {
                                    Text("≈ \(formattedDistance(meters)) · \(Int(meters / 0.762).formatted()) steps")
                                        .font(.wktLabel).foregroundColor(.earthGreen)
                                }
                            }
                        }

                        sectionCard("Notes (optional)") {
                            TextField("Route name or notes…", text: $routeName)
                                .foregroundColor(.earthCream)
                                .font(.wktBodyText)
                                .padding(12)
                                .background(Color.earthRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        if saveFailed {
                            Text("Couldn't save your walk. Try again.")
                                .font(.wktLabel)
                                .foregroundColor(.earthCream)
                        }

                        Button(action: save) {
                            WktPrimaryLabel(title: "Save Walk")
                                .opacity(isValid ? 1 : 0.45)
                        }
                        .buttonStyle(BounceButtonStyle(scale: 0.98))
                        .disabled(!isValid)
                    }
                    .padding(.horizontal, WktSpacing.screen)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Log a Past Walk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.earthMuted)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }.fontWeight(.semibold).foregroundColor(.earthGreen)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func formattedDistance(_ meters: Double) -> String {
        MKDistanceFormatter.abbreviated.string(fromDistance: meters)
    }

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        WktSection(title: title) {
            VStack(alignment: .leading, spacing: 8) { content() }
                .wktCard(padding: 14)
        }
    }

    private func save() {
        guard let meters = distanceMeters else { return }
        let totalSeconds = TimeInterval((durationHours * 60 + durationMinutes) * 60)
        let name = routeName.trimmingCharacters(in: .whitespaces).isEmpty ? "Past Walk" : routeName
        let session = WalkSession(
            id: UUID(),
            routeName: name,
            date: walkDate,
            elapsedTime: totalSeconds,
            totalDistance: meters,
            waypoints: [],
            lapCount: 1,
            isLoop: false
        )
        guard onSave(session) else {
            saveFailed = true
            return
        }
        let count = UserDefaults.standard.integer(forKey: "wkt_manualEntries_count")
        UserDefaults.standard.set(count + 1, forKey: "wkt_manualEntries_count")
        dismiss()
    }
}

// MARK: - Walk History Row

struct WalkHistoryRow: View {
    let session: WalkSession
    /// Opens the activity's summary.
    let onOpen: () -> Void
    let onWalkAgain: () -> Void
    let onInfo: () -> Void

    private var rowIcon: WktSymbol {
        switch session.activityType {
        case "running":    return .run
        case "cycling":    return .ride
        case "stationary": return .indoor
        default:           return .walk
        }
    }

    private var rowColor: Color {
        switch session.activityType {
        case "running":    return Color.accentRun
        case "cycling":    return Color.accentRide
        case "stationary": return Color.accentIndoor
        default:           return .earthGreen
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) { rowContent }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens the summary")
                .accessibilityIdentifier("history.row")
            actionButtons
        }
        .padding(.vertical, 8)
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            WktIconBadge(symbol: rowIcon, tint: rowColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.routeName).font(.wktRowTitle).foregroundColor(.earthCream).lineLimit(1)
                // "Hike · 15 Oct 2026 at 09:12", "Indoor walk · …": the row's title is the
                // route's name, so this says which activity it was.
                Text("\(session.wording.displayName) · \(session.formattedDate)")
                    .font(.wktLabel).foregroundColor(.earthMuted)
                HStack(spacing: 10) {
                    Label { Text(session.distanceText) } icon: { Image(wkt: .distance).wktIcon(.inline, tint: .earthMuted) }
                    Label { Text(session.timeText) } icon: { Image(wkt: .time).wktIcon(.inline, tint: .earthMuted) }
                }
                .font(.wktLabel).foregroundColor(.earthMuted)
                if !session.notes.isEmpty {
                    Text(session.notes)
                        .font(.wktLabel).foregroundColor(.earthMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var actionButtons: some View {
        VStack(spacing: 8) {
            Button { onWalkAgain() } label: {
                Image(wkt: .refresh)
                    .wktIcon(.inline, tint: rowColor)
                    .frame(width: 36, height: 36)
                    .background(Color.earthRaised, in: Circle())
            }
            .buttonStyle(BounceButtonStyle(scale: 0.92))
            // Replaying starts a route walk, never a hike (only a trail's own
            // Start makes one), so this names the activity, not "hike".
            .accessibilityLabel("Do this \(session.wording.activityMode.noun) again")
            Button { onInfo() } label: {
                Image(wkt: session.notes.isEmpty ? .notePlus : .noteText)
                    .wktIcon(.inline, tint: .earthCream)
                    .frame(width: 36, height: 36)
                    .background(Color.earthRaised, in: Circle())
            }
            .buttonStyle(BounceButtonStyle(scale: 0.92))
            .accessibilityLabel(session.notes.isEmpty ? "Add note" : "View note")
        }
    }
}
