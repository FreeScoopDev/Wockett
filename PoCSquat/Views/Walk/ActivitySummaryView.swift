import SwiftUI
import MapKit

// MARK: - Activity Summary View
//
// The one summary for every finished activity, walk, run, ride or indoor, and
// for any activity opened from Activity History. Until 2026-10-13 an indoor
// walk ended on a half sheet with three tiles and no Share or records, a walk
// ended from the mini tile showed nothing, and history offered only a notes
// sheet (design audit 2026-10-12, finding 22).
//
// What it shows comes from `ActivitySummaryContent`: a route map only when
// there is a route (an indoor or hand-logged walk has none, and gets no empty
// map), and the figures that make sense for the activity.

struct ActivitySummaryView: View {
    /// Right after finishing, or opened again from history.
    enum Moment { case justFinished, history }

    let session: WalkSession
    var moment: Moment = .justFinished
    /// Just finished: the records this activity set. History: the records it
    /// set at the time (`ActivitySummaryContent.recordsSet`).
    var records: [PRType] = []
    var splits: [(label: String, elapsed: TimeInterval)] = []
    /// The pets on this activity. Nil reads the walk's own `activePetIds`; an
    /// indoor walk credits its pets as entries of their own, so it passes them.
    var petIds: [UUID]?
    var onExcludeFromRouteStats: (() -> Void)?
    /// An activity not saved yet (an indoor walk of 100 steps or fewer): the
    /// summary offers to save it. Returns the records the save set, or nil
    /// when the write failed: then the button stays and the summary says so.
    var onSave: (() -> [PRType]?)?
    /// Saving it on Finish already failed (an indoor walk over 100 steps):
    /// the summary opens with "Couldn't save", and its Save button retries.
    var saveFailed = false
    /// The named trail this walk was on, carried in memory from the session
    /// (`NavigableRoute.trail`), for the post-walk questions. Nil from
    /// history, for a walk restored after the app was killed, and off trails.
    var trail: TrailRef?

    // Not private: a private stored property can make the memberwise
    // initializer private on CI's Xcode 26.6 (CLAUDE.md memory, #202).
    @EnvironmentObject var historyStore: WalkHistoryStore
    @EnvironmentObject var routeStore: CustomRouteStore
    @EnvironmentObject var petStore: PetStore

    @Environment(\.dismiss) private var dismiss

    @State private var excludedFromStats  = false
    @State private var savedAsRoute       = false
    @State private var showRouteNameField = false
    @State private var routeName          = ""
    @State private var showActivityShare  = false
    @State private var showScheduleSheet  = false
    @State private var ringProgress: [UUID: Double] = [:]
    @State private var savedLate          = false
    @State private var showSaveFailure    = false
    @State private var lateRecords: [PRType] = []
    /// The trail questions, decided once when the summary first appears.
    @State private var trailReport: TrailReportCardModel?
    @State private var trailReportDecided = false

    private var mode: ActivityMode { ActivitySummaryContent.mode(of: session) }
    /// "Hike complete!" for a hike; the activity's words otherwise.
    private var wording: SessionWording { session.wording }
    private var isJustFinished: Bool { moment == .justFinished }
    private var shownRecords: [PRType] { records + lateRecords }

    private var crew: [PetProfile] {
        let ids = petIds ?? session.activePetIds
        return petStore.pets.filter { ids.contains($0.id) }
    }

    private var canSaveAsRoute: Bool {
        // Free session (no saved-route ID) with enough breadcrumb points.
        isJustFinished && session.customRouteId == nil && session.waypoints.count > 5
    }

    private var completionMessage: String {
        let names = crew.map(\.name)
        switch names.count {
        case 0:  return "Nice work on \(session.routeName). Keep the momentum going!"
        case 1:  return "Nice work! \(names[0]) had a great \(wording.noun) too. 🐾"
        case 2:  return "Nice work! \(names[0]) and \(names[1]) loved it. 🐾"
        default: return "Nice work! The whole crew crushed it. 🐾"
        }
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .short; return f
    }()

    /// History's subtitle: when, and who came along.
    private var historySubtitle: String {
        let when = Self.dateFmt.string(from: session.date)
        let names = crew.map(\.name)
        guard !names.isEmpty else { return when }
        return "\(when)\nwith \(ListFormatter.localizedString(byJoining: names))"
    }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            if isJustFinished { ConfettiOverlay() }

