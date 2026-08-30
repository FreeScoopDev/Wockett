import CoreLocation
import MapKit
import SwiftUI

// MARK: - Activity Share Style

enum ActivityShareStyle: String, CaseIterable {
    case silhouette = "Silhouette"
    case map        = "Map"
}

// MARK: - Map Snapshot Service

private enum MapSnapshotService {
    // Fetches an MKMapSnapshotter image centered on the mid-route section.
    // The first/last ~150 m of waypoints are excluded from the region so the
    // snapshot doesn't reveal the exact start or end address. The full route
    // polyline is still drawn on top of the snapshot.
    static func fetchSnapshot(
        waypoints: [CLLocationCoordinate2D],
        size: CGSize,
        scale: CGFloat
    ) async -> UIImage? {
        guard waypoints.count >= 2 else { return nil }

        let safeCoords = regionCoordinates(from: waypoints)
        guard !safeCoords.isEmpty else { return nil }

        var minLat = safeCoords[0].latitude,  maxLat = safeCoords[0].latitude
        var minLon = safeCoords[0].longitude, maxLon = safeCoords[0].longitude
        for c in safeCoords {
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }

        let options = MKMapSnapshotter.Options()
        options.size  = size
        options.scale = scale
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude:  (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta:  (maxLat - minLat) * 1.5 + 0.003,
                longitudeDelta: (maxLon - minLon) * 1.5 + 0.003
            )
        )
        let config = MKStandardMapConfiguration()
        config.emphasisStyle = .muted
        options.preferredConfiguration = config

        return await withCheckedContinuation { cont in
            // MKMapSnapshotter completion is dispatched on the main queue by default.
            MKMapSnapshotter(options: options).start { snapshot, _ in
                guard let snapshot else { cont.resume(returning: nil); return }
                let fmt = UIGraphicsImageRendererFormat()
                fmt.scale = scale
                let result = UIGraphicsImageRenderer(size: snapshot.image.size, format: fmt).image { _ in
                    snapshot.image.draw(at: .zero)
                    let path = UIBezierPath()
                    var moved = false
                    for coord in waypoints {
                        let pt = snapshot.point(for: coord)
                        if !moved { path.move(to: pt); moved = true }
                        else      { path.addLine(to: pt) }
                    }
                    UIColor(red: 0.13, green: 0.57, blue: 0.64, alpha: 1).setStroke()
                    path.lineWidth   = 4
                    path.lineCapStyle  = .round
                    path.lineJoinStyle = .round
                    path.stroke()
                }
                cont.resume(returning: result)
            }
        }
    }

    // Returns the subset of waypoints that fall between the first and last ~150 m
    // of the route, used for setting the map's visible region.
    private static func regionCoordinates(
        from waypoints: [CLLocationCoordinate2D],
        cropMeters: Double = 150
    ) -> [CLLocationCoordinate2D] {
        guard waypoints.count >= 2 else { return waypoints }
        var cumulative: [Double] = [0]
        for i in 1..<waypoints.count {
            let a = CLLocation(latitude: waypoints[i-1].latitude, longitude: waypoints[i-1].longitude)
            let b = CLLocation(latitude: waypoints[i].latitude,   longitude: waypoints[i].longitude)
            cumulative.append(cumulative.last! + a.distance(from: b))
        }
        let total = cumulative.last!
        guard total > cropMeters * 3 else { return waypoints }
        return zip(waypoints, cumulative).compactMap { coord, d in
            (d >= cropMeters && d <= total - cropMeters) ? coord : nil
        }
    }
}

// MARK: - Silhouette Route View

private struct SilhouetteRouteView: View {
    let waypoints: [WaypointCoord]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard waypoints.count >= 2 else { return }
            let lons = waypoints.map(\.longitude)
            let lats = waypoints.map(\.latitude)
            guard let minLon = lons.min(), let maxLon = lons.max(),
                  let minLat = lats.min(), let maxLat = lats.max() else { return }

            let lonSpan = max(maxLon - minLon, 1e-5)
            let latSpan = max(maxLat - minLat, 1e-5)
            let pad: Double = 24
            let availW = size.width  - pad * 2
            let availH = size.height - pad * 2
            let scale  = min(availW / lonSpan, availH / latSpan)
            let usedW  = lonSpan * scale
            let usedH  = latSpan * scale
            let ox     = pad + (availW - usedW) / 2
            let oy     = pad + (availH - usedH) / 2

