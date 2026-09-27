import SwiftUI
import MapKit

// MARK: - Getting to a trail, on its detail
//
// Shown on a trail's detail when the person is not yet at it (beyond
// `TrailWalkPlanner.startRadiusMeters`). Two options — on foot and by bike —
// with MapKit's time and distance, the chosen one drawn dashed on the map,
// and "Start Walk to Trail" to go there in a Wockett session. Apple Maps
// stays one tap away, and leads outright for a trail a drive away
// (`TrailDirectionsPlanner.lead`). The logic lives in TrailDirections.swift.

struct TrailDirectionsSection: View {
    let item: TrailListItem
    let userLocation: CLLocationCoordinate2D?
    let activityMode: ActivityMode
    @Bindable var directions: TrailDirectionsModel
    let onStart: (NavigableRoute) -> Void
    /// Asks for a fresh fix. In Trails mode the location is otherwise read
    /// once when Routes opens, so without this the 100 m rule never fired and
    /// Start built the route from wherever the person was then.
    var refreshLocation: () async -> Void = {}

    @Environment(\.dynamicTypeSize) private var typeSize

    private static let spokenDistance: MKDistanceFormatter = {
        let f = MKDistanceFormatter()
        f.unitStyle = .full
        return f
    }()

    /// The trail point directions go to: the vertex nearest the person, as
    /// "Directions to the trail" always used.
    private var target: CLLocationCoordinate2D { TrailText.nearestCoordinate(of: item, to: userLocation) }

