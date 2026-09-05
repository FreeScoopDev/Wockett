import XCTest

final class SmokeTests: XCTestCase {

    // Timeouts here are deliberately generous. A GitHub macOS runner is a shared
    // VM and is several times slower than a developer Mac: on 2026-09-03 the same
    // commit passed 5/5 locally while testTabNavigation failed 3/3 on CI waiting
    // for the Community tab, and one testAccessoryBar attempt took 162 s. Every
    // wait that follows a map-bearing screen (Routes, the active session) is the
    // slow one, so those are the ones raised. A smoke test should fail when a
    // screen is broken, not when a rented machine is having a bad minute.

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for title in ["Don't Allow", "Not Now", "OK", "Allow", "Cancel"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            if alert.buttons.count > 0 { alert.buttons.element(boundBy: 0).tap(); return true }
            return false
        }
        app = XCUIApplication()
        app.launchArguments = ["-WKTUITest"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Finds an element by accessibility identifier regardless of its element type.
    /// SwiftUI decides whether a view surfaces as otherElement, staticText, etc.,
    /// and that mapping is not stable enough to hard-code in a test.
    private func el(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// iOS 26 discards `.accessibilityIdentifier` set on a `Tab`, so tab-bar
    /// buttons are only addressable by their visible title. Query by label.
    private func tab(_ title: String) -> XCUIElement {
        app.tabBars.buttons[title].firstMatch
    }

    /// Taps the centre of an element by coordinate, bypassing XCUITest's
    /// hittability gate. Custom-styled SwiftUI buttons (BounceButtonStyle here)
    /// can report `isHittable == false` while being perfectly tappable.
    private func forceTap(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    // MARK: - 1. Launch

    func testLaunch() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10),
                      "Home stat card must appear within 10 s of launch")
        for title in ["Health", "Routes", "Home", "Community", "Settings"] {
            XCTAssertTrue(tab(title).waitForExistence(timeout: 5),
                          "Tab '\(title)' must exist after launch")
        }
    }

    // MARK: - 2. Tab navigation

