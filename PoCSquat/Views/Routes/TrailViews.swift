import SwiftUI
import MapKit

// MARK: - Trails in the Routes tab
//
// The Trails side of the Routes | Trails switch (design agreed 2026-09-23,
// option A of the "Trails in Routes" canvas). Everything here reads the
// region packs on the phone, so the list appears instantly and works with no
// signal. Start Walk appears at the trail and follows the trail's own line
// (`TrailWalkPlanner`); saving a trail to My Routes is a separate change,
// because saved routes sync through CloudKit and a trail's line needs a field
// there.

struct TrailsPanel: View {
    @Bindable var finder: TrailFinder
    @Binding var selected: TrailListItem?
    @Binding var groupSections: Bool
    @Binding var includeShortPaths: Bool
    /// Where the list is centred: the chosen place, else the person.
    let userLocation: CLLocationCoordinate2D?
    /// The person's own location only, for directions, reach and the walk
    /// plan: never a chosen place (spec fix/route-start-place, item 11).
    let directionsOrigin: CLLocationCoordinate2D?
    let activityMode: ActivityMode
    let containerHeight: CGFloat
    let modePicker: AnyView
    let directions: TrailDirectionsModel
    let onStart: (TrailWalkPlan) -> Void
    let onStartApproach: (NavigableRoute) -> Void
    let locationState: RouteLocationState
    let onPlanOnMap: () -> Void
    var chosenName: String?
    var onChooseStart: (() -> Void)?
    var onUseMyLocation: () -> Void = {}
    var refreshLocation: () async -> Void = {}

    /// What the headings call the place the list is around.
    private var originName: String { chosenName ?? "you" }

    /// "Other paths" starts closed: it is the unnamed paths a
    /// downloaded state pack carries, there if wanted but not in the way.
    @State private var showOtherPaths = false
    private let featuredTrails = FeaturedTrailService.shared
    /// The features as they were when the list appeared: a fetch that lands
    /// while it is open shows next time, not as cards pushing the list down
    /// under a finger.
    @State private var shownFeatures: [FeaturedTrail] = []
    private let contributions = ContributionService.shared
    /// Contributions newly featured, announced once (`takeBanner` marks them).
    @State private var featuredNews: [Contribution] = []

    /// Trails in this list that Joe features, in list order, each once. They
    /// stay in "Trails near <place>" too.
    private var featured: [(item: TrailListItem, feature: FeaturedTrail)] {
        FeaturedTrails.featuredItems(finder.items, in: shownFeatures, at: Date()) { !TrailPackLibrary.shared.trails(key: $0).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.earthMuted.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            if let item = selected {
                TrailDetailView(item: item, userLocation: directionsOrigin, originName: originName, activityMode: activityMode,
                                directions: directions, onStart: onStart, onStartApproach: onStartApproach,
                                refreshLocation: refreshLocation) {
                    withAnimation(.spring(response: 0.3)) { selected = nil }
                }
            } else {
                modePicker
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                TrailFilterChips(filters: $finder.filters)
                    .padding(.bottom, 10)
                list
            }
        }
        // Same ceiling as the route results panel, a little taller because a
        // trail list is the whole point of this screen.
        .frame(maxHeight: containerHeight * 0.55)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routes.trailsPanel")
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
        .background(.ultraThinMaterial, ignoresSafeAreaEdges: .bottom)
    }

