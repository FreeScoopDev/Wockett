import SwiftUI
import MapKit

// MARK: - Trails in the Routes tab
//
// The Trails side of the Routes | Trails switch (design agreed 2026-09-23,
// option A of the "Trails in Routes" canvas). Everything here reads the
// region packs on the phone, so the list appears instantly and works with no
// signal. Walking a trail and saving one come with trail-following
// navigation: today every walk is routed between waypoints by MKDirections,
// which would pull a trail walk onto the streets.

struct TrailsPanel: View {
    @Bindable var finder: TrailFinder
    @Binding var selected: TrailListItem?
    @Binding var groupSections: Bool
    @Binding var includeShortPaths: Bool
    let userLocation: CLLocationCoordinate2D?
    let activityMode: ActivityMode
    let containerHeight: CGFloat
    let modePicker: AnyView

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            if let item = selected {
                TrailDetailView(item: item, userLocation: userLocation, activityMode: activityMode) {
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
                        .font(.title3.bold())
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
                        .font(.footnote.bold())
                        .foregroundColor(.earthGreen)
                    }
                    .accessibilityLabel("List options")
                    .accessibilityValue((groupSections ? "Grouped" : "Listed separately")
                                        + (includeShortPaths ? ", short paths shown" : ""))
                    .accessibilityIdentifier("routes.trailGrouping")
                }
                .padding(.horizontal, 20)

                if let message = emptyMessage {
                    Text(message)
                        .font(.subheadline)
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
                }

                TrailCreditLine()
                    .padding(.top, 4)
            }
            .padding(.bottom, 14)
        }
    }

    private var emptyMessage: String? {
        if let failure = finder.failure { return failure }
        if userLocation == nil {
            return "Turn on location for Wockett to see trails near you."
        }
        guard finder.hasSearched, finder.items.isEmpty else { return nil }
        let active = finder.filters != TrailFilters()
        return active
            ? "No trails within 10 miles match these filters."
            : "No trails within 10 miles. Wockett has trail data for North Carolina so far, with more regions on the way."
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
        Button(action: action) {
            Text(title)
                .font(.caption.bold())
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(isOn ? Color.earthGreenFill : Color.earthCard)
                .foregroundColor(isOn ? .white : .earthCream)
                .cornerRadius(20)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.94))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Card

struct TrailCard: View {
    let item: TrailListItem
    let activityMode: ActivityMode
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.earthGreen.opacity(0.16))
                        .frame(width: 50, height: 50)
                    Image(wkt: item.isLoop ? .loop : .routeTrail).wktIcon(.row, tint: .earthGreen)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name)
                        .font(.headline)
                        .foregroundColor(.earthCream)
                        .multilineTextAlignment(.leading)
                    Text(TrailText.summary(for: item))
                        .font(.footnote)
                        .foregroundColor(.earthMuted)
                    TrailTagRow(item: item, activityMode: activityMode)
                }
                Spacer(minLength: 0)
                Image(wkt: .chevronRight).wktIcon(.inline, tint: .earthMuted)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.earthCard)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.earthMuted.opacity(0.15), lineWidth: 1))
            )
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
            HStack(spacing: 6) {
                ForEach(tags, id: \.text) { tag in
                    Text(tag.text)
                        .font(.caption.bold())
                        .foregroundColor(tag.isDogRule ? .accentRide : .earthMuted)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((tag.isDogRule ? Color.accentRide : Color.earthMuted).opacity(0.14))
                        .cornerRadius(10)
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
    let onBack: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(wkt: .chevronLeft).wktIcon(.inline, tint: .earthGreen)
                        Text("All trails")
                    }
                    .font(.subheadline.bold())
                    .foregroundColor(.earthGreen)
                }
                .accessibilityIdentifier("routes.trailBack")

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.title2.bold())
                        .foregroundColor(.earthCream)
                    Text(TrailText.detailSubtitle(for: item))
                        .font(.subheadline)
                        .foregroundColor(.earthMuted)
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

                if item.isGroup { sectionList }

                Button(action: openDirections) {
                    Label {
                        Text("Directions to the trail")
                    } icon: {
                        Image(wkt: .openInMaps).wktIcon(.row, tint: .white, onFill: true)
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color.earthGreenFill)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .accessibilityIdentifier("routes.trailDirections")

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

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.earthMuted)
            Text(value).font(.title3.bold()).foregroundColor(.earthCream)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.earthCard))
        .accessibilityElement(children: .combine)
    }

    private var dogRule: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(wkt: item.confidentDogAccess == nil ? .info : .pets)
                .wktIcon(.row, tint: item.confidentDogAccess == nil ? .earthMuted : .accentRide)
            Text(TrailText.dogRuleSentence(item.confidentDogAccess))
                .font(.subheadline)
                .foregroundColor(.earthCream)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.earthCard))
        .accessibilityElement(children: .combine)
    }

    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(item.sections.count) sections nearby")
                .font(.subheadline.bold())
                .foregroundColor(.earthCream)
            ForEach(Array(item.sections.enumerated()), id: \.element.id) { index, section in
                HStack {
                    Text("Section \(index + 1)")
                    Spacer()
                    Text(sectionLine(section))
                }
                .font(.footnote)
                .foregroundColor(.earthMuted)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.earthCard))
    }

    private func sectionLine(_ section: TrailFeature) -> String {
        let length = TrailText.distance(section.lengthMeters)
        guard let userLocation else { return length }
        let away = BundledTrailSource.distanceMeters(from: userLocation, to: section)
        return "\(length) · \(TrailText.distance(away)) away"
    }

    /// Apple Maps to the point of the trail nearest the user (or its first
    /// point, without a location). No transport mode is forced: the trail may
    /// be a drive away, and Maps uses the person's own default.
    private func openDirections() {
        let target = TrailText.nearestCoordinate(of: item, to: userLocation)
        let mapItem = MKMapItem(location: CLLocation(latitude: target.latitude, longitude: target.longitude), address: nil)
        mapItem.name = item.name
        mapItem.openInMaps()
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
                .font(.caption2)
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

    static func walkingTime(_ meters: Double) -> String {
        // Same 1.4 m/s as CustomRoute.timeText.
        let mins = Int(meters / 1.4 / 60)
        return mins < 60 ? "\(mins) min" : "\(mins / 60)h \(mins % 60)m"
    }

    /// "6.5 mi · 4 sections · 1.5 mi away"
    static func summary(for item: TrailListItem) -> String {
        var parts = [distance(item.lengthMeters)]
        if item.isGroup { parts.append("\(item.sections.count) sections") }
        parts.append("\(distance(item.distanceMeters)) away")
        return parts.joined(separator: " · ")
    }

    static func detailSubtitle(for item: TrailListItem) -> String {
        let shape = item.isLoop ? "Loop" : (item.isGroup ? "\(item.sections.count) sections" : "Out and back")
        return "\(shape) · \(distance(item.distanceMeters)) from you"
    }

    static func tags(for item: TrailListItem) -> [Tag] {
        var tags: [Tag] = []
        if let rule = item.confidentDogAccess { tags.append(Tag(text: dogRuleTag(rule), isDogRule: true)) }
        switch item.surfaceKind {
        case .paved: tags.append(Tag(text: "Paved", isDogRule: false))
        case .unpaved: tags.append(Tag(text: "Unpaved", isDogRule: false))
        case nil: break
        }
        if item.allowsBike { tags.append(Tag(text: "Bikes OK", isDogRule: false)) }
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
