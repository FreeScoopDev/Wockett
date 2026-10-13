import Testing
import Foundation
@testable import PoCSquat

/// The Terms gate before a first community action (2026-10-12 audit, finding 6).
struct CommunityTermsTests {

    private func freshDefaults() -> UserDefaults {
        let name = "CommunityTermsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: The decision

    @Test("Never agreed: agreement is needed")
    func neverAgreed() {
        #expect(CommunityTerms.needsAgreement(acceptedVersion: nil, current: "2026-10-13"))
    }

    @Test("Agreed to the current version: not needed")
    func agreedCurrent() {
        #expect(!CommunityTerms.needsAgreement(acceptedVersion: "2026-10-13", current: "2026-10-13"))
    }

    @Test("Agreed to an older version: needed again once the constant changes")
    func agreedOlder() {
        #expect(CommunityTerms.needsAgreement(acceptedVersion: "2026-10-13", current: "2027-01-05"))
    }

    // MARK: The held action

    @Test("Not agreed: the action is held, not run, and the sheet shows")
    func heldUntilAgreed() {
        var gate = CommunityTermsGate(defaults: freshDefaults())
        var runs = 0
        gate.perform { runs += 1 }
        #expect(runs == 0)
        #expect(gate.pending != nil)
    }

    @Test("Agree runs the held action once and stores the version and date")
    func agreeRunsOnce() throws {
        let defaults = freshDefaults()
        var gate = CommunityTermsGate(defaults: defaults)
        var runs = 0
        gate.perform { runs += 1 }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        gate.agree(now: now)
        #expect(runs == 1)
        #expect(gate.pending == nil)
        #expect(defaults.string(forKey: CommunityTerms.acceptedVersionKey) == CommunityTerms.version)
        #expect(defaults.object(forKey: CommunityTerms.acceptedAtKey) as? Date == now)
        gate.agree(now: now)   // a second tap on a closing sheet
        #expect(runs == 1)
    }

    @Test("Cancel drops the action and stores nothing")
    func cancelDrops() {
        let defaults = freshDefaults()
        var gate = CommunityTermsGate(defaults: defaults)
        var runs = 0
        gate.perform { runs += 1 }
        gate.cancel()
        #expect(runs == 0)
        #expect(gate.pending == nil)
        #expect(defaults.string(forKey: CommunityTerms.acceptedVersionKey) == nil)
        gate.perform { runs += 1 }
        #expect(runs == 0, "still not agreed: the next action asks again")
        #expect(gate.pending != nil)
    }

    @Test("Once agreed, later actions run at once with no sheet, on any screen")
    func agreedRunsAtOnce() {
        let defaults = freshDefaults()
        var first = CommunityTermsGate(defaults: defaults)
        first.perform {}
        first.agree()
        var other = CommunityTermsGate(defaults: defaults)
        var runs = 0
        other.perform { runs += 1 }
        #expect(runs == 1)
        #expect(other.pending == nil)
    }

    @Test("A stored older version asks again")
    func olderStoredVersionAsks() {
        let defaults = freshDefaults()
        defaults.set("2026-01-01", forKey: CommunityTerms.acceptedVersionKey)
        var gate = CommunityTermsGate(defaults: defaults)
        var runs = 0
        gate.perform { runs += 1 }
        #expect(runs == 0)
        #expect(gate.pending != nil)
    }
}