    private var list: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 10) {
                if let news = ContributionMessages.banner(for: featuredNews) {
                    ContributionFeaturedBanner(text: news) {
                        withAnimation(.spring(response: 0.3)) { featuredNews = [] }
                    }
                    .padding(.horizontal, 20)
                }
                let picks = emptyMessage == nil ? featured : []
                if !picks.isEmpty {
                    WktSectionHeader(title: "Featured near \(originName)")
                        .padding(.horizontal, 20)
                    ForEach(picks, id: \.item.id) { pick in
                        FeaturedTrailCard(item: pick.item, feature: pick.feature, activityMode: activityMode) {
                            withAnimation(.spring(response: 0.3)) { selected = pick.item }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Trails near \(originName)")
                        .font(.wktSection)
                        .foregroundColor(.earthCream)
                    Spacer()
                    filtersButton
                }
                .padding(.horizontal, 20)

                // Above the list, the empty message and a failure alike, so Change
                // and Use my location never vanish with the trails.
                if locationState.isChosen { recoveryActions }

                if showsLocationRecovery, let reason = locationState.message {
                    LocationRecoveryActions.reason(reason)
                        .padding(.horizontal, 28)
                        .padding(.top, 12)
                    recoveryActions
                } else if let message = emptyMessage {
                    Text(message)
                        .font(.wktBodyText)
                        .foregroundColor(.earthMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.top, 24)
                        .padding(.bottom, emptyMessageBottom)
                    if offersRegions {
                        WktSecondaryButton(title: "Trail regions", symbol: .cloudDownload) { showRegions = true }
                            .accessibilityIdentifier("routes.trailRegionsEmpty")
                            .padding(.horizontal, 28)
                            .padding(.bottom, 16)
                    }
                    if filtersEmptiedList {
                        WktSecondaryButton(title: "Reset filters", action: resetFilters)
                            .accessibilityIdentifier("routes.trailFiltersResetEmpty")
                            .padding(.horizontal, 28)
                            .padding(.bottom, 16)
                    }
                } else {
                    ForEach(finder.items) { item in
                        TrailCard(item: item, activityMode: activityMode) {
                            withAnimation(.spring(response: 0.3)) { selected = item }
                        }
                        .accessibilityIdentifier("routes.trailCard")
                        .padding(.horizontal, 20)
                    }
                    if !finder.otherPaths.isEmpty {
                        otherPathsHeader
                            .padding(.horizontal, 20)
                        if showOtherPaths {
                            ForEach(finder.otherPaths) { item in
                                TrailCard(item: item, activityMode: activityMode) {
                                    withAnimation(.spring(response: 0.3)) { selected = item }
                                }
                                .accessibilityIdentifier("routes.otherPathCard")
                                .padding(.horizontal, 20)
                            }
                        }
                    }
                }

                TrailCreditLine()
                    .padding(.top, 4)
                // The empty message already offers the same screen.
                if !offersRegions { regionsLink }
            }
            .padding(.bottom, 14)
        }
        .onAppear {
            shownFeatures = featuredTrails.list
            featuredNews += contributions.takeBanner()
        }
        // On the scroll view, not the button: a sheet hosted inside the
        // LazyVStack could be dismissed when its row is unloaded.
        .sheet(isPresented: $showFilters) { filtersSheet }
        .sheet(isPresented: $showRegions) { TrailRegionsSheet() }
        .task { await featuredTrails.refreshIfStale() }
        // At most daily; a status that arrives now is announced now.
        .task { featuredNews += await contributions.bannerAfterRefresh() }
    }

    /// One card that opens and closes the unnamed paths, styled like a
    /// trail card so the list reads as one set.
    private var otherPathsHeader: some View {
        Button {
            withAnimation(.spring(response: 0.3)) { showOtherPaths.toggle() }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                WktIconBadge(symbol: .routeTrail)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Other paths")
                        .font(.wktRowTitle)
                        .foregroundColor(.earthCream)
                    Text(TrailText.otherPathsSummary(count: finder.otherPaths.count))
                        .font(.wktLabel)
                        .foregroundColor(.earthMuted)
                }
                Spacer(minLength: 0)
                Image(wkt: showOtherPaths ? .chevronUp : .chevronDown).wktIcon(.inline, tint: .earthMuted)
            }
            .wktCard()
        }
        .buttonStyle(.plain)
        .accessibilityValue(showOtherPaths ? "Shown" : "Hidden")
        .accessibilityIdentifier("routes.otherPaths")
    }

    /// Off or restricted with no place chosen, and no other failure to report.
    private var showsLocationRecovery: Bool {
        finder.failure == nil && locationState.showsPlanOnMap && !locationState.isChosen
    }

    private var recoveryActions: some View {
        LocationRecoveryActions(state: locationState, activityMode: activityMode, onPlanOnMap: onPlanOnMap,
                                onChooseStart: onChooseStart, chosenName: chosenName, onUseMyLocation: onUseMyLocation,
                                compact: locationState.isChosen)
            .padding(.horizontal, 20)
    }

    private var emptyMessage: String? {
        if let failure = finder.failure { return failure }
        if showsLocationRecovery { return locationState.message }
        // Allowed but no fix yet is a wait, not something to turn on.
        if userLocation == nil {
            return locationState.message ?? "Finding your location…"
        }
        guard finder.hasSearched, finder.items.isEmpty, finder.otherPaths.isEmpty else { return nil }
        return finder.filters.canNarrowList(groupSections: groupSections)
            ? Self.noFilterMatch
            : Self.noTrailsNearby
    }

    // MARK: Filters button and sheet

    @State private var showFilters = false

    private var activeFilterCount: Int {
        finder.filters.activeCount(groupSections: groupSections, showShortPaths: includeShortPaths)
    }

    private static let noFilterMatch = "No trails within 10 miles match these filters."
    private static let noTrailsNearby = "No trails within 10 miles. Download your state in Trail Regions to see its trails. More states are on the way."

    // MARK: Trail regions

    @State private var showRegions = false

    /// No trails nearby and no filter to blame: download a state.
    private var offersRegions: Bool { emptyMessage == Self.noTrailsNearby }

    private var emptyMessageBottom: CGFloat { filtersEmptiedList || offersRegions ? 8 : 24 }

    /// Where offline trail data lives; the same screen as Settings → Trail Regions.
    private var regionsLink: some View {
        Button("Trail regions and offline data") { showRegions = true }
            .font(.wktLabel)
            .foregroundColor(.earthGreen)
            .frame(minHeight: 44)
            .accessibilityIdentifier("routes.trailRegions")
    }

    /// The empty message is the filters' doing, so it offers to undo them.
    private var filtersEmptiedList: Bool { emptyMessage == Self.noFilterMatch }

    private func resetFilters() {
        finder.filters.reset(groupSections: &groupSections, showShortPaths: &includeShortPaths)
    }

    private var filtersButton: some View {
        Button { showFilters = true } label: {
            HStack(spacing: 4) {
                Image(wkt: .filter).wktIcon(.inline, tint: .earthGreen)
                Text(TrailText.filtersTitle(activeCount: activeFilterCount))
            }
            .font(.wktBodyText)
            .foregroundColor(.earthGreen)
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Filters")
        .accessibilityValue(TrailText.filtersValue(activeCount: activeFilterCount))
        .accessibilityIdentifier("routes.trailFilters")
    }

    private var filtersSheet: some View {
        TrailFiltersSheet(filters: $finder.filters, groupSections: $groupSections,
                          includeShortPaths: $includeShortPaths, onReset: resetFilters)
    }
}

