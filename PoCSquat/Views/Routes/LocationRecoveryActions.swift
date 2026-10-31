import SwiftUI

/// What Routes and Trails offer when location is off or restricted: the
/// way back (Settings) and a way that needs no location (the route builder).
/// One view, so both panels show the same actions.
struct LocationRecoveryActions: View {
    let state: RouteLocationState
    let onPlanOnMap: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if state.showsOpenSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                // Only iOS Settings can reverse a denial.
                WktSecondaryButton(title: "Open Settings", symbol: .settings) { UIApplication.shared.open(url) }
                    .accessibilityIdentifier("routes.openSettings")
            }
            if state.showsPlanOnMap {
                WktSecondaryButton(title: "Plan on the map", symbol: .buildRoute, action: onPlanOnMap)
                    .accessibilityIdentifier("routes.planOnMap")
            }
            Text("You can plan a route without your location. Recording a walk's path on the map needs it.")
                .font(.wktLabel)
                .foregroundColor(.earthMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
