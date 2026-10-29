import SwiftUI
import MapKit
import UIKit

// MARK: - Walk History View

struct WalkHistoryView: View {
    @ObservedObject var store: WalkHistoryStore
    @EnvironmentObject var petStore: PetStore
    @EnvironmentObject private var tabRouter: TabRouter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showManualEntry = false
    @State private var selectedSession: WalkSession?
    @State private var summarySession: WalkSession?
    @State private var repeatSession: WalkSession?
    @State private var shareSession: WalkSession?
    /// Set by the review sheet's Start; once the sheet has gone, the walk
    /// screen opens (`closeIfRepeatStarted`).
    @State private var repeatStarted = false
    /// Search and filters. View state only: never stored, gone when History
    /// closes (fix/history-search-filter).
    @State private var filter = HistoryFilter()
    /// Whether the search field is active. While it is, iOS hides the
    /// toolbar, filter menu included; Clear filters ends it.
    @State private var searchActive = false

    /// The rows on screen and the header computed from them, built once per
    /// render so the list, its header and its deletes all use the same rows.
    private var page: HistoryPage {
        HistoryPage(filter: filter, sessions: store.sessions,
                    petName: filter.petID.flatMap { id in petStore.pets.first { $0.id == id }?.name },
                    now: Date(), calendar: .current)
    }

