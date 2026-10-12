import Foundation

/// Wockett's App Store page, in one place: share messages (an activity, a
/// challenge) and Settings' Write a Review all point at it.
enum AppStoreLink {
    static let page = "https://apps.apple.com/app/id6794364736"
    /// Opens the App Store straight on the write-a-review sheet.
    static let writeReview = page + "?action=write-review"
}
