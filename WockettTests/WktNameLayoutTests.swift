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

    /// A pace's slash is glued to its unit with a word joiner (invisible),
    /// so "19:52/mi" cannot wrap after the slash (F5 audit N11). A slash
    /// that is not between a number and a unit is left alone.
    @Test func paceKeepsItsUnit() {
        let joiner = "\u{2060}"
        #expect(WktNameLayout.keepingUnits("19:52/mi") == "19:52/\(joiner)mi")
        #expect(WktNameLayout.keepingUnits("6:05/km") == "6:05/\(joiner)km")
        #expect(WktNameLayout.keepingUnits("1,379 steps") == "1,379\u{00A0}steps")
        #expect(WktNameLayout.keepingUnits("Walk / Run") == "Walk / Run")
        #expect(WktNameLayout.keepingUnits("and/or") == "and/or")
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
            #expect(WktNameLayout.usernameMinimumScale(size) == 1, "\(size)")
        }
        for size in Self.accessibility {
            #expect(WktNameLayout.authorLineLimit(size) == 2, "\(size)")
            #expect(WktNameLayout.usernameMinimumScale(size) == 0.7, "\(size)")
        }
    }

    /// Generated names really are one word: the rule above relies on it.
    /// Every part a name is built from, so the check is complete.
    @Test func generatedUsernamesHaveNoSpaces() {
        for part in CommunityNames.adjectives + CommunityNames.nouns + CommunityNames.numbers.map(String.init) {
            let spaced = part.contains { $0.isWhitespace }
            #expect(!spaced, "\(part)")
        }
        // And the parts are joined without one: a fixed sequence, so every
        // run checks the same names.
        var generator = CountingGenerator()
        for _ in 0..<100 {
            let name = CommunityNames.random(using: &generator)
            let spaced = name.contains { $0.isWhitespace }
            #expect(!spaced, "\(name)")
        }
    }

    private struct CountingGenerator: RandomNumberGenerator {
        var state: UInt64 = 0
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            return state
        }
    }

    /// Every size is in one list or the other, so a new case can't slip by.
    @Test func everySizeIsCovered() {
        #expect(Set(Self.normal + Self.accessibility) == Set(DynamicTypeSize.allCases))
    }
}