    var body: some View {
        let page = page
        ZStack {
            Color.earthBg.ignoresSafeArea()
            Group {
                switch page.state {
                case .noHistory: emptyState
                case .noMatch:   noMatchState
                case .rows:      historyList(page)
                }
            }
        }
        .navigationTitle("Activity History")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter.query, isPresented: $searchActive,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search names and notes")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if page.state != .noHistory { filterMenu }
                Button {
                    showManualEntry = true
                } label: {
                    Image(wkt: .add).wktIcon(.inline, tint: .earthGreen)
                }
                .accessibilityLabel("Add activity")
            }
        }
        .sheet(isPresented: $showManualEntry) {
            ManualWalkEntrySheet { session in store.add(session) }
        }
        .sheet(item: $selectedSession) { session in
            WalkSessionDetailSheet(session: session, store: store)
        }
        .sheet(item: $repeatSession, onDismiss: closeIfRepeatStarted) { session in
            RepeatReviewSheet(
                review: RepeatReview(session: session, activePets: petStore.activePets),
                // The same route the row's arrow started before the review.
                begin: { ActiveWalkStore.shared.beginSession(route: session.toNavigableRoute()) != nil },
                onStarted: { repeatStarted = true }
            )
        }
        .sheet(item: $shareSession) { session in
            ActivitySummaryShareSheet(session: session, historyStore: store)
        }
        .historySummaryCover(item: $summarySession, history: store.sessions)
        // With nothing stored, the filter menu is hidden; a filter left set
        // would greet the next walk logged with "No activities match".
        .onChange(of: store.sessions.isEmpty) { _, isEmpty in
            if isEmpty { filter = HistoryFilter() }
        }
    }

    /// After Repeat's Start, the walk screen opens, the way a route started
    /// from Routes opens it (`requestReopen`, then Home). `beginSession` only
    /// creates the session: recording, the Health workout and the pets' credit
    /// begin when the walk screen appears. Until 2026-10-27 History only
    /// closed, leaving a mini tile at 0:00 that recorded nothing until it was
    /// tapped. After Cancel, History stays.
    private func closeIfRepeatStarted() {
        guard repeatStarted else { return }
        repeatStarted = false
        dismiss()
        ActiveWalkStore.shared.requestReopen()
        tabRouter.selected = .home
    }

    private var emptyState: some View {
        // Activity-neutral: this list holds runs, rides and indoor walks too.
        WktEmptyState(symbol: .history, title: "No activities yet",
                      message: "Finish a walk, run or ride to build your history",
                      actionTitle: "Log a Past Walk") { showManualEntry = true }
    }

    /// Something is stored, but the search or filters match none of it. Not
    /// the empty state: that one says there is no history at all.
    private var noMatchState: some View {
        WktEmptyState(symbol: .find, title: "No activities match",
                      message: "Try other words, or clear the filters to see everything",
                      actionTitle: "Clear filters") {
            filter = HistoryFilter()
            searchActive = false
        }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("history.noMatch")
    }

    // MARK: Filter menu

    private var filterMenu: some View {
        Menu {
            Picker(selection: $filter.activity) {
                Text("Any activity").tag(ActivityMode?.none)
                // The activities Home offers, in its order.
                ForEach(HomeActivityPicker.modes, id: \.self) { mode in
                    Text(mode.displayName).tag(ActivityMode?.some(mode))
                }
            } label: {
                Text("Activity")
            }
            .pickerStyle(.menu)
            Picker(selection: $filter.period) {
                ForEach(HistoryFilter.Period.allCases, id: \.self) { period in
                    Text(period.title).tag(period)
                }
            } label: {
                Text("Period")
            }
            .pickerStyle(.menu)
            if !petStore.pets.isEmpty {
                Picker(selection: $filter.petID) {
                    Text("Any pet").tag(UUID?.none)
                    ForEach(petStore.pets) { pet in
                        Text(pet.name).tag(UUID?.some(pet.id))
                    }
                } label: {
                    Text("Pet")
                }
                .pickerStyle(.menu)
            }
            if filter.menuCount > 0 {
                Divider()
                Button { filter.resetMenu() } label: {
                    Label { Text("Reset") } icon: { Image(wkt: .undo) }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(wkt: .filter)
                    .wktIcon(.inline, tint: .earthGreen, filled: filter.menuCount > 0)
                if filter.menuCount > 0 {
                    Text("\(filter.menuCount)")
                        .font(.wktLabel.monospacedDigit())
                        .foregroundColor(.earthGreen)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Filters")
        .accessibilityValue(filter.accessibilityValue)
        .accessibilityIdentifier("history.filter")
    }

    // MARK: Header

    private func statsHeader(_ page: HistoryPage) -> some View {
        // The scope is named, and the figures are the sums over exactly the
        // rows listed below: every one, rides and zero-distance records
        // included, so it says so rather than averaging them.
        let totals = page.totals
        return WktSection(title: page.title) {
            // Rows of two at the accessibility sizes, without the dividers:
            // a quarter of the width cut "This week" to "This w…".
            WktStatRow(spacing: 0, rowSpacing: WktSpacing.betweenCards) {
                statCell("\(totals.count)", totals.count == 1 ? "Activity" : "Activities")
                columnDivider
                statCell(totals.distanceText(), "Distance")
                columnDivider
                statCell(totals.timeText, "Time")
                columnDivider
                statCell("\(page.thisWeek)", "This week")
            }
            .wktCard(padding: 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(totals.summary()). \(page.thisWeek) this week")
            .accessibilityIdentifier("history.header")
        }
        .padding(.horizontal, WktSpacing.screen)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var columnDivider: some View {
        if WktStatColumns.columns(typeSize) == nil {
            Rectangle().fill(Color.earthTrack).frame(width: 1, height: 36)
        }
    }

    private func statCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.wktRowTitle.monospacedDigit()).foregroundColor(.earthCream)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.wktLabel).foregroundColor(.earthMuted)
                .lineLimit(WktStatColumns.labelLineLimit(typeSize)).minimumScaleFactor(0.8)
                .multilineTextAlignment(WktStatColumns.labelAlignment(typeSize))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func historyList(_ page: HistoryPage) -> some View {
        let rows = page.rows
        return List {
            Section {
                statsHeader(page)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(rows) { session in
                WalkHistoryRow(session: session,
                               onOpen: { summarySession = session },
                               onEdit: { selectedSession = session },
                               onRepeat: {
                                   repeatStarted = false
                                   repeatSession = session
                               },
                               onShare: { shareSession = session })
                .listRowBackground(Color.earthCard)
                .listRowSeparatorTint(Color.earthTrack)
            }
            // The offsets are into `rows`, the list on screen, which a search
            // or filter makes a subset of the store's. The page converts them
            // to ids: passed to the store as offsets, they would delete other
            // walks.
            .onDelete { page.delete($0, from: store) }
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
                        // Reached from a row's More menu as "Edit details": it
                        // edits the type and the note, so it says so.
                        VStack(spacing: 2) {
                            Text("Edit details")
                                .font(.wktRowTitle).foregroundColor(.earthCream)
                                .accessibilityAddTraits(.isHeader)
                            Text(Self.dateFmt.string(from: session.date))
                                .font(.wktBodyText).foregroundColor(.earthMuted)
                        }
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
                            Text("\(SaveFailureText.title(noun: ActivityMode.walking.noun)). \(SaveFailureText.tryAgain).")
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
    /// Opens `WalkSessionDetailSheet`: the activity type and the note.
    let onEdit: () -> Void
    /// Opens the review sheet; only its Start begins anything.
    let onRepeat: () -> Void
    let onShare: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) { ActivityRowContent(text: ActivityRowText(session)) }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens the summary")
                .accessibilityIdentifier("history.row")
            moreMenu
        }
        .padding(.vertical, 8)
    }

    /// One labelled menu instead of two icon-only circles, one of which began
    /// a walk on the tap. Every action has a visible title in the menu.
    private var moreMenu: some View {
        Menu {
            Button(action: onEdit) {
                Label { Text("Edit details") } icon: { Image(wkt: .edit) }
            }
            Button(action: onRepeat) {
                Label { Text("Repeat") } icon: { Image(wkt: .refresh) }
            }
            Button(action: onShare) {
                Label { Text("Share") } icon: { Image(wkt: .share) }
            }
        } label: {
            Image(wkt: .more)
                .wktIcon(.inline, tint: .earthCream)
                .frame(width: 44, height: 44)
                .background(Color.earthRaised, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .accessibilityHint("Edit details, repeat or share this \(session.wording.noun)")
        .accessibilityIdentifier("history.more")
    }
}

// MARK: - Activity row (History and Home)

/// What one saved activity's row says. Activity History's rows and Home's
/// Recent activity both read it, so the two cannot word the same walk
/// differently (fix/home-start-first, 2026-10-28).
struct ActivityRowText: Equatable {
    /// The route's name: "Downtown Loop", "Past Walk", "Nala's Indoor Walk".
    let title: String
    /// "Hike · Oct 15, 2026 at 9:12 AM", "Indoor walk · …": the title is the
    /// route's name, so this says which activity it was.
    let subtitle: String
    let distance: String
    let time: String
    /// The note, or nil when there is none.
    let notes: String?
    let symbol: WktSymbol

    init(_ session: WalkSession, locale: Locale = .current, timeZone: TimeZone = .current) {
        title = session.routeName
        subtitle = "\(session.wording.displayName) · \(session.formattedDate(locale: locale, timeZone: timeZone))"
        distance = session.distanceText
        time = session.timeText
        notes = session.notes.isEmpty ? nil : session.notes
        switch session.activityType {
        case "running":    symbol = .run
        case "cycling":    symbol = .ride
        case "stationary": symbol = .indoor
        default:           symbol = .walk
        }
    }
}

/// The row's icon and text, without the row's actions: History adds its More
/// menu beside it, Home shows it alone.
struct ActivityRowContent: View {
    let text: ActivityRowText

    private var tint: Color {
        switch text.symbol {
        case .run:    return Color.accentRun
        case .ride:   return Color.accentRide
        case .indoor: return Color.accentIndoor
        default:      return .earthGreen
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            WktIconBadge(symbol: text.symbol, tint: tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(text.title).font(.wktRowTitle).foregroundColor(.earthCream).lineLimit(1)
                Text(text.subtitle)
                    .font(.wktLabel).foregroundColor(.earthMuted)
                HStack(spacing: 10) {
                    Label { Text(text.distance) } icon: { Image(wkt: .distance).wktIcon(.inline, tint: .earthMuted) }
                    Label { Text(text.time) } icon: { Image(wkt: .time).wktIcon(.inline, tint: .earthMuted) }
                }
                .font(.wktLabel).foregroundColor(.earthMuted)
                if let notes = text.notes {
                    Text(notes)
                        .font(.wktLabel).foregroundColor(.earthMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
