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
                    Image(systemName: "plus").foregroundColor(.earthGreen)
                }
            }
        }
        .navigationDestination(isPresented: $isBuilding) {
            CustomRouteBuilderView { route in store.save(route) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bookmark")
                .font(.system(size: 64)).foregroundColor(.earthMuted.opacity(0.4))
            Text("Nothing Saved Yet")
                .font(.headline).foregroundColor(.earthCream)
            Text("Build a custom route or bookmark locations to find them here")
                .font(.subheadline).foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
            Button { isBuilding = true } label: {
                Label("Create Route", systemImage: "plus")
                    .padding(.horizontal, 24).padding(.vertical, 16)
                    .background(Color.earthOrangeFill).foregroundColor(.white).bold()
                    .cornerRadius(12)
            }
            .padding(.top, 8)
        }
        .padding()
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
                        .listRowSeparatorTint(Color.earthMuted.opacity(0.2))
                    }
                    .onDelete { store.delete(at: $0) }
                } header: {
                    Text("My Routes")
                        .font(.caption.bold()).foregroundColor(.earthMuted)
                        .textCase(nil)
                }
            }
            if !bookmarkStore.bookmarks.isEmpty {
                Section {
                    ForEach(bookmarkStore.bookmarks) { bookmark in
                        BookmarkRow(bookmark: bookmark)
                            .listRowBackground(Color.earthCard)
                            .listRowSeparatorTint(Color.earthMuted.opacity(0.2))
                    }
                    .onDelete { bookmarkStore.delete(at: $0) }
                } header: {
                    Text("Bookmarked Places")
                        .font(.caption.bold()).foregroundColor(.earthMuted)
                        .textCase(nil)
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
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentInfo.opacity(0.15))
                    .frame(width: 46, height: 46)
                Image(systemName: "bookmark.fill")
                    .foregroundColor(Color.accentInfo)
                    .font(.system(size: 18, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(bookmark.name).font(.headline).foregroundColor(.earthCream)
                Text(bookmark.address)
                    .font(.footnote).foregroundColor(.earthMuted).lineLimit(1)
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
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.earthGreen.opacity(0.15))
                    .frame(width: 46, height: 46)
                Image(systemName: route.isLoop ? "arrow.triangle.2.circlepath" : "arrow.right")
                    .foregroundColor(.earthGreen)
                    .font(.system(size: 18, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(route.name).font(.headline).foregroundColor(.earthCream)
                HStack(spacing: 10) {
                    Label(route.distanceText, systemImage: "ruler")
                    Label("~\(route.estimatedSteps.formatted()) steps", systemImage: "figure.walk")
                }
                .font(.footnote).foregroundColor(.earthMuted)
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
    @State private var routeLegs:         [MKRoute] = []
    @State private var isLoading          = false
    @State private var routeWeather:      RouteWeather?
    @State private var elevationProfile:  ElevationProfile?
    @State private var isLoadingElevation = false
    @State private var showMapsAlert      = false
    @State private var isEditing               = false
    @State private var shareState: ShareState  = .idle
    @State private var showActiveSessionAlert  = false

    init(route: CustomRoute, historyStore: WalkHistoryStore, routeStore: CustomRouteStore) {
        self.route        = route
        self.historyStore = historyStore
        self.routeStore   = routeStore
        _activityMode     = State(initialValue: route.activityMode)
    }

    private enum ShareState { case idle, sharing, shared, failed }
    private var shareButtonColor: Color {
        switch shareState {
        case .idle:    return Color.accentInfoFill
        case .sharing: return Color.accentInfoFill.opacity(0.6)
        case .shared:  return .earthGreenFill
        case .failed:  return .red.opacity(0.7)
        }
    }

    var body: some View {
        ZStack {
            Color.earthBg.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    CustomRouteMapView(
                        waypoints: route.waypoints.map { $0.clCoordinate },
                        routeLegs: routeLegs
                    )
                    if isLoading {
                        ProgressView().tint(.earthGreen)
                            .padding(16)
                            .background(.black.opacity(0.6))
                            .cornerRadius(10)
                    }
                }
                .frame(height: 320)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(route.name)
                                    .font(.title2.bold()).foregroundColor(.earthCream)
                                Label(
                                    route.isLoop ? "Loop route" : "One-way route",
                                    systemImage: route.isLoop ? "arrow.triangle.2.circlepath" : "arrow.right"
                                )
                                .font(.caption).foregroundColor(.earthGreen)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(route.distanceText).font(.title3.bold()).foregroundColor(.earthCream)
                                Text("~\(route.estimatedSteps.formatted()) steps")
                                    .font(.subheadline).foregroundColor(.earthMuted)
                            }
                        }

                        if let weather = routeWeather {
                            WeatherWidget(weather: weather)
                        }

                        if let profile = elevationProfile {
                            ElevationProfileChart(profile: profile)
                        } else if isLoadingElevation {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.earthCard)
                                .frame(height: 80)
                                .overlay {
                                    HStack(spacing: 8) {
                                        ProgressView().tint(.earthGreen)
                                        Text("Calculating elevation...")
                                            .font(.subheadline).foregroundColor(.earthMuted)
                                    }
                                }
                        }

                        HStack(spacing: 12) {
                            infoTile(icon: "mappin.circle",
                                     value: "\(route.waypoints.count)",
                                     label: "waypoints")
                            infoTile(icon: "clock",
                                     value: route.timeText,
                                     label: "est. time")
                        }

                        HStack(spacing: 8) {
                            modeChip(.walking)
                            modeChip(.running)
                            modeChip(.cycling)
                        }

                        Button {
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
                        } label: {
                            Label("Start \(activityMode.sessionLabel)", systemImage: activityMode.icon)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18).padding(.horizontal, 20)
                                .background(activityMode.tileFillColor).foregroundColor(.white)
                                .fontWeight(.semibold).cornerRadius(14)
                        }

                        NavigationLink {
                            RouteSessionHistoryView(route: route, historyStore: historyStore)
                        } label: {
                            Label("View Run History", systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.earthCard)
                                .foregroundColor(.earthCream)
                                .fontWeight(.semibold)
                                .cornerRadius(12)
                        }
                        .buttonStyle(.plain)

                        VStack(spacing: 4) {
                            Button {
                                if route.waypoints.count > 2 {
                                    showMapsAlert = true
                                } else {
                                    openInMaps()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "map")
                                    Text("Open in Apple Maps")
                                }
                                .font(.subheadline).foregroundColor(.earthMuted)
                            }
                            Text("Laps and multi-stop routes aren't supported in Apple Maps")
                                .font(.caption)
                                .foregroundColor(.earthMuted.opacity(0.6))
                                .multilineTextAlignment(.center)
                        }
                        .alert("Apple Maps Limitation", isPresented: $showMapsAlert) {
                            Button("Navigate to Start") { openInMapsStartOnly() }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("Apple Maps doesn't support multi-stop walking routes. Wockett will navigate you to the start of your route — follow the in-app map for the full path.")
                        }

                        // Community sharing
                        VStack(spacing: 10) {
                            Divider().background(Color.earthMuted.opacity(0.15))
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Share to Community")
                                        .font(.subheadline.bold()).foregroundColor(.earthCream)
                                    Text("Posting as \(CommunityRouteService.shared.username)")
                                        .font(.caption2).foregroundColor(.earthMuted)
                                }
                                Spacer()
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
                                HStack(spacing: 8) {
                                    switch shareState {
                                    case .idle:
                                        Image(systemName: "arrow.up.circle")
                                        Text("Share Route")
                                    case .sharing:
                                        ProgressView().tint(.white).scaleEffect(0.85)
                                        Text("Sharing…")
                                    case .shared:
                                        Image(systemName: "checkmark.circle.fill")
                                        Text("Shared!")
                                    case .failed:
                                        Image(systemName: "exclamationmark.circle")
                                        Text("Couldn't Share")
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(shareButtonColor)
                                .foregroundColor(.white)
                                .fontWeight(.semibold)
                                .cornerRadius(12)
                            }
                            .disabled(shareState != .idle)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { isEditing = true } label: {
                    Image(systemName: "pencil").foregroundColor(.earthGreen)
                }
            }
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
    private func modeChip(_ mode: ActivityMode) -> some View {
        let selected = activityMode == mode
        Button {
            activityMode = mode
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.icon).font(.system(size: 13, weight: .semibold))
                Text(mode.sessionLabel).font(.subheadline.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(selected ? mode.tileFillColor : Color.earthCard)
            .foregroundColor(selected ? .white : .earthCream)
            .cornerRadius(20)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.95))
    }

    @ViewBuilder
    private func infoTile(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(.earthGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.subheadline.bold()).foregroundColor(.earthCream)
                Text(label).font(.caption).foregroundColor(.earthMuted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.earthCard)
        .cornerRadius(10)
    }

    private func loadLegs() async {
        isLoading = true

        let coords = route.waypoints.map { $0.clCoordinate }
        var legs: [MKRoute] = []

        async let weatherFetch = RouteWeatherService.shared.fetchWeather(for: route.centroid)

        for i in 0..<(coords.count - 1) {
            let req           = MKDirections.Request()
            req.source        = MKMapItem(location: CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude), address: nil)
            req.destination   = MKMapItem(location: CLLocation(latitude: coords[i + 1].latitude, longitude: coords[i + 1].longitude), address: nil)
            req.transportType = .walking
            if let r = try? await MKDirections(request: req).calculate().routes.first { legs.append(r) }
        }

        if route.isLoop, let first = coords.first, let last = coords.last {
            let req           = MKDirections.Request()
            req.source        = MKMapItem(location: CLLocation(latitude: last.latitude, longitude: last.longitude), address: nil)
            req.destination   = MKMapItem(location: CLLocation(latitude: first.latitude, longitude: first.longitude), address: nil)
            req.transportType = .walking
            if let r = try? await MKDirections(request: req).calculate().routes.first { legs.append(r) }
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
