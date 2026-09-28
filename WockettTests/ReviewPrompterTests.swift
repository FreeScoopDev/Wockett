import Testing
import Foundation
@testable import PoCSquat

struct ReviewPrompterTests {

    private func freshDefaults() -> UserDefaults {
        let suite = "ReviewPrompterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func nothingDue_withoutAHighlight() {
        let prompter = ReviewPrompter(defaults: freshDefaults(), version: "1.14")
        #expect(!prompter.isDue)
        #expect(!prompter.consume())
    }

    @Test func highlight_asksOnce() {
        let prompter = ReviewPrompter(defaults: freshDefaults(), version: "1.14")
        prompter.noteHighlight()
        #expect(prompter.isDue)
        #expect(prompter.consume())
        #expect(!prompter.isDue)
        #expect(!prompter.consume())
    }

    @Test func secondHighlight_sameVersion_asksNothing() {
        let defaults = freshDefaults()
        let first = ReviewPrompter(defaults: defaults, version: "1.14")
        first.noteHighlight()
        #expect(first.consume())

        // A relaunch in the same version: a new instance over the same defaults.
        let relaunched = ReviewPrompter(defaults: defaults, version: "1.14")
        relaunched.noteHighlight()
        #expect(!relaunched.isDue)
        #expect(!relaunched.consume())
    }

    @Test func newVersion_asksAgain() {
        let defaults = freshDefaults()
        let old = ReviewPrompter(defaults: defaults, version: "1.14")
        old.noteHighlight()
        #expect(old.consume())

        let updated = ReviewPrompter(defaults: defaults, version: "1.15")
        updated.noteHighlight()
        #expect(updated.isDue)
        #expect(updated.consume())
    }

    @Test func highlightNotAskedFor_doesNotUseUpTheVersion() {
        // A highlight the root never acted on (the app was closed first) must
        // not count as having asked.
        let defaults = freshDefaults()
        let closedEarly = ReviewPrompter(defaults: defaults, version: "1.14")
        closedEarly.noteHighlight()

        let relaunched = ReviewPrompter(defaults: defaults, version: "1.14")
        relaunched.noteHighlight()
        #expect(relaunched.consume())
    }
}
