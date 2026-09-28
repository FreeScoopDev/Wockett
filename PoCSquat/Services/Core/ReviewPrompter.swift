import Foundation
import Observation
import StoreKit
import SwiftUI

// MARK: - Review Prompter
//
// Asks for an App Store rating right after a moment the user is pleased with:
// a personal record on the walk summary, or a newly earned badge. At most once
// per app version. Apple also caps the system prompt at three a year per
// device and decides whether it shows at all, so this only chooses *when* to
// ask, never *whether* the sheet appears. It never appears in TestFlight.
//
// The screens that produce the moment (the summary, the badge cover) are
// dismissed as they report it, so the app root asks, once the cover is gone.

@Observable
final class ReviewPrompter {
    static let shared = ReviewPrompter()

    static let askedVersionKey = "wkt_reviewAskedVersion_v1"

    /// True between a highlight and the root asking for the review.
    private(set) var isDue = false

    private let defaults: UserDefaults
    private let version: String

    init(defaults: UserDefaults = .standard,
         version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") {
        self.defaults = defaults
        self.version  = version
    }

    /// A personal record or a new badge just happened. Due unless this version
    /// has already asked.
    func noteHighlight() {
        guard !version.isEmpty, defaults.string(forKey: Self.askedVersionKey) != version else { return }
        isDue = true
    }

    /// The root is about to ask. Returns false when nothing is due, and records
    /// the version so the next highlight in this version asks nothing.
    func consume() -> Bool {
        guard isDue else { return false }
        isDue = false
        defaults.set(version, forKey: Self.askedVersionKey)
        return true
    }
}

// MARK: - Root modifier

private struct AsksForReviewWhenDue: ViewModifier {
    @Environment(\.requestReview) private var requestReview
    private let prompter = ReviewPrompter.shared

    func body(content: Content) -> some View {
        content.onChange(of: prompter.isDue) { _, isDue in
            guard isDue else { return }
            Task { @MainActor in
                // Let the summary or badge cover finish sliding away first; the
                // system sheet over a half-dismissed cover reads as a glitch.
                try? await Task.sleep(for: .seconds(1))
                // A system sheet under UI tests would wake the interruption
                // monitor, like notification banners do (CLAUDE.md).
                guard !isWKTUITestMode, prompter.consume() else { return }
                requestReview()
            }
        }
    }
}

extension View {
    /// Applied once, at the app root.
    func asksForReviewWhenDue() -> some View { modifier(AsksForReviewWhenDue()) }
}