// MARK: - Filters

/// The quick toggles above the list. The dog filter and the list options
/// live in the Filters sheet only: as the last chip in a sideways scroller,
/// "Hide no-dog trails" sat cut off at the screen's edge ("Hid…").
struct TrailFilterChips: View {
    @Binding var filters: TrailFilters

    private var usesMiles: Bool { Locale.current.measurementSystem == .us }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Loops", isOn: filters.loopsOnly) { filters.loopsOnly.toggle() }
                chip("Paved", isOn: filters.surface == .paved) {
                    filters.surface = filters.surface == .paved ? nil : .paved
                }
                chip("Unpaved", isOn: filters.surface == .unpaved) {
                    filters.surface = filters.surface == .unpaved ? nil : .unpaved
                }
                chip(usesMiles ? "Under 2 mi" : "Under 3 km", isOn: filters.shortOnly) { filters.shortOnly.toggle() }
            }
            .padding(.horizontal, 20)
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        WktChoiceChip(title: title, selected: isOn, action: action)
    }
}

/// Every filter and list option in one place, applied as it changes (spec
/// fix/trail-filters-regions, PR A). Reset puts the list back as it first
/// appears: chips off, segments combined, short paths hidden.
struct TrailFiltersSheet: View {
    @Binding var filters: TrailFilters
    @Binding var groupSections: Bool
    @Binding var includeShortPaths: Bool
    let onReset: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var usesMiles: Bool { Locale.current.measurementSystem == .us }
    private var activeCount: Int {
        filters.activeCount(groupSections: groupSections, showShortPaths: includeShortPaths)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                form
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .presentationDetents([.medium, .large])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routes.trailFiltersSheet")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Reset", action: onReset)
                .disabled(activeCount == 0)
                .accessibilityIdentifier("routes.trailFiltersReset")
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
                .foregroundColor(.earthGreen)
                .accessibilityIdentifier("routes.trailFiltersDone")
        }
    }

    private var form: some View {
        List {
            Section {
                toggle("Loops only", isOn: $filters.loopsOnly)
                surfacePicker
                toggle(usesMiles ? "Under 2 mi only" : "Under 3 km only", isOn: $filters.shortOnly)
            } header: { WktListHeader(title: "Show") }
            Section {
                toggle("Exclude trails marked no dogs", isOn: $filters.hideNoDogs)
            } header: { WktListHeader(title: "Dogs") } footer: {
                footer("Trails that don't say anything about dogs stay in the list. Only a posted rule is shown on a trail.")
            }
            Section {
                segmentsPicker
            } header: { WktListHeader(title: "Trail segments") }
            Section {
                toggle(usesMiles ? "Show short paths (under 0.25 mi)" : "Show short paths (under 400 m)",
                       isOn: $includeShortPaths)
            } header: { WktListHeader(title: "Short paths") }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private static let surfaceOptions: [WktSegmentedPicker<TrailSurfaceKind?>.Option] = [
        .init(value: nil, title: "Any"),
        .init(value: .paved, title: "Paved"),
        .init(value: .unpaved, title: "Unpaved")
    ]

    /// Labelled as Settings labels its pickers, so "Any" says what it is about.
    private var surfacePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Surface").foregroundColor(.earthCream)
            WktSegmentedPicker(selection: $filters.surface, options: Self.surfaceOptions)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Surface")
        .listRowBackground(Color.earthCard)
    }

    /// Checkmark rows, not `WktSegmentedPicker`: its one-line options cut
    /// "Combine segments of the same trail" to a few words at half the width.
    private var segmentsPicker: some View {
        Picker("Trail segments", selection: $groupSections) {
            Text("Combine segments of the same trail").tag(true)
            Text("Show individual trail segments").tag(false)
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .foregroundColor(.earthCream)
        .tint(.earthGreen)
        .listRowBackground(Color.earthCard)
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Text(title).foregroundColor(.earthCream) }
            .tint(.earthGreenFill)
            .listRowBackground(Color.earthCard)
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(.wktLabel).foregroundColor(.earthMuted)
    }
}

