import Testing
import CoreLocation
@testable import PoCSquat

/// The mini tile's End asks at the app root, driven by
/// `ActiveWalkStore.endConfirmationRequested` (iOS 26.5 never shows a dialog
/// attached inside the tab bar's bottom accessory). A walk that ends another
/// way, such as the Live Activity's End, must not leave that question up.
struct MiniTileEndConfirmationTests {

    @Test @MainActor func endingTheSession_clearsTheEndQuestion() throws {
        let store = ActiveWalkStore()
        let route = NavigableRoute(
            name: "Out and back",
            waypoints: [CLLocationCoordinate2D(latitude: 37.77, longitude: -122.43),
                        CLLocationCoordinate2D(latitude: 37.78, longitude: -122.44)],
            lapCount: 1, isLoop: false, totalDistance: 1500,
            isCustomRoute: true, isCommunityRoute: false, activityMode: .walking)
        let mgr = try #require(store.beginSession(route: route))
        mgr.writesSnapshots = false
        store.endConfirmationRequested = true

        store.endSession()

        #expect(store.endConfirmationRequested == false)
    }
}
