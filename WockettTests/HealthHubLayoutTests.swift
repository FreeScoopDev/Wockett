import Testing
@testable import PoCSquat

/// The Health tab's order (fix/health-tab-order, 2026-10-31): the person's own
/// activity and steps before what Health interprets, fun facts after the real
/// statistics, the disclaimer last. `HealthHubView` draws exactly this list.
struct HealthHubLayoutTests {
    @Test("Ready: activity, calendar, recovery, walking health, fun facts, disclaimer")
    func ready() {
        #expect(HealthHubLayout.sections(extras: .ready)
                == [.activity, .calendar, .recovery, .walking, .funFacts, .disclaimer])
    }

    @Test("Never asked: recovery holds the connect card, no walking health")
    func needsAsk() {
        #expect(HealthHubLayout.sections(extras: .needsAsk)
                == [.activity, .calendar, .recovery, .funFacts, .disclaimer])
    }

    @Test("Still checking: neither recovery nor walking health")
    func checking() {
        #expect(HealthHubLayout.sections(extras: .checking)
                == [.activity, .calendar, .funFacts, .disclaimer])
    }
}
