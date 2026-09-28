import Testing
import Foundation
@testable import PoCSquat

/// The inbox that turns Siri and Control Center requests into a walk, and
/// the fallback behind "How many steps today". Each test uses its own
/// throwaway defaults suite, so nothing touches the real app group.
@MainActor
struct WalkIntentInboxTests {

    private func throwawayDefaults() throws -> UserDefaults {
        let suite = "wkt.tests.intent.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func controlCenterTap(in defaults: UserDefaults, mode: String = "walking", postedAt: Date?) {
        defaults.set(true, forKey: WalkIntentInbox.Keys.pending)
        defaults.set(mode, forKey: WalkIntentInbox.Keys.mode)
        if let postedAt { defaults.set(postedAt, forKey: WalkIntentInbox.Keys.postedAt) }
    }

    // MARK: - Control Center (app group)

    @Test func controlCenterTap_isConsumedOnce_andCleared() throws {
        let defaults = try throwawayDefaults()
        let inbox = WalkIntentInbox(store: defaults)
        controlCenterTap(in: defaults, mode: "cycling", postedAt: Date())

        #expect(inbox.consume() == WalkIntentRequest(mode: .cycling))
        #expect(inbox.consume() == nil)
        #expect(defaults.object(forKey: WalkIntentInbox.Keys.pending) == nil)
        #expect(defaults.object(forKey: WalkIntentInbox.Keys.mode) == nil)
        #expect(defaults.object(forKey: WalkIntentInbox.Keys.postedAt) == nil)
    }

    @Test func requestWithNoTime_asLeftBy113_isIgnoredAndCleared() throws {
        let defaults = try throwawayDefaults()
        let inbox = WalkIntentInbox(store: defaults)
        controlCenterTap(in: defaults, postedAt: nil)

        #expect(inbox.consume() == nil)
        #expect(defaults.object(forKey: WalkIntentInbox.Keys.pending) == nil)
    }

    @Test func requestOlderThanFiveMinutes_isIgnored() throws {
        let defaults = try throwawayDefaults()
        let now = Date()
        let inbox = WalkIntentInbox(store: defaults, now: { now })
        controlCenterTap(in: defaults, postedAt: now.addingTimeInterval(-(WalkIntentInbox.maxAge + 1)))
        #expect(inbox.consume() == nil)

        controlCenterTap(in: defaults, postedAt: now.addingTimeInterval(-(WalkIntentInbox.maxAge - 1)))
        #expect(inbox.consume() == WalkIntentRequest(mode: .walking))
    }

    // MARK: - Siri (in process)

    @Test func siriPost_isConsumedOnce() throws {
        let inbox = WalkIntentInbox(store: try throwawayDefaults())
        inbox.post(WalkIntentRequest(mode: .running))
        #expect(inbox.pending == WalkIntentRequest(mode: .running))
        #expect(inbox.consume() == WalkIntentRequest(mode: .running))
        #expect(inbox.pending == nil)
        #expect(inbox.consume() == nil)
    }

    @Test func intentModeWords_mapOntoActivityModes() {
        #expect(WalkIntentInbox.mode(fromIntentValue: "indoor") == .stationary)
        #expect(WalkIntentInbox.mode(fromIntentValue: "cycling") == .cycling)
        #expect(WalkIntentInbox.mode(fromIntentValue: "running") == .running)
        #expect(WalkIntentInbox.mode(fromIntentValue: "nonsense") == .walking)
        #expect(WalkIntentInbox.mode(fromIntentValue: nil) == .walking)
    }

    // MARK: - Steps fallback

    @Test func cachedSteps_takesTheFresherOfTheTwoWriters() throws {
        let defaults = try throwawayDefaults()
        let now = Date()
        defaults.set(5_000, forKey: "wkt_widget_steps")
        defaults.set(now.addingTimeInterval(-60), forKey: "wkt_widget_lastRefresh")
        defaults.set(7_000, forKey: "bg_todaySteps")
        defaults.set(now.addingTimeInterval(-600), forKey: "bg_lastRefresh")
        #expect(SiriStepsAnswer.cached(in: defaults, now: now) == 5_000)

        defaults.set(now, forKey: "bg_lastRefresh")
        #expect(SiriStepsAnswer.cached(in: defaults, now: now) == 7_000)
    }

    @Test func cachedSteps_isNilWhenNothingWasRefreshedToday() throws {
        let defaults = try throwawayDefaults()
        let now = Date()
        defaults.set(5_000, forKey: "wkt_widget_steps")
        defaults.set(now.addingTimeInterval(-2 * 86_400), forKey: "wkt_widget_lastRefresh")
        #expect(SiriStepsAnswer.cached(in: defaults, now: now) == nil)
        #expect(SiriStepsAnswer.cached(in: nil, now: now) == nil)
    }

    // MARK: - Tracking day

    @Test func trackingDay_startsAtThreeInTheMorning() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let fourAM = try #require(cal.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 4)))
        let twoAM  = try #require(cal.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 2)))
        let threeAM28 = try #require(cal.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 3)))
        let threeAM27 = try #require(cal.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 3)))
        #expect(StepManager.trackingDayStart(now: fourAM, calendar: cal) == threeAM28)
        #expect(StepManager.trackingDayStart(now: twoAM, calendar: cal) == threeAM27)
    }
}
