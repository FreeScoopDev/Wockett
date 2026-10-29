import Testing
import SwiftUI
@testable import PoCSquat

/// Stat rows keep one row and one-line labels at every normal text size, and
/// go to two columns with wrapping labels at every accessibility size (spec
/// fix/large-text-stat-rows). The expected values are written out, not
/// derived from `isAccessibilitySize`.
struct WktStatColumnsTests {
    private static let normal: [DynamicTypeSize] = [
        .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge
    ]
    private static let accessibility: [DynamicTypeSize] = [
        .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5
    ]

    @Test func normalSizesKeepOneRowAndOneLine() {
        for size in Self.normal {
            #expect(WktStatColumns.columns(size) == nil, "\(size)")
            #expect(WktStatColumns.labelLineLimit(size) == 1, "\(size)")
            #expect(WktStatColumns.labelAlignment(size) == .leading, "\(size)")
        }
    }

    @Test func accessibilitySizesUseTwoColumnsAndWrap() {
        for size in Self.accessibility {
            #expect(WktStatColumns.columns(size) == 2, "\(size)")
            #expect(WktStatColumns.labelLineLimit(size) == nil, "\(size)")
            #expect(WktStatColumns.labelAlignment(size) == .center, "\(size)")
        }
    }

    /// Every size is in one list or the other, so a new case can't slip by.
    @Test func everySizeIsCovered() {
        #expect(Set(Self.normal + Self.accessibility) == Set(DynamicTypeSize.allCases))
    }

    // MARK: - The layout's arithmetic (WktStatColumnsLayout.frames)

    private func frames(_ heights: [CGFloat], width: CGFloat = 350) -> [CGRect] {
        WktStatColumnsLayout.frames(columns: 2, spacing: 10, rowSpacing: 12, width: width,
                                    heightAt: { index, _ in heights[index] }, count: heights.count)
    }

    /// One stat (a ride's trail detail: Length only) keeps the full width.
    @Test func oneStatTakesTheFullWidth() {
        #expect(frames([50]) == [CGRect(x: 0, y: 0, width: 350, height: 50)])
    }

    /// Three: two in the first row, the third alone in one column's width.
    /// Each row is as tall as its tallest stat, and rows are 12 apart.
    @Test func threeStatsMakeARowOfTwoAndAnOrphan() {
        #expect(frames([40, 60, 30]) == [
            CGRect(x: 0, y: 0, width: 170, height: 60),
            CGRect(x: 180, y: 0, width: 170, height: 60),
            CGRect(x: 0, y: 72, width: 170, height: 30)
        ])
    }

    /// Four with a taller tile in the second row (a ride's Climb with its
    /// descent line): its neighbour is offered the same height.
    @Test func fourStatsShareEachRowsTallestHeight() {
        #expect(frames([50, 50, 40, 70]) == [
            CGRect(x: 0, y: 0, width: 170, height: 50),
            CGRect(x: 180, y: 0, width: 170, height: 50),
            CGRect(x: 0, y: 62, width: 170, height: 70),
            CGRect(x: 180, y: 62, width: 170, height: 70)
        ])
    }

    /// Five (a walk with a climb): rows of two, two, one.
    @Test func fiveStatsMakeThreeRows() {
        let result = frames([10, 20, 30, 40, 50])
        #expect(result.map(\.minY) == [0, 0, 32, 32, 84])
        #expect(result.map(\.minX) == [0, 180, 0, 180, 0])
        #expect(result.map(\.height) == [20, 20, 40, 40, 50])
    }

    /// Heights are asked for at one column's width, not the whole row's.
    @Test func heightsAreMeasuredAtOneColumnsWidth() {
        var asked: Set<CGFloat> = []
        _ = WktStatColumnsLayout.frames(columns: 2, spacing: 10, rowSpacing: 12, width: 350,
                                        heightAt: { _, width in asked.insert(width); return 10 }, count: 3)
        #expect(asked == [170])
    }

    @Test func noStatsHaveNoFrames() {
        #expect(frames([]).isEmpty)
    }
}