            let toPoint: (WaypointCoord) -> CGPoint = { wp in
                CGPoint(
                    x: ox + (wp.longitude - minLon) * scale,
                    y: oy + (maxLat - wp.latitude)  * scale   // flip Y axis
                )
            }

            var path = Path()
            path.move(to: toPoint(waypoints[0]))
            for wp in waypoints.dropFirst() { path.addLine(to: toPoint(wp)) }
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Activity Summary Card
//
// Pure value view — no @State, no environment objects — so ImageRenderer can
// render it synchronously on any actor.

struct ActivitySummaryCard: View {
    static let cardWidth:   CGFloat = 360
    static let cardHeight:  CGFloat = 460
    static let visualHeight: CGFloat = 240

    let session: WalkSession
    let style: ActivityShareStyle
    let mapImage: UIImage?          // pre-fetched; nil → silhouette fallback
    let routeComparison: String?    // e.g. "Fastest yet on this route"

    private var mode: ActivityMode {
        ActivityMode(rawValue: session.activityType) ?? .walking
    }

    private var dateText: String {
        let f = DateFormatter(); f.dateStyle = .medium
        return f.string(from: session.date)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.10, green: 0.09, blue: 0.08)

            VStack(spacing: 0) {
                visualSection
                    .frame(width: Self.cardWidth, height: Self.visualHeight)

                statsSection
                    .frame(width: Self.cardWidth, height: Self.cardHeight - Self.visualHeight)
            }
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var visualSection: some View {
        if style == .map, let img = mapImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: Self.cardWidth, height: Self.visualHeight)
                .clipped()
        } else {
            ZStack {
                Color(red: 0.13, green: 0.12, blue: 0.11)
                if waypoints.count >= 2 {
                    SilhouetteRouteView(waypoints: waypoints, color: mode.tileColor)
                        .padding(8)
                } else {
                    Image(systemName: mode.icon)
                        .font(.system(size: 80))
                        .foregroundColor(mode.tileColor.opacity(0.35))
                }
            }
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(style == .map && mapImage != nil ? 0.18 : 0.1))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: mode.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(mode.tileColor)
                    Text(session.routeName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }

                HStack(spacing: 0) {
                    statCol(value: session.distanceText,      label: "Distance")
                    separator
                    statCol(value: session.timeText,          label: "Time")
                    separator
                    statCol(value: session.paceOrSpeedText,   label: session.paceOrSpeedLabel)
                }

                if let comparison = routeComparison {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.yellow)
                        Text(comparison)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.yellow)
                    }
                }

                HStack {
                    Text(dateText)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                    Spacer()
                    HStack(spacing: 3) {
                        Text("Wockett")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(mode.tileColor.opacity(0.85))
                        Text("🐾")
                            .font(.system(size: 10))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)

            Spacer(minLength: 0)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 28)
    }

    private func statCol(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    private var waypoints: [WaypointCoord] { session.waypoints }
}

// MARK: - Activity Summary Share Sheet

struct ActivitySummaryShareSheet: View {
    let session: WalkSession
    var historyStore: WalkHistoryStore? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var shareStyle: ActivityShareStyle = .silhouette
    @State private var includeAppLink = false
    @State private var mapImage: UIImage?  = nil
    @State private var isLoadingMap        = false
    @State private var isRendering         = false
    @State private var shareItems: [Any]   = []
    @State private var showSystemShare     = false

    private static let appStoreURL = "https://apps.apple.com/app/id6794364736"

