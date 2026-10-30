import Testing
import SwiftUI
@testable import PoCSquat

/// Names in narrow rows and cards keep one line and their side-by-side
/// layouts at every normal text size, and wrap and stack at every
/// accessibility size (spec fix/large-text-names). The expected values are
/// written out, not derived from `isAccessibilitySize`.
struct WktNameLayoutTests {
    private static let normal: [DynamicTypeSize] = [
        .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge
    ]
    private static let accessibility: [DynamicTypeSize] = [
        .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5
    ]

    @Test func normalSizesKeepOneLineSideBySide() {
        for size in Self.normal {
            #expect(WktNameLayout.lineLimit(size) == 1, "\(size)")
            #expect(WktNameLayout.stacks(size) == false, "\(size)")
        }
    }

    @Test func accessibilitySizesWrapAndStack() {
        for size in Self.accessibility {
            #expect(WktNameLayout.lineLimit(size) == nil, "\(size)")
            #expect(WktNameLayout.stacks(size), "\(size)")
        }
    }

    /// A number and its unit are joined by a no-break space; every other
    /// space is left alone, so the line can still break between the parts.
    @Test func numbersKeepTheirUnits() {
        let nbsp = "\u{00A0}"
        #expect(WktNameLayout.keepingUnits("1.6 mi · Paved · 0.4 mi away")
                == "1.6\(nbsp)mi · Paved · 0.4\(nbsp)mi away")
        #expect(WktNameLayout.keepingUnits("9.1 mi · Hard · 166 mi away")
                == "9.1\(nbsp)mi · Hard · 166\(nbsp)mi away")
        #expect(WktNameLayout.keepingUnits("Little Rock Trail") == "Little Rock Trail")
    }

    /// Pins the rule's values (it cannot see whether a view uses them): a
    /// username keeps one line wherever it stands alone, and "by <name>"
    /// gets a second line only at the accessibility sizes, for the name to
    /// drop under "by" (spec fix/large-text-chips-rows, item 7). With any
    /// more lines a too-wide name would break mid-word.
    @Test func usernamesAreNeverBroken() {
        #expect(WktNameLayout.usernameLineLimit == 1)
        for size in Self.normal {
            #expect(WktNameLayout.authorLineLimit(size) == 1, "\(size)")
        }
        for size in Self.accessibility {
            #expect(WktNameLayout.authorLineLimit(size) == 2, "\(size)")
        }
    }

    /// Generated names really are one word: the rule above relies on it.
    /// Every part a name is built from, so the check is complete.
    @Test func generatedUsernamesHaveNoSpaces() {
        for part in CommunityNames.adjectives + CommunityNames.nouns + CommunityNames.numbers.map(String.init) {
            let spaced = part.contains { $0.isWhitespace }
            #expect(!spaced, "\(part)")
        }
    }

    /// Every size is in one list or the other, so a new case can't slip by.
    @Test func everySizeIsCovered() {
        #expect(Set(Self.normal + Self.accessibility) == Set(DynamicTypeSize.allCases))
    }
}
