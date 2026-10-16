import XCTest

/// One UI test per batch-1 how-to video (spec feat/how-to-video-recordings).
///
/// These tests only drive the screens. A separate script starts
/// `simctl io booted recordVideo` around each one and selects it with
/// `-only-testing:WockettUITests/HowToVideoTests/test_video_<nn>_<slug>`;
/// nothing here records, and nothing here calls `simctl`.
///
/// They are skipped unless `WKT_HOW_TO_RECORD=1` reaches the test runner
/// (pass `TEST_RUNNER_WKT_HOW_TO_RECORD=1` to xcodebuild), so CI and an
/// ordinary `scripts/test.sh` run report them as skipped, never as passed.
///
/// The app launches with exactly `["-WKTDemo"]`: the seeded walk and route,
/// the fixed downtown-Raleigh location for Find Routes and Trails, and no
/// permission sheet, banner, badge cover or resume prompt over Home. Not the
/// smoke tests' launch helper, which adds `-WKTUITest` and with it no splash,
/// no animations and the Times Square stub routes.
///
/// Every step first waits for the screen it is about to act on, by
/// identifier or visible title, so a wrong screen fails at that wait,
/// before the script has recorded anything worth keeping.
final class HowToVideoTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WKT_HOW_TO_RECORD"] == "1",
                          "How-to recording test: runs only with WKT_HOW_TO_RECORD=1 "
                          + "(xcodebuild TEST_RUNNER_WKT_HOW_TO_RECORD=1), so CI never runs it")
        continueAfterFailure = false
        // Permission alerts only (location, the first time a walk starts on a
        // fresh simulator). A notification banner also arrives here; tapping
        // one that has slid away fails the test at the tap, so let it be.
        addUIInterruptionMonitor(withDescription: "Permission alert") { alert in
            guard alert.elementType == .alert else { return false }
            for title in ["Allow While Using App", "Allow Once", "Allow", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        app = XCUIApplication()
        app.launchArguments = ["-WKTDemo"]
        app.launch()
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    // MARK: - Helpers

    /// An element by identifier, whatever type SwiftUI surfaces it as.
    private func el(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Tab bar buttons by visible title: iOS 26 drops identifiers set on `Tab`.
    private func selectTab(_ title: String) {
        let button = app.tabBars.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "The \(title) tab is missing")
        button.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: button)
        XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 10), .completed,
                       "The \(title) tab did not select")
    }

    /// Custom-styled buttons (BounceButtonStyle) can report not hittable while
    /// being tappable; the smoke tests tap these by coordinate too.
    private func forceTap(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// The location prompt a fresh simulator shows when the first walk starts
    /// sits in springboard. The interruption monitor only runs on the next
    /// interaction, and a test that next waits (video 5) never makes one.
    private func allowLocationIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    private func waitForHome() {
        XCTAssertTrue(el("home.statCard").waitForExistence(timeout: 30),
                      "Home must be up after launch (the splash runs under -WKTDemo)")
    }

    /// Home > Walk > Start Walk, each step checked before it is taken.
    private func startWalkFromHome() {
        waitForHome()
        let walkTile = app.buttons["home.tile.walk"]
        XCTAssertTrue(walkTile.waitForExistence(timeout: 15), "Home's Walk tile is missing")
        forceTap(walkTile)
        let start = app.buttons["home.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Home's Start button is missing")
        XCTAssertEqual(start.label, "Start Walk", "Walk must be the selected activity")
        // Without -WKTUITest Home animates in; a tap before it settles got hit
        // point {-1, -1} and was lost (seen once, 2026-10-16). Wait until it can be hit.
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: start)
        XCTAssertEqual(XCTWaiter().wait(for: [hittable], timeout: 10), .completed, "Start Walk never became tappable")
        start.tap()
        XCTAssertTrue(el("session.root").waitForExistence(timeout: 30),
                      "Start Walk must open the walk screen")
        allowLocationIfAsked()
    }

    /// Distance walked, in metres, from the session's distance tile, whose
    /// label is "distance: 0.12 mi" (or ft, km, m). Nil when it can't be read.
    private static func metres(fromDistanceLabel label: String) -> Double? {
        let parts = label.replacingOccurrences(of: "distance: ", with: "").split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0].replacingOccurrences(of: ",", with: "")) else { return nil }
        switch parts[1] {
        case "mi": return value * 1609.344
        case "ft": return value * 0.3048
        case "km": return value * 1000
        case "m":  return value
        default:   return nil
        }
    }

    // MARK: - 01 Start a walk in two taps

    func test_video_01_start_a_walk() {
        startWalkFromHome()
        let elapsed = el("session.elapsed")
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10), "The walk timer is missing")
        let first = elapsed.label
        let ticked = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in elapsed.label != first }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [ticked], timeout: 10), .completed,
                       "The walk timer must be running")
    }

    // MARK: - 02 Find a loop from your door

    func test_video_02_find_a_loop() {
        waitForHome()
        selectTab("Routes")
        let findRoutes = app.buttons["routes.findRoutes"]
        XCTAssertTrue(findRoutes.waitForExistence(timeout: 30), "Routes must show Find Routes")

        // The 20/30/45 min chips (WalkIntent.quickOptions) sit above Find Routes.
        for minutes in [20, 45, 30] {
            let chip = app.buttons["\(minutes) min"]
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "The \(minutes) min chip is missing")
            chip.tap()
        }
        XCTAssertTrue(app.buttons["30 min"].isSelected, "30 min must be the chosen length")

        findRoutes.tap()
        XCTAssertTrue(el("routes.resultsPanel").waitForExistence(timeout: 60),
                      "Find Routes must list routes from the demo location")
        let card = app.buttons["routes.routeCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "No route card listed")
        forceTap(card)
        XCTAssertTrue(app.buttons["routes.startWalk"].waitForExistence(timeout: 10),
                      "Choosing a route must offer Start Walk")
    }

    // MARK: - 03 Named trails

    func test_video_03_named_trails() {
        waitForHome()
        selectTab("Routes")
        let picker = el("routes.modePicker")
        XCTAssertTrue(picker.waitForExistence(timeout: 30), "Routes must show the Routes | Trails picker")
        picker.buttons["Trails"].tap()

        XCTAssertTrue(el("routes.trailsPanel").waitForExistence(timeout: 15), "Trails must open its list")
        let firstCard = app.buttons["routes.trailCard"].firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 20), "No trails listed near the demo location")
        // Animation wait: the list springs in (0.3 s); a card tapped mid-spring can miss.
        sleep(1)
        firstCard.tap()

        XCTAssertTrue(el("routes.trailDetail").waitForExistence(timeout: 10), "A trail card must open its detail")
        XCTAssertTrue(app.buttons["routes.trailDirections"].waitForExistence(timeout: 10),
                      "The trail detail must offer directions")
        // Animation wait: the detail's spring transition (0.3 s) must finish before Back is tapped.
        sleep(1)
        let back = app.buttons["routes.trailBack"]
        XCTAssertTrue(back.exists, "The trail detail must have its back button")
        back.tap()
        XCTAssertTrue(firstCard.waitForExistence(timeout: 10), "Back must return to the trail list")
    }

    // MARK: - 04 Build your own route

    func test_video_04_build_your_own_route() {
        waitForHome()
        let myRoutes = el("home.myRoutes")
        XCTAssertTrue(myRoutes.waitForExistence(timeout: 15), "Home's My Routes card is missing")
        forceTap(myRoutes)

        // The list has no identifier of its own; its title is "Saved Items".
        XCTAssertTrue(app.navigationBars["Saved Items"].waitForExistence(timeout: 10),
                      "My Routes must open the Saved Items list")
        let add = app.buttons["New route"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Saved Items must have the + (New route) button")
        add.tap()

        // The builder has no identifier either; its title is "Build Route" until a point goes in.
        XCTAssertTrue(app.navigationBars["Build Route"].waitForExistence(timeout: 10),
                      "+ must open the route builder")
        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 10), "The builder's map is missing")
        // Three points in the upper map, clear of the bottom panel.
        for offset in [CGVector(dx: 0.35, dy: 0.22), CGVector(dx: 0.65, dy: 0.25), CGVector(dx: 0.55, dy: 0.42)] {
            map.coordinate(withNormalizedOffset: offset).tap()
            // Each leg is a MapKit directions request; the next tap waits for
            // the builder to accept this one (the Loop switch shows only while idle).
            if offset.dx != 0.35 {
                XCTAssertTrue(app.switches["Loop"].waitForExistence(timeout: 30),
                              "The builder must route the new leg and offer Loop")
            }
        }
        XCTAssertTrue(app.navigationBars["Edit Route"].exists, "A point on the map must turn the builder to Edit Route")
        XCTAssertTrue(app.staticTexts["3"].exists, "Three taps must make three points")

        let loop = app.switches["Loop"]
        // On the switch itself, at the trailing end: the element's centre is
        // its "Loop" label, and a tap there doesn't toggle it.
        loop.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: loop)
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 30), .completed, "Loop must close the route")

        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "The builder must offer Undo")
        // With the loop closed, the first Undo only reopens it
        // (`CustomRouteBuilder.undoLast`); all three points stay.
        undo.tap()
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: loop)
        XCTAssertEqual(XCTWaiter().wait(for: [opened], timeout: 10), .completed, "The first Undo must reopen the loop")
        XCTAssertTrue(app.staticTexts["3"].exists, "Reopening the loop keeps all three points")
        // The second Undo removes the last point.
        undo.tap()
        // Nothing labelled "3" may survive: not pin 3 on the map (pins are
        // titled by their number) and not the Points chip. Asserting "2"
        // exists would pass on pin 2 alone, whatever Undo did.
        let three = app.descendants(matching: .any).matching(NSPredicate(format: "label == '3'")).firstMatch
        XCTAssertTrue(three.waitForNonExistence(timeout: 30),
                      "Undo must remove the third point and its pin; still labelled 3: "
                      + app.descendants(matching: .any).matching(NSPredicate(format: "label == '3'"))
                        .allElementsBoundByIndex.map { "\($0.elementType.rawValue) \($0.frame)" }.joined(separator: "; "))
        XCTAssertTrue(app.staticTexts["2"].exists, "Two points must remain after Undo")
        XCTAssertTrue(app.buttons["Save Route"].waitForExistence(timeout: 30),
                      "Two points still make a route that can be saved")
    }

    // MARK: - 05 Save a walk as a route

    /// A live walk, not the seeded one: a summary opened from Activity
    /// History never offers "Save as Custom Route" (`canSaveAsRoute` needs
    /// `moment == .justFinished`), so the -WKTDemo walk can't show this.
    /// The walk needs a moving simulator location to record a line, which
    /// the recording script supplies (`simctl location … start`) before this
    /// test; with a still location it fails at the distance wait below.
    func test_video_05_save_a_walk_as_a_route() {
        startWalkFromHome()

        let distance = el("session.root").descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'distance: '")).firstMatch
        XCTAssertTrue(distance.waitForExistence(timeout: 10), "The walk's distance tile is missing")
        // About 150 m: well past the six breadcrumbs (one per ~5 m) the
        // summary needs before it offers to save the line.
        let walked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (Self.metres(fromDistanceLabel: distance.label) ?? 0) >= 150
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [walked], timeout: 240), .completed,
                       "The walk recorded no distance (\(distance.label)). The simulator's location "
                       + "must be moving: the recording script starts `simctl location … start` first")

        let finish = el("session.finish")
        XCTAssertTrue(finish.waitForExistence(timeout: 5), "The walk screen's Finish is missing")
        finish.press(forDuration: 1.4)
        let confirm = app.buttons["session.confirmFinish"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Holding Finish must ask to finish")
        confirm.tap()

        XCTAssertTrue(el("summary.root").waitForExistence(timeout: 15), "Finishing must show the summary")
        let save = app.buttons["Save as Custom Route"]
        var swipes = 0
        while !save.isHittable && swipes < 8 {
            el("summary.root").swipeUp()
            swipes += 1
        }
        XCTAssertTrue(save.exists, "A recorded walk's summary must offer Save as Custom Route")
        save.tap()

        let name = app.textFields["Route name…"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "Save as Custom Route must ask for a name")
        // The field appears near the bottom of the summary and the keyboard
        // slides up over it; typing before it has focus was lost twice
        // ("Neither element nor any descendant has keyboard focus").
        let canHit = NSPredicate(format: "hittable == true")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: canHit, object: name)], timeout: 10),
                       .completed, "The route name field never became tappable")
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "Tapping the name field must raise the keyboard")
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: name)
        XCTAssertEqual(XCTWaiter().wait(for: [focused], timeout: 10), .completed, "The route name field must have focus")
        name.typeText("Morning Loop")
        let saveName = app.buttons["Save"]
        XCTAssertTrue(saveName.waitForExistence(timeout: 5), "The name field's Save is missing")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: canHit, object: saveName)], timeout: 10),
                       .completed, "The name field's Save never became tappable")
        saveName.tap()
        // CONTAINS, not an exact title: the saved state swaps the button's symbol too.
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Saved as Custom Route'")).firstMatch
        if !saved.waitForExistence(timeout: 15) {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Accessibility tree after Save"
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("Save must confirm the walk is now a route")
        }
    }

    // MARK: - 06 Turn around here

    /// Routes > Trails > an out-and-back trail > a round trip > Start, then
    /// "Head back now" on the walk screen. A trail walk starts from the trail
    /// only within 150 m of it (`TrailWalkPlanner.startRadiusMeters`); the
    /// -WKTDemo location (downtown Raleigh) is about 650 m from the nearest
    /// one, so the detail offers only a walk *to* the trail, which never
    /// offers Head back (`canHeadBack` needs `route.approach == nil`). The test
    /// is skipped there, with that reason, rather than recording a video that
    /// can't reach the screen. Head back also needs 50 m walked along the
    /// trail, which the recording script's moving location supplies.
    func test_video_06_turn_around_here() throws {
        waitForHome()
        selectTab("Routes")
        let picker = el("routes.modePicker")
        XCTAssertTrue(picker.waitForExistence(timeout: 30), "Routes must show the Routes | Trails picker")
        picker.buttons["Trails"].tap()
        XCTAssertTrue(el("routes.trailsPanel").waitForExistence(timeout: 15), "Trails must open its list")
        let firstCard = app.buttons["routes.trailCard"].firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 20), "No trails listed near the demo location")
        firstCard.tap()
        XCTAssertTrue(el("routes.trailDetail").waitForExistence(timeout: 10), "A trail card must open its detail")

        let start = app.buttons["routes.trailStart"]
        let approach = app.buttons["routes.trailApproachStart"]
        let either = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in start.exists || approach.exists },
                                               object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [either], timeout: 20), .completed,
                       "The trail detail must offer a way to start")
        try XCTSkipUnless(start.exists,
                          "Video 6 needs a -WKTDemo location within 150 m of an out-and-back trail; "
                          + "downtown Raleigh is ~650 m from the nearest, so only a walk to the trail is offered")

        let option = app.buttons["routes.trailWalkOption"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "An out-and-back trail must offer round trips")
        option.tap()
        forceTap(start)
        XCTAssertTrue(el("session.root").waitForExistence(timeout: 30), "Start must open the walk screen")
        allowLocationIfAsked()

        let headBack = app.buttons["session.headBack"]
        XCTAssertTrue(headBack.waitForExistence(timeout: 240),
                      "Head back now must appear 50 m along the trail; the simulator's location must "
                      + "be moving along it (the recording script starts `simctl location … start`)")
        headBack.tap()
        // The dialog's own button, looked up inside the dialog: the walk
        // screen's pill (session.headBack) and the expanded panel's button
        // are also titled "Head back now", and tapping one of those again
        // would only reopen the dialog.
        let hasTitle = NSPredicate(format: "label == 'Head back to the start?'")
        let sheet = app.sheets.containing(.staticText, identifier: "Head back to the start?").firstMatch
        let alert = app.alerts.matching(hasTitle).firstMatch
        let dialogUp = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in sheet.exists || alert.exists },
                                                 object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [dialogUp], timeout: 5), .completed,
                       "Head back now must ask first, in its \"Head back to the start?\" dialog")
        let dialog = sheet.exists ? sheet : alert
        let confirm = dialog.buttons["Head back now"]
        XCTAssertTrue(confirm.exists, "The dialog must offer Head back now")
        confirm.tap()
        XCTAssertTrue(headBack.waitForNonExistence(timeout: 10), "After heading back it is not offered again")
        XCTAssertTrue(el("session.root").exists, "Heading back keeps the same walk going")
    }

    // MARK: - 07 Hold to finish, keep walking

    func test_video_07_hold_to_finish_keep_walking() {
        startWalkFromHome()
        let finish = el("session.finish")
        XCTAssertTrue(finish.waitForExistence(timeout: 10), "The walk screen's Finish is missing")
        // The timer visibly running before the hold, so the video shows a walk under way.
        let elapsedTile = el("session.elapsed")
        XCTAssertTrue(elapsedTile.waitForExistence(timeout: 10), "The walk timer is missing")
        let started = elapsedTile.label
        let running = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in elapsedTile.label != started }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [running], timeout: 10), .completed, "The walk timer must be running")
        finish.press(forDuration: 1.4)

        let keepGoing = app.buttons["session.keepGoing"]
        XCTAssertTrue(keepGoing.waitForExistence(timeout: 5), "Holding Finish must ask to finish")
        XCTAssertEqual(keepGoing.label, "Keep walking")
        XCTAssertTrue(app.buttons["session.confirmFinish"].exists, "The confirmation must also offer Finish and save")
        // Animation wait: the confirmation slides up; a tap mid-slide lands short of the button.
        sleep(1)
        keepGoing.tap()

        XCTAssertTrue(keepGoing.waitForNonExistence(timeout: 5), "Keep walking must close the confirmation")
        let elapsed = el("session.elapsed")
        XCTAssertTrue(elapsed.exists, "Keep walking must leave the walk screen up")
        let before = elapsed.label
        let ticking = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in elapsed.label != before }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [ticking], timeout: 10), .completed,
                       "The walk must still be running: nothing lost")
        XCTAssertFalse(el("summary.root").exists, "Keep walking must not end the walk")
    }

    // MARK: - 10 Start a challenge and share it

    /// Community > Start a challenge > Create Challenge > the new challenge >
    /// Share Challenge. Creating one saves to CloudKit's public database, so
    /// it needs a simulator signed in to iCloud; without one the form shows
    /// its error and the test is skipped with that error as the reason.
    func test_video_10_start_a_challenge_and_share_it() throws {
        waitForHome()
        selectTab("Community")
        XCTAssertTrue(el("community.root").waitForExistence(timeout: 30), "Community must open")
        let startChallenge = app.buttons["Start a challenge"]
        XCTAssertTrue(startChallenge.waitForExistence(timeout: 15), "Community must offer Start a challenge")
        startChallenge.tap()

        let name = app.textFields["challenge.create.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15), "Start a challenge must open the New Challenge form")
        // Unique per run: every run that gets this far leaves its challenge in
        // CloudKit's Development public database, and a fixed name could open
        // an earlier run's instead of this one's.
        let title = "Weekend Walkers \(Int(Date().timeIntervalSince1970) % 1_000_000)"
        name.tap()
        name.typeText(title)
        let create = app.buttons["challenge.create.submit"]
        XCTAssertTrue(create.exists, "The form's Create Challenge is missing")
        create.tap()

        // The Terms come first if this simulator hasn't agreed yet.
        let terms = el("terms.sheet")
        if terms.waitForExistence(timeout: 5) {
            el("terms.agree").tap()
            XCTAssertTrue(terms.waitForNonExistence(timeout: 10), "Agree must close the Terms")
        }

        let error = el("challenge.create.error")
        let outcome = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !name.exists || error.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [outcome], timeout: 30), .completed,
                       "Create Challenge must either save or say why it couldn't")
        try XCTSkipIf(error.exists,
                      "Video 10 needs a simulator signed in to iCloud (a challenge saves to CloudKit's "
                      + "public database); Create Challenge said '\(error.label)'")

        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The new challenge must be listed")
        card.tap()
        let share = app.buttons["challenge.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 15), "The challenge must offer Share Challenge")
        share.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10),
                      "Share Challenge must open the share sheet")
    }
}
