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

    // MARK: - 3b. Walk screen at the largest text size

    /// At Accessibility 2 (the walk screen's ceiling, `wktTextSizeCap`) the
    /// walk screen stacks Pause above a full-width Finish, and the pulled-up
    /// panel stays below the map controls with its last stat reachable (spec
    /// fix/large-text-walk-screen). Until then Finish was 140 pt beside Pause
    /// and read "Hold to fi…". A guided walk (the -WKTDemo walk, repeated
    /// from History), because it has the tallest panel: a two-line route
    /// name, the progress bar and the most stats. Frames only: the
    /// accessibility tree reports full labels, so a cut-off word can't be
    /// seen here; Finish's width is the stand-in for room to read
    /// "Hold to finish".
    func testWalkScreenFitsAtAccessibility2() {
        startGuidedWalkAtAccessibility2()

        let window = app.windows.firstMatch.frame
        let pause = app.buttons["session.pause"]
        let finish = el("session.finish")
        let more = app.buttons["session.more"]
        let panel = el("session.panel")
        let orientation = app.buttons["session.orientation"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertTrue(more.exists && panel.exists && orientation.exists,
                      "The panel, its More button and the map controls must be there")

        func checkActions(_ state: String) {
            XCTAssertLessThanOrEqual(pause.frame.maxX, window.maxX, "Pause off the right edge (\(state))")
            XCTAssertLessThanOrEqual(finish.frame.maxX, window.maxX, "Finish off the right edge (\(state))")
            XCTAssertGreaterThanOrEqual(finish.frame.minY, pause.frame.maxY,
                                        "Finish must sit below Pause (\(state)): \(finish.frame) vs \(pause.frame)")
            XCTAssertGreaterThanOrEqual(finish.frame.width, pause.frame.width - 1,
                                        "Finish must have Pause's full width (\(state)): \(finish.frame.width)")
            XCTAssertLessThanOrEqual(finish.frame.maxY, window.maxY, "Finish below the screen (\(state))")
            XCTAssertLessThanOrEqual(orientation.frame.maxY, panel.frame.minY,
                                     "The panel must stay below North up (\(state)): \(panel.frame) vs \(orientation.frame)")
        }
        checkActions("collapsed")

        // Pulled up: the last stat must be reachable by scrolling the panel,
        // and then sit between the header and the buttons, inside the screen.
        more.tap()
        let stops = el("session.stops")
        XCTAssertTrue(stops.waitForExistence(timeout: 10), "The pulled-up panel must list stops")
        // Animation wait: the panel's spring (0.35 s) must settle before frames are read.
        sleep(1)
        checkActions("expanded")
        var swipes = 0
        while stops.frame.maxY > pause.frame.minY && swipes < 4 {
            // A short drag inside the scrolling part, just above the buttons:
            // the header has its own drag, which would collapse the panel.
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: window.midX, dy: pause.frame.minY - 30))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -80)))
            swipes += 1
        }
        let last = stops.frame
        XCTAssertTrue(window.contains(last), "The last stat must be inside the window: \(last) in \(window)")
        XCTAssertLessThanOrEqual(last.maxY, pause.frame.minY, "The last stat must clear the buttons: \(last)")
        XCTAssertGreaterThanOrEqual(last.minY, more.frame.maxY,
                                    "The last stat must not be scrolled under the header: \(last) vs \(more.frame)")

        // The hold still finishes it.
        finish.press(forDuration: 1.4)
        let confirm = app.buttons["session.confirmFinish"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Holding Finish must open the confirmation")
        confirm.tap()
        XCTAssertTrue(el("summary.root").waitForExistence(timeout: 10), "Summary must appear after finishing")
        app.buttons["summary.done"].tap()
    }

    /// Relaunches at Accessibility 2 with the -WKTDemo walk and repeats it
    /// from History: a guided walk, the tallest panel.
    private func startGuidedWalkAtAccessibility2() {
        app.terminate()
        app.launchArguments += ["-WKTDemo", "-UIPreferredContentSizeCategoryName",
                                "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))
        openHistoryFromHealth()
        app.buttons["history.more"].firstMatch.tap()
        let repeatItem = app.buttons["Repeat"].firstMatch
        XCTAssertTrue(repeatItem.waitForExistence(timeout: 5), "More must offer Repeat")
        repeatItem.tap()
        let start = app.buttons["history.repeat.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Repeat must open the review sheet")
        start.tap()
        XCTAssertTrue(el("session.root").waitForExistence(timeout: 30),
                      "Start must open the walk screen. \(screenState())")
    }

    // MARK: - 3c. Paused walk at the largest text size

    /// Paused at Accessibility 2, the panel header says "Paused" and there is
    /// no banner row or Resume pill: the wrapped banner and its pill pushed
    /// the panel up to 84 pt over North up on an iPhone 17e, and a one-line
    /// banner still 44 pt (spec fix/large-text-paused-banner). The main
    /// button is the one Resume, and it resumes. Run it on an iPhone 17e as
    /// well as an iPhone 17: the overlap was worst on the small phone.
    func testPausedWalkFitsAtAccessibility2() {
        startGuidedWalkAtAccessibility2()

        let window = app.windows.firstMatch.frame
        let pause = app.buttons["session.pause"]
        let more = app.buttons["session.more"]
        let panel = el("session.panel")
        let controls = ["session.minimize", "session.recenter", "session.orientation"].map { app.buttons[$0] }
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        XCTAssertTrue(more.exists && panel.exists && controls.allSatisfy(\.exists),
                      "The panel, its More button and the three map controls must be there")

        pause.tap()
        let pausedNote = el("session.paused")
        XCTAssertTrue(pausedNote.waitForExistence(timeout: 5), "Pausing must show that the walk is paused")
        XCTAssertEqual(pausedNote.label, "Walk paused", "VoiceOver must still hear the full words")
        XCTAssertEqual(pause.label, "Resume walk", "The main button must offer Resume while paused")
        // Every button that says Resume. A pill in the banner would make two.
        let resumes = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Resume'"))

        func checkPaused(_ state: String) {
            // Animation wait: the panel's spring (0.35 s) must settle before frames are read.
            sleep(1)
            XCTAssertEqual(resumes.count, 1,
                           "Exactly one Resume control (\(state)): \(resumes.allElementsBoundByIndex.map(\.label))")
            for control in controls {
                XCTAssertLessThanOrEqual(control.frame.maxY, panel.frame.minY,
                                         "The paused panel must stay below \(control.identifier) (\(state)): "
                                         + "\(panel.frame) vs \(control.frame)")
            }
            let name = panel.staticTexts["Downtown Loop"]
            XCTAssertTrue(name.exists, "The route name must be in the panel (\(state))")
            XCTAssertTrue(window.contains(name.frame), "The route name must be on screen (\(state)): \(name.frame)")
            XCTAssertGreaterThanOrEqual(name.frame.minY, panel.frame.minY,
                                        "The route name must be inside the panel (\(state)): \(name.frame)")
            XCTAssertLessThanOrEqual(pause.frame.maxY, window.maxY, "Resume below the screen (\(state))")
        }
        checkPaused("collapsed")
        more.tap()
        XCTAssertTrue(el("session.stops").waitForExistence(timeout: 10), "The pulled-up panel must list stops")
        checkPaused("expanded")

        // The one Resume resumes.
        pause.tap()
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Pause walk'"),
                                                object: pause)
        XCTAssertEqual(XCTWaiter().wait(for: [resumed], timeout: 5), .completed,
                       "Resume must resume the walk: the button says \(pause.label)")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pausedNote)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "The paused note must go on resume")
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

    // MARK: - 5a. Routes results at the largest text size

    /// At Accessibility 2 the results panel must fit the window. One child
    /// wider than the screen widens the whole panel, which is how Save and
    /// Share went off-screen at AX5 (F5 audit B1, N6); on `main` before
    /// spec fix/large-text-routes-panel the panel was 401 pt on a 390 pt
    /// iPhone 17e and 404 pt on a 402 pt iPhone 17 (the audit saw 399), all
    /// of it from the weather tile's row: without the tile it was 390. The
    /// WeatherKit attribution is an Apple requirement, so it must be there
    /// and wholly inside the window. Cut-off or one-character lines are not
    /// in the accessibility tree (a label keeps its full text): the
    /// screenshots are the evidence for those. Run it on an iPhone 17e as
    /// well as an iPhone 17: the small phone is the tight one.
    func testRoutesResultsFitAtAccessibility2() throws {
        app.terminate()
        app.launchArguments += ["-WKTDemo", "-UIPreferredContentSizeCategoryName",
                                "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))
        selectTab("Routes")
        let findRoutes = app.buttons["routes.findRoutes"]
        XCTAssertTrue(findRoutes.waitForExistence(timeout: 30))
        findRoutes.tap()

        let panel = el("routes.resultsPanel")
        XCTAssertTrue(panel.waitForExistence(timeout: 60), "Find Routes must list routes from the demo location")
        XCTAssertTrue(app.buttons["routes.routeCard"].firstMatch.waitForExistence(timeout: 10), "No route card listed")
        // GitHub's runner may get no WeatherKit answer; then there is no tile and
        // nothing to attribute. Everywhere else the tile is required.
        let tile = el("routes.weatherTile")
        let hasWeather = tile.waitForExistence(timeout: 30)
        if ProcessInfo.processInfo.environment["WOCKETT_CI"] != "1" {
            XCTAssertTrue(hasWeather, "The demo location must get a weather tile")
        }
        // Animation wait: the panel and the weather tile settle before frames are read.
        sleep(1)

        let window = app.windows.firstMatch.frame
        func inside(_ frame: CGRect) -> Bool { frame.minX >= window.minX && frame.maxX <= window.maxX }
        let panelFrame = panel.frame
        XCTAssertTrue(inside(panelFrame),
                      "The results panel is wider than the window: \(panelFrame) in \(window). "
                      + "Too wide: \(widerThan(window, in: panel))")

        let save = app.buttons["Save route"].firstMatch
        let share = app.buttons["Share route"].firstMatch
        XCTAssertTrue(save.exists && share.exists, "The first route card must offer Save and Share")
        XCTAssertTrue(inside(save.frame), "Save is off-screen: \(save.frame) in \(window)")
        XCTAssertTrue(inside(share.frame), "Share is off-screen: \(share.frame) in \(window)")

        // Without a tile the checks above pass even with the overflow back,
        // so say so instead of reporting a pass that guarded nothing.
        try XCTSkipUnless(hasWeather, "No WeatherKit answer on this runner; the weather row's overflow was not exercised")
        // SwiftUI's Link reaches the accessibility tree as a button on iOS
        // 26.5; either type is accepted. "°" rules out the forecast toggle,
        // whose label starts with the temperature.
        let linkOrButton = NSPredicate(format: "(elementType == %d OR elementType == %d) "
                                       + "AND label CONTAINS 'Weather' AND NOT (label CONTAINS '°')",
                                       XCUIElement.ElementType.link.rawValue,
                                       XCUIElement.ElementType.button.rawValue)
        let attribution = tile.descendants(matching: .any).matching(linkOrButton).firstMatch
        XCTAssertTrue(attribution.exists,
                      "The weather tile must carry Apple's Weather attribution link: \(tile.debugDescription)")
        XCTAssertTrue(inside(attribution.frame), "The attribution is off-screen: \(attribution.frame) in \(window)")
        XCTAssertTrue(inside(tile.frame), "The weather tile is off-screen: \(tile.frame) in \(window)")
    }

    /// The elements under `root` that reach past the window's sides, widest
    /// first, for a failure message that names the culprit.
    private func widerThan(_ window: CGRect, in root: XCUIElement) -> String {
        root.descendants(matching: .any).allElementsBoundByIndex
            .map { ($0.identifier.isEmpty ? $0.label : $0.identifier, $0.elementType.rawValue, $0.frame) }
            .filter { $0.2.maxX > window.maxX || $0.2.minX < window.minX }
            .sorted { $0.2.width > $1.2.width }
            .prefix(8)
            .map { "\($0.0) [type \($0.1)] \($0.2)" }
            .joined(separator: "; ")
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

    /// A walk logged through Log a Past Walk has no route, so its Repeat
    /// review says why and has no Start (spec fix/history-repeat-no-route,
    /// 2026-10-28: Start used to open a walk screen whose timer never moved).
    /// The menu still offers Repeat, so the reason can be found.
    func testHistoryRepeatWithNoRouteExplainsAndHasNoStart() {
        app.terminate()
        app.launchArguments += ["-WKTDemo"]
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))
        openHistoryFromHealth()

        // A past walk, newer than the demo one, so its row is first.
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
        XCTAssertTrue(historyRows.firstMatch.label.contains("Riverside Path"), historyRows.firstMatch.label)

        app.buttons["history.more"].firstMatch.tap()
        let repeatItem = app.buttons["Repeat"].firstMatch
        XCTAssertTrue(repeatItem.waitForExistence(timeout: 5), "More must still offer Repeat")
        repeatItem.tap()
        let reason = el("history.repeat.reason")
        XCTAssertTrue(reason.waitForExistence(timeout: 10), "The review must say why it can't repeat")
        XCTAssertEqual(reason.label,
                       "This walk has no route to follow, so it can't be repeated. Start a new one from Home.")
        XCTAssertFalse(app.buttons["history.repeat.start"].exists, "A walk with no route must have no Start")

        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(historyRows.firstMatch.waitForExistence(timeout: 10), "Cancel must return to the list")
        XCTAssertFalse(app.buttons["accessory.miniTile"].waitForExistence(timeout: 2),
                       "Nothing may begin from a review with no Start")
    }

    // MARK: - 6b. History: Repeat review at the largest text size

    /// At Accessibility 2 the Repeat review must open with Start and Cancel
    /// inside the window, without a drag. At its medium height Start sat
    /// half below the screen on an iPhone 17e (maxY 858 on an 844 pt window)
    /// and Cancel off it on both phones (F5 audit N4; spec
    /// fix/large-text-repeat-sheet), so at accessibility sizes it opens at
    /// .large. Run it on an iPhone 17e: the 17 already fit Start.
    func testRepeatSheetFitsAtAccessibility2() {
        app.terminate()
        app.launchArguments += ["-WKTDemo", "-UIPreferredContentSizeCategoryName",
                                "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))
        openHistoryFromHealth()
        app.buttons["history.more"].firstMatch.tap()
        let repeatItem = app.buttons["Repeat"].firstMatch
        XCTAssertTrue(repeatItem.waitForExistence(timeout: 5), "More must offer Repeat")
        repeatItem.tap()
        let start = app.buttons["history.repeat.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Repeat must open the review sheet")
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.exists, "The review must offer Cancel")
        // Animation wait: the sheet settles at its detent before frames are read.
        sleep(1)

        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(start.frame.maxY, window.maxY,
                                 "Start is below the screen: \(start.frame) in \(window)")
        XCTAssertTrue(window.contains(start.frame), "Start is off-screen: \(start.frame) in \(window)")
        XCTAssertTrue(window.contains(cancel.frame), "Cancel is off-screen: \(cancel.frame) in \(window)")
    }

    // MARK: - 6c. Home: Start first, then Recent activity

    /// Home opens on Start, above the step hero, and lists the newest saved
    /// activities under it (spec fix/home-start-first). A past walk logged
    /// now is the first Recent row, which opens its summary, and All
    /// activities opens History. -WKTDemo seeds the one finished walk.
    func testHomeStartsFirstAndListsRecentActivity() {
        app.terminate()
        app.launchArguments += ["-WKTDemo"]
        app.launch()
        let hero = el("home.statCard")
        let start = app.buttons["home.start"]
        XCTAssertTrue(hero.waitForExistence(timeout: 30))
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertLessThan(start.frame.minY, hero.frame.minY, "Start must sit above the step hero")
        let recent = el("home.recent")
        XCTAssertTrue(recent.waitForExistence(timeout: 10), "With a saved walk, Home must list Recent activity")
        XCTAssertLessThan(recent.frame.minY, hero.frame.minY, "Recent activity must sit above the step hero")

        // Log a past walk, newer than the demo one.
        openHistoryFromHealth()
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

        // Scrolling Health to reach Activity History collapses the tab bar to
        // the selected tab (iOS 26); tapping that expands it again.
        if !tab("Home").waitForExistence(timeout: 3) { tab("Health").tap() }
        selectTab("Home")
        let rows = app.buttons.matching(identifier: "home.recent.row")
        let two = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: rows)
        XCTAssertEqual(XCTWaiter().wait(for: [two], timeout: 10), .completed,
                       "Home must list both walks, saw \(rows.count)")
        let first = rows.element(boundBy: 0)
        let riversideFirst = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH 'Riverside Path'"), object: first)
        XCTAssertEqual(XCTWaiter().wait(for: [riversideFirst], timeout: 10), .completed,
                       "The walk just logged must be first: \(rows.allElementsBoundByIndex.map { "\($0.label) @\($0.frame.minY)" })")
        first.tap()
        XCTAssertTrue(el("summary.root").waitForExistence(timeout: 10), "A Recent row must open its summary")
        let done = app.buttons["summary.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        let summaryGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == NO"),
                                                    object: el("summary.root"))
        wait(for: [summaryGone], timeout: 15)

        let all = app.buttons["home.recent.all"]
        XCTAssertTrue(all.waitForExistence(timeout: 10), "Recent activity must offer All activities")
        all.tap()
        XCTAssertTrue(app.navigationBars["Activity History"].waitForExistence(timeout: 15),
                      "All activities must open History")
        XCTAssertFalse(hero.exists, "History must be pushed over Home")
        expectHistoryRows(2, "History must list both walks")

        // Delete both: back on Home, no Recent activity section at all.
        for remaining in [1, 0] {
            historyRows.firstMatch.swipeLeft()
            let delete = app.buttons["Delete"].firstMatch
            XCTAssertTrue(delete.waitForExistence(timeout: 5), "A row must offer Delete on a swipe")
            delete.tap()
            expectHistoryRows(remaining, "Delete must remove the row")
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(hero.waitForExistence(timeout: 10), "Back must return to Home")
        XCTAssertFalse(recent.exists, "With nothing saved, Home must show no Recent activity")
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

    // MARK: - 7a. Location off

    /// With location denied, Routes explains it before any search and offers
    /// only what can work: Open Settings and Plan on the map, not Find Routes
    /// or the nearby actions (spec fix/route-location-recovery, criteria 1
    /// and 3). `-WKTLocationOff` makes RouteManager report a denial even
    /// under -WKTUITest. Open Settings is never tapped: it leaves the app.
    func testRoutesExplainLocationOffBeforeAnySearch() {
        app.terminate()
        app.launchArguments = ["-WKTUITest", "-WKTLocationOff"]
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))
        selectTab("Routes")

        let findRoutes = app.buttons["routes.findRoutes"]
        XCTAssertTrue(findRoutes.waitForExistence(timeout: 30))
        XCTAssertFalse(findRoutes.isEnabled, "Find Routes must be disabled with location off")
        let reason = "Location is off for Wockett, so routes can't start from where you are."
        XCTAssertTrue(app.staticTexts[reason].exists, "The reason must show before any search")
        XCTAssertTrue(app.buttons["routes.openSettings"].exists, "Routes must offer Open Settings")
        XCTAssertTrue(app.buttons["routes.planOnMap"].exists, "Routes must offer Plan on the map")
        XCTAssertTrue(el("routes.locationNote").exists, "Routes must say what works without location")
        // "Try nearby loops" shows only after a failed search, which can't
        // happen here: RouteLocationStateTests covers its rule.
        for title in ["Search a place", "Nearby places"] {
            XCTAssertFalse(app.buttons[title].exists, "\(title) needs a location and must be hidden")
        }

        // Each panel's Plan on the map opens the builder: Routes here, Trails below.
        app.buttons["routes.planOnMap"].tap()
        let builder = app.navigationBars["Build Route"]
        XCTAssertTrue(builder.waitForExistence(timeout: 15), "Routes' Plan on the map must open the route builder")
        builder.buttons.firstMatch.tap()
        XCTAssertTrue(findRoutes.waitForExistence(timeout: 15), "Back must return to Routes")

        let picker = el("routes.modePicker")
        picker.buttons["Trails"].tap()
        XCTAssertTrue(el("routes.trailsPanel").waitForExistence(timeout: 15))
        // The Routes panel leaves with an animation; until it has gone, its
        // reason and buttons would satisfy the Trails assertions below.
        XCTAssertTrue(findRoutes.waitForNonExistence(timeout: 10), "The Routes panel must give way to Trails")
        XCTAssertTrue(el("routes.locationNote").exists, "Trails must say what works without location")
        XCTAssertTrue(app.staticTexts[reason].waitForExistence(timeout: 10), "Trails must give the same reason")
        XCTAssertTrue(app.buttons["routes.openSettings"].exists, "Trails must offer Open Settings")
        XCTAssertFalse(app.buttons["routes.trailCard"].firstMatch.exists, "No trails can be listed without a location")

        app.buttons["routes.planOnMap"].tap()
        XCTAssertTrue(builder.waitForExistence(timeout: 15), "Trails' Plan on the map must open the route builder")
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

    // MARK: - 8b. Community You card at the largest text size

    /// At Accessibility 2 the You card's two buttons stack, each the full
    /// width: side by side they read "Start a c…" / "Share a r…" (F5 audit
    /// B6, spec fix/large-text-buttons). Both must be inside the window and
    /// not overlap. Those two alone passed against the side-by-side row,
    /// which also fits and does not overlap; the cut-off titles are not in
    /// the accessibility tree (a label keeps its full text), so the stacked
    /// check is what fails when the row comes back. Screenshots are the
    /// evidence for the titles themselves.
    func testCommunityYouCardButtonsStackAtAccessibility2() {
        app.terminate()
        app.launchArguments += ["-WKTDemo", "-UIPreferredContentSizeCategoryName",
                                "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))
        selectTab("Community")
        XCTAssertTrue(el("community.root").waitForExistence(timeout: 30))

        let start = app.buttons["Start a challenge"].firstMatch
        let share = app.buttons["Share a route"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15), "Start a challenge missing from the You card")
        XCTAssertTrue(share.waitForExistence(timeout: 5), "Share a route missing from the You card")
        var swipes = 0
        while !(start.isHittable && share.isHittable) && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        // Animation wait: the scroll must settle before frames are read.
        sleep(1)

        let window = app.windows.firstMatch.frame
        let first = start.frame
        let second = share.frame
        for (name, frame) in [("Start a challenge", first), ("Share a route", second)] {
            XCTAssertLessThanOrEqual(frame.maxX, window.maxX, "\(name) past the right edge: \(frame) in \(window)")
            XCTAssertGreaterThanOrEqual(frame.minX, window.minX, "\(name) past the left edge: \(frame)")
        }
        XCTAssertFalse(first.intersects(second), "The buttons overlap: \(first) and \(second)")
        XCTAssertGreaterThanOrEqual(second.minY, first.maxY,
                                    "Share a route must sit below Start a challenge: \(first) and \(second)")
    }

    // MARK: - 8b. Stat rows at Accessibility 2

    /// At Accessibility 2 a row of three or four stats goes two to a row
    /// (spec fix/large-text-stat-rows): a third of the width broke the
    /// summary's "Distanc / e", a quarter cut History's "This w…" (F5 audit
    /// H3, H4). Frames only, since a cut-off label keeps its full text in the
    /// accessibility tree: the stats' centres take exactly two values, and
    /// every stat is inside the window. Run on an iPhone 17e or 17.
    func testStatRowsUseTwoColumnsAtAccessibility2() {
        app.terminate()
        app.launchArguments += ["-WKTDemo", "-UIPreferredContentSizeCategoryName",
                                "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))

        // History's header: four cells, each read as "value, label".
        openHistoryFromHealth()
        let header = el("history.header")
        XCTAssertTrue(header.waitForExistence(timeout: 10), "History must show its header")
        let cellLabels = NSPredicate(format: "label MATCHES %@", ".+, (Activity|Activities|Distance|Time|This week)")
        let cells = app.staticTexts.matching(cellLabels).allElementsBoundByIndex
            .filter { header.frame.intersects($0.frame) }
        expectTwoColumns(cells, count: 4, name: "History's header cells")

        // The just-finished summary: Distance, Time and Steps tiles.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        if !tab("Home").waitForExistence(timeout: 3) { tab("Health").tap() }
        selectTab("Home")
        startWalkFromHome()
        let finish = el("session.finish")
        XCTAssertTrue(finish.waitForExistence(timeout: 30), "The walk screen must offer Finish")
        finish.press(forDuration: 1.4)
        let confirm = app.buttons["session.confirmFinish"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Holding Finish must open the confirmation")
        confirm.tap()
        let summary = el("summary.root")
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "Finishing must open the summary")
        let tileLabels = NSPredicate(format: "label MATCHES %@", ".+ (Distance|Time|Steps)(, .*)?")
        let tiles = summary.otherElements.matching(tileLabels)
        let three = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 3"), object: tiles)
        XCTAssertEqual(XCTWaiter().wait(for: [three], timeout: 10), .completed,
                       "The summary must show three tiles, saw \(tiles.allElementsBoundByIndex.map(\.label))")
        expectTwoColumns(tiles.allElementsBoundByIndex, count: 3, name: "The summary's tiles")
    }

    /// `count` stats, in two columns, each inside the window. A column is
    /// told by its centre, not its left edge: History's cells are centred
    /// text, whose frames start wherever their own width puts them.
    private func expectTwoColumns(_ stats: [XCUIElement], count: Int, name: String) {
        let window = app.windows.firstMatch.frame
        let frames = stats.map(\.frame)
        XCTAssertEqual(frames.count, count, "\(name): expected \(count), saw \(stats.map(\.label))")
        let centres = Set(frames.map { Int($0.midX.rounded()) })
        XCTAssertEqual(centres.count, 2, "\(name) must sit in two columns: \(frames)")
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.minX, window.minX, "\(name) past the left edge: \(frame)")
            XCTAssertLessThanOrEqual(frame.maxX, window.maxX, "\(name) past the right edge: \(frame) in \(window)")
        }
    }

    // MARK: - 8c. Names in narrow rows at Accessibility 2

    /// At Accessibility 2 Home's two Routes cards stack, and a trail's
    /// Official chip sits under its name (spec fix/large-text-names): side by
    /// side, they cut the names to "Find a Ro…" and "Little R…" (F5 audit
    /// H8, H10). Frames only, since a cut-off name keeps its full text in the
    /// accessibility tree; screenshots are the evidence for the text itself.
    func testNamesStackAtAccessibility2() {
        app.terminate()
        app.launchArguments += ["-WKTDemo", "-UIPreferredContentSizeCategoryName",
                                "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))
        let window = app.windows.firstMatch.frame

        // Home's Routes cards: My Routes below Find a Route, both full width.
        let find = app.buttons["home.findRoute"]
        let mine = app.buttons["home.myRoutes"]
        XCTAssertTrue(find.waitForExistence(timeout: 10), "Home must show Find a Route")
        XCTAssertTrue(mine.waitForExistence(timeout: 5), "Home must show My Routes")
        XCTAssertGreaterThanOrEqual(mine.frame.minY, find.frame.maxY,
                                    "My Routes must sit below Find a Route: \(find.frame) and \(mine.frame)")
        for card in [find, mine] {
            XCTAssertLessThanOrEqual(card.frame.maxX, window.maxX, "Past the right edge: \(card.frame) in \(window)")
        }

        // Trails near you needs a location: Routes asks for the demo one.
        selectTab("Routes")
        XCTAssertTrue(app.buttons["routes.findRoutes"].waitForExistence(timeout: 30))
        selectTab("Community")
        XCTAssertTrue(el("community.root").waitForExistence(timeout: 30))
        let row = app.buttons.matching(NSPredicate(format: "label ENDSWITH ', Official'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Community must list an official trail near the demo location")
        let name = row.staticTexts.element(boundBy: 0)
        let chip = row.staticTexts["Official"]
        XCTAssertTrue(chip.exists, "The trail row must show its Official chip")
        XCTAssertNotEqual(name.label, "Official")
        XCTAssertTrue(row.label.hasPrefix(name.label + ","), "The first text must be the trail's name: \(name.label)")
        // Left edge first: beside the name, the chip sits at the row's
        // trailing edge whatever the name's length. Below alone could pass
        // beside a short name whose detail wraps to many lines.
        XCTAssertEqual(chip.frame.minX, name.frame.minX, accuracy: 2,
                       "Official must start under the name: \(name.frame) and \(chip.frame)")
        XCTAssertGreaterThanOrEqual(chip.frame.minY, name.frame.maxY,
                                    "Official must sit below the name: \(name.frame) and \(chip.frame)")
        XCTAssertLessThanOrEqual(row.frame.maxX, window.maxX, "Trail row past the right edge: \(row.frame)")
    }

    // MARK: - 8d. Chips and rows at Accessibility 2

    /// At Accessibility 2 the Insights comparison chip wraps instead of
    /// cutting to "Nothing last week to…" (F5 audit H7), and a History row
    /// keeps "0.7 mi" and "12m 58s" each on one line instead of splitting
    /// value from unit (C5; spec fix/large-text-chips-rows). Frames only: a
    /// cut-off text keeps its full label in the accessibility tree, so the
    /// screenshots are the evidence for the text itself. One line of the
    /// chip is 30 pt high at AX2, and of a row label 28 pt; the row's title
    /// is one line by rule, so it is the yardstick for "one line".
    func testChipsAndRowsWrapAtAccessibility2() {
        app.terminate()
        app.launchArguments += ["-WKTDemo", "-UIPreferredContentSizeCategoryName",
                                "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))
        let window = app.windows.firstMatch.frame

        // History: the demo walk's distance and time, each on one line.
        openHistoryFromHealth()
        let row = app.buttons["history.row"].firstMatch
        let title = row.staticTexts.element(boundBy: 0)
        XCTAssertTrue(row.label.hasPrefix(title.label + ","), "The row's first text must be its title: \(title.label)")
        let values = row.label.components(separatedBy: ", ").suffix(2)
        XCTAssertEqual(values.count, 2, "The row must end with distance and time: \(row.label)")
        for value in values {
            let label = row.staticTexts[value]
            XCTAssertTrue(label.exists, "History's row must show \(value)")
            // A title laid out but not drawn has a sliver of a frame.
            XCTAssertGreaterThan(label.frame.height, title.frame.height * 0.6,
                                 "\(value) must be drawn at full height: \(label.frame)")
            XCTAssertLessThan(label.frame.height, title.frame.height * 1.4,
                              "\(value) must sit on one line: \(label.frame) against the title's \(title.frame)")
            XCTAssertLessThanOrEqual(label.frame.maxX, window.maxX, "\(value) past the right edge: \(label.frame)")
        }

        // Insights: the comparison chip wraps to more than one line.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(el("health.root").waitForExistence(timeout: 10))
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Insights'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Insights missing from Health")
        var swipes = 0
        while !card.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        card.tap()
        // The demo walk is two hours old, so for the first two hours of a
        // week it counts as last week's and the chip says the shorter
        // "Down 100% vs last week", which may fit one line.
        let chip = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH 'Nothing last week' OR label ENDSWITH 'vs last week'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "Insights must compare with last week")
        if chip.label.hasPrefix("Nothing") {
            XCTAssertGreaterThan(chip.frame.height, 45, "The chip must wrap to two lines: \(chip.frame)")
        } else {
            XCTContext.runActivity(named: "Wrap check skipped: the chip reads \"\(chip.label)\"") { _ in }
        }
        XCTAssertLessThanOrEqual(chip.frame.maxX, window.maxX, "The chip past the right edge: \(chip.frame)")

        // The daily chart sums itself up for VoiceOver (spec
        // fix/large-text-leftovers, item 1): its total, and the best day when
        // there is one (none in a week's first two hours, as above).
        let chart = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Distance by day this week'")).firstMatch
        XCTAssertTrue(chart.exists, "Insights must show the daily chart")
        XCTAssertTrue(chart.label.contains(" in total"), "The chart must sum itself up: \(chart.label)")
    }

    // MARK: - 8e. Share Route sheet at Accessibility 2

    /// At Accessibility 2 the Share Route sheet's tiles go two to a row in a
    /// form that scrolls (spec fix/large-text-leftovers). On `main` before
    /// it, the tiles sat three across ("Distan…" on an iPhone 17e) in a form
    /// that ran past the sheet and up under Cancel. Frames only: a cut-off
    /// title keeps its full label in the accessibility tree, so screenshots
    /// are the evidence for the text itself. The weather and Share
    /// Achievement sheets have no UI test: under -WKTUITest Home never
    /// fetches the weather, and the badge celebration that opens Share
    /// Achievement is suppressed.
    func testShareRouteSheetFitsAtAccessibility2() {
        app.terminate()
        app.launchArguments += ["-WKTDemo", "-UIPreferredContentSizeCategoryName",
                                "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))

        // Share Route, from the first route card.
        selectTab("Routes")
        let findRoutes = app.buttons["routes.findRoutes"]
        XCTAssertTrue(findRoutes.waitForExistence(timeout: 30))
        findRoutes.tap()
        XCTAssertTrue(el("routes.resultsPanel").waitForExistence(timeout: 60), "Find Routes must list routes")
        let share = app.buttons["Share route"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10), "The first route card must offer Share")
        // Animation wait: the results panel settles before the tap.
        sleep(2)
        forceTap(share)
        let sheetTitle = app.navigationBars["Share Route"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 10), "Share must open the Share Route sheet")
        let tileLabels = NSPredicate(format: "label MATCHES %@", ".+ (Distance|Time|Steps)(, .*)?")
        let tiles = app.otherElements.matching(tileLabels).allElementsBoundByIndex
            .filter { $0.frame.minY >= sheetTitle.frame.maxY }
        // Tiles under the sheet's title only: three across, the form ran up
        // under Cancel on an iPhone 17e, so fewer than three were counted.
        expectTwoColumns(tiles, count: 3, name: "Share Route's tiles")
        // Not asserted: that Post scrolls into view. With the demo route it
        // was on screen on main as well, so the check could not fail.
    }

    // MARK: - 8h. Share review: everything above Publish

    /// Both Share buttons open one review (spec fix/share-review-sheet): the
    /// home warning, the map of what is published, Hide start and finish and
    /// the shared length all sit above Publish, and hiding is on when no
    /// choice was ever stored. Publish is never tapped, so nothing is posted.
    /// The map is not checked: it needs the privacy offset, which a simulator
    /// with no iCloud account (CI) never gets.
    func testShareReviewPutsEverythingAbovePublish() {
        app.terminate()
        app.launchArguments += ["-WKTDemo"]
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))

        // A saved route: My Routes, the seeded Capitol Loop, Share Route.
        let mine = app.buttons["home.myRoutes"]
        XCTAssertTrue(mine.waitForExistence(timeout: 15), "Home must show My Routes")
        var swipes = 0
        while mine.frame.maxY > app.windows.firstMatch.frame.maxY - 120 && swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        forceTap(mine)
        XCTAssertTrue(app.navigationBars["Saved Items"].waitForExistence(timeout: 10), "My Routes must open")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Capitol Loop'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The demo's saved route must be listed")
        row.tap()
        let share = app.buttons["Share Route"]
        XCTAssertTrue(share.waitForExistence(timeout: 10), "The route detail must offer Share Route")
        swipes = 0
        while !share.isHittable && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        share.tap()
        expectReviewAbovePublish(from: "a saved route")
        let name = el("routes.shareName")
        XCTAssertTrue(name.exists, "The review from a saved route must show its name")
        XCTAssertLessThanOrEqual(name.frame.maxY, el("routes.sharePublish").frame.minY,
                                 "The route name that goes public must show above Publish")

        // A suggested route: Find Routes, the first card's Share. Relaunched:
        // the route detail, pushed from Home, hides the tab bar.
        app.navigationBars["Share Route"].buttons["Cancel"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))
        selectTab("Routes")
        let findRoutes = app.buttons["routes.findRoutes"]
        XCTAssertTrue(findRoutes.waitForExistence(timeout: 30))
        findRoutes.tap()
        XCTAssertTrue(el("routes.resultsPanel").waitForExistence(timeout: 60), "Find Routes must list routes")
        let cardShare = app.buttons["Share route"].firstMatch
        XCTAssertTrue(cardShare.waitForExistence(timeout: 10), "The first route card must offer Share")
        sleep(2)  // Animation wait: the results panel settles before the tap.
        forceTap(cardShare)
        expectReviewAbovePublish(from: "a suggested route")
    }

    /// The review's parts, each wholly above Publish, in the sheet just opened.
    private func expectReviewAbovePublish(from entry: String) {
        XCTAssertTrue(app.navigationBars["Share Route"].waitForExistence(timeout: 10),
                      "Share from \(entry) must open the review")
        let publish = el("routes.sharePublish")
        XCTAssertTrue(publish.waitForExistence(timeout: 10), "The review from \(entry) must have Publish")
        XCTAssertTrue(app.staticTexts["Anyone using Wockett can see this route"].exists,
                      "The review from \(entry) must say who can see it")
        for id in ["routes.shareHomeWarning", "routes.shareHideEnds", "routes.sharePrivacyNote"] {
            let part = el(id)
            XCTAssertTrue(part.exists, "\(id) is missing from the review from \(entry)")
            XCTAssertLessThanOrEqual(part.frame.maxY, publish.frame.minY,
                                     "\(id) must sit above Publish (from \(entry)): \(part.frame) vs \(publish.frame)")
        }
        // Only true with no stored choice, which a UI-test simulator never has.
        XCTAssertEqual(app.switches["routes.shareHideEnds"].value as? String, "1",
                       "Hide start and finish must default to on (from \(entry))")
    }

    // MARK: - 8f. Busy buttons at Accessibility 2

    /// A button keeps its size while it works (spec fix/large-text-leftovers,
    /// item 2). On `main` before it, at Accessibility 2 on an iPhone 17e,
    /// Share Route's Post went from 90 pt to a 56 pt spinner and Create
    /// Challenge from 58.7 to 56 pt, so everything below jumped on tap.
    /// `-WKTHoldBusy` (UI tests only) shows every `WktBusyLabel` busy; the
    /// test measures each button idle, then held busy, and compares heights.
    func testBusyButtonsKeepTheirSizeAtAccessibility2() {
        let idle = busyButtonHeights(held: false)
        let busy = busyButtonHeights(held: true)
        for name in ["Find Routes", "Post", "Create Challenge"] {
            guard let idleHeight = idle[name], let busyHeight = busy[name] else {
                XCTFail("\(name) was not measured: idle \(idle), busy \(busy)")
                continue
            }
            XCTAssertEqual(busyHeight, idleHeight, accuracy: 0.5,
                           "\(name) must keep its idle height while busy")
        }
        // Without these the comparison could be two 56 pt minimums agreeing.
        // Find Routes has no such guard: it is 56 pt idle and busy at
        // Accessibility 2, so its comparison only shows the button is still
        // there and tappable while held busy. Sync, Share Route on a saved
        // route, Share Achievement and the walk card's Share are covered by
        // WktBusyLabelSizeTests (the shared view) only.
        XCTAssertGreaterThan(idle["Post"] ?? 0, 60, "Post & Save to My Routes wraps at Accessibility 2")
        XCTAssertGreaterThan(idle["Create Challenge"] ?? 0, 56.5, "Create Challenge outgrows 56 pt at Accessibility 2")
    }

    /// The three buttons' heights at Accessibility 2, idle or held busy.
    private func busyButtonHeights(held: Bool) -> [String: CGFloat] {
        app.terminate()
        app.launchArguments = ["-WKTUITest", "-WKTDemo", "-UIPreferredContentSizeCategoryName",
                               "UICTContentSizeCategoryAccessibilityL"] + (held ? ["-WKTHoldBusy"] : [])
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))
        var heights: [String: CGFloat] = [:]

        selectTab("Routes")
        let findRoutes = app.buttons["routes.findRoutes"]
        XCTAssertTrue(findRoutes.waitForExistence(timeout: 30))
        heights["Find Routes"] = findRoutes.frame.height
        // Held busy shows only the label; the button still finds routes.
        forceTap(findRoutes)
        XCTAssertTrue(el("routes.resultsPanel").waitForExistence(timeout: 60), "Find Routes must list routes")
        let share = app.buttons["Share route"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10), "The first route card must offer Share")
        sleep(2)  // Animation wait: the results panel settles before the tap.
        forceTap(share)
        let sheetTitle = app.navigationBars["Share Route"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 10), "Share must open the Share Route sheet")
        let post = el("routes.sharePublish")
        XCTAssertTrue(post.waitForExistence(timeout: 5), "The sheet must have Post")
        heights["Post"] = post.frame.height
        sheetTitle.buttons["Cancel"].tap()
        XCTAssertTrue(sheetTitle.waitForNonExistence(timeout: 10), "Cancel must close the sheet")

        selectTab("Community")
        XCTAssertTrue(el("community.root").waitForExistence(timeout: 30))
        let start = app.buttons["Start a challenge"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), "Community must offer Start a challenge")
        var swipes = 0
        while !start.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        start.tap()
        let create = app.buttons["challenge.create.submit"]
        XCTAssertTrue(create.waitForExistence(timeout: 15), "Start a challenge must open the form")
        heights["Create Challenge"] = create.frame.height
        return heights
    }

    // MARK: - 8g. Round 2 at Accessibility 2

    private func launchAtAccessibility2() {
        app.terminate()
        app.launchArguments = ["-WKTUITest", "-WKTDemo", "-UIPreferredContentSizeCategoryName",
                               "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30))
    }

    /// Spec fix/large-text-round2, items 1 and 3. Frames only: a cut-off
    /// title keeps its full label in the accessibility tree, so screenshots
    /// are the evidence for the text itself. On `main` before it, on an
    /// iPhone 17e: the community card's Start Walk sat beside the Wockett
    /// count ("Start…"), "9.1 mi" was two lines (56.7 pt against the 28.3 pt
    /// "by" line), and the elevation plot was 7 pt tall (48 pt at default).
    func testElevationChartAtAccessibility2() throws {
        launchAtAccessibility2()

        // Item 3: the route detail's elevation chart. Each data mark's frame
        // is the plot's full height, so a mark measures the plot.
        selectTab("Routes")
        let findRoutes = app.buttons["routes.findRoutes"]
        XCTAssertTrue(findRoutes.waitForExistence(timeout: 30))
        findRoutes.tap()
        XCTAssertTrue(el("routes.resultsPanel").waitForExistence(timeout: 60), "Find Routes must list routes")
        let card = app.buttons["routes.routeCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        sleep(2)  // Animation wait: the results panel settles before the tap.
        forceTap(card)
        let mark = app.otherElements.matching(NSPredicate(format: "label MATCHES %@", "[0-9.]+ to [0-9.]+")).firstMatch
        // The profile comes from a public elevation API: when it is down or
        // rate-limited the card says so, and the test is skipped.
        if !mark.waitForExistence(timeout: 15), app.staticTexts["Elevation data unavailable"].exists {
            throw XCTSkip("The elevation service did not answer")
        }
        XCTAssertTrue(mark.exists, "The route detail must show the elevation chart")
        XCTAssertGreaterThan(mark.frame.height, 48, "The elevation plot must be taller than at default: \(mark.frame)")
    }

    /// Item 1, apart from the elevation check so a skip there never hides it.
    func testCommunityRouteCardAtAccessibility2() {
        launchAtAccessibility2()
        let window = app.windows.firstMatch.frame

        // Community → Top community routes → See all.
        selectTab("Community")
        XCTAssertTrue(el("community.root").waitForExistence(timeout: 30))
        let heading = app.staticTexts["Top community routes"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 30), "Community must list top community routes")
        var swipes = 0
        while !heading.isHittable && swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        let seeAll = app.buttons.matching(NSPredicate(format: "label == 'See all'")).allElementsBoundByIndex
            .first { $0.isHittable && $0.frame.minY > heading.frame.minY - 60 }
        XCTAssertNotNil(seeAll, "Top community routes must offer See all")
        seeAll?.tap()
        let start = app.buttons.matching(NSPredicate(format: "label == 'Start Walk'")).firstMatch
        let wocketts = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Wocketts' OR label ENDSWITH 'Wockett'")).firstMatch
        let author = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'by '")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15), "A community route card must offer Start Walk")
        XCTAssertTrue(wocketts.exists && author.exists, "The card must show its Wockett count and author")
        XCTAssertGreaterThanOrEqual(start.frame.minY, wocketts.frame.maxY,
                                    "Start Walk must sit under the Wockett count: \(wocketts.frame) and \(start.frame)")
        XCTAssertLessThanOrEqual(start.frame.maxX, window.maxX, "Start Walk past the right edge: \(start.frame)")
        let distance = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9.]+ (mi|km)")).firstMatch
        XCTAssertTrue(distance.exists, "The card must show its distance")
        XCTAssertLessThan(distance.frame.height, author.frame.height * 1.4,
                          "The distance must sit on one line: \(distance.frame) against \(author.frame)")
    }

    /// Spec fix/large-text-round2, items 4 and 6. Frames only, as above.
    /// On `main` before it, on an iPhone 17e: the badges sat three across
    /// ("Maratho / ner") and the four Duration chips sat in one row.
    func testBadgesAndChipsAtAccessibility2() {
        launchAtAccessibility2()

        // Item 4: Distance badges in two columns. Not asserted: that a name
        // keeps its words whole. With two columns every name fits a line on
        // an iPhone 17e, so a check could not fail; the rule is pinned in
        // WktNameLayoutTests and the screenshots are the evidence.
        selectTab("Community")
        XCTAssertTrue(el("community.root").waitForExistence(timeout: 30))
        let allBadges = app.buttons["All badges"].firstMatch
        XCTAssertTrue(allBadges.waitForExistence(timeout: 15), "Community must offer All badges")
        var swipes = 0
        while !allBadges.isHittable && swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        allBadges.tap()
        let names = ["First Steps", "Warming Up", "On a Roll", "Century Walk"].map { app.staticTexts[$0].firstMatch }
        // The grid is lazy: its tiles exist only once scrolled to.
        XCTAssertTrue(app.navigationBars["Streaks & Badges"].waitForExistence(timeout: 10))
        swipes = 0
        while !(names[3].exists && names[3].isHittable) && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        expectTwoColumns(names, count: 4, name: "The Distance badges")

        // Item 6: New Challenge's Duration chips, two to a row.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let startChallenge = app.buttons["Start a challenge"].firstMatch
        XCTAssertTrue(startChallenge.waitForExistence(timeout: 15), "Community must offer Start a challenge")
        swipes = 0
        while !startChallenge.isHittable && swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        startChallenge.tap()
        XCTAssertTrue(app.buttons["challenge.create.submit"].waitForExistence(timeout: 15), "The form must open")
        let chips = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ days")).allElementsBoundByIndex
        expectTwoColumns(chips, count: 4, name: "The Duration chips")
    }

    /// Spec fix/large-text-round2, item 2. On `main` before it, on an iPhone
    /// 17e, Download sat beside the state's name and both broke mid-word.
    func testTrailRegionsStackAtAccessibility2() throws {
        launchAtAccessibility2()
        let window = app.windows.firstMatch.frame
        selectTab("Settings")
        XCTAssertTrue(el("settings.root").waitForExistence(timeout: 30))
        let regions = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Trail Regions'")).firstMatch
        var swipes = 0
        while !(regions.exists && regions.isHittable) && swipes < 25 {
            app.swipeUp()
            swipes += 1
        }
        regions.tap()
        let download = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download ' OR label BEGINSWITH 'Update '")).firstMatch
        // The regions come from CloudKit's public database: with no network
        // the screen lists none, and the test is skipped.
        guard download.waitForExistence(timeout: 30) else {
            throw XCTSkip("Trail Regions listed no region")
        }
        let state = String(download.label.split(separator: " ", maxSplits: 1)[1])
        let name = app.staticTexts[state].firstMatch
        XCTAssertTrue(name.exists, "Trail Regions must show \(state)")
        XCTAssertGreaterThanOrEqual(download.frame.minY, name.frame.maxY,
                                    "\(download.label) must sit under the name: \(name.frame) and \(download.frame)")
        XCTAssertLessThanOrEqual(download.frame.maxX, window.maxX, "Download past the right edge: \(download.frame)")
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