// MARK: - Card

struct TrailCard: View {
    let item: TrailListItem
    let activityMode: ActivityMode
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                WktIconBadge(symbol: item.isLoop ? .loop : .routeTrail)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name)
                        .font(.wktRowTitle)
                        .foregroundColor(.earthCream)
                        .multilineTextAlignment(.leading)
                    Text(TrailText.summary(for: item))
                        .font(.wktLabel)
                        .foregroundColor(.earthMuted)
                    TrailTagRow(item: item, activityMode: activityMode)
                }
                Spacer(minLength: 0)
                Image(wkt: .chevronRight).wktIcon(.inline, tint: .earthMuted)
            }
            .wktCard()
        }
        .buttonStyle(.plain)
    }
}

struct TrailTagRow: View {
    let item: TrailListItem
    let activityMode: ActivityMode

    var body: some View {
        let tags = TrailText.tags(for: item)
        if !tags.isEmpty {
            WktFlowRow {
                ForEach(tags, id: \.text) { tag in
                    WktStatusChip(text: tag.text, dot: tag.isDogRule ? .accentRide : .earthMuted)
                }
            }
        }
    }
}

// MARK: - Detail

struct TrailDetailView: View {
    let item: TrailListItem
    /// Live only: directions never start from a chosen place.
    let userLocation: CLLocationCoordinate2D?
    var originName = "you"
    let activityMode: ActivityMode
    let directions: TrailDirectionsModel
    let onStart: (TrailWalkPlan) -> Void
    let onStartApproach: (NavigableRoute) -> Void
    var refreshLocation: () async -> Void = {}
    let onBack: () -> Void

    @EnvironmentObject private var historyStore: WalkHistoryStore
    /// The last choice, so the next trail starts with it (Joe walks the same
    /// distance most days).
    @AppStorage(TrailWalkOption.byTimeKey) private var byTime = false
    @AppStorage(TrailWalkOption.choiceKey) private var storedChoice = ""
    var walkerFacts: TrailFactSummaryService = .shared

    /// How far there is to go from here: toward the farther end of a line,
    /// or half way round a loop.
    private var reach: (meters: Double, isLoop: Bool)? {
        TrailWalkPlanner.reach(for: item, from: userLocation)
    }

    private var pace: Double { TrailWalkOption.pace(for: activityMode, history: historyStore.sessions) }

    /// For a walk planned without this screen (arriving at a trail), so "30
    /// min" means the same distance there; per activity, so a run's pace
    /// never times a walk (critic runs 1 and 2 of #163).
    private func rememberPace() {
        UserDefaults.standard.set(pace, forKey: TrailWalkOption.paceKey(for: activityMode))
    }

    private var options: [TrailWalkOption] {
        guard let reach else { return [] }
        return TrailWalkOption.options(reach: reach.meters, isLoop: reach.isLoop, byTime: byTime,
                                       usesMiles: Locale.current.measurementSystem == .us,
                                       metersPerSecond: pace)
    }

    private var chosen: TrailWalkOption? {
        let all = options
        return all.first { $0.id == storedChoice } ?? TrailWalkOption.defaultChoice(in: all)
    }

    /// A walk from where the person stands, when they are at the trail.
    private var startPlan: TrailWalkPlan? {
        TrailWalkPlanner.plan(for: item, from: userLocation, target: chosen?.target ?? .whole)
    }

