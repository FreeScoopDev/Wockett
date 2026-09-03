import XCTest

final class SmokeTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            let dismiss = alert.buttons["Don't Allow"].exists ? alert.buttons["Don't Allow"] :
                          alert.buttons["OK"].exists ? alert.buttons["OK"] :
                          alert.buttons.element(boundBy: 0)
            if dismiss.exists { dismiss.tap() }
            return true
        }
        app = XCUIApplication()
        app.launchArguments = ["-WKTUITest"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    /// Finds an element by accessibility identifier regardless of its element
    /// type. SwiftUI decides whether a given view surfaces as otherElement,
    /// staticText or something else, and that mapping is not stable enough to
    /// hard-code in a test.
    private func el(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: - 1. Launch

    func testLaunch() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10),
                      "Home stat card must appear within 10 s of launch")
        for id in ["tab.health", "tab.routes", "tab.home", "tab.community", "tab.settings"] {
            XCTAssertTrue(el(id).exists, "Tab '\(id)' must exist after launch")
        }
    }

    // MARK: - 2. Tab navigation

    func testTabNavigation() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))

        el("tab.health").tap()
        XCTAssertTrue(el("health.root").waitForExistence(timeout: 5))

        el("tab.routes").tap()
        XCTAssertTrue(app.buttons["routes.findRoutes"].waitForExistence(timeout: 5))

        el("tab.community").tap()
        XCTAssertTrue(el("community.root").waitForExistence(timeout: 5))

        el("tab.settings").tap()
        XCTAssertTrue(el("settings.root").waitForExistence(timeout: 5))

        el("tab.home").tap()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 5),
                      "Stat card must still be present after returning to Home")
    }

    // MARK: - 3. Walk lifecycle

    func testWalkLifecycle() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))

        app.buttons["home.tile.walk"].tap()
        XCTAssertTrue(el("session.root").waitForExistence(timeout: 15),
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

        app.buttons["home.tile.walk"].tap()
        XCTAssertTrue(el("session.root").waitForExistence(timeout: 15))

        app.buttons["Minimize session"].tap()
        let sessionGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == NO"),
            object: el("session.root")
        )
        wait(for: [sessionGone], timeout: 10)

        el("tab.community").tap()

        let miniTile = app.buttons["accessory.miniTile"]
        XCTAssertTrue(miniTile.waitForExistence(timeout: 5),
                      "Mini tile must appear on Community tab while walk is active")
        XCTAssertTrue(miniTile.isHittable, "Mini tile must be hittable above the tab bar")

        miniTile.tap()
        XCTAssertTrue(el("session.root").waitForExistence(timeout: 10),
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

        el("tab.routes").tap()

        let findRoutes = app.buttons["routes.findRoutes"]
        XCTAssertTrue(findRoutes.waitForExistence(timeout: 5))
        findRoutes.tap()

        // Network + location required; allow up to 30 s.
        let resultsPanel = el("routes.resultsPanel")
        XCTAssertTrue(resultsPanel.waitForExistence(timeout: 30),
                      "Results panel must appear after route generation")

        let startWalk = app.buttons["routes.startWalk"]
        XCTAssertTrue(startWalk.exists, "Start Walk button must exist in the results panel")
        XCTAssertTrue(startWalk.isHittable,
                      "Start Walk must be hittable — not covered by the tab bar")
    }
}
