import SwiftUI

/// The **Hide start and finish** choice and the length this share will
/// publish (`SharedRouteTrim`), under the preview in `ShareReviewSheet`.
/// Takes the outcome, worked out once by the sheet, so a long recorded walk
/// isn't trimmed again for every part.
struct RouteSharePrivacyNote: View {
    let outcome: SharedRouteTrim.Outcome
    @Binding var hideEnds: Bool
    /// The path or the privacy offset is still loading: say so rather than
    /// why the route can't be shared.
    var isPreparing = false
    /// Asks iCloud for the privacy offset again, after it couldn't be fetched.
    var onRetry: (() -> Void)?

    var body: some View {
        let tint: Color = Self.canShare(outcome) || isPreparing ? .earthMuted : .earthOrange
        VStack(alignment: .leading, spacing: WktSpacing.betweenCards) {
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

            if !isPreparing, outcome == .offsetUnavailable, let onRetry {
                WktPillButton(title: "Try again", action: onRetry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wktCard()
    }

    static func canShare(_ outcome: SharedRouteTrim.Outcome) -> Bool {
        if case .trimmed = outcome { return true }
        return false
    }

    /// The shared length, and why it isn't the route's whole length when it
    /// isn't, or why the route can't be shared.
    static func text(for outcome: SharedRouteTrim.Outcome) -> String {
        guard case .trimmed(let trimmed) = outcome else { return SharedRouteTrim.message(for: outcome) ?? "" }
        let shared = SharedRouteTrim.formatted(trimmed.keptMeters)
        let full = SharedRouteTrim.formatted(trimmed.fullMeters)
        if shared != full { return "Start and end are left off, so the shared route is \(shared), not \(full)." }
        return trimmed.hidesEnds ? "Start and end are left off. The shared route is \(shared)."
            : "The whole route is shared: \(shared)."
    }
}

/// What a share sheet draws and what its Publish button sends: one value, so
/// the preview can't show one path while another goes public.
struct ShareReview {
    /// The route as the user keeps it; nil while it loads, or when it can't.
    let route: CustomRoute?
    /// What a share of it publishes (`SharedRouteTrim.prepare`).
    let outcome: SharedRouteTrim.Outcome

    init(route: CustomRoute?, hideEnds: Bool, offset: SharePrivacyOffset?) {
        self.route = route
        outcome = route.map { SharedRouteTrim.prepare($0, hideEnds: hideEnds, offset: offset) } ?? .notAPath
    }

    var trimmed: SharedRouteTrim.Trimmed? {
        if case .trimmed(let trimmed) = outcome { return trimmed }
        return nil
    }

    /// Publishes exactly `trimmed`, the previewed path, or throws why it can't.
    func publish(name: String, with publisher: SharedRoutePublishing) async throws {
        guard let trimmed else { throw SharedRouteTrim.CannotShareError(outcome: outcome) }
        try await publisher.publish(name: name, trimmed: trimmed)
    }
}
