import Testing
@testable import PoCSquat

// Throwaway, never merged. Proves that the GitHub Actions "Tests (iOS)"
// check goes red when a unit test fails, before it becomes the required
// check on main (NEW-APP.md part 4).
struct ProveCIGateTests {
    @Test func aDeliberatelyBrokenTestMustTurnTheCheckRed() {
        #expect(1 + 1 == 3, "deliberate failure to prove the gate")
    }
}