            ScrollView {
                VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                    header
                    if ActivitySummaryContent.hasRoute(session) { routeMap }
                    ActivityStatTiles(session: session)
                    // High up, so it is seen before Done; it counts as asked only once seen.
                    if let trailReport { TrailReportCard(model: trailReport, noun: wording.noun) }

                    if !shownRecords.isEmpty { prBanner }
                    if isJustFinished, let line = stopEncouragement {
                        Text(line)
                            .font(.wktRowTitle).foregroundColor(.earthGreen)
                            .transition(.opacity)
                    }
                    if isJustFinished, !crew.isEmpty { petRingsSection }
                    // A run reclassified as a ride in Activity History keeps
                    // its saved splits; a ride never shows them.
                    if mode.hasPaceAndSplits, !splitRows.isEmpty { unitSplitsSection }
                    if isJustFinished, !splits.isEmpty { checkpointsSection }
                    if isJustFinished, session.customRouteId != nil, onExcludeFromRouteStats != nil { routeStatsPrompt }
                    if canSaveAsRoute { saveAsRouteSection }
                    if onSave != nil { saveToHistoryButton }

                    VStack(spacing: WktSpacing.betweenCards) {
                        WktSecondaryButton(title: "Share this \(wording.noun)", symbol: .share) {
                            showActivityShare = true
                        }
                        WktSecondaryButton(title: "Schedule this \(mode.noun) again", symbol: .calendarAdd) {
                            showScheduleSheet = true
                        }
                    }
                }
                .padding(.horizontal, WktSpacing.screen)
                .padding(.top, 24)
                .padding(.bottom, 16)
            }
            // Done is the one primary action, always in reach however long
            // the summary runs.
            .safeAreaInset(edge: .bottom) {
                WktPrimaryButton(title: "Done") { finish() }
                    .accessibilityIdentifier("summary.done")
                    .padding(.horizontal, WktSpacing.screen)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .background(Color.earthBg)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary.root")
        .onAppear {
            animateRings()
            decideTrailReport()
            if saveFailed, !savedLate { showSaveFailure = true }
        }
        .saveFailureAlert(noun: showSaveFailure ? wording.noun : nil,
                          onTryAgain: { showSaveFailure = false; saveLate() },
                          onKeepGoing: { showSaveFailure = false })
        .sheet(isPresented: $showActivityShare) {
            ActivitySummaryShareSheet(session: session, historyStore: historyStore)
        }
        .sheet(isPresented: $showScheduleSheet) {
            ScheduleWalkSheet(routeName: session.routeName)
        }
    }

    /// Done. A record just set is a pleased moment: the root asks for a
    /// rating once this has gone (`ReviewPrompter`). Never from history.
    private func finish() {
        if isJustFinished, !shownRecords.isEmpty { ReviewPrompter.shared.noteHighlight() }
        dismiss()
    }

    /// Whether to ask about the trail: decided once per summary, within the
    /// policy's limits. The ask is spent when the card is seen, not here.
    private func decideTrailReport() {
        guard !trailReportDecided else { return }
        trailReportDecided = true
        trailReport = TrailReportCardModel.forSummary(trail: trail, session: session, moment: moment,
                                                      walkStore: ActiveWalkStore.shared)
    }

    private func animateRings() {
        guard isJustFinished else { return }
        for (i, pet) in crew.enumerated() {
            let today = petStore.todaySteps(for: pet, in: historyStore.sessions)
            let progress = min(1.0, Double(today) / Double(max(1, pet.goalSteps)))
            withAnimation(.spring(duration: 0.9, bounce: 0.25).delay(Double(i) * 0.18)) {
                ringProgress[pet.id] = progress
            }
        }
    }

    // MARK: - Header and route

    private var header: some View {
        VStack(spacing: 12) {
            WktIconBadge(symbol: mode.wktSymbol, tint: mode.tileColor, size: 64)
                .padding(.bottom, 4)
            Text(isJustFinished ? "\(wording.displayName) complete!" : session.routeName)
                .font(isJustFinished ? .wktMetric : .wktCardTitle)
                .foregroundColor(.earthCream)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(isJustFinished ? completionMessage : historySubtitle)
                .font(.wktBodyText)
                .foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
    }

    /// Only for an activity with a line to draw; one without has no map at all.
    private var routeMap: some View {
        Map(initialPosition: .automatic, interactionModes: []) {
            MapPolyline(coordinates: session.waypoints.map(\.clCoordinate))
                .stroke(mode.tileColor, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        .mapStyle(.standard(emphasis: .muted))
        .frame(height: 180)
        .clipShape(RoundedRectangle.wktCard)
        .overlay(RoundedRectangle.wktCard.strokeBorder(Color.earthStroke, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map of this \(wording.noun)'s route")
    }

    private var saveToHistoryButton: some View {
        WktSecondaryButton(title: savedLate ? "Saved to Activity History" : "Save to Activity History",
                           symbol: savedLate ? .success : .history) {
            saveLate()
        }
        .disabled(savedLate)
    }

    /// The Save button, and Try again after a failed save: a write that
    /// fails leaves the button as it was and says so.
    private func saveLate() {
        guard !savedLate, let onSave else { return }
        savedLate = true
        guard let records = onSave() else {
            savedLate = false
            showSaveFailure = true
            return
        }
        withAnimation { lateRecords = records }
    }

    // MARK: - Subviews

    private var prBanner: some View {
        let plural = shownRecords.count > 1 ? "s" : ""
        return WktSection(title: isJustFinished ? "New personal record\(plural)" : "Personal record\(plural) set") {
            HStack(spacing: WktSpacing.betweenCards) {
                ForEach(shownRecords) { pr in
                    VStack(spacing: 4) {
                        Text(pr.emoji).font(.title2) // the record's own emoji (data)
                        Text(pr.title)
                            .font(.wktLabel).foregroundColor(.earthCream)
                            .multilineTextAlignment(.center)
                        Text(pr.valueText)
                            .font(.wktRowTitle)
                            .foregroundColor(.earthOrange)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .wktCardBackground(fill: .earthCard)
                    .overlay(RoundedRectangle.wktCard
                        .strokeBorder(Color.earthOrange.opacity(0.4), lineWidth: 1))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(pr.title): \(pr.valueText)")
                }
            }
        }
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private var petRingsSection: some View {
        WktSection(title: "Your crew's progress today") {
            HStack(spacing: 24) {
                ForEach(crew) { pet in
                    let progress = ringProgress[pet.id] ?? 0
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .stroke(Color.earthTrack, lineWidth: 7)
                                .frame(width: 72, height: 72)
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(pet.accentColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                                .frame(width: 72, height: 72)
                                .rotationEffect(.degrees(-90))
                            Text(pet.displayEmoji).font(.title2) // the pet's own emoji (data)
                        }
                        Text(pet.name).font(.wktLabel).foregroundColor(.earthCream)
                        Text(WktPercent.text(progress)).font(.wktLabel).foregroundColor(pet.accentColor)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(pet.name)
                    .accessibilityValue("\(WktPercent.text(progress)) of daily step goal")
                }
            }
            .frame(maxWidth: .infinity)
            .wktCard()
        }
    }

    private var splitRows: [ActivitySummaryContent.SplitRow] {
        ActivitySummaryContent.splitRows(session.unitSplits)
    }

    /// Per-mile or per-km splits, saved with the activity, so they show again
    /// when it is opened from Activity History (`feat/run-pace-splits`).
    private var unitSplitsSection: some View {
        WktSection(title: "Splits") {
            VStack(spacing: 0) {
                ForEach(splitRows.indices, id: \.self) { i in
                    if i > 0 { WktDivider() }
                    let row = splitRows[i]
                    HStack {
                        Text(row.label).font(.wktRowTitle).foregroundColor(.earthCream)
                        Spacer()
                        Text(row.time).font(Font.wktBodyText.monospacedDigit()).foregroundColor(.earthCream)
                        Text(row.pace).font(Font.wktLabel.monospacedDigit()).foregroundColor(.earthMuted)
                            .frame(minWidth: 72, alignment: .trailing)
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.label): \(row.time), \(row.pace)")
                }
            }
            .wktCard(padding: 14)
        }
    }

    /// A guided route's checkpoint times (20/40/60/80%, or a custom route's
    /// points). Called "Splits" until 2026-10-14, when per-mile splits took
    /// that name.
    private var checkpointsSection: some View {
        WktSection(title: "Checkpoints") {
            VStack(spacing: 0) {
                ForEach(splits.indices, id: \.self) { i in
                    if i > 0 { WktDivider() }
                    HStack {
                        Text(splits[i].label).font(.wktRowTitle).foregroundColor(.earthCream)
                        Spacer()
                        Text(splitText(splits[i].elapsed)).font(.wktBodyText).foregroundColor(.earthCream)
                        if i > 0 {
                            Text("(+\(splitText(splits[i].elapsed - splits[i-1].elapsed)))")
                                .font(.wktLabel).foregroundColor(.earthMuted)
                        }
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
            }
            .wktCard(padding: 14)
        }
    }

    private var routeStatsPrompt: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(excludedFromStats ? "Excluded from route history" : "Counting toward \"\(session.routeName)\"")
                    .font(.wktRowTitle)
                    .foregroundColor(excludedFromStats ? .earthMuted : .earthCream)
                Text(excludedFromStats ? "This session won't appear in route runs" : "Tap exclude to skip route stats for this session")
                    .font(.wktLabel).foregroundColor(.earthMuted)
            }
            Spacer()
            if !excludedFromStats {
                WktPillButton(title: "Exclude", tint: .earthCream) {
                    excludedFromStats = true
                    onExcludeFromRouteStats?()
                }
            }
        }
        .wktCard()
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: excludedFromStats)
    }

    private var saveAsRouteSection: some View {
        Group {
            if showRouteNameField {
                HStack(spacing: 10) {
                    TextField("Route name…", text: $routeName)
                        .font(.wktBodyText)
                        .foregroundColor(.earthCream)
                        .padding(.horizontal, WktSpacing.cardPadding)
                        .frame(minHeight: 52)
                        .wktCardBackground()
                    WktPillButton(title: "Save") { saveAsRoute() }
                }
            } else {
                WktSecondaryButton(title: savedAsRoute ? "Saved as Custom Route" : "Save as Custom Route",
                                   symbol: savedAsRoute ? .success : .saved) {
                    if !savedAsRoute { showRouteNameField = true }
                }
                .disabled(savedAsRoute)
            }
        }
    }

    // MARK: - Helpers

    private var stopEncouragement: String? {
        guard let routeId = session.customRouteId,
              let currentStops = session.stopCount else { return nil }
        let prev = historyStore.sessions
            .filter { $0.customRouteId == routeId && $0.countsTowardRouteStats && $0.id != session.id }
            .sorted { $0.date > $1.date }.first
        guard let prev, let prevStops = prev.stopCount, currentStops < prevStops else { return nil }
        if session.totalDistance > 200, session.elapsedTime > 0,
           prev.totalDistance > 200, prev.elapsedTime > 0 {
            let currPace = session.elapsedTime / (session.totalDistance / 1000)
            let prevPace = prev.elapsedTime / (prev.totalDistance / 1000)
            if currPace < prevPace { return nil }
        }
        return "Fewer stops than last time!"
    }

    private func splitText(_ t: TimeInterval) -> String {
        let s = Int(t); let m = s / 60
        return m < 60 ? "\(m)m \(s % 60)s" : "\(m / 60)h \(m % 60)m"
    }

    private func saveAsRoute() {
        let name = routeName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "My \(wording.sessionLabel)" : routeName
        routeStore.save(CustomRoute(
            id: UUID(),
            name: name,
            waypoints: session.waypoints,
            totalDistance: session.totalDistance,
            isLoop: false,
            createdAt: Date(),
            activityMode: mode
        ))
        savedAsRoute = true
        showRouteNameField = false
    }
}

// MARK: - Stat tiles

/// The figures an activity shows (`ActivitySummaryContent.stats`) as icon
/// tiles: three in a row, or two rows of two. The summary and the history
/// notes sheet both use it, so a ride never shows steps on either.
struct ActivityStatTiles: View {
    let session: WalkSession

    private var stats: [SummaryStat] { ActivitySummaryContent.stats(for: session) }
    private var mode: ActivityMode { ActivitySummaryContent.mode(of: session) }

    var body: some View {
        VStack(spacing: WktSpacing.betweenCards) {
            ForEach(Self.rows(count: stats.count), id: \.self) { row in
                HStack(spacing: WktSpacing.betweenCards) {
                    ForEach(row, id: \.self) { tile(stats[$0]) }
                }
                // Tiles in a row share the tallest one's height, so a climb's
                // descent line doesn't leave its neighbours short.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Which tiles share a row: three in a row, two rows of two for four,
    /// and three then two for five (a walk or run with a climb).
    static func rows(count: Int) -> [[Int]] {
        let sizes: [Int]
        switch count {
        case 4:  sizes = [2, 2]
        default: sizes = Array(repeating: 3, count: count / 3) + (count % 3 > 0 ? [count % 3] : [])
        }
        var start = 0
        return sizes.map { size in
            defer { start += size }
            return Array(start..<start + size)
        }
    }

    private func tile(_ stat: SummaryStat) -> some View {
        WktIconStatTile(value: stat.value(for: session), label: stat.label,
                        symbol: stat == .steps ? mode.wktSymbol : stat.symbol, tint: tint(stat),
                        detail: stat.detail(for: session),
                        accessibilityDetail: stat.accessibilityDetail(for: session),
                        fillsHeight: true)
    }

    private func tint(_ stat: SummaryStat) -> Color {
        switch stat {
        case .distance, .estimatedDistance: return .earthGreen
        case .time:                         return .earthOrange
        default:                            return mode.tileColor
        }
    }
}

extension View {
    /// The summary an activity ended on, again, from a list of past ones:
    /// same screen, same Share card, and the records it set at the time.
    /// Activity History and the day sheet both open it through here.
    func historySummaryCover(item: Binding<WalkSession?>, history: [WalkSession]) -> some View {
        fullScreenCover(item: item) { session in
            ActivitySummaryView(
                session: session,
                moment: .history,
                records: ActivitySummaryContent.recordsSet(by: session, in: history)
            )
        }
    }
}
