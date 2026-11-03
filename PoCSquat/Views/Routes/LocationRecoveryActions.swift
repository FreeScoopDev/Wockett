import SwiftUI

/// What Routes and Trails offer when location is off or restricted: the
/// way back (Settings) and a way that needs no location (the route builder).
/// One view, so both panels show the same actions.
struct LocationRecoveryActions: View {
    let state: RouteLocationState
    let activityMode: ActivityMode
    let onPlanOnMap: () -> Void
    /// Routes only, for now: Trails leaves these out and offers Part 1's actions.
    var onChooseStart: (() -> Void)?
    var chosenName: String?
    var onUseMyLocation: () -> Void = {}

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
                WktFlowRow(spacing: 8) {
                    WktPillButton(title: "Change", action: onChooseStart)
                        .accessibilityIdentifier("routes.changeStart")
                    if state.canUseLiveLocation {
                        WktPillButton(title: "Use my location", action: onUseMyLocation)
                            .accessibilityIdentifier("routes.useMyLocation")
                    }
                }
            } else if let onChooseStart {
                WktSecondaryButton(title: "Choose a starting place", symbol: .find, action: onChooseStart)
                    .accessibilityIdentifier("routes.chooseStart")
            }
            if state.showsOpenSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                // Only iOS Settings can reverse a denial.
                WktSecondaryButton(title: "Open Settings", symbol: .settings) { UIApplication.shared.open(url) }
                    .accessibilityIdentifier("routes.openSettings")
            }
            if state.showsPlanOnMap {
                WktSecondaryButton(title: "Plan on the map", symbol: .buildRoute, action: onPlanOnMap)
                    .accessibilityIdentifier("routes.planOnMap")
            }
            Text("You can plan a route without your location. Recording a \(activityMode.noun)'s path on the map needs it.")
                .font(.wktLabel)
                .foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("routes.locationNote")
        }
    }
}
