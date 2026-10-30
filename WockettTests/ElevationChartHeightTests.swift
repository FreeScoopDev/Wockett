import Testing
import SwiftUI
@testable import PoCSquat

/// The route elevation chart keeps its 110 pt at every normal text size and
/// is twice that at every accessibility size, where its axis labels alone
/// filled 110 pt and the profile drew as a flat line (spec
/// fix/large-text-round2, item 3). Pins the values; the UI test
/// `testRouteCardsAndElevationAtAccessibility2` measures the drawn plot.
struct ElevationChartHeightTests {
    @Test func heightPerTextSize() {
        let normal: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]
        let accessibility: [DynamicTypeSize] = [
            .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5
        ]
        #expect(Set(normal + accessibility) == Set(DynamicTypeSize.allCases))
        for size in normal {
            #expect(ElevationProfileChart.chartHeight(size) == 110, "\(size)")
        }
        for size in accessibility {
            #expect(ElevationProfileChart.chartHeight(size) == 220, "\(size)")
        }
    }
}
