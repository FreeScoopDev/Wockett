import Testing
@testable import PoCSquat

/// The health footnote's words are fixed by the liability review; a change
/// to them is a change to what the app claims, so it should fail here first.
struct HealthDisclaimerTests {
    @Test("The disclaimer says exactly what the review asked")
    func text() {
        #expect(HealthDisclaimer.text == "For general information, not medical advice. Wockett isn't a medical device.")
    }
}
