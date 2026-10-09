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
    let userLocation: CLLocationCoordinate2D?
    let activityMode: ActivityMode
    let containerHeight: CGFloat
    let modePicker: AnyView
    let directions: TrailDirectionsModel
    let onStart: (TrailWalkPlan) -> Void
    let onStartApproach: (NavigableRoute) -> Void
    var refreshLocation: () async -> Void = {}

    /// "Other paths" starts closed: it is the unnamed paths a
    /// downloaded state pack carries, there if wanted but not in the way.
    @State private var showOtherPaths = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.earthMuted.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            if let item = selected {
                TrailDetailView(item: item, userLocation: userLocation, activityMode: activityMode,
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
                HStack(alignment: .firstTextBaseline) {
                    Text("Trails near you")
                        .font(.wktSection)
                        .foregroundColor(.earthCream)
                    Spacer()
                    Menu {
                        Picker("Trail sections", selection: $groupSections) {
                            Text("Group sections").tag(true)
                            Text("List sections separately").tag(false)
                        }
                        Toggle(isOn: $includeShortPaths) {
                            Text(Locale.current.measurementSystem == .us
                                 ? "Show short paths (under 0.25 mi)"
                                 : "Show short paths (under 400 m)")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(groupSections ? "Grouped" : "Sections")
                            Image(wkt: .chevronDown).wktIcon(.inline, tint: .earthGreen)
                        }
                        .font(.wktBodyText)
                        .foregroundColor(.earthGreen)
                        .frame(minHeight: 44)
                    }
                    .accessibilityLabel("List options")
                    .accessibilityValue((groupSections ? "Grouped" : "Listed separately")
                                        + (includeShortPaths ? ", short paths shown" : ""))
                    .accessibilityIdentifier("routes.trailGrouping")
                }
                .padding(.horizontal, 20)

                if let message = emptyMessage {
                    Text(message)
                        .font(.wktBodyText)
                        .foregroundColor(.earthMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
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
            }
            .padding(.bottom, 14)
        }
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

    private var emptyMessage: String? {
        if let failure = finder.failure { return failure }
        if userLocation == nil {
            return "Turn on location for Wockett to see trails near you."
        }
        guard finder.hasSearched, finder.items.isEmpty, finder.otherPaths.isEmpty else { return nil }
        let active = finder.filters != TrailFilters()
        return active
            ? "No trails within 10 miles match these filters."
            : "No trails within 10 miles. Download your state in Settings → Trail Regions to see its trails. More states are on the way."
    }
}

// MARK: - Filters

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
                chip("Hide no-dog trails", isOn: filters.hideNoDogs) { filters.hideNoDogs.toggle() }
            }
            .padding(.horizontal, 20)
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        WktChoiceChip(title: title, selected: isOn, action: action)
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
    let userLocation: CLLocationCoordinate2D?
    let activityMode: ActivityMode
    let directions: TrailDirectionsModel
    let onStart: (TrailWalkPlan) -> Void
    let onStartApproach: (NavigableRoute) -> Void
    var refreshLocation: () async -> Void = {}
    let onBack: () -> Void

    @EnvironmentObject private var historyStore: WalkHistoryStore
    /// The last choice, so the next trail starts with it (Joe walks the same
    /// distance most days).
    @AppStorage("trailWalkByTime") private var byTime = false
    @AppStorage("trailWalkChoice") private var storedChoice = ""

    /// How far there is to go from here: toward the farther end of a line,
    /// or half way round a loop.
    private var reach: (meters: Double, isLoop: Bool)? {
        TrailWalkPlanner.reach(for: item, from: userLocation)
    }

    private var options: [TrailWalkOption] {
        guard let reach else { return [] }
        return TrailWalkOption.options(reach: reach.meters, isLoop: reach.isLoop, byTime: byTime,
                                       usesMiles: Locale.current.measurementSystem == .us,
                                       metersPerSecond: TrailWalkOption.pace(for: activityMode,
                                                                             history: historyStore.sessions))
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
                    Text(TrailText.detailSubtitle(for: item))
                        .font(.wktBodyText)
                        .foregroundColor(.earthMuted)
                }

                // What to do next sits right under the name, so Start (at the
                // trail) or the way there (not yet) needs no scrolling.
                if let plan = startPlan {
                    startButton(plan)
                } else {
                    TrailDirectionsSection(item: item, userLocation: userLocation, activityMode: activityMode,
                                           directions: directions, onStart: onStartApproach,
                                           refreshLocation: refreshLocation)
                }

                HStack(spacing: 8) {
                    stat("Length", TrailText.distance(item.lengthMeters))
                    if activityMode == .walking {
                        stat("About", TrailText.walkingTime(item.lengthMeters))
                    }
                    if activityMode != .cycling {
                        stat("Steps", "~\(Int(item.lengthMeters / 0.762).formatted())")
                    }
                }

                TrailTagRow(item: item, activityMode: activityMode)

                dogRule

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

    private func startButton(_ plan: TrailWalkPlan) -> some View {
        VStack(spacing: 8) {
            if options.count > 1 { chooser }
            Button { onStart(plan) } label: {
                WktPrimaryLabel(title: "Start \(activityMode.sessionLabel)", symbol: activityMode.wktSymbol)
            }
            .buttonStyle(BounceButtonStyle(scale: 0.98))
            .accessibilityIdentifier("routes.trailStart")
            Text(TrailText.startCaption(for: plan))
                .font(.wktLabel)
                .foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
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

    /// "3 paths with no name": what the closed "Other paths" card holds, so
    /// it is clear nothing named is hidden there.
    static func otherPathsSummary(count: Int) -> String {
        "\(count) \(count == 1 ? "path" : "paths") with no name"
    }

    /// "6.5 mi · 1.5 mi away". One trail is one trail: how many pieces the
    /// map data stores it in is not shown (Joe, 2026-10-08: "I don't want
    /// there to be a bunch of trail segments for one trail"). The separate
    /// view, in the list's menu, still lists the pieces.
    static func summary(for item: TrailListItem) -> String {
        "\(distance(item.lengthMeters)) · \(distance(item.distanceMeters)) away"
    }

    /// A trail in several pieces is neither a loop nor provably an out and
    /// back, so it gets no shape word.
    static func detailSubtitle(for item: TrailListItem) -> String {
        let from = "\(distance(item.distanceMeters)) from you"
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
            id: "whole",
            title: "\(isLoop ? "Full loop" : "End and back") · \(TrailText.distance(wholeMeters))",
            target: isLoop ? .whole : .roundTrip(meters: wholeMeters))
        var shorter: [TrailWalkOption] = []
        if byTime {
            for minutes in minuteChoices {
                let meters = Double(minutes) * 60 * metersPerSecond
                guard meters < wholeMeters - 100 else { continue }
                shorter.append(TrailWalkOption(id: "t\(minutes)", title: "\(minutes) min",
                                               target: .roundTrip(meters: meters)))
            }
        } else {
            for value in usesMiles ? mileChoices : kilometreChoices {
                let meters = value * (usesMiles ? 1_609.344 : 1_000)
                guard meters < wholeMeters - 100 else { continue }
                shorter.append(TrailWalkOption(id: "d\(Int(value))\(usesMiles ? "mi" : "km")",
                                               title: "\(Int(value)) \(usesMiles ? "mi" : "km")",
                                               target: .roundTrip(meters: meters)))
            }
        }
        return shorter + [whole]
    }

    /// The choice last made on a trail's detail (its @AppStorage keys), for a
    /// walk planned without that screen: arriving at a trail the session was
    /// heading for. A typical pace stands in for the person's own.
    static func lastChosenTarget(reach: Double, isLoop: Bool, activityMode: ActivityMode,
                                 defaults: UserDefaults = .standard) -> TrailWalkTarget {
        let all = options(reach: reach, isLoop: isLoop, byTime: defaults.bool(forKey: "trailWalkByTime"),
                          usesMiles: Locale.current.measurementSystem == .us,
                          metersPerSecond: pace(for: activityMode, history: []))
        let stored = defaults.string(forKey: "trailWalkChoice")
        return (all.first { $0.id == stored } ?? defaultChoice(in: all))?.target ?? .whole
    }

    /// 2 mi or 3 km when there is room for it, else the nearest shorter
    /// choice, else the whole trail.
    static func defaultChoice(in options: [TrailWalkOption]) -> TrailWalkOption? {
        let preferred = ["d2mi", "d3km", "t30"]
        return options.first { preferred.contains($0.id) }
            ?? options.last { $0.id != "whole" }
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