    private var routeComparison: String? {
        guard let store = historyStore else { return nil }
        return Self.computeComparison(session: session, store: store)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        cardPreview
                        stylePickerSection
                        appLinkToggleSection
                        shareButton
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Share Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.earthMuted)
                }
            }
        }
        .sheet(isPresented: $showSystemShare) {
            ActivityShareSheet(activityItems: shareItems)
        }
        .presentationDetents([.large])
    }

    // MARK: - Sub-views

    private var cardPreview: some View {
        let scale: CGFloat = 0.88
        return ActivitySummaryCard(
            session: session,
            style: shareStyle,
            mapImage: mapImage,
            routeComparison: routeComparison
        )
        .scaleEffect(scale)
        .frame(
            width:  ActivitySummaryCard.cardWidth  * scale,
            height: ActivitySummaryCard.cardHeight * scale
        )
        .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 6)
        .animation(.easeInOut(duration: 0.25), value: shareStyle)
        .animation(.easeInOut(duration: 0.25), value: mapImage != nil)
    }

    private var stylePickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Map style", selection: $shareStyle) {
                ForEach(ActivityShareStyle.allCases, id: \.self) { s in
                    Label(s.rawValue, systemImage: s == .silhouette ? "scribble.variable" : "map")
                        .tag(s)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: shareStyle) { _, newStyle in
                if newStyle == .map, mapImage == nil { Task { await loadMap() } }
            }

            if isLoadingMap {
                HStack(spacing: 8) {
                    ProgressView().tint(.earthGreen)
                    Text("Loading map…")
                        .font(.caption).foregroundColor(.earthMuted)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal)
    }

    private var appLinkToggleSection: some View {
        Toggle(isOn: $includeAppLink) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Include App Store Link")
                    .font(.subheadline).foregroundColor(.earthCream)
                Text("Adds the Wockett download link to the share caption")
                    .font(.caption).foregroundColor(.earthMuted)
            }
        }
        .tint(.earthGreen)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.earthCard)
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private var shareButton: some View {
        Button {
            Task { await renderAndShare() }
        } label: {
            Group {
                if isRendering {
                    ProgressView().tint(.white)
                        .accessibilityLabel("Preparing share image")
                } else {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isShareDisabled ? Color.earthMuted.opacity(0.4) : Color.earthGreen)
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .disabled(isShareDisabled)
        .padding(.horizontal)
    }

    private var isShareDisabled: Bool {
        isRendering || (shareStyle == .map && isLoadingMap)
    }

    // MARK: - Actions

    private func loadMap() async {
        guard !session.waypoints.isEmpty else { return }
        isLoadingMap = true
        let coords = session.waypoints.map(\.clCoordinate)
        mapImage = await MapSnapshotService.fetchSnapshot(
            waypoints: coords,
            size: CGSize(width: ActivitySummaryCard.cardWidth,
                         height: ActivitySummaryCard.visualHeight),
            scale: 3.0
        )
        isLoadingMap = false
    }

    @MainActor
    private func renderAndShare() async {
        isRendering = true
        defer { isRendering = false }

        let card = ActivitySummaryCard(
            session: session,
            style: shareStyle,
            mapImage: mapImage,
            routeComparison: routeComparison
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3.0
        guard let image = renderer.uiImage else { return }

        var items: [Any] = [image]
        if includeAppLink {
            let verb: String
            switch session.activityType {
            case "cycling": verb = "rode"
            case "running": verb = "ran"
            default:        verb = "walked"
            }
            items.append(
                "Just \(verb) \(session.distanceText) in \(session.timeText) on Wockett 🐾\n\(Self.appStoreURL)"
            )
        }

        shareItems = items
        showSystemShare = true
    }

    // MARK: - Route comparison

    private static func computeComparison(session: WalkSession, store: WalkHistoryStore) -> String? {
        guard let routeId = session.customRouteId,
              session.totalDistance > 200, session.elapsedTime > 0 else { return nil }
        let prior = store.sessions.filter {
            $0.customRouteId == routeId
            && $0.countsTowardRouteStats
            && !$0.flaggedPossibleVehicle
            && $0.id != session.id
            && $0.totalDistance > 200
            && $0.elapsedTime > 0
        }
        guard !prior.isEmpty else { return nil }

        let newPace  = session.elapsedTime / (session.totalDistance / 1000)
        let bestPace = prior.map { $0.elapsedTime / ($0.totalDistance / 1000) }.min() ?? .infinity
        if newPace < bestPace { return "Fastest yet on this route" }

        let longestPrior = prior.map(\.totalDistance).max() ?? 0
        if session.totalDistance > longestPrior { return "Longest on this route" }

        return nil
    }
}