    var body: some View {
        VStack(spacing: 0) {
            details
            // Start under the details, not in them: at Accessibility 2 on an
            // iPhone 17e it cleared the tab bar by 4.7 pt under a two-line
            // name, and a longer name or the chooser pushed it under.
            if let plan = startPlan {
                startButton(plan)
                    .wktActionBar()
            }
        }
        // Published walker answers for this trail: cached, fetched at most daily.
        .task(id: item.id) {
            await walkerFacts.refreshIfStale(keys: TrailFactSummaries.keys(of: item))
        }
    }

    private var details: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(wkt: .chevronLeft).wktIcon(.inline, tint: .earthGreen)
                        Text("Back")
                    }
                    .font(.wktBodyText)
                    .foregroundColor(.earthGreen)
                    .frame(minHeight: 44)
                }
                .accessibilityLabel("Back to trails")
                .accessibilityIdentifier("routes.trailBack")

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.wktCardTitle)
                        .foregroundColor(.earthCream)
                    Text(TrailText.detailSubtitle(for: item, from: originName))
                        .font(.wktBodyText)
                        .foregroundColor(.earthMuted)
                }

                // What to do next sits right under the name, so Start (at the
                // trail) or the way there (not yet) needs no scrolling.
                if let plan = startPlan {
                    walkChoice(plan)
                } else {
                    TrailDirectionsSection(item: item, userLocation: userLocation, activityMode: activityMode,
                                           directions: directions, onStart: { rememberPace(); onStartApproach($0) },
                                           refreshLocation: refreshLocation)
                }

                // Rows of two at the accessibility sizes: a third of the
                // width cut the values to "About 29…" and "Steps ~3,…".
                WktStatRow(spacing: 8) {
                    stat("Length", TrailText.distance(item.lengthMeters))
                    if activityMode == .walking {
                        stat("About", TrailText.walkingTime(item.lengthMeters))
                    }
                    if activityMode != .cycling {
                        stat("Steps", "~\(Int(item.lengthMeters / 0.762).formatted())")
                    }
                }

                TrailTagRow(item: item, activityMode: activityMode)

                TrailFactsCard(facts: TrailFacts.facts(for: item, activityMode: activityMode),
                               walkerLines: walkerFacts.lines(forKeys: TrailFactSummaries.keys(of: item)))

                dogRule

                // Named trails only: a nomination is about a trail people can find again.
                if TrailRef.canNominate(item) {
                    TrailNominateButton(item: item)
                }

                TrailCreditLine()
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            // On the content, not the ScrollView: the panel's own identifier
            // lands on the first scroll view inside it and would replace this.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("routes.trailDetail")
        }
    }

    /// How far to go and what the walk is; Start itself is in the bar below.
    private func walkChoice(_ plan: TrailWalkPlan) -> some View {
        VStack(spacing: 8) {
            if options.count > 1 { chooser }
            Text(TrailText.startCaption(for: plan))
                .font(.wktLabel)
                .foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private func startButton(_ plan: TrailWalkPlan) -> some View {
        Button {
            rememberPace()
            // The trail goes with the walk, for the summary's questions.
            onStart(plan.started(from: item))
        } label: {
            // "Start Hike" on a hikeable trail; the session started gets
            // the same word from the same plan (`TrailWalkPlan.wording`).
            WktPrimaryLabel(title: "Start \(plan.wording(activityMode: activityMode).sessionLabel)",
                            symbol: activityMode.wktSymbol)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.98))
        .accessibilityIdentifier("routes.trailStart")
    }

    /// How far to go: Distance | Time, then a choice of round trips and the
    /// whole trail (2026-10-09).
    private var chooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            WktSegmentedPicker(selection: $byTime, options: [
                .init(value: false, title: "Distance"),
                .init(value: true, title: "Time")
            ])
            .accessibilityIdentifier("routes.trailWalkBy")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options) { option in
                        WktChoiceChip(title: option.title, selected: option.id == chosen?.id) {
                            storedChoice = option.id
                        }
                        .accessibilityIdentifier("routes.trailWalkOption")
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.wktLabel).foregroundColor(.earthMuted)
            // Card title size, as the Community hub's stat tiles.
            Text(value).font(.wktCardTitle).foregroundColor(.earthCream)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .wktCard(padding: 14)
        .accessibilityElement(children: .combine)
    }

    private var dogRule: some View {
        HStack(alignment: .top, spacing: 10) {
            WktIconBadge(symbol: item.confidentDogAccess == nil ? .info : .pets,
                         tint: item.confidentDogAccess == nil ? .earthMuted : .accentRide)
            Text(TrailText.dogRuleSentence(item.confidentDogAccess))
                .font(.wktBodyText)
                .foregroundColor(.earthCream)
                .fixedSize(horizontal: false, vertical: true)
        }
        .wktCard()
        .accessibilityElement(children: .combine)
    }

}

