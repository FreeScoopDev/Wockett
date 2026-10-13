import SwiftUI

/// The line under both Share Route buttons: what a share makes public and what
/// it leaves off (`SharedRouteTrim`). One view, so the route card's sheet and
/// My Routes say the same thing.
struct RouteSharePrivacyNote: View {
    let route: CustomRoute

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(wkt: .lock).wktIcon(.inline, tint: tint)
            Text(Self.text(for: route))
                .font(.wktLabel)
                .foregroundColor(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("routes.sharePrivacyNote")
    }

    private var tint: Color { Self.canShare(route) ? .earthMuted : .earthOrange }

    static func canShare(_ route: CustomRoute) -> Bool {
        if case .trimmed = SharedRouteTrim.trim(route.waypoints, isLoop: route.isLoop) { return true }
        return false
    }

    static func text(for route: CustomRoute) -> String {
        switch SharedRouteTrim.trim(route.waypoints, isLoop: route.isLoop) {
        case .trimmed(let trimmed):
            let shared = SharedRouteTrim.formatted(trimmed.publishedDistance(totalDistance: route.totalDistance))
            return "Shared routes are public. The first and last \(SharedRouteTrim.formatted(SharedRouteTrim.trimMeters))"
                + " are left off, so this one shares as \(shared)."
        case .tooShort:
            return SharedRouteTrim.TooShortError().message
        }
    }
}
