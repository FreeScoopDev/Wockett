import SwiftUI
import MapKit
import CoreLocation

// MARK: - Route Builder View

struct CustomRouteBuilderView: View {
    @StateObject private var builder: CustomRouteBuilder
    @State private var showSaveSheet = false
    @State private var routeName     = ""
    @Environment(\.dismiss) private var dismiss
    let onSave: (CustomRoute) -> Void
    private let initialIsLoop: Bool

    init(initialWaypoints: [CLLocationCoordinate2D] = [], initialIsLoop: Bool = false, initialActivityMode: ActivityMode = .walking, routeName: String = "", onSave: @escaping (CustomRoute) -> Void) {
        _builder = StateObject(wrappedValue: CustomRouteBuilder(initialWaypoints: initialWaypoints, initialActivityMode: initialActivityMode))
        self.initialIsLoop = initialIsLoop
        self._routeName    = State(initialValue: routeName)
        self.onSave        = onSave
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CustomRouteMapView(
                waypoints: builder.waypoints,
                routeLegs: builder.allLegs,
                onTap:     { builder.addWaypoint($0) }
            )
            .ignoresSafeArea()

            // Empty-state hint
            if builder.waypoints.isEmpty {
                VStack(spacing: 10) {
                    Image(wkt: .tap)
                        .font(.system(size: 34)).foregroundColor(.earthGreen)
                    Text("Tap the map to add waypoints")
                        .font(.headline).foregroundColor(.earthCream)
                    Text("MapKit finds \(builder.activityMode == .cycling ? "cycling" : "walking/running") routes between each point")
                        .font(.subheadline).foregroundColor(.earthMuted)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                .padding(.bottom, 160)
            }

            // Bottom control panel
            VStack(spacing: 12) {
                // Activity mode toggle chips
                HStack(spacing: 8) {
                    modeChip(.walking)
                    modeChip(.running)
                    modeChip(.cycling)
                }
                .padding(.horizontal)

                if !builder.waypoints.isEmpty {
                    HStack(spacing: 0) {
                        statChip(value: "\(builder.waypoints.count)", label: "points")
                        Divider()
                            .frame(height: 30)
                            .background(Color.earthMuted.opacity(0.3))
                            .padding(.horizontal, 12)
                        statChip(value: distanceText(builder.totalDistance), label: "distance")
                        if builder.isComputing {
                            Divider()
                                .frame(height: 30)
                                .background(Color.earthMuted.opacity(0.3))
                                .padding(.horizontal, 12)
                            ProgressView().tint(.earthGreen).scaleEffect(0.85)
                        }
                        Spacer()
                        if builder.waypoints.count >= 2 && !builder.isComputing {
                            Toggle(isOn: Binding(get: { builder.isLoopClosed },
                                                 set: { _ in builder.toggleLoop() })) {
                                Text("Loop").font(.subheadline.bold()).foregroundColor(.earthCream)
                            }
                            .tint(.earthGreenFill).fixedSize()
                        }
                    }
                    .padding(.horizontal)
                }

                HStack(spacing: 10) {
                    if !builder.waypoints.isEmpty {
                        Button { builder.undoLast() } label: {
                            Label {
                                Text("Undo")
                            } icon: {
                                Image(wkt: .undo).wktIcon(.inline, tint: .earthCream)
                            }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(Color.earthCard)
                            .foregroundColor(.earthCream)
                            .cornerRadius(12)
                        }
                    }
                    if builder.canSave {
                        Button { showSaveSheet = true } label: {
                            Text("Save Route")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(Color.earthOrangeFill)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
        }
        .navigationTitle(builder.waypoints.isEmpty ? "Build Route" : "Edit Route")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !builder.waypoints.isEmpty {
                await builder.computeAllLegs(closedLoop: initialIsLoop)
            }
        }
        .sheet(isPresented: $showSaveSheet) {
            SaveRouteSheet(routeName: $routeName) {
                let route = builder.build(name: routeName)
                onSave(route)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func modeChip(_ mode: ActivityMode) -> some View {
        let selected = builder.activityMode == mode
        Button {
            guard !selected && !builder.isComputing else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                builder.activityMode = mode
            }
            if !builder.waypoints.isEmpty {
                Task { await builder.recomputeAllLegs() }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(mode.sessionLabel)
                    .font(.subheadline.bold())
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(selected ? Color.earthGreenFill : Color.earthCard)
            .foregroundColor(selected ? .white : .earthCream)
            .cornerRadius(20)
        }
        .buttonStyle(BounceButtonStyle(scale: 0.95))
        .disabled(builder.isComputing)
    }

    @ViewBuilder
    private func statChip(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).foregroundColor(.earthCream)
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
    }

    private func distanceText(_ m: Double) -> String {
        MKDistanceFormatter.abbreviated.string(fromDistance: m)
    }
}

// MARK: - Save Sheet

struct SaveRouteSheet: View {
    @Binding var routeName: String
    @Environment(\.dismiss) private var dismiss
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.earthBg.ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(wkt: .mapFill)
                        .font(.system(size: 52)).foregroundColor(.earthGreen)
                    Text("Name your route")
                        .font(.subheadline).foregroundColor(.earthMuted)
                    TextField("e.g. Morning Loop", text: $routeName)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .foregroundColor(.earthCream)
                        .padding()
                        .background(Color.earthCard)
                        .cornerRadius(12)
                    Spacer()
                }
                .padding(32)
            }
            .navigationTitle("Save Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave() }.foregroundColor(.earthGreen)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.earthMuted)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
