import SwiftUI

/// The card under both Share Route buttons: a warning that a route which
/// starts or ends at home shows where the user lives, the **Hide start and
/// finish** choice, and what this share will publish (`SharedRouteTrim`). One
/// view, so the route card's sheet and My Routes say the same thing. Takes
/// the outcome, worked out once by the screen, so a long recorded walk isn't
/// trimmed again for every part.
struct RouteSharePrivacyNote: View {
    let outcome: SharedRouteTrim.Outcome
    @Binding var hideEnds: Bool
    /// The path or the privacy offset is still loading: say so rather than
    /// why the route can't be shared.
    var isPreparing = false

    var body: some View {
        let tint: Color = Self.canShare(outcome) || isPreparing ? .earthMuted : .earthOrange
        VStack(alignment: .leading, spacing: WktSpacing.betweenCards) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(wkt: .warning).wktIcon(.inline, tint: .earthOrange)
                Text(SharedRouteTrim.homeWarning)
                    .font(.wktLabel)
                    .foregroundColor(.earthCream)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("routes.shareHomeWarning")

            Toggle(isOn: $hideEnds) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide start and finish")
                        .font(.wktBodyText)
                        .foregroundColor(.earthCream)
                    Text("Leaves off at least \(SharedRouteTrim.formatted(SharedRouteTrim.trimMeters)) at each end")
                        .font(.wktLabel)
                        .foregroundColor(.earthMuted)
                }
            }
            .tint(.earthGreenFill)
            .accessibilityIdentifier("routes.shareHideEnds")

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(wkt: .lock).wktIcon(.inline, tint: tint)
                Text(isPreparing ? "Getting the route ready to share…" : Self.text(for: outcome))
                    .font(.wktLabel)
                    .foregroundColor(tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("routes.sharePrivacyNote")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wktCard()
    }

    static func canShare(_ outcome: SharedRouteTrim.Outcome) -> Bool {
        if case .trimmed = outcome { return true }
        return false
    }

    static func text(for outcome: SharedRouteTrim.Outcome) -> String {
        guard case .trimmed(let trimmed) = outcome else { return SharedRouteTrim.message(for: outcome) ?? "" }
        let shared = SharedRouteTrim.formatted(trimmed.keptMeters)
        guard trimmed.hidesEnds else { return "Shared routes are public. The whole route is shared: \(shared)." }
        return "Shared routes are public. Everything within at least "
            + "\(SharedRouteTrim.formatted(SharedRouteTrim.trimMeters)) of the start and finish is left off, "
            + "so this one shares as \(shared)."
    }
}
