import Testing
import CoreLocation
@testable import PoCSquat

/// Spec fix/route-location-recovery, Part 1: what Routes and Trails offer
/// for each permission, and that test and demo runs always count as live.
struct RouteLocationStateTests {

    private static let allStatuses: [CLAuthorizationStatus] = [
        .notDetermined, .restricted, .denied, .authorizedAlways, .authorizedWhenInUse
    ]

    @Test(arguments: [
        (CLAuthorizationStatus.notDetermined, RouteLocationState.willAsk),
        (.restricted, .restricted),
        (.denied, .off),
        (.authorizedAlways, .live),
        (.authorizedWhenInUse, .live)
    ])
    func eachStatusGivesItsState(status: CLAuthorizationStatus, expected: RouteLocationState) {
        #expect(RouteLocationState.make(auth: status, bypass: false) == expected)
    }

    @Test(arguments: allStatuses)
    func bypassIsLiveWhateverTheStatus(status: CLAuthorizationStatus) {
        #expect(RouteLocationState.make(auth: status, bypass: true) == .live)
    }

    @Test func deniedHidesNearbyActionsAndOffersSettingsAndTheMap() {
        let state = RouteLocationState.make(auth: .denied, bypass: false)
        #expect(!state.canFindRoutes)
        #expect(!state.showsNearbyActions)
        #expect(state.showsOpenSettings)
        #expect(state.showsPlanOnMap)
        #expect(state.message == "Location is off for Wockett, so routes can't start from where you are.")
    }

    @Test func restrictedHidesOpenSettings() {
        let state = RouteLocationState.make(auth: .restricted, bypass: false)
        #expect(!state.canFindRoutes)
        #expect(!state.showsNearbyActions)
        #expect(!state.showsOpenSettings)
        #expect(state.showsPlanOnMap)
        #expect(state.message == "Location is restricted on this iPhone.")
    }

    @Test func notDeterminedCanSearchAndSaysItWillAsk() {
        let state = RouteLocationState.make(auth: .notDetermined, bypass: false)
        #expect(state.canFindRoutes)
        #expect(state.showsNearbyActions)
        #expect(!state.showsOpenSettings)
        #expect(!state.showsPlanOnMap)
        #expect(state.message == "Wockett will ask to use your location.")
    }

    /// "Try nearby loops" needs the location a failed search lacked.
    @Test func nearbyLoopsOnlyWhenLiveAndNotAfterALocationFailure() {
        #expect(RouteLocationState.live.offersNearbyLoops(afterLocationFailure: false))
        #expect(!RouteLocationState.live.offersNearbyLoops(afterLocationFailure: true))
        for state in [RouteLocationState.willAsk, .off, .restricted] {
            #expect(!state.offersNearbyLoops(afterLocationFailure: false))
        }
    }

    /// RouteManager passes its own fixed location as the bypass: without
    /// it, every `-WKTDemo` and `-WKTUITest` run would see the permission
    /// the simulator happens to have. The test host starts at .notDetermined.
    @Test @MainActor func routeManagerWithAFixedLocationIsLive() {
        let manager = RouteManager(fixedLocation: CLLocation(latitude: 35.78, longitude: -78.64))
        #expect(manager.locationState == .live)
    }

    @Test func liveOffersEverythingAndExplainsNothing() {
        let state = RouteLocationState.make(auth: .authorizedWhenInUse, bypass: false)
        #expect(state.canFindRoutes)
        #expect(state.showsNearbyActions)
        #expect(!state.showsOpenSettings)
        #expect(!state.showsPlanOnMap)
        #expect(state.message == nil)
    }

    // MARK: - A chosen starting place (spec fix/route-start-place)

    @Test(arguments: allStatuses, [false, true])
    func aChosenPlaceIsChosenOverItsPermission(status: CLAuthorizationStatus, bypass: Bool) {
        let base = RouteLocationState.make(auth: status, bypass: bypass)
        let state = RouteLocationState.make(auth: status, bypass: bypass, hasChosenPlace: true)
        #expect(state == .chosen(over: base))
        #expect(state.base == base)
        #expect(state.canFindRoutes)
        #expect(state.showsNearbyActions)
        #expect(state.offersNearbyLoops(afterLocationFailure: false))
        #expect(!state.offersNearbyLoops(afterLocationFailure: true))
        #expect(!state.usesLiveLocation, "A chosen place is never the live location")
        #expect(state.message == nil)
        #expect(state.showsOpenSettings == base.showsOpenSettings)
        #expect(state.canUseLiveLocation == base.canFindRoutes)
    }

    @Test func chosenOverDeniedCanSearchAndStillOffersSettings() {
        let state = RouteLocationState.make(auth: .denied, bypass: false, hasChosenPlace: true)
        #expect(state.canFindRoutes)
        #expect(state.showsOpenSettings)
        #expect(!state.canUseLiveLocation)
    }

    @Test func chosenOverRestrictedHidesSettings() {
        let state = RouteLocationState.make(auth: .restricted, bypass: false, hasChosenPlace: true)
        #expect(state.canFindRoutes)
        #expect(!state.showsOpenSettings)
        #expect(!state.canUseLiveLocation)
    }

    @Test func chosenOverLiveCanUseTheLiveLocation() {
        let state = RouteLocationState.make(auth: .authorizedWhenInUse, bypass: false, hasChosenPlace: true)
        #expect(state.canUseLiveLocation)
        #expect(!state.usesLiveLocation)
    }

    /// Back from Settings with location on, a chosen place or not, a fix is
    /// fetched; choosing a place never asks for one (critic, PR A).
    @Test func aFreshFixOnlyWhenLiveLocationBecomesUsable() {
        #expect(RouteLocationState.needsFreshFix(from: .chosen(over: .off), to: .chosen(over: .live)))
        #expect(RouteLocationState.needsFreshFix(from: .off, to: .live))
        #expect(!RouteLocationState.needsFreshFix(from: .off, to: .chosen(over: .off)))
        #expect(!RouteLocationState.needsFreshFix(from: .live, to: .chosen(over: .live)))
        #expect(!RouteLocationState.needsFreshFix(from: .chosen(over: .live), to: .live))
    }

    @Test(arguments: allStatuses, [false, true])
    func noChosenPlaceIsTheSameAsBefore(status: CLAuthorizationStatus, bypass: Bool) {
        let state = RouteLocationState.make(auth: status, bypass: bypass, hasChosenPlace: false)
        #expect(state == RouteLocationState.make(auth: status, bypass: bypass))
        #expect(!state.isChosen)
        #expect(state.usesLiveLocation == state.canFindRoutes)
    }
}