// MARK: - Facts

/// What the map data states about a trail (`TrailFacts`): one row per stated
/// fact, and the provenance caption under the card. Then, separately and
/// below, what walkers say (`TrailFactSummaries`): one line per published
/// summary, under its own heading and caption, never merged into a map-data
/// line (spec feat/trail-walker-reports, criterion 5). Either part shows only
/// when it has something; most trails have neither, and the screen must look
/// complete without them.
struct TrailFactsCard: View {
    let facts: [TrailFacts.Fact]
    var walkerLines: [WalkerFactLine] = []

    /// Which parts show, in order. Pure, so the rules are tested.
    enum Part: Hashable { case mapData, walkers }

    static func parts(facts: [TrailFacts.Fact], walkerLines: [WalkerFactLine]) -> [Part] {
        (facts.isEmpty ? [] : [.mapData]) + (walkerLines.isEmpty ? [] : [.walkers])
    }

    static let walkersTitle = "Walkers say"

    /// Each part's own caption, never shared.
    static func caption(for part: Part) -> String {
        switch part {
        case .mapData: return TrailFacts.caption
        case .walkers: return walkersCaption
        }
    }
    static let walkersCaption = "Combined answers from walkers after their walks, shown once at least \(TrailFactSummaries.minimumWalkers) agree. Not map data or a current report."

