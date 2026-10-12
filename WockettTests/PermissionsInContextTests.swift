import Testing
import Foundation
import HealthKit
import CoreLocation
@testable import PoCSquat

/// The decisions behind asking for each permission where it is used
/// (2026-10-12): which Health types the first-launch sheet asks for, when the
/// Health tab shows its connect card, and the calendar day's walk reminder.
@MainActor
struct PermissionsInContextTests {

    // MARK: Health split

    @Test func firstLaunchReadsOnlyStepsAndDistance() {
        #expect(StepManager.coreReadTypes == [HKQuantityType(.stepCount), HKQuantityType(.distanceWalkingRunning)])
    }

    @Test func firstLaunchAsksForNoneOfTheHealthTabTypes() {
        #expect(StepManager.coreReadTypes.isDisjoint(with: HealthExtrasAccess.readTypes))
    }

    @Test func healthTabAsksForEveryTypeItsCardsRead() {
        let expected = RecoveryService.readTypes.union(GaitHealthService.readTypes.map { $0 as HKObjectType })
        #expect(HealthExtrasAccess.readTypes == expected)
        #expect(HealthExtrasAccess.readTypes.count == 10)
    }

    @Test func firstLaunchStillAsksToSaveWalksWithTheirRoute() {
        #expect(StepManager.coreShareTypes.contains(.workoutType()))
        #expect(StepManager.coreShareTypes.contains(HKSeriesType.workoutRoute()))
    }

    // MARK: Health tab card

    private func access(_ status: HKAuthorizationRequestStatus?, available: Bool = true,
                        requested: RequestLog = RequestLog()) -> HealthExtrasAccess {
        HealthExtrasAccess(
            isAvailable: available,
            status: { _ in
                guard let status else { throw HKError(.errorHealthDataUnavailable) }
                return status
            },
            request: { types in await requested.record(types) }
        )
    }

    @Test func neverAskedShowsTheCard() async {
        let sut = access(.shouldRequest)
        await sut.refresh()
        #expect(sut.state == .needsAsk)
    }

    @Test func alreadyAskedShowsTheTabAsBefore() async {
        let sut = access(.unnecessary)
        await sut.refresh()
        #expect(sut.state == .ready)
    }

    @Test func unknownStatusShowsTheTabAsBefore() async {
        let unknown = access(.unknown)
        await unknown.refresh()
        #expect(unknown.state == .ready)
        let failing = access(nil)
        await failing.refresh()
        #expect(failing.state == .ready)
    }

    @Test func noHealthDataNeverShowsTheCard() async {
        let sut = access(.shouldRequest, available: false)
        await sut.refresh()
        #expect(sut.state == .ready)
    }

    @Test func connectAsksForExactlyTheTabsTypesThenShowsTheCards() async {
        let log = RequestLog()
        let sut = access(.shouldRequest, requested: log)
        await sut.refresh()
        await sut.connect()
        #expect(sut.state == .ready)
        #expect(await log.requests == [HealthExtrasAccess.readTypes])
    }

    // MARK: Location at walk start

    private typealias Session = NavigationSessionManager

    @Test func aWalkAsksForLocationWhenNeverAsked() {
        #expect(Session.locationAction(status: .notDetermined, tracking: true, paused: false) == .ask)
    }

    @Test func aWalkRestartsUpdatesOnceLocationIsGranted() {
        #expect(Session.locationAction(status: .authorizedWhenInUse, tracking: true, paused: false) == .startUpdates)
    }

    @Test func nothingIsAskedBeforeAWalkStartsOrAfterItEnds() {
        #expect(Session.locationAction(status: .notDetermined, tracking: false, paused: false) == .nothing)
    }

    @Test func aDeniedOrUnknownStatusAsksNothing() {
        #expect(Session.locationAction(status: .denied, tracking: true, paused: false) == .nothing)
        #expect(Session.locationAction(status: nil, tracking: true, paused: false) == .nothing)
    }

    @Test func aPausedWalkLeavesRestartingToResume() {
        #expect(Session.locationAction(status: .authorizedWhenInUse, tracking: true, paused: true) == .nothing)
    }

    // MARK: Calendar day reminder

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    private func day(_ d: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 15))!
    }

    @Test func goalDayReminderIsOnceAtEightThatMorning() {
        let reminder = WalkReminder.goalDay(day(20), goal: 8000, calendar: calendar)
        let eight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 8))!
        #expect(reminder.schedule == .once(eight))
        #expect(reminder.routeName == nil)
        #expect(reminder.title.contains(8000.formatted()))
    }

    @Test func goalDayReminderIsFoundOnlyForItsOwnDay() {
        let saved = [WalkReminder.goalDay(day(20), goal: 8000, calendar: calendar)]
        #expect(WalkReminder.hasGoalDayReminder(on: day(20), in: saved, calendar: calendar))
        #expect(!WalkReminder.hasGoalDayReminder(on: day(21), in: saved, calendar: calendar))
    }

    @Test func aRouteReminderThatMorningIsNotTheDaysReminder() {
        let eight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 8))!
        let route = WalkReminder(title: "River loop", routeName: "River loop", schedule: .once(eight))
        #expect(!WalkReminder.hasGoalDayReminder(on: day(20), in: [route], calendar: calendar))
    }
}

/// Records what `HealthExtrasAccess` asked HealthKit for.
actor RequestLog {
    private(set) var requests: [Set<HKObjectType>] = []
    func record(_ types: Set<HKObjectType>) { requests.append(types) }
}
