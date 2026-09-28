import Testing
import Foundation
@testable import PoCSquat

/// The app writes the widget's numbers through one writer; the widget reads
/// them by the key names in `AppGroup.WidgetKey`. Each test uses a throwaway
/// defaults suite and never asks WidgetKit to reload.
struct WidgetSnapshotTests {

    private func throwawayDefaults() throws -> UserDefaults {
        let suite = "wkt.tests.widget.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func write_landsUnderTheKeysTheShippedWidgetReads() throws {
        // The literal names are what 1.13's widget already reads; renaming
        // them would blank every installed widget until its next refresh.
        let defaults = try throwawayDefaults()
        let now = Date()
        #expect(WidgetSnapshot.write(steps: 4_321, distanceMeters: 3_100.5, goal: 8_000,
                                     to: defaults, now: now, reloadWidget: false))
        #expect(defaults.integer(forKey: "wkt_widget_steps") == 4_321)
        #expect(defaults.double(forKey: "wkt_widget_distanceMeters") == 3_100.5)
        #expect(defaults.integer(forKey: "wkt_widget_goal") == 8_000)
        #expect(defaults.object(forKey: "wkt_widget_lastRefresh") as? Date == now)
    }

    @Test func backgroundRefresh_leavesTheGoalAlone() throws {
        let defaults = try throwawayDefaults()
        WidgetSnapshot.write(steps: 100, distanceMeters: 80, goal: 12_000, to: defaults, reloadWidget: false)
        WidgetSnapshot.write(steps: 250, distanceMeters: 190, to: defaults, reloadWidget: false)
        let values = try #require(WidgetSnapshot.read(from: defaults))
        #expect(values.steps == 250)
        #expect(values.distanceMeters == 190)
        #expect(values.goal == 12_000)
    }

    @Test func read_isNilUntilSomethingWasWritten() throws {
        #expect(WidgetSnapshot.read(from: try throwawayDefaults()) == nil)
        #expect(WidgetSnapshot.read(from: nil) == nil)
        #expect(WidgetSnapshot.write(steps: 1, distanceMeters: 1, to: nil, reloadWidget: false) == false)
    }

    @Test func streakKey_isTheOneTheWidgetReads() {
        #expect(AppGroup.WidgetKey.streak == "wkt_widget_streak")
        #expect(AppGroup.stepWidgetKind == "WocketStepWidget")
        #expect(AppGroup.identifier == "group.com.scoops.wockett")
    }
}