    var body: some View {
        let parts = Self.parts(facts: facts, walkerLines: walkerLines)
        if !parts.isEmpty {
            // Rendered in `parts` order, so the tested order is the shown one.
            VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                ForEach(parts, id: \.self) { part in
                    switch part {
                    case .mapData: mapFacts
                    case .walkers: walkersSay
                    }
                }
            }
        }
    }

    private var mapFacts: some View {
        WktSection(title: "Trail facts") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(facts, id: \.kind) { fact in
                    HStack(alignment: .center, spacing: 12) {
                        WktIconBadge(symbol: fact.symbol)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.label)
                                .font(.wktLabel)
                                .foregroundColor(.earthMuted)
                            Text(fact.text)
                                .font(.wktBodyText)
                                .foregroundColor(.earthCream)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .wktCard()
            Text(Self.caption(for: .mapData))
                .font(.wktLabel)
                .foregroundColor(.earthMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        // One element, caption included, so VoiceOver never reads a fact
        // without the line saying it is map data, not a report.
        .accessibilityElement(children: .combine)
        // The heading's trait would otherwise make the whole card a heading.
        .accessibilityRemoveTraits(.isHeader)
        .accessibilityIdentifier("routes.trailFacts")
    }

    private var walkersSay: some View {
        WktSection(title: Self.walkersTitle) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(walkerLines) { line in
                    HStack(alignment: .center, spacing: 12) {
                        WktIconBadge(symbol: line.symbol, tint: .accentRide)
                        Text(line.text)
                            .font(.wktBodyText)
                            .foregroundColor(.earthCream)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .wktCard()
            Text(Self.caption(for: .walkers))
                .font(.wktLabel)
                .foregroundColor(.earthMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Its own element, with its own caption: VoiceOver reads "Walkers
        // say" and never runs these lines into the map facts.
        .accessibilityElement(children: .combine)
        .accessibilityRemoveTraits(.isHeader)
        .accessibilityIdentifier("routes.walkersSay")
    }
}

// MARK: - Credit

/// The licence line for every trail source on screen, from the packs
/// themselves — never typed here (ODbL attribution is a legal obligation).
struct TrailCreditLine: View {
    private var registry: TrailAttributionRegistry { .shared }

    var body: some View {
        let lines = registry.required.map(\.attribution)
        if !lines.isEmpty {
            Text("Trail data \(lines.joined(separator: " · "))")
                .font(.wktBody(11))
                .foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
        }
    }
}

// MARK: - Text

enum TrailText {
    struct Tag: Hashable {
        let text: String
        let isDogRule: Bool
    }

    static func distance(_ meters: Double) -> String {
        MKDistanceFormatter.abbreviated.string(fromDistance: meters)
    }

    /// "Starts where you are and goes round the loop · 1.1 mi"
    static func startCaption(for plan: TrailWalkPlan) -> String {
        if let turn = plan.turnaroundMeters {
            let what = plan.turnsAtTrailEnd ? "To the trail's end and back"
                                            : "Out \(distance(turn)) and back to where you start"
            let scope = plan.isSectionOnly ? "On the section you're at. " : ""
            return "\(scope)\(what) · \(distance(plan.distanceMeters))"
        }
        let route = plan.isLoop ? "goes round the loop" : "follows the trail to its far end"
        let scope = plan.isSectionOnly ? "On the section you're at: starts where you are and \(route)"
                            : "Starts where you are and \(route)"
        return "\(scope) · \(distance(plan.distanceMeters))"
    }

    static func walkingTime(_ meters: Double) -> String {
        // Same 1.4 m/s as CustomRoute.timeText.
        let mins = Int(meters / 1.4 / 60)
        return mins < 60 ? "\(mins) min" : "\(mins / 60)h \(mins % 60)m"
    }

    /// "Filters", or "Filters (2)" with two on: the Trails list's button.
    static func filtersTitle(activeCount: Int) -> String {
        activeCount == 0 ? "Filters" : "Filters (\(activeCount))"
    }

    /// The Filters button's accessibility value: "None active", "2 active".
    static func filtersValue(activeCount: Int) -> String {
        activeCount == 0 ? "None active" : "\(activeCount) active"
    }

    /// "3 paths with no name": what the closed "Other paths" card holds, so
    /// it is clear nothing named is hidden there.
    static func otherPathsSummary(count: Int) -> String {
        "\(count) \(count == 1 ? "path" : "paths") with no name"
    }

    /// "6.5 mi · 1.5 mi away". One trail is one trail: how many pieces the
    /// map data stores it in is not shown (Joe, 2026-10-08: "I don't want
    /// there to be a bunch of trail segments for one trail"). The separate
    /// view, in the Filters sheet, still lists the pieces.
    static func summary(for item: TrailListItem) -> String {
        "\(distance(item.lengthMeters)) · \(distance(item.distanceMeters)) away"
    }

    /// A trail in several pieces is neither a loop nor provably an out and
    /// back, so it gets no shape word.
    static func detailSubtitle(for item: TrailListItem, from origin: String = "you") -> String {
        let from = "\(distance(item.distanceMeters)) from \(origin)"
        if item.isGroup { return from }
        return "\(item.isLoop ? "Loop" : "Out and back") · \(from)"
    }

    static func tags(for item: TrailListItem) -> [Tag] {
        var tags: [Tag] = []
        if let rule = item.confidentDogAccess { tags.append(Tag(text: dogRuleTag(rule), isDogRule: true)) }
        switch item.surfaceKind {
        case .paved: tags.append(Tag(text: "Paved", isDogRule: false))
        case .unpaved: tags.append(Tag(text: "Unpaved", isDogRule: false))
        case nil: break
        }
        if item.isBikePath {
            tags.append(Tag(text: "Bike path", isDogRule: false))
        } else if item.allowsBike {
            tags.append(Tag(text: "Bikes OK", isDogRule: false))
        }
        if item.isLoop { tags.append(Tag(text: "Loop", isDogRule: false)) }
        return tags
    }

    static func dogRuleTag(_ rule: DogAccess) -> String {
        switch rule {
        case .offLeashAllowed: return "Off-leash OK"
        case .leashRequired: return "Dogs on leash"
        case .notPermitted: return "No dogs"
        case .unknown: return ""
        }
    }

    static func dogRuleSentence(_ rule: DogAccess?) -> String {
        switch rule {
        case .offLeashAllowed: return "Dogs are allowed off leash here, according to the trail data."
        case .leashRequired: return "Dogs are welcome on a leash, according to the trail data."
        case .notPermitted: return "Dogs aren't allowed on this trail, according to the trail data."
        case .unknown, nil: return "Dog rules aren't listed for this trail. Check the signs at the trailhead."
        }
    }

    /// The trail vertex nearest `origin`: close enough for a directions
    /// target, and a vertex is always a real point on the trail.
    static func nearestCoordinate(of item: TrailListItem, to origin: CLLocationCoordinate2D?) -> CLLocationCoordinate2D {
        let all = item.polylines.flatMap { $0 }
        guard let first = all.first else { return item.sections[0].bounds.center }
        guard let origin else { return first }
        let here = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        return all.min {
            here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                < here.distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude))
        } ?? first
    }
}


// MARK: - How far to walk

/// One choice in the trail detail's "how far" row (2026-10-09). A line trail
/// is always walked out and back, so the walk ends where it began; the whole
/// trail is "to the end and back", or the full loop.
struct TrailWalkOption: Identifiable, Equatable {
    let id: String
    let title: String
    let target: TrailWalkTarget
    /// The round trip in metres; for the full loop, the loop.
    let meters: Double

    static let byTimeKey = "trailWalkByTime"
    static let choiceKey = "trailWalkChoice"
    static func paceKey(for mode: ActivityMode) -> String { "trailWalkPace.\(mode.rawValue)" }
    static let wholeID = "whole"
    /// Loops up to this long start on the full loop, as before out-and-back
    /// existed (5 mi / 8 km); longer ones start on the usual round trip.
    static let shortLoopMeters = 8_046.72

    static let mileChoices: [Double] = [1, 2, 3, 5]
    static let kilometreChoices: [Double] = [2, 3, 5, 8]
    static let minuteChoices: [Int] = [20, 30, 45, 60]

    /// The choices from where the person stands, `reach` metres from the far
    /// end (or half a loop). A round trip as long as the whole trail or longer
    /// is left out: it would only be the whole trail again.
    static func options(reach: Double, isLoop: Bool, byTime: Bool, usesMiles: Bool,
                        metersPerSecond: Double) -> [TrailWalkOption] {
        let wholeMeters = 2 * reach
        let whole = TrailWalkOption(
            id: wholeID,
            title: "\(isLoop ? "Full loop" : "End and back") · \(TrailText.distance(wholeMeters))",
            target: isLoop ? .whole : .roundTrip(meters: wholeMeters), meters: wholeMeters)
        var shorter: [TrailWalkOption] = []
        if byTime {
            for minutes in minuteChoices {
                let meters = Double(minutes) * 60 * metersPerSecond
                guard meters < wholeMeters - 100 else { continue }
                shorter.append(TrailWalkOption(id: "t\(minutes)", title: "\(minutes) min",
                                               target: .roundTrip(meters: meters), meters: meters))
            }
        } else {
            for value in usesMiles ? mileChoices : kilometreChoices {
                let meters = value * (usesMiles ? 1_609.344 : 1_000)
                guard meters < wholeMeters - 100 else { continue }
                shorter.append(TrailWalkOption(id: "d\(Int(value))\(usesMiles ? "mi" : "km")",
                                               title: "\(Int(value)) \(usesMiles ? "mi" : "km")",
                                               target: .roundTrip(meters: meters), meters: meters))
            }
        }
        return shorter + [whole]
    }

    /// The choice last made on a trail's detail (its @AppStorage keys), for a
    /// walk planned without that screen: arriving at a trail the session was
    /// heading for. The pace is the one that screen last used for this
    /// activity, or a typical one.
    static func lastChosenTarget(reach: Double, isLoop: Bool, activityMode: ActivityMode,
                                 defaults: UserDefaults = .standard) -> TrailWalkTarget {
        let storedPace = defaults.double(forKey: paceKey(for: activityMode))
        let all = options(reach: reach, isLoop: isLoop, byTime: defaults.bool(forKey: byTimeKey),
                          usesMiles: Locale.current.measurementSystem == .us,
                          metersPerSecond: storedPace > 0 ? storedPace : pace(for: activityMode, history: []))
        let stored = defaults.string(forKey: choiceKey)
        return (all.first { $0.id == stored } ?? defaultChoice(in: all))?.target ?? .whole
    }

    /// A loop up to `shortLoopMeters` starts on the full loop, as it did
    /// before (critic review of #163: a 1.5 mi park loop defaulted to a 1 mi
    /// out-and-back). Otherwise 2 mi / 3 km / 30 min when there is room for
    /// it, else the nearest shorter choice, else the whole trail.
    static func defaultChoice(in options: [TrailWalkOption]) -> TrailWalkOption? {
        if let whole = options.last, whole.id == wholeID, whole.target == .whole, whole.meters <= shortLoopMeters {
            return whole
        }
        let preferred = ["d2mi", "d3km", "t30"]
        return options.first { preferred.contains($0.id) }
            ?? options.last { $0.id != wholeID }
            ?? options.last
    }

    /// The person's usual speed for this activity, from their last 20 that
    /// were long enough to judge (over 500 m and 5 minutes), else a typical
    /// one. Kept within sensible bounds, so one GPS-glitched walk cannot
    /// place a 30-minute turnaround three miles out.
    static func pace(for mode: ActivityMode, history: [WalkSession]) -> Double {
        let (fallback, low, high): (Double, Double, Double) = switch mode {
        case .running: (2.7, 1.8, 5.0)
        case .cycling: (5.0, 3.0, 9.0)
        default:       (1.3, 0.7, 2.2)
        }
        let speeds = history
            .filter { $0.activityType == mode.rawValue && !$0.flaggedPossibleVehicle
                && $0.totalDistance > 500 && $0.elapsedTime > 300 }
            .prefix(20)
            .map { $0.totalDistance / $0.elapsedTime }
            .sorted()
        guard !speeds.isEmpty else { return fallback }
        return min(max(speeds[speeds.count / 2], low), high)
    }
}