    func testTabNavigation() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))

        tab("Health").tap()
        XCTAssertTrue(el("health.root").waitForExistence(timeout: 15))

        tab("Routes").tap()
        XCTAssertTrue(app.buttons["routes.findRoutes"].waitForExistence(timeout: 30))

        tab("Community").tap()
        XCTAssertTrue(el("community.root").waitForExistence(timeout: 30))

        tab("Settings").tap()
        XCTAssertTrue(el("settings.root").waitForExistence(timeout: 30))

        tab("Home").tap()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30),
                      "Stat card must still be present after returning to Home")
    }

    // MARK: - 3. Walk lifecycle

    func testWalkLifecycle() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))

        let walkTile = app.buttons["home.tile.walk"]
        XCTAssertTrue(walkTile.waitForExistence(timeout: 15))
        forceTap(walkTile)
        XCTAssertTrue(el("session.root").waitForExistence(timeout: 30),
                      "Session screen must appear after starting a walk")

        let elapsed = el("session.elapsed")
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        let initialLabel = elapsed.label

        let timerTicked = XCTNSPredicateExpectation(
            predicate: NSPredicate { [elapsed] _, _ in elapsed.label != initialLabel },
            object: nil
        )
        wait(for: [timerTicked], timeout: 5)

        app.buttons["session.finish"].tap()
        XCTAssertTrue(el("summary.root").waitForExistence(timeout: 10),
                      "Summary screen must appear after finishing")

        app.buttons["summary.done"].tap()
    }

    // MARK: - 4. Active-walk accessory bar

    func testAccessoryBar() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))

        XCTAssertFalse(app.buttons["accessory.miniTile"].exists,
                       "Mini tile must not exist before a walk is started")

        let walkTile = app.buttons["home.tile.walk"]
        XCTAssertTrue(walkTile.waitForExistence(timeout: 15))
        forceTap(walkTile)
        XCTAssertTrue(el("session.root").waitForExistence(timeout: 30))

        app.buttons["session.minimize"].tap()
        let sessionGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == NO"),
            object: el("session.root")
        )
        wait(for: [sessionGone], timeout: 25)

        tab("Community").tap()

        let miniTile = app.buttons["accessory.miniTile"]
        XCTAssertTrue(miniTile.waitForExistence(timeout: 30),
                      "Mini tile must appear on Community tab while walk is active")
        XCTAssertTrue(miniTile.isHittable, "Mini tile must be hittable above the tab bar")

        miniTile.tap()
        XCTAssertTrue(el("session.root").waitForExistence(timeout: 20),
                      "Tapping the mini tile must reopen the session")

        app.buttons["session.finish"].tap()
        XCTAssertTrue(el("summary.root").waitForExistence(timeout: 10))
        app.buttons["summary.done"].tap()

        let miniGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == NO"),
            object: app.buttons["accessory.miniTile"]
        )
        wait(for: [miniGone], timeout: 10)
    }

    // MARK: - 5. Routes tab reachability

    func testRoutesReachable() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))

        tab("Routes").tap()

        let findRoutes = app.buttons["routes.findRoutes"]
        XCTAssertTrue(findRoutes.waitForExistence(timeout: 30))

        // Clipping guard #1 — the config panel, before any search.
        // This panel has no ScrollView, so its bottom-most control either clears the
        // tab bar or it is permanently unreachable. No scrolling, no rescue: a plain
        // hittability check here is a true test. This is the exact bug that shipped
        // on 2026-09-05 and that the old Start Walk assertion could not catch.
        let nearbyPlaces = app.buttons["routes.nearbyPlaces"]
        XCTAssertTrue(nearbyPlaces.waitForExistence(timeout: 10),
                      "Config panel's bottom row must exist")
        XCTAssertTrue(nearbyPlaces.isHittable,
                      "Config panel's bottom row must clear the tab bar — it cannot be scrolled")

        findRoutes.tap()

        // Network + location required; allow up to 30 s.
        let resultsPanel = el("routes.resultsPanel")
        XCTAssertTrue(resultsPanel.waitForExistence(timeout: 30),
                      "Results panel must appear after route generation")

        // Start Walk is gated on `selectedRoute`, which only RouteCard's onSelect
        // sets. This test used to assert Start Walk existed the moment routes were
        // generated — behaviour the app never had. Select a route first.
        let firstCard = app.buttons["routes.routeCard"].firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 10),
                      "At least one route card must be listed after generation")
        forceTap(firstCard)

        // Functional check only: selecting a route reveals Start Walk.
        //
        // This deliberately does NOT assert hittability. Start Walk has content below
        // it in the scroll view (Open in Apple Maps, then the community section), so a
        // swipe can always lift it clear of the tab bar — which made the previous
        // `scroll until hittable, then assert hittable` version unable to fail. It
        // passed green while the config panel next door was visibly clipped.
        let startWalk = app.buttons["routes.startWalk"]
        XCTAssertTrue(startWalk.waitForExistence(timeout: 10),
                      "Start Walk must appear once a route is selected")

        // Clipping guard #2 — the results panel, scrolled to the bottom.
        // `routes.communityToggle` is the last unconditional element in the panel.
        // Scrolling is legitimate here precisely because nothing renders below it: if
        // the panel's content is laid out under the tab bar, the scroll view runs out
        // of content before this clears the bar, and the assertion fails. That is the
        // property the old version lacked.
        let lastRow = app.buttons["routes.communityToggle"]
        XCTAssertTrue(lastRow.waitForExistence(timeout: 10),
                      "Community toggle must exist in the results panel")

        var scrollAttempts = 0
        while !lastRow.isHittable && scrollAttempts < 5 {
            resultsPanel.swipeUp()
            scrollAttempts += 1
        }
        XCTAssertTrue(lastRow.isHittable,
                      "The results panel's last row must scroll clear of the tab bar")
    }
}
