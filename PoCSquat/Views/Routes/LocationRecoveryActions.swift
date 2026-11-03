import SwiftUI

/// What Routes and Trails offer when location is off or restricted: the
/// way back (Settings) and a way that needs no location (the route builder).
/// One view, so both panels show the same actions.
struct LocationRecoveryActions: View {
    let state: RouteLocationState
    let activityMode: ActivityMode
    let onPlanOnMap: () -> Void
    /// Choosing a starting place, in Routes and Trails: both panels pass them.
    var onChooseStart: (() -> Void)?
    var chosenName: String?
    var onUseMyLocation: () -> Void = {}
    /// Trails with a place chosen: only the starting-from row, so the list
    /// stays on screen. Settings and the builder are one tap away in Routes.
    var compact = false
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The reason, styled the same in Routes (above Find Routes) and Trails.
    static func reason(_ text: String) -> some View {
        Text(text)
            .font(.wktLabel)
            .foregroundColor(.earthCream)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("routes.locationMessage")
    }

    var body: some View {
        VStack(spacing: 10) {
            if let onChooseStart, let chosenName {
                Text("Starting from \(chosenName)")
                    .font(.wktBodyText)
                    .foregroundColor(.earthCream)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("routes.startingFrom")
                HStack(spacing: 8) {
                    WktPillButton(title: "Change", action: onChooseStart)
                        .accessibilityIdentifier("routes.changeStart")
                    if state.canUseLiveLocation {
                        WktPillButton(title: "Use my location", action: onUseMyLocation)
                            .accessibilityIdentifier("routes.useMyLocation")
                    }
                }
            } else if let onChooseStart {
                // No icon at the accessibility sizes: the panel has no height left for a second line.
                WktSecondaryButton(title: "Choose a starting place", symbol: typeSize.isAccessibilitySize ? nil : .find,
                                   action: onChooseStart)
                    .accessibilityIdentifier("routes.chooseStart")
            }
            if !compact, state.showsOpenSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                // Only iOS Settings can reverse a denial.
                WktSecondaryButton(title: "Open Settings", symbol: .settings) { UIApplication.shared.open(url) }
                    .accessibilityIdentifier("routes.openSettings")
            }
            if !compact, state.showsPlanOnMap {
                // A link, not a button: at Accessibility 2 a third button left
                // "Choose a starting place" no room to wrap (spec owner decision 2).
                Button(action: onPlanOnMap) {
                    Label { Text("Plan on the map") } icon: { Image(wkt: .buildRoute).wktIcon(.inline, tint: .earthGreen) }
                        .font(.wktBodyText)
                        .foregroundColor(.earthGreen)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("routes.planOnMap")
            }
            if !compact, !state.canUseLiveLocation {
                Text("You can plan a route without your location. Recording a \(activityMode.noun)'s path on the map needs it.")
                    .font(.wktLabel)
                    .foregroundColor(.earthMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("routes.locationNote")
            }
        }
    }
}
