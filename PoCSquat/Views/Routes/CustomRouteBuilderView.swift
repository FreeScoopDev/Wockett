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
                routeLegs: builder.allLegs.map { RouteLeg($0) },
                onTap:     { builder.addWaypoint($0) }
            )
            .ignoresSafeArea()

            // Empty-state hint
            if builder.waypoints.isEmpty {
                VStack(spacing: 10) {
                    WktIconBadge(symbol: .tap, size: 56)
                    Text("Tap the map to add waypoints")
                        .font(.wktRowTitle).foregroundColor(.earthCream)
                    Text("MapKit finds \(builder.activityMode == .cycling ? "cycling" : "walking/running") routes between each point")
                        .font(.wktBodyText).foregroundColor(.earthMuted)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.bottom, 160)
            }

            // Bottom control panel
            VStack(spacing: 12) {
                // Activity mode toggle chips
                WktSegmentedPicker(selection: Binding(
                    get: { builder.activityMode },
                    set: { mode in
                        guard mode != builder.activityMode, !builder.isComputing else { return }
                        builder.activityMode = mode
                        if !builder.waypoints.isEmpty {
                            Task { await builder.recomputeAllLegs() }
                        }
                    }
                ), options: [ActivityMode.walking, .running, .cycling].map {
                    .init(value: $0, title: $0.sessionLabel, symbol: $0.wktSymbol)
                })
                .disabled(builder.isComputing)
                .padding(.horizontal, WktSpacing.screen)

                if !builder.waypoints.isEmpty {
                    HStack(spacing: 0) {
                        statChip(value: "\(builder.waypoints.count)", label: "points")
                        Divider()
                            .frame(height: 30)
                            .background(Color.earthTrack)
                            .padding(.horizontal, 12)
                        statChip(value: distanceText(builder.totalDistance), label: "distance")
                        if builder.isComputing {
                            Divider()
                                .frame(height: 30)
                                .background(Color.earthTrack)
                                .padding(.horizontal, 12)
                            ProgressView().tint(.earthGreen).scaleEffect(0.85)
                        }
                        Spacer()
                        if builder.waypoints.count >= 2 && !builder.isComputing {
                            Toggle(isOn: Binding(get: { builder.isLoopClosed },
                                                 set: { _ in builder.toggleLoop() })) {
                                Text("Loop").font(.wktRowTitle).foregroundColor(.earthCream)
                            }
                            .tint(.earthGreenFill).fixedSize()
                        }
                    }
                    .padding(.horizontal, WktSpacing.screen)
                }

                HStack(spacing: 10) {
                    if !builder.waypoints.isEmpty {
                        WktSecondaryButton(title: "Undo", symbol: .undo) { builder.undoLast() }
                    }
                    if builder.canSave {
                        WktPrimaryButton(title: "Save Route") { showSaveSheet = true }
                    }
                }
                .padding(.horizontal, WktSpacing.screen)
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
    private func statChip(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.wktRowTitle).foregroundColor(.earthCream)
            Text(label.prefix(1).uppercased() + label.dropFirst()).font(.wktLabel).foregroundColor(.earthMuted)
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
                    WktIconBadge(symbol: .mapFill, size: 64)
                    Text("Name your route")
                        .font(.wktBodyText).foregroundColor(.earthMuted)
                    TextField("e.g. Morning Loop", text: $routeName)
                        .font(.wktCardTitle)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.earthCream)
                        .padding()
                        .wktCardBackground()
                    Spacer()
                }
                .padding(32)
            }
            .navigationTitle("Save Route")
            .navigationBarTitleDisplayMode(.inline)
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
