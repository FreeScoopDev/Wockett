import SwiftUI
import MapKit
import CoreLocation

// MARK: - My Routes List

struct CustomRoutesListView: View {
    @ObservedObject var store:         CustomRouteStore
    @ObservedObject var historyStore:  WalkHistoryStore
    @ObservedObject var bookmarkStore: BookmarkStore = BookmarkStore.shared
    @State private var isBuilding = false

    private var hasContent: Bool { !store.routes.isEmpty || !bookmarkStore.bookmarks.isEmpty }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            Group {
                if hasContent { contentList } else { emptyState }
            }
        }
        .navigationTitle("Saved Items")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.reload() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { isBuilding = true } label: {
                    Image(wkt: .add).wktIcon(.inline, tint: .earthGreen)
                }
                .accessibilityLabel("New route")
            }
        }
        .navigationDestination(isPresented: $isBuilding) {
            CustomRouteBuilderView { route in store.save(route) }
        }
    }

    private var emptyState: some View {
        WktEmptyState(symbol: .saved, title: "Nothing saved yet",
                      message: "Build a custom route or bookmark locations to find them here",
                      actionTitle: "Create Route") { isBuilding = true }
    }

    private var contentList: some View {
        List {
            if !store.routes.isEmpty {
                Section {
                    ForEach(store.routes) { route in
                        NavigationLink(destination: CustomRouteDetailView(route: route, historyStore: historyStore, routeStore: store)) {
                            CustomRouteRow(route: route)
                        }
                        .listRowBackground(Color.earthCard)
                        .listRowSeparatorTint(Color.earthTrack)
                    }
                    .onDelete { store.delete(at: $0) }
                } header: {
                    WktSectionHeader(title: "My Routes")
                }
            }
            if !bookmarkStore.bookmarks.isEmpty {
                Section {
                    ForEach(bookmarkStore.bookmarks) { bookmark in
                        BookmarkRow(bookmark: bookmark)
                            .listRowBackground(Color.earthCard)
                            .listRowSeparatorTint(Color.earthTrack)
                    }
                    .onDelete { bookmarkStore.delete(at: $0) }
                } header: {
                    WktSectionHeader(title: "Bookmarked places")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Bookmark Row

struct BookmarkRow: View {
    let bookmark: BookmarkedLocation

    var body: some View {
        HStack(spacing: 14) {
            WktIconBadge(symbol: .saved, tint: .accentInfo)
            VStack(alignment: .leading, spacing: 4) {
                Text(bookmark.name).font(.wktRowTitle).foregroundColor(.earthCream)
                Text(bookmark.address)
                    .font(.wktLabel).foregroundColor(.earthMuted).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Route Row

struct CustomRouteRow: View {
    let route: CustomRoute

    var body: some View {
        HStack(spacing: 14) {
            WktIconBadge(symbol: route.isLoop ? .loop : .arrowRight)
            VStack(alignment: .leading, spacing: 4) {
                Text(route.name).font(.wktRowTitle).foregroundColor(.earthCream)
                HStack(spacing: 10) {
                    Label { Text(route.distanceText) } icon: { Image(wkt: .distance).wktIcon(.inline, tint: .earthMuted) }
                    Label { Text("~\(route.estimatedSteps.formatted()) steps") } icon: { Image(wkt: .walk).wktIcon(.inline, tint: .earthMuted) }
                }
                .font(.wktLabel).foregroundColor(.earthMuted)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Route Detail

struct CustomRouteDetailView: View {
    let route:  CustomRoute
    @ObservedObject var historyStore: WalkHistoryStore
    @ObservedObject var routeStore:   CustomRouteStore
    @Environment(\.dismiss) private var dismiss
    @State private var activityMode:      ActivityMode
    @State private var routeLegs:         [RouteLeg] = []
    @State private var isLoading          = false
    @State private var routeWeather:      RouteWeather?
    @State private var elevationProfile:  ElevationProfile?
    @State private var isLoadingElevation = false
    @State private var showMapsAlert      = false
    @State private var isEditing               = false
    @State private var shareState: ShareState  = .idle
    @State private var showActiveSessionAlert  = false
    @State private var showRename              = false
    @State private var renameText              = ""
    /// Set when the route is a recorded walk (`RecordedRoute`): drawn as its
    /// own line, pinned only at its checkpoints, never sent to MKDirections.
    /// Worked out in `.task`, not `init`: the list builds a detail view for
    /// every row it draws, and a long ride is thousands of points.
    @State private var recordedLine: RecordedRoute.Line?
    @State private var isClassified = false

    init(route: CustomRoute, historyStore: WalkHistoryStore, routeStore: CustomRouteStore) {
        self.route        = route
        self.historyStore = historyStore
        self.routeStore   = routeStore
        _activityMode     = State(initialValue: route.activityMode)
    }

    private var pinCoordinates: [CLLocationCoordinate2D] {
        guard isClassified else { return [] }
        return recordedLine?.checkpoints ?? route.waypoints.map { $0.clCoordinate }
    }

    private enum ShareState { case idle, sharing, shared, failed }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    CustomRouteMapView(
                        waypoints: pinCoordinates,
                        routeLegs: routeLegs
                    )
                    if isLoading {
                        ProgressView().tint(.earthGreen)
                            .padding(16)
                            .background(Color.earthBg.opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .frame(height: 320)

                ScrollView {
                    VStack(alignment: .leading, spacing: WktSpacing.betweenSections) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(route.name)
                                    .font(.wktCardTitle).foregroundColor(.earthCream)
                                Label {
                                    Text(route.isLoop ? "Loop route" : "One-way route")
                                } icon: {
                                    Image(wkt: route.isLoop ? .loop : .arrowRight).wktIcon(.inline, tint: .earthGreen)
                                }
                                .font(.wktLabel).foregroundColor(.earthGreen)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(route.distanceText).font(.wktCardTitle).foregroundColor(.earthCream)
                                Text("~\(route.estimatedSteps.formatted()) steps")
                                    .font(.wktBodyText).foregroundColor(.earthMuted)
                            }
                        }

                        if let weather = routeWeather {
                            WeatherWidget(weather: weather)
                        }

                        if let profile = elevationProfile {
                            ElevationProfileChart(profile: profile)
                        } else if isLoadingElevation {
                            HStack(spacing: 8) {
                                ProgressView().tint(.earthGreen)
                                Text("Calculating elevation...")
                                    .font(.wktBodyText).foregroundColor(.earthMuted)
                            }
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .wktCardBackground()
                        }

                        HStack(spacing: WktSpacing.betweenCards) {
                            infoTile(icon: .mapPinFill,
                                     value: isClassified ? "\(pinCoordinates.count)" : "–",
                                     label: recordedLine == nil ? "Waypoints" : "Checkpoints")
                            infoTile(icon: .time,
                                     value: route.timeText,
                                     label: "Est. time")
                        }

                        VStack(spacing: WktSpacing.betweenCards) {
                            WktSegmentedPicker(selection: $activityMode, options: [ActivityMode.walking, .running, .cycling].map {
                                .init(value: $0, title: $0.sessionLabel, symbol: $0.wktSymbol)
                            })

                            WktPrimaryButton(title: "Start \(activityMode.sessionLabel)", symbol: activityMode.wktSymbol) {
                                let nav = NavigableRoute(
                                    name:          route.name,
                                    waypoints:     route.waypoints.map { $0.clCoordinate },
                                    lapCount:      1,
                                    isLoop:        route.isLoop,
                                    totalDistance: route.totalDistance,
                                    isCustomRoute: true,
                                    activityMode:  activityMode,
                                    customRouteId: route.id
                                )
                                guard ActiveWalkStore.shared.beginSession(route: nav) != nil else {
                                    showActiveSessionAlert = true
                                    return
                                }
                                dismiss()
                            }

                            NavigationLink {
                                RouteSessionHistoryView(route: route, historyStore: historyStore)
                            } label: {
                                WktSecondaryLabel(title: "View History", symbol: .history)
                            }
                            .buttonStyle(BounceButtonStyle(scale: 0.98))
                        }

                        VStack(spacing: 4) {
                            Button {
                                if route.waypoints.count > 2 {
                                    showMapsAlert = true
                                } else {
                                    openInMaps()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(wkt: .openInMaps).wktIcon(.inline, tint: .earthMuted)
                                    Text("Open in Apple Maps")
                                }
                                .font(.wktBodyText).foregroundColor(.earthMuted)
                                .frame(minHeight: 44)
                            }
                            Text("Laps and multi-stop routes aren't supported in Apple Maps")
                                .font(.wktLabel)
                                .foregroundColor(.earthMuted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .alert("Apple Maps Limitation", isPresented: $showMapsAlert) {
                            Button("Navigate to Start") { openInMapsStartOnly() }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("Apple Maps doesn't support multi-stop walking routes. Wockett will navigate you to the start of your route — follow the in-app map for the full path.")
                        }

                        // Community sharing
                        VStack(alignment: .leading, spacing: WktSpacing.betweenCards) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Share to Community")
                                    .font(.wktSection).foregroundColor(.earthCream)
                                    .accessibilityAddTraits(.isHeader)
                                Text("Posting as \(CommunityNameService.shared.displayName)")
                                    .font(.wktLabel).foregroundColor(.earthMuted)
                                    // The name a share would really go out under, checked without claiming.
                                    .task { await CommunityNameService.shared.refreshDisplayName() }
                            }
                            Button {
                                guard shareState == .idle else { return }
                                shareState = .sharing
                                Task {
                                    do {
                                        try await CommunityRouteService.shared.publish(route: route)
                                        shareState = .shared
                                    } catch {
                                        shareState = .failed
                                    }
                                }
                            } label: {
                                switch shareState {
                                case .idle:
                                    WktSecondaryLabel(title: "Share Route", symbol: .upload)
                                case .sharing:
                                    HStack(spacing: 8) {
                                        ProgressView().tint(.earthCream).scaleEffect(0.85)
                                        Text("Sharing…").font(.wktHeading(17)).foregroundColor(.earthCream)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 56)
                                    .background(Color.earthRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                case .shared:
                                    WktSecondaryLabel(title: "Shared!", symbol: .success)
                                case .failed:
                                    WktSecondaryLabel(title: "Couldn't Share", symbol: .errorCircle)
                                }
                            }
                            .buttonStyle(BounceButtonStyle(scale: 0.98))
                            .disabled(shareState != .idle)
                        }
                    }
                    .padding(WktSpacing.screen)
                }
            }
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                // A recorded walk can't go through the builder, which routes
                // every leg with MKDirections; it can still be renamed.
                Button {
                    if recordedLine == nil {
                        isEditing = true
                    } else {
                        renameText = route.name
                        showRename = true
                    }
                } label: {
                    Image(wkt: .buildRoute).wktIcon(.inline, tint: .earthGreen)
                }
                .accessibilityLabel(recordedLine == nil ? "Build route" : "Rename route")
            }
        }
        .alert("Rename Route", isPresented: $showRename) {
            TextField("Route name", text: $renameText)
            Button("Save") {
                var renamed = route
                renamed.name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                routeStore.update(renamed)
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This route follows a recorded line, so it keeps that shape.")
        }
        .alert("Walk Already Active", isPresented: $showActiveSessionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You have a walk in progress. Return to the home screen to resume or end it first.")
        }
        .navigationDestination(isPresented: $isEditing) {
            CustomRouteBuilderView(
                initialWaypoints:    route.waypoints.map { $0.clCoordinate },
                initialIsLoop:       route.isLoop,
                initialActivityMode: route.activityMode,
                routeName:           route.name
            ) { updated in
                var updatedRoute = updated
                updatedRoute = CustomRoute(
                    id:            route.id,
                    name:          updated.name,
                    waypoints:     updated.waypoints,
                    totalDistance: updated.totalDistance,
                    isLoop:        updated.isLoop,
                    createdAt:     route.createdAt,
                    activityMode:  updated.activityMode
                )
                routeStore.update(updatedRoute)
            }
        }
        .task { await loadLegs() }
    }

    @ViewBuilder
    private func infoTile(icon: WktSymbol, value: String, label: String) -> some View {
        HStack(spacing: 12) {
            WktIconBadge(symbol: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.wktRowTitle).foregroundColor(.earthCream)
                Text(label).font(.wktLabel).foregroundColor(.earthMuted)
            }
        }
        .wktCard(padding: 14)
        .accessibilityElement(children: .combine)
    }

    private func loadLegs() async {
        isLoading = true
        if !isClassified {
            recordedLine = RecordedRoute.line(for: route.waypoints.map { $0.clCoordinate }, isLoop: route.isLoop)
            isClassified = true
        }

        let coords = route.waypoints.map { $0.clCoordinate }
        var legs: [RouteLeg] = []

        async let weatherFetch = RouteWeatherService.shared.fetchWeather(for: route.centroid)

        if let recordedLine {
            legs = [RouteLeg(path: recordedLine.path)]
        } else {
            for i in 0..<(coords.count - 1) {
                let req           = MKDirections.Request()
                req.source        = MKMapItem(location: CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude), address: nil)
                req.destination   = MKMapItem(location: CLLocation(latitude: coords[i + 1].latitude, longitude: coords[i + 1].longitude), address: nil)
                req.transportType = .walking
                if let r = try? await MKDirections(request: req).calculate().routes.first { legs.append(RouteLeg(r)) }
            }

            if route.isLoop, let first = coords.first, let last = coords.last {
                let req           = MKDirections.Request()
                req.source        = MKMapItem(location: CLLocation(latitude: last.latitude, longitude: last.longitude), address: nil)
                req.destination   = MKMapItem(location: CLLocation(latitude: first.latitude, longitude: first.longitude), address: nil)
                req.transportType = .walking
                if let r = try? await MKDirections(request: req).calculate().routes.first { legs.append(RouteLeg(r)) }
            }
        }

        routeLegs = legs
        isLoading = false

        routeWeather = await weatherFetch

        let polylineCoords = legs.flatMap { leg -> [CLLocationCoordinate2D] in
            let pts = leg.polyline.points()
            return (0..<leg.polyline.pointCount).map { pts[$0].coordinate }
        }
        if !polylineCoords.isEmpty {
            isLoadingElevation = true
            elevationProfile = try? await ElevationService.shared.fetchProfile(for: polylineCoords)
            isLoadingElevation = false
        }
    }

    private func openInMaps() {
        let coords = route.waypoints.map { $0.clCoordinate }
        guard !coords.isEmpty else { return }

        var items: [MKMapItem] = [.forCurrentLocation()]
        for (i, coord) in coords.enumerated() {
            let item = MKMapItem(location: CLLocation(latitude: coord.latitude, longitude: coord.longitude), address: nil)
            item.name = i == 0 ? "\(route.name) — Start" : "Stop \(i + 1)"
            items.append(item)
        }
        if route.isLoop {
            let ret = MKMapItem(location: CLLocation(latitude: coords[0].latitude, longitude: coords[0].longitude), address: nil)
            ret.name = "\(route.name) — Return"
            items.append(ret)
        }
        MKMapItem.openMaps(
            with: items,
            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
        )
    }

    private func openInMapsStartOnly() {
        guard let first = route.waypoints.first else { return }
        let item = MKMapItem(location: CLLocation(latitude: first.clCoordinate.latitude, longitude: first.clCoordinate.longitude), address: nil)
        item.name = "\(route.name) — Start"
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}