    private var isCurrentTrail: Bool { directions.trailID == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if userLocation == nil {
                noLocation
            } else if isCurrentTrail, case .failed(let message) = directions.phase {
                failed(message)
            } else if isCurrentTrail, case .loaded = directions.phase {
                loaded
            } else {
                loading
            }
        }
        .onAppear(perform: requestDirections)
        .task(id: item.id) { await refreshLocation() }
        .onChange(of: locationKey) { _, _ in requestDirections() }
        .onChange(of: activityMode) { _, mode in
            directions.reselect(activityMode: mode, straightLineMeters: item.distanceMeters)
        }
        .onChange(of: item.id) { _, _ in requestDirections() }
        .onDisappear { directions.cancel() }
    }

    /// Changes when the person's location does; CLLocationCoordinate2D is not Equatable.
    private var locationKey: [Double] {
        userLocation.map { [$0.latitude, $0.longitude] } ?? []
    }

    private func requestDirections() {
        guard let origin = userLocation else { return }
        directions.request(trailID: item.id, from: origin, to: target,
                           activityMode: activityMode, straightLineMeters: item.distanceMeters)
    }

    // MARK: States

    private var noLocation: some View {
        VStack(spacing: 8) {
            mapsPrimaryButton(title: "Directions to the trail", launchMode: nil)
            Text("Turn on location for Wockett to show the way from where you are, and to offer the trail \(activityMode.noun) when you get there.")
                .font(.wktBody(12))
                .foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 12) {
            WktSectionHeader(title: "Get to the trail")
            options(TrailDirectionsPlanner.order(for: TrailDirectionsPlanner.lead(
                distanceMeters: item.distanceMeters, activityMode: activityMode)), isLoading: true)
            mapsLink(launchMode: nil)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(wkt: .cloudOff).wktIcon(.row, tint: .earthMuted)
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.wktBody(15))
                        .foregroundColor(.earthCream)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        directions.retry()
                        requestDirections()
                    } label: {
                        Text("Try again")
                            .font(.wktBody(13))
                            .foregroundColor(.earthGreen)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("routes.trailDirectionsRetry")
                }
            }
            .wktCard(padding: 12)
            mapsPrimaryButton(title: "Directions to the trail", launchMode: nil)
        }
    }

    @ViewBuilder
    private var loaded: some View {
        let lead = TrailDirectionsPlanner.lead(distanceMeters: directions.leadDistance(straightLine: item.distanceMeters),
                                               activityMode: activityMode)
        let order = TrailDirectionsPlanner.order(for: lead)
        let selected = directions.selected
        VStack(alignment: .leading, spacing: 12) {
            if lead == .drive {
                // A drive away: Maps leads, and Wockett's own options follow.
                mapsPrimaryButton(title: "Drive in Maps", launchMode: MKLaunchOptionsDirectionsModeDriving)
                WktSectionHeader(title: "Or get there under your own steam")
                options(order, isLoading: false)
                if let selected, directions.route(for: selected) != nil {
                    startButton(selected, prominent: false)
                }
            } else {
                WktSectionHeader(title: "Get to the trail")
                options(order, isLoading: false)
                if let selected, directions.route(for: selected) != nil {
                    startButton(selected, prominent: true)
                    mapsLink(launchMode: selected.launchMode)
                } else {
                    mapsLink(launchMode: nil)
                }
            }
        }
    }

    // MARK: Options

    @ViewBuilder
    private func options(_ order: [TrailDirectionsMode], isLoading: Bool) -> some View {
        // Side by side, or stacked when the text is large enough that two
        // tiles would squeeze their numbers.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        layout {
            ForEach(order, id: \.self) { mode in
                optionTile(mode, isLoading: isLoading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func optionTile(_ mode: TrailDirectionsMode, isLoading: Bool) -> some View {
        let session = mode.sessionMode(current: activityMode)
        let route = isLoading ? nil : directions.route(for: mode)
        let isSelected = !isLoading && directions.selected == mode && route != nil
        let accent = session.tileColor
        let seconds = route.map { TrailDirectionsPlanner.travelSeconds(for: session, expected: $0.expectedTravelTime,
                                                                      meters: $0.distance) }
        return Button {
            withAnimation(.spring(response: 0.3)) { directions.selected = mode }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(wkt: session.wktSymbol).wktIcon(.inline, tint: accent)
                    Text(session.sessionLabel)
                        .font(.wktBody(13))
                        .foregroundColor(.earthMuted)
                    Spacer(minLength: 0)
                    // Always laid out, so choosing a tile does not change its height.
                    Image(wkt: .success).wktIcon(.inline, tint: accent, filled: true)
                        .opacity(isSelected ? 1 : 0)
                }
                if let route, let seconds {
                    Text(TrailDirectionsPlanner.durationText(seconds))
                        .font(.wktDisplay(22))
                        .foregroundColor(.earthCream)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(TrailText.distance(route.distance))
                        .font(.wktBody(13))
                        .foregroundColor(.earthMuted)
                } else if isLoading {
                    ProgressView()
                        .tint(accent)
                        .frame(height: 28)
                    Text("Finding the way…")
                        .font(.wktBody(13))
                        .foregroundColor(.earthMuted)
                } else {
                    Text("Not available")
                        .font(.wktHeading(17))
                        .foregroundColor(.earthMuted)
                        .frame(minHeight: 28, alignment: .leading)
                    Text("No \(session.noun) route here")
                        .font(.wktBody(13))
                        .foregroundColor(.earthMuted)
                }
            }
            // Side by side, both tiles take the taller one's height.
            .frame(maxHeight: .infinity, alignment: .top)
            .wktCard(padding: 12)
            // The hairline TrailCard and RouteCard have; the activity's
            // colour when chosen.
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? accent : Color.earthMuted.opacity(0.15), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(BounceButtonStyle(scale: 0.97))
        .disabled(route == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(session: session, route: route, seconds: seconds, isLoading: isLoading))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(route == nil ? "" : "Shows this way on the map")
        .accessibilityIdentifier("routes.trailDirectionsOption")
    }

    private func accessibilityLabel(session: ActivityMode, route: MKRoute?, seconds: TimeInterval?,
                                    isLoading: Bool) -> String {
        if let route, let seconds {
            return TrailDirectionsPlanner.accessibilityLabel(
                sessionLabel: session.sessionLabel, seconds: seconds,
                spokenDistance: Self.spokenDistance.string(fromDistance: route.distance))
        }
        return isLoading ? "\(session.sessionLabel) to trail, finding the way"
                         : "\(session.sessionLabel) to trail, not available here"
    }

    // MARK: Buttons

    private func startButton(_ mode: TrailDirectionsMode, prominent: Bool) -> some View {
        let session = mode.sessionMode(current: activityMode)
        return VStack(spacing: 8) {
            Button {
                guard let origin = userLocation, let route = directions.route(for: mode) else { return }
                let approach = TrailApproach(item: item)
                onStart(approach.navigableRoute(from: origin, to: target,
                                                distanceMeters: route.distance, activityMode: session))
            } label: {
                Label {
                    Text("Start \(session.sessionLabel) to Trail")
                } icon: {
                    Image(wkt: session.wktSymbol).wktIcon(.row, tint: prominent ? .white : .earthGreen,
                                                          onFill: prominent)
                }
                .font(.wktBody(17))
                .frame(maxWidth: .infinity)
                .padding(.vertical, prominent ? 18 : 14)
                .background(prominent ? Color.earthGreenFill : Color.earthCard)
                .foregroundColor(prominent ? .white : .earthGreen)
                .cornerRadius(14)
            }
            .accessibilityIdentifier("routes.trailApproachStart")
            Text("When you reach the trail, Wockett offers to carry on along it as the trail \(session.noun).")
                .font(.wktBody(12))
                .foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    /// The full-width primary: no location, no route, or a trail a drive away.
    private func mapsPrimaryButton(title: String, launchMode: String?) -> some View {
        Button { openInMaps(launchMode: launchMode) } label: {
            Label {
                Text(title)
            } icon: {
                Image(wkt: .openInMaps).wktIcon(.row, tint: .white, onFill: true)
            }
            .font(.wktBody(17))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color.earthGreenFill)
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .accessibilityIdentifier("routes.trailDirections")
    }

    /// The secondary, as "Open in Apple Maps" under a route's Start button.
    private func mapsLink(launchMode: String?) -> some View {
        Button { openInMaps(launchMode: launchMode) } label: {
            HStack(spacing: 4) {
                Image(wkt: .openInMaps).wktIcon(.inline, tint: .earthMuted)
                Text("Open in Apple Maps")
            }
            .font(.wktBody(15))
            .foregroundColor(.earthMuted)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("routes.trailDirections")
    }

    /// Apple Maps to the trail point nearest the person. With no mode given,
    /// Maps uses the person's own default.
    private func openInMaps(launchMode: String?) {
        let mapItem = MKMapItem(location: CLLocation(latitude: target.latitude, longitude: target.longitude), address: nil)
        mapItem.name = item.name
        if let launchMode {
            mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: launchMode])
        } else {
            mapItem.openInMaps()
        }
    }
}
