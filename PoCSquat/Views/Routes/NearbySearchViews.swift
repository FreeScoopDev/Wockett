import SwiftUI
import MapKit
import CoreLocation

// MARK: - Destination Search Sheet

private struct SearchResult: Identifiable {
    let id = UUID()
    let mapItem: MKMapItem
}

struct DestinationSearchSheet: View {
    let userLocation: CLLocation?
    let onSelect: (MKMapItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    // Search field
                    HStack(spacing: 10) {
                        Image(wkt: .find).wktIcon(.inline, tint: .earthMuted)
                        TextField("Café, park, gym, landmark...", text: $searchText)
                            .foregroundColor(.earthCream)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(wkt: .close).wktIcon(.inline, tint: .earthMuted, filled: true)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.earthCard)
                    .cornerRadius(12)
                    .padding()

                    if searchText.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(wkt: .place)
                                .font(.system(size: 44))
                                .foregroundColor(.earthMuted.opacity(0.4))
                            Text("Search for anywhere you'd like to walk — a café, park, gym, landmark, or friend's street.")
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.earthMuted)
                                .padding(.horizontal, 32)
                        }
                        Spacer()
                    } else if isSearching {
                        Spacer()
                        ProgressView().tint(.earthGreen)
                        Spacer()
                    } else if results.isEmpty {
                        Spacer()
                        Text("No places found")
                            .font(.subheadline)
                            .foregroundColor(.earthMuted)
                        Spacer()
                    } else {
                        List {
                            ForEach(results) { result in
                                SearchResultRow(result: result, userLocation: userLocation) {
                                    onSelect(result.mapItem)
                                    dismiss()
                                }
                                .listRowBackground(Color.earthCard.opacity(0.7))
                                .listRowSeparatorTint(Color.earthMuted.opacity(0.2))
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("Walk to a Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.earthMuted)
                }
            }
        }
        .onChange(of: searchText) { _, query in
            searchTask?.cancel()
            guard !query.isEmpty else { results = []; return }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await performSearch(query: query)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                    .fontWeight(.semibold).foregroundColor(.earthGreen)
            }
        }
    }

    private func performSearch(query: String) async {
        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let location = userLocation {
            request.region = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: 10_000,
                longitudinalMeters: 10_000
            )
        }
        if let response = try? await MKLocalSearch(request: request).start() {
            results = response.mapItems.map { SearchResult(mapItem: $0) }
        }
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    let userLocation: CLLocation?
    let onTap: () -> Void

    private var subtitle: String? { result.mapItem.address?.shortAddress ?? result.mapItem.addressRepresentations?.cityName }

    private var distanceText: String? {
        guard let userLoc = userLocation else { return nil }
        let coord = result.mapItem.location.coordinate
        let dist = userLoc.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: dist)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(wkt: .mapPinFill)
                    .wktIcon(.row, tint: .earthGreen, filled: true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.mapItem.name ?? "Unknown place")
                        .foregroundColor(.earthCream)
                        .font(.body)
                    if let sub = subtitle {
                        Text(sub)
                            .foregroundColor(.earthMuted)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let dist = distanceText {
                    Text(dist)
                        .font(.subheadline)
                        .foregroundColor(.earthMuted)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - POI Category

struct POICategory: Identifiable {
    enum SearchType {
        case category(MKPointOfInterestCategory)
        case naturalLanguage(String)
    }

    let id = UUID()
    let name: String
    let emoji: String
    let searchType: SearchType

    init(name: String, emoji: String, mkCategory: MKPointOfInterestCategory) {
        self.name = name; self.emoji = emoji; self.searchType = .category(mkCategory)
    }
    init(name: String, emoji: String, query: String) {
        self.name = name; self.emoji = emoji; self.searchType = .naturalLanguage(query)
    }

    // Nature and landmarks first, then social/amenity, then dog-walker
    static let all: [POICategory] = [
        POICategory(name: "Parks",          emoji: "🌳", mkCategory: .park),
        POICategory(name: "National Parks", emoji: "🏞️", mkCategory: .nationalPark),
        POICategory(name: "Trails",         emoji: "🥾", query: "hiking trail trailhead"),
        POICategory(name: "Beaches",        emoji: "🏖️", mkCategory: .beach),
        POICategory(name: "Museums",        emoji: "🏛️", mkCategory: .museum),
        POICategory(name: "Libraries",      emoji: "📚", mkCategory: .library),
        POICategory(name: "Cafés",          emoji: "☕", mkCategory: .cafe),
        POICategory(name: "Restaurants",    emoji: "🍽️", mkCategory: .restaurant),
        POICategory(name: "Bakeries",       emoji: "🥐", mkCategory: .bakery),
        POICategory(name: "Gyms",           emoji: "💪", mkCategory: .fitnessCenter),
        POICategory(name: "Dog Parks",      emoji: "🐕", query: "dog park"),
        POICategory(name: "Pet Stores",     emoji: "🦴", query: "pet store"),
        POICategory(name: "Vets",           emoji: "🩺", query: "veterinarian"),
    ]
}

// MARK: - Nearby Places Sheet

struct NearbyPlacesSheet: View {
    let fetchLocation: () async -> CLLocation?
    let onSelect: (MKMapItem, Bool) -> Void   // (destination, wantsLoop)

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: POICategory?
    @State private var resolvedLocation: CLLocation?
    @State private var results: [MKMapItem] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                Group {
                    if let category = selectedCategory {
                        poiResultsList(for: category)
                    } else {
                        categoryGrid
                    }
                }
            }
            .navigationTitle(selectedCategory?.name ?? "What's around you?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if selectedCategory != nil {
                        Button {
                            selectedCategory = nil
                            results = []
                        } label: {
                            HStack(spacing: 4) {
                                Image(wkt: .chevronLeft).wktIcon(.inline, tint: .earthGreen)
                                Text("Categories")
                            }
                            .foregroundColor(.earthGreen)
                        }
                    } else {
                        Button("Cancel") { dismiss() }
                            .foregroundColor(.earthMuted)
                    }
                }
            }
        }
    }

    private var categoryGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pick a vibe and we'll find somewhere to walk to.")
                    .font(.subheadline)
                    .foregroundColor(.earthMuted)
                    .padding(.horizontal)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(POICategory.all) { category in
                        Button {
                            selectedCategory = category
                            Task { await loadPOIs(for: category) }
                        } label: {
                            VStack(spacing: 10) {
                                Text(category.emoji)
                                    .font(.system(size: 42))
                                Text(category.name)
                                    .font(.subheadline.bold())
                                    .foregroundColor(.earthCream)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 22)
                            .background(Color.earthCard)
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.earthGreen.opacity(0.2), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private func poiResultsList(for category: POICategory) -> some View {
        if isLoading {
            VStack(spacing: 12) {
                Spacer()
                ProgressView().tint(.earthGreen)
                Text("Finding \(category.name.lowercased()) nearby…")
                    .font(.subheadline).foregroundColor(.earthMuted)
                Spacer()
            }
        } else if results.isEmpty {
            VStack(spacing: 14) {
                Spacer()
                Text(category.emoji).font(.system(size: 52))
                Text("None found nearby")
                    .font(.headline).foregroundColor(.earthCream)
                Text("Try a different category or expand your walk radius.")
                    .font(.subheadline).foregroundColor(.earthMuted)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                Spacer()
            }
        } else {
            List {
                ForEach(results, id: \.self) { item in
                    NearbyPlaceRow(
                        item: item,
                        userLocation: resolvedLocation,
                        onWalkThere: { onSelect(item, false); dismiss() },
                        onLoopBack:  { onSelect(item, true);  dismiss() }
                    )
                    .listRowBackground(Color.earthCard)
                    .listRowSeparatorTint(Color.earthMuted.opacity(0.2))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func loadPOIs(for category: POICategory) async {
        isLoading = true
        defer { isLoading = false }

        if resolvedLocation == nil {
            resolvedLocation = await fetchLocation()
        }
        guard let location = resolvedLocation else { return }

        let region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 3_000,
            longitudinalMeters: 3_000
        )

        let request = MKLocalSearch.Request()
        request.region = region

        switch category.searchType {
        case .category(let mkCat):
            request.resultTypes = .pointOfInterest
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [mkCat])
        case .naturalLanguage(let query):
            request.naturalLanguageQuery = query
        }

        guard let response = try? await MKLocalSearch(request: request).start() else {
            results = []
            return
        }

        results = response.mapItems.sorted { a, b in
            location.distance(from: a.location) < location.distance(from: b.location)
        }
    }
}

// MARK: - POI Category Metadata

extension MKPointOfInterestCategory {
    var tagEmoji: String {
        switch self {
        case .park:          return "🌳"
        case .nationalPark:  return "🏞️"
        case .beach:         return "🏖️"
        case .cafe:          return "☕"
        case .bakery:        return "🥐"
        case .restaurant:    return "🍽️"
        case .museum:        return "🏛️"
        case .library:       return "📚"
        case .fitnessCenter: return "💪"
        case .brewery:       return "🍺"
        case .winery:        return "🍷"
        case .theater:       return "🎭"
        case .movieTheater:  return "🎬"
        case .zoo:           return "🦁"
        case .amusementPark: return "🎡"
        case .aquarium:      return "🐠"
        case .stadium:       return "🏟️"
        default:             return "📍"
        }
    }

    var tagLabel: String {
        switch self {
        case .park:          return "Park"
        case .nationalPark:  return "National Park"
        case .beach:         return "Beach"
        case .cafe:          return "Café"
        case .bakery:        return "Bakery"
        case .restaurant:    return "Restaurant"
        case .museum:        return "Museum"
        case .library:       return "Library"
        case .fitnessCenter: return "Gym"
        case .brewery:       return "Brewery"
        case .winery:        return "Winery"
        case .theater:       return "Theatre"
        case .movieTheater:  return "Cinema"
        case .zoo:           return "Zoo"
        case .amusementPark: return "Amusement Park"
        case .aquarium:      return "Aquarium"
        case .stadium:       return "Stadium"
        default:             return "Place"
        }
    }

    var tagColor: Color {
        switch self {
        case .park, .nationalPark, .beach, .zoo, .aquarium, .campground:
            return .earthGreen
        case .cafe, .bakery, .restaurant, .brewery, .winery, .foodMarket:
            return .earthOrange
        case .museum, .library, .theater, .movieTheater, .amusementPark, .university:
            return Color(red: 0.50, green: 0.30, blue: 0.80)
        case .fitnessCenter:
            return Color(red: 0.20, green: 0.50, blue: 0.90)
        default:
            return .earthMuted
        }
    }
}

// MARK: - Mini Route Shape

private struct MiniRouteShape: View {
    let origin: CLLocationCoordinate2D
    let destination: CLLocationCoordinate2D

    @State private var points: [CGPoint] = []

    var body: some View {
        Canvas { ctx, size in
            guard points.count > 1 else { return }
            var path = Path()
            path.move(to: points[0])
            for pt in points.dropFirst() { path.addLine(to: pt) }
            ctx.stroke(path, with: .color(.earthGreen), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            // Origin dot
            ctx.fill(Path(ellipseIn: CGRect(x: points[0].x - 4, y: points[0].y - 4, width: 8, height: 8)), with: .color(.earthGreen))
            // Destination dot
            if let last = points.last {
                ctx.fill(Path(ellipseIn: CGRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8)), with: .color(.earthOrange))
            }
        }
        .frame(width: 64, height: 64)
        .background(Color.earthCard)
        .cornerRadius(10)
        .task(id: "\(origin.latitude),\(destination.latitude)") { await fetchRoute() }
    }

    private func fetchRoute() async {
        let req = MKDirections.Request()
        req.source        = MKMapItem(location: origin.clLocation,      address: nil)
        req.destination   = MKMapItem(location: destination.clLocation, address: nil)
        req.transportType = .walking

        guard let route = try? await MKDirections(request: req).calculate().routes.first else { return }

        let pl = route.polyline
        let ptCount = pl.pointCount
        guard ptCount > 1 else { return }

        var raw: [CLLocationCoordinate2D] = []
        let mkPts = pl.points()
        for i in 0..<ptCount { raw.append(mkPts[i].coordinate) }

        let minLat = raw.map(\.latitude).min()!
        let maxLat = raw.map(\.latitude).max()!
        let minLon = raw.map(\.longitude).min()!
        let maxLon = raw.map(\.longitude).max()!
        let latSpan = max(maxLat - minLat, 1e-6)
        let lonSpan = max(maxLon - minLon, 1e-6)
        let pad: Double = 6
        let drawW: Double = 64 - pad * 2
        let drawH: Double = 64 - pad * 2

        points = raw.map { coord in
            CGPoint(
                x: pad + (coord.longitude - minLon) / lonSpan * drawW,
                y: pad + (1 - (coord.latitude - minLat) / latSpan) * drawH
            )
        }
    }
}

// MARK: - Nearby Place Row

private struct NearbyPlaceRow: View {
    let item: MKMapItem
    let userLocation: CLLocation?
    let onWalkThere: () -> Void
    let onLoopBack:  () -> Void

    @Environment(\.openURL) private var openURL

    private var subtitle: String? { item.address?.shortAddress ?? item.addressRepresentations?.cityName }

    private var distanceText: String? {
        guard let userLoc = userLocation else { return nil }
        let dist = userLoc.distance(from: item.location)
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: dist)
    }

    private var callURL: URL? {
        guard let phone = item.phoneNumber else { return nil }
        let cleaned = phone.filter { $0.isNumber || $0 == "+" }
        return cleaned.isEmpty ? nil : URL(string: "tel:\(cleaned)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill((item.pointOfInterestCategory?.tagColor ?? .earthGreen).opacity(0.15))
                        .frame(width: 44, height: 44)
                    Text(item.pointOfInterestCategory?.tagEmoji ?? "📍")
                        .font(.system(size: 20))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name ?? "Unknown place")
                        .foregroundColor(.earthCream)
                        .font(.body)
                    if let sub = subtitle {
                        Text(sub)
                            .foregroundColor(.earthMuted)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                    if let cat = item.pointOfInterestCategory {
                        Text("\(cat.tagEmoji) \(cat.tagLabel)")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(cat.tagColor.opacity(0.15))
                            .foregroundColor(cat.tagColor)
                            .cornerRadius(20)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    if let userLoc = userLocation {
                        MiniRouteShape(
                            origin: userLoc.coordinate,
                            destination: item.location.coordinate
                        )
                    }
                    if let dist = distanceText {
                        Text(dist)
                            .font(.caption)
                            .foregroundColor(.earthMuted)
                    }
                }
            }

            HStack(spacing: 8) {
                Button { onWalkThere() } label: {
                    Label {
                        Text("Walk There")
                    } icon: {
                        Image(wkt: .arrowRight).wktIcon(.inline, tint: .earthGreen)
                    }
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.earthGreen.opacity(0.15))
                    .foregroundColor(.earthGreen)
                    .cornerRadius(8)
                }
                Button { onLoopBack() } label: {
                    Label {
                        Text("& Back")
                    } icon: {
                        Image(wkt: .loop).wktIcon(.inline, tint: .earthMuted)
                    }
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.earthCard)
                    .foregroundColor(.earthMuted)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.earthMuted.opacity(0.3), lineWidth: 1))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .contextMenu {
            if let url = callURL {
                Button { openURL(url) } label: {
                    Label {
                        Text("Call")
                    } icon: {
                        Image(wkt: .phone).wktIcon(.inline, tint: .primary)
                    }
                }
            }
            if let url = item.url {
                Button { openURL(url) } label: {
                    Label {
                        Text("Visit Website")
                    } icon: {
                        Image(wkt: .link).wktIcon(.inline, tint: .primary)
                    }
                }
            }
            Button {
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
            } label: {
                Label {
                    Text("Open in Apple Maps")
                } icon: {
                    Image(wkt: .mapFill).wktIcon(.inline, tint: .primary)
                }
            }
        }
    }
}

// MARK: - POI Emoji Loader

struct POIEmojiLoader: View {
    private let emojis = ["🌳", "🏖️", "🏛️", "📚", "☕", "🍽️", "🥐", "💪"]
    @State private var index   = 0
    @State private var opacity = 1.0

    var body: some View {
        Text(emojis[index])
            .font(.system(size: 18))
            .opacity(opacity)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(650))
                    withAnimation(.easeInOut(duration: 0.2)) { opacity = 0 }
                    try? await Task.sleep(for: .milliseconds(220))
                    index = (index + 1) % emojis.count
                    withAnimation(.easeInOut(duration: 0.2)) { opacity = 1 }
                }
            }
    }
}
