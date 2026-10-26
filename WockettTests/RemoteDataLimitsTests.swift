import Testing
import CloudKit
import Foundation
@testable import PoCSquat

/// Public routes and remote links are written by anyone with an iCloud
/// account (or a tampered pack), so the app limits what it accepts
/// (2026-10-12 audit, finding 21).
struct RemoteDataLimitsTests {

    private func route(_ points: [[String: Double]]) throws -> SharedRoute? {
        let json = String(data: try JSONSerialization.data(withJSONObject: points), encoding: .utf8) ?? "[]"
        let r = CKRecord(recordType: "SharedRoute", recordID: CKRecord.ID(recordName: UUID().uuidString))
        r["name"] = "Loop" as CKRecordValue
        r["waypointsJSON"] = json as CKRecordValue
        r["distanceMeters"] = 1_000.0 as CKRecordValue
        return SharedRoute(record: r)
    }

    private func points(_ count: Int) -> [[String: Double]] {
        (0..<count).map { ["latitude": 35.78 + Double($0) * 1e-5, "longitude": -78.64] }
    }

    @Test("A route at the publish cap opens; one point over is refused")
    func pointCap() throws {
        let cap = SharedRouteTrim.maxPublishedPoints
        #expect(try route(points(cap))?.waypoints.count == cap)
        #expect(try route(points(cap + 1)) == nil)
    }

    @Test("Points that are not real coordinates are dropped, the rest kept")
    func outOfRange() throws {
        let shared = try #require(try route([
            ["latitude": 35.78, "longitude": -78.64],
            ["latitude": 91, "longitude": 0],
            ["latitude": 0, "longitude": -180.5],
            ["latitude": -90, "longitude": 180]
        ]))
        #expect(shared.waypoints.map(\.latitude) == [35.78, -90])
    }

    @Test("Only http(s) links with a host are opened",
          arguments: [("https://wockett.app", true), ("http://example.org/a", true), ("HTTPS://example.org", true),
                      ("tel:5551234", false), ("sms:5551234", false), ("mailto:a@b.c", false),
                      ("wockett://challenge/x", false), ("javascript:alert(1)", false), ("https://", false), ("https://:80", false), ("https://@", false),
                      ("file:///etc/hosts", false)])
    func links(link: String, opens: Bool) {
        #expect((RemoteLink.web(link) != nil) == opens)
        #expect((RemoteLink.web(URL(string: link)) != nil) == opens)
    }

    @Test("A negative or non-finite distance is refused", arguments: [-1.0, Double.infinity, -Double.infinity, Double.nan])
    func badDistance(distance: Double) {
        let r = CKRecord(recordType: "SharedRoute", recordID: CKRecord.ID(recordName: UUID().uuidString))
        r["name"] = "Loop" as CKRecordValue
        r["waypointsJSON"] = "[]" as CKRecordValue
        r["distanceMeters"] = distance as CKRecordValue
        #expect(SharedRoute(record: r) == nil)
    }

    @Test("A distance past the cap is refused; the cap itself opens")
    func distanceCap() {
        func shared(_ distance: Double) -> SharedRoute? {
            let r = CKRecord(recordType: "SharedRoute", recordID: CKRecord.ID(recordName: UUID().uuidString))
            r["name"] = "Loop" as CKRecordValue
            r["waypointsJSON"] = "[]" as CKRecordValue
            r["distanceMeters"] = distance as CKRecordValue
            return SharedRoute(record: r)
        }
        #expect(shared(SharedRoute.maxDistanceMeters) != nil)
        #expect(shared(SharedRoute.maxDistanceMeters.nextUp) == nil)
        #expect(shared(1e30) == nil)
    }

    @Test("Saturating conversion never traps", arguments: [1e30, -1e30, Double.nan, Double.infinity, -Double.infinity, 9.3e18])
    func saturating(value: Double) {
        _ = saturatingInt(value)
        #expect(saturatingInt(.nan) == 0)
        #expect(saturatingInt(1e30) == Int.max)
        #expect(saturatingInt(-1e30) == Int.min)
        #expect(saturatingInt(42.9) == 42)
    }

    @Test("A challenge goal past the caps is refused", arguments: [1e30, -1.0, Double.nan, Double.infinity])
    func challengeGoalCaps(value: Double) {
        func challenge(type: ChallengeGoalType, key: String, value: Double) -> WalkChallenge? {
            let r = CKRecord(recordType: "Challenge")
            r["title"] = "T" as CKRecordValue
            r["startDate"] = Date().addingTimeInterval(-86_400) as CKRecordValue
            r["endDate"] = Date().addingTimeInterval(86_400) as CKRecordValue
            r["goalType"] = type.rawValue as CKRecordValue
            r[key] = value as CKRecordValue
            return WalkChallenge(record: r)
        }
        #expect(challenge(type: .distance, key: "goalDistanceMeters", value: value) == nil)
        #expect(challenge(type: .pace, key: "goalPaceSecsPerKm", value: value) == nil)
        #expect(challenge(type: .distance, key: "goalDistanceMeters", value: WalkChallenge.maxGoalDistanceMeters) != nil)
        #expect(challenge(type: .pace, key: "goalPaceSecsPerKm", value: WalkChallenge.maxGoalPaceSecsPerKm) != nil)
    }

    @Test("No link is no link")
    func noLink() {
        #expect(RemoteLink.web(nil as String?) == nil)
        #expect(RemoteLink.web(nil as URL?) == nil)
    }
}
