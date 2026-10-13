import SwiftUI

/// The line under both Share Route buttons: what a share makes public and what
/// it leaves off (`SharedRouteTrim`). One view, so the route card's sheet and
/// My Routes say the same thing. Takes the trim's outcome, worked out once by
/// the screen, so a long recorded walk isn't trimmed again for every part.
struct RouteSharePrivacyNote: View {
    let outcome: SharedRouteTrim.Outcome
    let totalDistance: Double
    /// The path is still loading: say so rather than why it can't be shared.
    var isPreparing = false

    var body: some View {
        let tint: Color = Self.canShare(outcome) || isPreparing ? .earthMuted : .earthOrange
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(wkt: .lock).wktIcon(.inline, tint: tint)
            Text(isPreparing ? "Getting the route ready to share…" : Self.text(for: outcome, totalDistance: totalDistance))
                .font(.wktLabel)
                .foregroundColor(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("routes.sharePrivacyNote")
    }

    static func canShare(_ outcome: SharedRouteTrim.Outcome) -> Bool {
        if case .trimmed = outcome { return true }
        return false
    }

    static func text(for outcome: SharedRouteTrim.Outcome, totalDistance: Double) -> String {
        guard case .trimmed(let trimmed) = outcome else { return SharedRouteTrim.message(for: outcome) ?? "" }
        let shared = SharedRouteTrim.formatted(trimmed.publishedDistance(totalDistance: totalDistance))
        return "Shared routes are public. Everything within at least "
            + "\(SharedRouteTrim.formatted(SharedRouteTrim.trimMeters)) of the start and finish is left off, "
            + "so this one shares as \(shared)."
    }
}
