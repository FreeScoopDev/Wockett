import Testing
import Foundation
import SwiftUI
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

    // MARK: The sheet's buttons

    /// A gate held in a box, behind a Binding built the way SwiftUI's `$state` is.
    private final class GateBox {
        var gate: CommunityTermsGate
        init(_ gate: CommunityTermsGate) { self.gate = gate }
        var binding: Binding<CommunityTermsGate> {
            Binding(get: { self.gate }, set: { self.gate = $0 })
        }
    }

    @Test("The sheet's Agree, through a Binding, runs the held action and records agreement")
    func sheetAgreeThroughBinding() {
        let defaults = freshDefaults()
        let box = GateBox(CommunityTermsGate(defaults: defaults))
        var runs = 0
        box.gate.perform { runs += 1 }
        box.binding.sheetAgree()
        #expect(runs == 1)
        #expect(box.gate.pending == nil, "the write must reach the state behind the Binding")
        #expect(defaults.string(forKey: CommunityTerms.acceptedVersionKey) == CommunityTerms.version)
    }

    @Test("The sheet's Cancel, through a Binding, drops the held action and records nothing")
    func sheetCancelThroughBinding() {
        let defaults = freshDefaults()
        let box = GateBox(CommunityTermsGate(defaults: defaults))
        var runs = 0
        box.gate.perform { runs += 1 }
        box.binding.sheetCancel()
        #expect(runs == 0)
        #expect(box.gate.pending == nil)
        #expect(defaults.string(forKey: CommunityTerms.acceptedVersionKey) == nil)
    }

    // MARK: The screens use it

    /// Splits a source file at each top-level declaration (a line starting at
    /// column 0 with `struct`, `class`, `enum`, `actor` or `extension`, after
    /// any access level and `final`), so a gate and its sheet must sit in the
    /// same type, not merely the same file: a sheet on the wrong view never
    /// shows for the other view's gate.
    static func topLevelDeclarations(_ source: String) -> [String] {
        let start = /^((private|fileprivate|internal|public)\s+)?(final\s+)?(struct|class|enum|actor|extension)\s/
        var chunks: [String] = [""]
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.prefixMatch(of: start) != nil { chunks.append("") }
            chunks[chunks.count - 1] += line + "\n"
        }
        return chunks
    }

    @Test("The declaration split puts a gate and a sheet in different types apart")
    func declarationSplit() {
        let source = """
        import SwiftUI

        struct A: View {
            @State private var termsGate = CommunityTermsGate()
            struct Inner {}
        }

        private struct B: View {
            var body: some View { Text("").communityTermsSheet($termsGate) }
        }
        extension A {}
        final class C {}
        """
        let chunks = Self.topLevelDeclarations(source)
        #expect(chunks.count == 5, "preamble, A, B, extension, C (found \(chunks.count))")
        #expect(chunks[1].contains("CommunityTermsGate()") && chunks[1].contains("struct Inner"))
        #expect(!chunks[1].contains("communityTermsSheet"))
        #expect(chunks[2].contains("communityTermsSheet"))
    }

    /// Every screen that holds a community action in a gate must also present
    /// the sheet, or Agree can never be reached and the button is a dead tap.
    /// Reads the app's sources next to this file (the repo checkout), and
    /// counts per top-level declaration, not per file: two screens share
    /// AchievementFeedView.swift, RouteCardViews.swift and ChallengeView.swift.
    @Test("Every screen with a Terms gate presents the Terms sheet")
    func everyGateHasItsSheet() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PoCSquat")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var gated = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for chunk in Self.topLevelDeclarations(source) {
                let gates = chunk.components(separatedBy: "= CommunityTermsGate()").count - 1
                let sheets = chunk.components(separatedBy: ".communityTermsSheet($termsGate)").count - 1
                let uses = chunk.components(separatedBy: "termsGate.perform").count - 1
                guard gates + sheets + uses > 0 else { continue }
                let name = chunk.split(separator: "\n").first { $0.prefixMatch(of: /\S/) != nil } ?? ""
                #expect(gates == sheets, "\(file.lastPathComponent), \(name): \(gates) gates, \(sheets) sheets")
                #expect(uses >= gates, "\(file.lastPathComponent), \(name): a gate nothing uses")
                gated += gates
            }
        }
        #expect(gated >= 9, "the nine screens with community actions (found \(gated))")
    }
}
