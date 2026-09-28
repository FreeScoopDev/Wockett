import Testing
import Foundation
@testable import PoCSquat

/// The conversion behind "Log a Past Walk": the typed number is in the
/// phone's unit, and the walk is stored in metres like every other walk.
struct ManualWalkEntryTests {

    @Test func usPhone_typedNumberIsMiles() {
        // 3 miles is 4828 m, not 3000 m (the 1.13 result).
        let meters = ManualWalkEntrySheet.meters(fromDistanceText: "3", useMetric: false)
        #expect(meters != nil)
        #expect(abs((meters ?? 0) - 4828.032) < 0.01)
    }

    @Test func metricPhone_typedNumberIsKilometres() {
        #expect(ManualWalkEntrySheet.meters(fromDistanceText: "3.5", useMetric: true) == 3500)
    }

    @Test func distance_mustBeAPositiveNumber() {
        #expect(ManualWalkEntrySheet.meters(fromDistanceText: "0", useMetric: false) == nil)
        #expect(ManualWalkEntrySheet.meters(fromDistanceText: "-2", useMetric: true) == nil)
        #expect(ManualWalkEntrySheet.meters(fromDistanceText: "three", useMetric: true) == nil)
        #expect(ManualWalkEntrySheet.meters(fromDistanceText: "", useMetric: true) == nil)
        #expect(ManualWalkEntrySheet.meters(fromDistanceText: " 2 ", useMetric: true) == 2000)
    }

    @Test func steps_useTheAppStride() {
        #expect(ManualWalkEntrySheet.meters(fromStepsText: "1000") == 762)
        #expect(ManualWalkEntrySheet.meters(fromStepsText: "0") == nil)
    }
}
