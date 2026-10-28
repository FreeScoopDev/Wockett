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
    /// Set when the interruption monitor answers an alert; `selectTab` re-taps
    /// only then.
    private var interruptionHandled = false

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "System alert") { [weak self] alert in
            // Only permission alerts. A notification banner also arrives here, and
            // tapping one that has already slid away fails the test at the tap
            // ("no matches found for Descendants matching type BannerNotification").
            // Returning false lets XCTest carry on; banners never block a tap.
            guard alert.elementType == .alert else { return false }
            for title in ["Don't Allow", "Not Now", "OK", "Allow", "Cancel"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                self?.interruptionHandled = true
                return true
            }
            if alert.buttons.count > 0 {
                alert.buttons.element(boundBy: 0).tap()
                self?.interruptionHandled = true
                return true
            }
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
    /// `testGuidedWalkEndedFromLiveActivityReturnsHome` at Routes (3 of its 6
    /// CI failures). It re-taps only when the monitor answered an alert during
    /// the tap; a tab that ignores a tap with no alert in the way fails here,
    /// so a tab bar that needs two taps can't pass. Every call is still
    /// followed by the screen's own wait.
    private func selectTab(_ title: String) {
        let button = tab(title)
        let selected = NSPredicate(format: "selected == true")
        for _ in 0..<3 {
            interruptionHandled = false
            button.tap()
            let wait = XCTNSPredicateExpectation(predicate: selected, object: button)
            if XCTWaiter().wait(for: [wait], timeout: 10) == .completed { return }
            guard interruptionHandled else {
                XCTFail("The \(title) tab did not select on a tap, and no alert was in the way")
                return
            }
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

    // MARK: - 4b. Indoor walk ends on the shared summary

    /// Indoor ends on the same full-screen summary as every other activity
    /// (2026-10-13; it was a half sheet of its own). The simulator has no
    /// pedometer, so the walk has 0 steps and is not saved: the summary still
    /// appears, and Done must close it and the indoor screen together. A
    /// hittable tab, not `exists`, proves both covers went (CLAUDE.md).
    func testIndoorWalkEndsOnTheSummary() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))
        let indoorTile = app.buttons["home.tile.indoor"]
        XCTAssertTrue(indoorTile.waitForExistence(timeout: 15))
        forceTap(indoorTile)
        let start = app.buttons["home.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(start.label, "Start Indoor")
        start.tap()

        let finish = app.buttons["indoor.finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 15), "Start Indoor must open the indoor screen")
        finish.tap()
        XCTAssertTrue(el("summary.root").waitForExistence(timeout: 10),
                      "Finishing an indoor walk must show the summary")
        let done = app.buttons["summary.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()

        let summaryGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == NO"), object: el("summary.root"))
        let homeHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == YES"), object: tab("Home"))
        XCTAssertEqual(XCTWaiter().wait(for: [summaryGone, homeHittable], timeout: 15), .completed,
                       "Done must close the summary and the indoor screen. \(screenState())")
        XCTAssertFalse(finish.exists, "the indoor screen must be gone too")
    }

    // MARK: - 4c. Mini tile's Save & End shows the summary

    /// Save & End on the mini tile ends the walk from outside the walk screen;
    /// the app root then shows the same summary (2026-10-13; it showed
    /// nothing). The presentation is the risky part: the tile and its
    /// confirmation dialog go away in the same tap that asks for it.
    func testMiniTileSaveAndEndShowsTheSummary() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))
        startWalkFromHome()
        XCTAssertTrue(el("session.root").waitForExistence(timeout: 30))
        app.buttons["session.minimize"].tap()
        let sessionGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == NO"), object: el("session.root"))
        wait(for: [sessionGone], timeout: 25)

        // On Community, as in testAccessoryBar: the tile is full size there.
        selectTab("Community")
        let end = app.buttons["End walk"]
        XCTAssertTrue(end.waitForExistence(timeout: 30), "the mini tile's End button must be there")
        end.tap()
        let save = app.buttons["Save & End Walk"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "End must ask to save or discard")
        save.tap()

        XCTAssertTrue(el("summary.root").waitForExistence(timeout: 15),
                      "Save & End must show the summary. \(screenState())")
        app.buttons["summary.done"].tap()
        let summaryGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == NO"), object: el("summary.root"))
        let communityHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == YES"), object: tab("Community"))
        XCTAssertEqual(XCTWaiter().wait(for: [summaryGone, communityHittable], timeout: 15), .completed,
                       "Done must close the summary. \(screenState())")
        XCTAssertFalse(app.buttons["accessory.miniTile"].exists, "the walk must have ended")
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
    /// Notification Centre through springboard, which the runner does not do
    /// reliably: since it landed (#201) it failed 6 of the 15 UI jobs that
    /// finished. 3 were the lost Routes tap `selectTab` now handles; the rest
    /// were the runner's: no Live Activity in Notification Centre (run
    /// 38312665429), the End Walk tap not ending the walk (38394086194, on a
    /// change that passed this test locally), and the route list (38324667161).
    /// It passed in the other 9, so it is not impossible there, only too
    /// unreliable to keep the advisory job meaningful. The UI job sets `TEST_RUNNER_WOCKETT_CI=1` in
    /// `.github/workflows/tests.yml`, which xcodebuild passes to this process
    /// as `WOCKETT_CI`; a local run has neither, so the test runs there.
    func testGuidedWalkEndedFromLiveActivityReturnsHome() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["WOCKETT_CI"] == "1",
                      "GitHub's runner doesn't drive Notification Centre reliably")
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

    // MARK: - 6c. History: Repeat reviews before it starts

    /// Health → Activity History. A row's More menu reaches Edit details,
    /// and Repeat opens a review that begins nothing until Start (spec
    /// fix/history-actions, 2026-10-27; the row's arrow used to begin a walk
    /// on the tap). Start opens the walk screen and its timer runs: a session
    /// that only exists (a mini tile at 0:00) records nothing. A second Start
    /// while that walk is active shows the existing alert and leaves the
    /// review up. -WKTDemo seeds the one finished walk (DemoMode).
    func testHistoryRepeatReviewsBeforeStarting() {
        app.terminate()
        app.launchArguments += ["-WKTDemo"]
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))

        let more = app.buttons["history.more"].firstMatch
        let repeatItem = app.buttons["Repeat"].firstMatch
        let start = app.buttons["history.repeat.start"]
        let miniTile = app.buttons["accessory.miniTile"]

        func openHistory() {
            selectTab("Health")
            XCTAssertTrue(el("health.root").waitForExistence(timeout: 30))
            let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Activity History'")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10), "Activity History missing from Health")
            var swipes = 0
            while !card.isHittable && swipes < 8 {
                app.swipeUp()
                swipes += 1
            }
            card.tap()
            XCTAssertTrue(more.waitForExistence(timeout: 15), "A history row must have its More menu")
        }

        func openRepeat() {
            more.tap()
            XCTAssertTrue(repeatItem.waitForExistence(timeout: 5), "More must offer Repeat")
            repeatItem.tap()
            XCTAssertTrue(start.waitForExistence(timeout: 10), "Repeat must open the review sheet")
        }

        openHistory()

        // Edit details is one tap from the menu and says what it is.
        more.tap()
        let edit = app.buttons["Edit details"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "More must offer Edit details")
        edit.tap()
        XCTAssertTrue(app.staticTexts["Edit details"].waitForExistence(timeout: 10),
                      "The details sheet must say Edit details")
        XCTAssertTrue(app.staticTexts["Activity type"].exists, "Edit details must reach the type picker")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 10))

        // Repeat: the review is up and nothing has begun.
        openRepeat()
        XCTAssertFalse(miniTile.waitForExistence(timeout: 2), "Repeat must not begin a walk before Start")
        XCTAssertFalse(el("session.root").exists, "Repeat must not open a walk before Start")

        // Cancel: still nothing.
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 10), "Cancel must return to the list")
        XCTAssertFalse(miniTile.waitForExistence(timeout: 2), "Cancel must leave no walk in progress")

        // Start begins one, and it records.
        openRepeat()
        start.tap()
        XCTAssertTrue(el("session.root").waitForExistence(timeout: 30),
                      "Start must open the walk screen. \(screenState())")
        let elapsed = el("session.elapsed")
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        let first = elapsed.label
        let ticked = XCTNSPredicateExpectation(
            predicate: NSPredicate { [elapsed] _, _ in elapsed.label != first }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [ticked], timeout: 10), .completed,
                       "The repeated walk must be recording")
        // A full-screen cover leaves the views beneath it in the tree, so wait
        // for the walk screen to go before using the tab bar (testAccessoryBar).
        app.buttons["session.minimize"].tap()
        let sessionGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == NO"), object: el("session.root"))
        wait(for: [sessionGone], timeout: 25)
        XCTAssertTrue(miniTile.waitForExistence(timeout: 30), "The walk must still be in progress")

        // Again while it is active: the existing alert, and the review stays.
        // After the walk screen minimizes here the tab bar can be collapsed
        // to the Home button (iOS 26.5, seen 2026-10-27); tapping it expands it.
        if !tab("Health").waitForExistence(timeout: 3) { tab("Home").tap() }
        openHistory()
        openRepeat()
        start.tap()
        let alert = app.alerts["Walk Already Active"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "A second walk must be refused with the alert")
        alert.buttons["OK"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5), "The review must stay up when nothing started")
    }

    // MARK: - 6d. History: search, filters, and deleting from a filtered list

    /// Health → Activity History with the -WKTDemo walk on screen.
    private func openHistoryFromHealth() {
        selectTab("Health")
        XCTAssertTrue(el("health.root").waitForExistence(timeout: 30))
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Activity History'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Activity History missing from Health")
        var swipes = 0
        while !card.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        card.tap()
        XCTAssertTrue(app.buttons["history.row"].firstMatch.waitForExistence(timeout: 15),
                      "History must list the demo walk")
    }

    private var historyRows: XCUIElementQuery { app.buttons.matching(identifier: "history.row") }

    /// Waits until the list shows `count` rows.
    private func expectHistoryRows(_ count: Int, _ message: String) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == \(count)"),
                                              object: historyRows)
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: 10), .completed,
                       "\(message): expected \(count) rows, saw \(historyRows.count)")
    }

    /// The header's figures, read from its accessibility label
    /// ("2 activities · 3.1 mi · 1h 5m. 2 this week").
    private func expectHistoryHeader(startsWith prefix: String) {
        let header = el("history.header")
        XCTAssertTrue(header.waitForExistence(timeout: 10), "History must show its header")
        XCTAssertTrue(header.label.hasPrefix(prefix), "Header said “\(header.label)”, expected “\(prefix)…”")
    }

    /// Search narrows the list and the header to the matching row, clearing
    /// it brings both back, and a swipe-delete in a searched list deletes the
    /// row that was swiped (spec fix/history-search-filter). The second walk
    /// is logged through Log a Past Walk, so the list has two to tell apart.
    func testHistorySearchNarrowsAndDeletesTheSwipedRow() {
        app.terminate()
        app.launchArguments += ["-WKTDemo"]
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))
        openHistoryFromHealth()

        // A second walk, newer than the demo one, so it is the first row.
        app.buttons["Add activity"].tap()
        let distance = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Distance in'")).firstMatch
        XCTAssertTrue(distance.waitForExistence(timeout: 10), "Log a Past Walk must open")
        distance.tap()
        distance.typeText("2")
        let name = app.textFields.matching(NSPredicate(format: "placeholderValue == 'Route name or notes…'")).firstMatch
        name.tap()
        name.typeText("Riverside Path")
        app.buttons["Done"].firstMatch.tap()
        app.buttons["Save Walk"].tap()
        expectHistoryRows(2, "Both walks must be listed")
        XCTAssertTrue(app.staticTexts["All activities"].exists, "Unfiltered, the header covers all activities")
        expectHistoryHeader(startsWith: "2 activities")

        // Search by name: only the match is left, and the header follows it.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "History must have a search field")
        search.tap()
        search.typeText("river")
        expectHistoryRows(1, "Searching “river” must leave one row")
        XCTAssertTrue(historyRows.firstMatch.label.contains("Riverside Path"), historyRows.firstMatch.label)
        expectHistoryHeader(startsWith: "1 activity ·")

        // Clearing the text restores both.
        search.buttons["Clear text"].tap()
        expectHistoryRows(2, "Clearing the search must restore every row")
        expectHistoryHeader(startsWith: "2 activities")

        // Delete from a searched list: the visible row is the demo walk, the
        // second in the whole list. Offset 0 in the whole list is Riverside.
        search.typeText("downtown")
        expectHistoryRows(1, "Searching “downtown” must leave one row")
        XCTAssertTrue(historyRows.firstMatch.label.contains("Downtown Loop"), historyRows.firstMatch.label)
        historyRows.firstMatch.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "A row must offer Delete on a swipe")
        delete.tap()
        XCTAssertTrue(el("history.noMatch").waitForExistence(timeout: 10),
                      "With the only match deleted, the search matches nothing")

        search.buttons["Clear text"].tap()
        expectHistoryRows(1, "One walk must be left")
        XCTAssertTrue(historyRows.firstMatch.label.contains("Riverside Path"),
                      "The swiped walk must be the one deleted, not the first in the list: \(historyRows.firstMatch.label)")
        expectHistoryHeader(startsWith: "1 activity ·")
    }

    /// A search or filter that matches nothing says so, which is not the
    /// empty-history state, and Clear filters brings everything back.
    func testHistoryNoResultsAndClearFilters() {
        app.terminate()
        app.launchArguments += ["-WKTDemo"]
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))
        openHistoryFromHealth()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "History must have a search field")
        search.tap()
        search.typeText("zzzz")
        XCTAssertTrue(el("history.noMatch").waitForExistence(timeout: 10), "No match must say so")
        XCTAssertTrue(app.staticTexts["No activities match"].exists)
        XCTAssertFalse(app.staticTexts["No activities yet"].exists, "No match is not an empty history")

        app.buttons["Clear filters"].tap()
        expectHistoryRows(1, "Clear filters must restore the list")
        XCTAssertTrue(app.staticTexts["All activities"].waitForExistence(timeout: 5),
                      "Clear filters must restore the All activities header")
        XCTAssertNotEqual(search.value as? String, "zzzz", "Clear filters must clear the search text too")

        // The filter menu: Run matches nothing here (the demo walk is a walk).
        // iOS 26 can drop an identifier on a toolbar item (as it does on a
        // Tab), so the menu is found by its identifier or its label.
        let filter = app.buttons.matching(
            NSPredicate(format: "identifier == 'history.filter' OR label == 'Filters'")).firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5),
                      "History must have a filter menu. Bar: \(app.navigationBars.firstMatch.debugDescription)")
        XCTAssertEqual(filter.value as? String, "No filters active")
        filter.tap()
        let activity = app.buttons["Activity"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 5), "The filter menu must offer Activity")
        activity.tap()
        let run = app.buttons["Run"].firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 5), "Activity must offer Run")
        run.tap()
        XCTAssertTrue(el("history.noMatch").waitForExistence(timeout: 10), "Run must match nothing here")
        XCTAssertEqual(filter.value as? String, "1 filter active")

        app.buttons["Clear filters"].tap()
        expectHistoryRows(1, "Clear filters must undo the menu's filter too")
        XCTAssertEqual(filter.value as? String, "No filters active")
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

    // MARK: - 7b. My contributions

    /// Settings → Community → My contributions opens, and with nothing
    /// nominated from this device it shows the empty state that explains
    /// nominating (spec feat/contribution-status, criterion 4). Nothing
    /// nominates under -WKTUITest, and the status store is a stub then, so
    /// the list is empty and nothing reaches CloudKit.
    func testMyContributionsEmptyState() {
        // An empty list whatever this simulator saved before: the argument
        // domain is read ahead of the app's own defaults ("W10=" is "[]").
        app.terminate()
        app.launchArguments += ["-wkt_contributions_v1", "<data>W10=</data>"]
        app.launch()

        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))
        selectTab("Settings")
        XCTAssertTrue(el("settings.root").waitForExistence(timeout: 30))

        let row = el("settings.myContributions")
        var swipes = 0
        while !row.isHittable && swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "My contributions missing from Settings → Community")
        row.tap()

        XCTAssertTrue(el("contributions.root").waitForExistence(timeout: 10), "My contributions did not open")
        XCTAssertTrue(el("contributions.empty").waitForExistence(timeout: 10), "Empty state missing with nothing nominated")
        XCTAssertTrue(app.staticTexts["No contributions yet"].exists)
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

    // MARK: - 9. Terms before a first community action

    /// Community → Start a challenge → Create Challenge with the Terms not yet
    /// agreed to. Cancel must close the Terms sheet and leave the form as it
    /// was, with nothing saved; Agree must close it and run the save. A sheet
    /// that never presents fails at the first wait, and Agree wired to Cancel
    /// fails at the last. The name is over the 60-character limit, so the save
    /// stops at `ContentFilter` before anything reaches CloudKit and shows
    /// its error offline, on CI and on a signed-in simulator alike.
    func testCommunityTermsGateOnCreateChallenge() {
        // Read before the app's own domain, so earlier runs that agreed don't count.
        app.terminate()
        app.launchArguments += ["-wkt_termsAcceptedVersion", "none"]
        app.launch()

        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 10))
        selectTab("Community")
        XCTAssertTrue(el("community.root").waitForExistence(timeout: 30))
        let start = app.buttons["Start a challenge"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), "Start a challenge missing from Community")
        start.tap()

        let name = app.textFields["challenge.create.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15), "New Challenge form did not open")
        let tooLong = String(repeating: "Walk ", count: 13).trimmingCharacters(in: .whitespaces)
        name.tap()
        name.typeText(tooLong)

        let create = app.buttons["challenge.create.submit"]
        let sheet = el("terms.sheet")
        let error = el("challenge.create.error")
        create.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Create Challenge must ask for the Terms first")
        XCTAssertFalse(error.exists, "the save must wait for the Terms")

        el("terms.cancel").tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Cancel must close the Terms sheet")
        XCTAssertTrue(name.exists, "Cancel must leave the New Challenge form open")
        XCTAssertEqual(name.value as? String, tooLong, "Cancel must leave the form unchanged")
        XCTAssertFalse(error.waitForExistence(timeout: 3), "Cancel must not run the save")

        create.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "still not agreed: Create asks again")
        el("terms.agree").tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Agree must close the Terms sheet")
        XCTAssertTrue(error.waitForExistence(timeout: 10), "Agree must run the held save")
    }
}
