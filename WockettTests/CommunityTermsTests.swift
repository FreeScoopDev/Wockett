import Testing
import Foundation
@testable import PoCSquat

/// The Terms gate before a first community action (2026-10-12 audit, finding 6).
struct CommunityTermsTests {

    /// A throwaway suite; never `.standard`, which would record agreement in the test host.
    private func freshDefaults() -> UserDefaults {
        let name = "CommunityTermsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("no UserDefaults suite \(name)")
            return UserDefaults(suiteName: "CommunityTermsTests-fallback")!
        }
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

    // MARK: The screens use it

    /// Every screen that holds a community action in a gate must also present
    /// the sheet, or Agree can never be reached and the button is a dead tap.
    /// Reads the app's sources next to this file (the repo checkout).
    @Test("Every screen with a Terms gate presents the Terms sheet")
    func everyGateHasItsSheet() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PoCSquat")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var gated = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let gates = source.components(separatedBy: "= CommunityTermsGate()").count - 1
            let sheets = source.components(separatedBy: ".communityTermsSheet($termsGate)").count - 1
            let uses = source.components(separatedBy: "termsGate.perform").count - 1
            #expect(gates == sheets, "\(file.lastPathComponent): \(gates) gates, \(sheets) sheets")
            #expect(uses >= gates, "\(file.lastPathComponent): a gate nothing uses")
            gated += gates
        }
        #expect(gated >= 9, "the nine screens with community actions (found \(gated))")
    }
}

