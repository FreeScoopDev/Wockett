import SwiftUI

// MARK: - Save failure alert
//
// One alert for every activity whose save did not reach the disk (2026-10-27):
// "Couldn't save your {noun}", Try again or Keep going. Until then a failed
// write was silent and the screen showed the walk as saved. Nothing is shown
// on a save that worked.
//
// The presenting binding only reads: each button's action clears or replaces
// the failure itself, so a Try again that fails again leaves it set and the
// alert comes back for the new failure.

extension View {
    /// Shows the alert while `noun` is non-nil.
    func saveFailureAlert(noun: String?, onTryAgain: @escaping () -> Void,
                          onKeepGoing: @escaping () -> Void) -> some View {
        alert(SaveFailureText.title(noun: noun ?? "walk"),
              isPresented: Binding(get: { noun != nil }, set: { _ in })) {
            Button(SaveFailureText.tryAgain, action: onTryAgain)
            Button(SaveFailureText.keepGoing, role: .cancel, action: onKeepGoing)
        }
    }
}

enum SaveFailureText {
    static func title(noun: String) -> String { "Couldn't save your \(noun)" }
    static let tryAgain = "Try again"
    static let keepGoing = "Keep going"
}

/// The app root's copy, for a walk that failed to save away from the walk
/// screen: the mini tile's Save & End, the Live Activity's End, a route
/// completed while minimised. The walk screen shows its own while it is up,
/// because an alert here cannot appear over its full-screen cover.
struct WalkSaveFailureAlert: ViewModifier {
    @Environment(ActiveWalkStore.self) private var walkStore

    func body(content: Content) -> some View {
        let onWalkScreen = walkStore.session?.isSessionScreenVisible ?? false
        content.saveFailureAlert(
            noun: onWalkScreen ? nil : walkStore.saveFailure?.noun,
            onTryAgain: { walkStore.retrySave() },
            onKeepGoing: { walkStore.keepGoingAfterSaveFailure() })
    }
}
