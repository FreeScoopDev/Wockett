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
            // Only permission alerts. A notification banner also arrives here, and
            // tapping one that has already slid away fails the test at the tap
            // ("no matches found for Descendants matching type BannerNotification").
            // Returning false lets XCTest carry on; banners never block a tap.
            guard alert.elementType == .alert else { return false }
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

    /// Selects a tab, tapping again if XCTest lost the tap. A system alert that
    /// is up when a tab is tapped goes to the interruption monitor first, and
    /// XCTest then loses the tap itself: CI run 38282011787 answered a
    /// location prompt ("Allow Once"), logged "Computed hit point {-1, -1}"
    /// for the Health tab, and the tab never changed, so the wait for
    /// `health.root` ran out. That was every `testHealthShowsDisclaimer`
    /// failure (6, 2026-10-11/12), and the same lost tap stopped
    /// `testGuidedWalkEndedFromLiveActivityReturnsHome` at Routes. Every call
    /// is still followed by the screen's own wait, so a broken tab still fails.
    private func selectTab(_ title: String) {
        let button = tab(title)
        let selected = NSPredicate(format: "selected == true")
        for _ in 0..<3 {
            button.tap()
            let wait = XCTNSPredicateExpectation(predicate: selected, object: button)
            if XCTWaiter().wait(for: [wait], timeout: 5) == .completed { return }
        }
    }

    /// Taps the centre of an element by coordinate, bypassing XCUITest's
    /// hittability gate. Custom-styled SwiftUI buttons (BounceButtonStyle here)
    /// can report `isHittable == false` while being perfectly tappable.
    private func forceTap(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Home's picker only selects an activity; its Start button starts it.
    /// The check in between is what proves the picker no longer starts a
    /// session on its own, as the tiles it replaced did.
    private func startWalkFromHome() {
        let walkTile = app.buttons["home.tile.walk"]
        XCTAssertTrue(walkTile.waitForExistence(timeout: 15))
        forceTap(walkTile)
        XCTAssertTrue(walkTile.isSelected, "Tapping Walk must select it")
        XCTAssertFalse(el("session.root").waitForExistence(timeout: 2),
                       "Tapping an activity must not start a session by itself")
        let start = app.buttons["home.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(start.label, "Start Walk")
        start.tap()
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

        selectTab("Health")
        XCTAssertTrue(el("health.root").waitForExistence(timeout: 15))

        selectTab("Routes")
        XCTAssertTrue(app.buttons["routes.findRoutes"].waitForExistence(timeout: 30))

        selectTab("Community")
        XCTAssertTrue(el("community.root").waitForExistence(timeout: 30))

        selectTab("Settings")
        XCTAssertTrue(el("settings.root").waitForExistence(timeout: 30))

        selectTab("Home")
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30),
                      "Stat card must still be present after returning to Home")
    }

    // MARK: - 3. Walk lifecycle

    func testWalkLifecycle() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))

        startWalkFromHome()
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

        // Finish is protected (2026-09-24): a plain tap must not end the
        // session, a one-second hold opens a confirmation, and only
        // "Finish and save" ends it.
        let finish = el("session.finish")
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.tap()
        XCTAssertFalse(el("session.confirmFinish").waitForExistence(timeout: 2),
                       "A plain tap on Finish must not ask to end the session")
        XCTAssertTrue(el("session.root").exists, "A plain tap on Finish must not end the session")

        finish.press(forDuration: 1.4)
        let confirm = app.buttons["session.confirmFinish"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Holding Finish must open the confirmation")
        confirm.tap()
        XCTAssertTrue(el("summary.root").waitForExistence(timeout: 10),
                      "Summary screen must appear after finishing")

        app.buttons["summary.done"].tap()
    }

    // MARK: - 4. Active-walk accessory bar

    func testAccessoryBar() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))

        XCTAssertFalse(app.buttons["accessory.miniTile"].exists,
                       "Mini tile must not exist before a walk is started")

        startWalkFromHome()
        XCTAssertTrue(el("session.root").waitForExistence(timeout: 30))

        app.buttons["session.minimize"].tap()
        let sessionGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == NO"),
            object: el("session.root")
        )
        wait(for: [sessionGone], timeout: 25)

        selectTab("Community")

        let miniTile = app.buttons["accessory.miniTile"]
        XCTAssertTrue(miniTile.waitForExistence(timeout: 30),
                      "Mini tile must appear on Community tab while walk is active")
        XCTAssertTrue(miniTile.isHittable, "Mini tile must be hittable above the tab bar")

        miniTile.tap()
        XCTAssertTrue(el("session.root").waitForExistence(timeout: 20),
                      "Tapping the mini tile must reopen the session")

        el("session.finish").press(forDuration: 1.4)
        let confirm = app.buttons["session.confirmFinish"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(el("summary.root").waitForExistence(timeout: 10))
        app.buttons["summary.done"].tap()

        // Failed once on Xcode Cloud (PR #87, 2026-09-27) and never in 33 local
        // runs, fresh simulators included. Locally the tile is gone at the first
        // check, about 1 s after Done, so a 10 s miss is a stuck state rather than
        // a slow machine, and a longer timeout would not help. The failure left
        // only "exceeded timeout", so this reports which screen was up and what
        // the tile said: that text reaches the GitHub check-run summary.
        let leftoverTile = app.buttons["accessory.miniTile"]
        let miniGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == NO"),
            object: leftoverTile
        )
        if XCTWaiter().wait(for: [miniGone], timeout: 10) != .completed {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Mini tile still present"
            shot.lifetime = .keepAlways
            add(shot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Accessibility tree"
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("Mini tile still present 10 s after Done. \(screenState()), "
                    + "tile label '\(leftoverTile.label)'")
        }
    }

    /// One line describing what is on screen, for failure messages that must
    /// explain themselves from a CI summary alone.
    private func screenState() -> String {
        let marks = ["summary.root", "session.root", "home.statCard", "community.root"]
            .map { "\($0)=\(el($0).exists)" }
        let elapsed = el("session.elapsed")
        let timer = elapsed.exists ? ", session.elapsed '\(elapsed.label)'" : ""
        return marks.joined(separator: " ") + ", alerts=\(app.alerts.count)" + timer
    }

    // MARK: - 5. Routes tab reachability

    func testRoutesReachable() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))

        selectTab("Routes")

        let findRoutes = app.buttons["routes.findRoutes"]
        XCTAssertTrue(findRoutes.waitForExistence(timeout: 30))
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

        let startWalk = app.buttons["routes.startWalk"]
        XCTAssertTrue(startWalk.waitForExistence(timeout: 10),
                      "Start Walk must appear once a route is selected")

        // This test deliberately stops here, and does NOT assert that anything
        // clears the floating tab bar. Measured on an iPhone 17 (2026-09-05): every
        // candidate element in both Routes panels sits 90-101pt above the bar with
        // no scrolling at all, so `isHittable` is true no matter what the layout
        // does. Two successive attempts at a clipping assertion were written here,
        // and both passed green against a deliberately broken layout before anyone
        // checked whether they could fail.
        //
        // The regression actually reported against v1.10 was content sitting below
        // the fold in a short panel — a visual problem that hittability cannot see.
        // Covering it needs snapshot testing, not XCUITest. Until that exists, this
        // gap is uncovered, and it is better to say so here than to leave an
        // assertion that looks like protection and isn't.
    }

    // MARK: - 5b. Guided walk ended from the Live Activity

    /// A guided walk's screen is a full-screen cover on Home. Ending the walk
    /// from the Live Activity while that screen is up must take the person
    /// back to Home, not leave them on an empty cover with no way out.
    ///
    /// Skipped on GitHub Actions, run everywhere else. It ends the walk from
    /// Notification Centre, and the runner's simulator does not show the Live
    /// Activity there (run 38312665429: "End Walk button must be in
    /// Notification Centre"). The UI job sets `TEST_RUNNER_WOCKETT_CI=1` in
    /// `.github/workflows/tests.yml`, which xcodebuild passes to this process
    /// as `WOCKETT_CI`; a local run has neither, so the test runs there.
    func testGuidedWalkEndedFromLiveActivityReturnsHome() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["WOCKETT_CI"] == "1",
                      "GitHub's runner can't show the Live Activity in Notification Centre")
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))
        selectTab("Routes")
        let findRoutes = app.buttons["routes.findRoutes"]
        XCTAssertTrue(findRoutes.waitForExistence(timeout: 30))
        findRoutes.tap()
        let firstCard = app.buttons["routes.routeCard"].firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 30))
        forceTap(firstCard)
        let startWalk = app.buttons["routes.startWalk"]
        XCTAssertTrue(startWalk.waitForExistence(timeout: 10))
        forceTap(startWalk)
        XCTAssertTrue(el("session.root").waitForExistence(timeout: 30),
                      "Start Walk must open the guided walk screen")

        // The real End button, on the Live Activity in Notification Centre.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.001))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)))
        let end = springboard.buttons["End Walk"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 15),
                      "The Live Activity's End Walk button must be in Notification Centre")
        end.tap()
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.999))
        bottom.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        app.activate()

        // A full-screen cover leaves the views beneath it in the tree, so
        // `exists` would pass on an empty cover; only a hittable tab proves
        // the cover went.
        let sessionGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == NO"), object: el("session.root"))
        let homeHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == YES"), object: tab("Home"))
        if XCTWaiter().wait(for: [sessionGone, homeHittable], timeout: 20) != .completed {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "After Live Activity End"
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("Home is not back 20 s after the Live Activity ended the walk. "
                    + "\(screenState()), mini tile \(app.buttons["accessory.miniTile"].exists)")
        }
        // Nothing may replace the walk that ended. Until 2026-10-12 the walk
        // screen started a free walk here, and a cover closing over it would
        // still hide that from the checks above.
        XCTAssertFalse(app.buttons["accessory.miniTile"].waitForExistence(timeout: 5),
                       "No walk may be running after the Live Activity ended it")
    }

    // MARK: - 6. Trail data credits

    /// The bundled trail pack opened at launch and Settings → About credits its
    /// source. This is the first user-visible piece of Trails, and the ODbL
    /// credit is a licence obligation, so its presence is a smoke check. Under
    /// -WKTUITest the pack still loads — it is local data, nothing to stub.
    func testSettingsShowsTrailDataCredits() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))
        selectTab("Settings")
        XCTAssertTrue(el("settings.root").waitForExistence(timeout: 30))

        // About is near the bottom of a long list.
        let credits = el("settings.trailData")
        var swipes = 0
        while !credits.exists && swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(credits.waitForExistence(timeout: 10), "Trail data rows missing from Settings → About")

        // The pack's region line and the OSM credit both come from the data, not copy.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'North Carolina:'")).firstMatch.exists,
                      "Bundled North Carolina pack should be described")
        XCTAssertTrue(app.descendants(matching: .any)
                        .matching(NSPredicate(format: "label CONTAINS 'OpenStreetMap'")).firstMatch.exists,
                      "ODbL attribution line missing")
    }

    // MARK: - 6b. Health disclaimer

    /// The Health screen ends with the "not medical advice" footnote
    /// (liability review, 2026-10-11): present, with the exact words, and
    /// reachable by scrolling to the end of a long screen.
    func testHealthShowsDisclaimer() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))
        selectTab("Health")
        // 30 s like the other tabs: a loaded CI machine took longer than 15 (PR 186).
        XCTAssertTrue(el("health.root").waitForExistence(timeout: 30))
        let note = app.staticTexts["health.disclaimer"]
        XCTAssertTrue(note.waitForExistence(timeout: 10), "Health disclaimer missing from the Health screen")
        // In the tree isn't on screen: a plain VStack keeps off-screen text in
        // the accessibility tree, so scroll until it can be reached.
        var swipes = 0
        while !note.isHittable && swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(note.isHittable, "Health disclaimer can't be scrolled into view")
        XCTAssertEqual(note.label, "For general information, not medical advice. Wockett isn't a medical device.")
    }

    // MARK: - 7. Trails list

    /// Routes → Trails lists real trails from the bundled pack, a card opens
    /// its detail, and "All trails" comes back. Under -WKTUITest the list
    /// searches from downtown Raleigh (RouteManager's stub location, Times
    /// Square, has no pack), so this runs against the North Carolina data the
    /// app ships.
    func testTrailsList() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))
        selectTab("Routes")
        let picker = el("routes.modePicker")
        XCTAssertTrue(picker.waitForExistence(timeout: 30))
        picker.buttons["Trails"].tap()

        let firstCard = app.buttons["routes.trailCard"].firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 15), "No trails listed near downtown Raleigh")
        firstCard.tap()

        XCTAssertTrue(el("routes.trailDetail").waitForExistence(timeout: 10))
        // Waited for, like every other step: the detail's directions section
        // can land a moment after the detail itself, and a bare `exists`
        // failed on CI with no change to the screen (main 0ce9854, 2026-10-10).
        XCTAssertTrue(app.buttons["routes.trailDirections"].waitForExistence(timeout: 10))
        app.buttons["routes.trailBack"].tap()
        XCTAssertTrue(firstCard.waitForExistence(timeout: 10))
    }

    // MARK: - 8. Step goal editor

    /// Settings → Daily Step Goal opens the goal editor and Cancel closes it.
    /// From 1.10 to 1.12 nothing presented the editor at all, so the goal,
    /// the weekly schedule and the tags could not be changed; this is the
    /// check that the way in still exists.
    func testStepGoalEditorOpensFromSettings() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))
        selectTab("Settings")
        XCTAssertTrue(el("settings.root").waitForExistence(timeout: 30))

        let row = app.buttons["settings.stepGoal"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Daily Step Goal row missing from Settings")
        row.tap()

        let editor = app.navigationBars["Daily Goal"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Goal editor did not open")
        editor.buttons["Cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10), "Cancel must close the goal editor")
    }
}
