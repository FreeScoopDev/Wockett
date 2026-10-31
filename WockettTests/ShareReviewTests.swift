import Testing
import CloudKit
import CoreLocation
@testable import PoCSquat

/// The share sheet's map draws `ShareReview.trimmed`, and its Publish button
/// calls `ShareReview.publish`. These check that what reaches the publisher
/// is exactly what the map drew, with Hide start and finish on and off. A
/// recording fake stands in for CloudKit: nothing is published.
@MainActor
struct ShareReviewTests {

    /// Records what it was asked to publish.
    final class RecordingPublisher: SharedRoutePublishing {
        var published: [(name: String, trimmed: SharedRouteTrim.Trimmed)] = []
        func publish(name: String, trimmed: SharedRouteTrim.Trimmed) async throws {
            published.append((name, trimmed))
        }
    }

    private let home = CLLocationCoordinate2D(latitude: 35.78, longitude: -78.64)
    private let offset = SharePrivacyOffset(east: 90, north: -60, extra: 40)

    /// A recorded-looking path north from home, a point every 0.0002° (about
    /// 22 m), so the 10 m respacing makes the published points differ from
    /// the route's own.
    private var route: CustomRoute {
        let path = (0..<80).map { WaypointCoord(CLLocationCoordinate2D(latitude: home.latitude + Double($0) * 0.0002,
                                                                      longitude: home.longitude)) }
        return CustomRoute(id: UUID(), name: "River walk", waypoints: path, totalDistance: 1_750,
                           isLoop: false, createdAt: Date())
    }

    @Test("Publish sends the previewed path", arguments: [false, true])
    func publishSendsThePreview(hideEnds: Bool) async throws {
        let review = ShareReview(route: route, hideEnds: hideEnds, offset: offset)
        let preview = try #require(review.trimmed, "the fixture must be shareable")
        #expect(preview.hidesEnds == hideEnds)
        #expect(preview.waypoints != route.waypoints, "the fixture must tell the drawn route from the respaced one")

        let publisher = RecordingPublisher()
        try await review.publish(name: "River walk", with: publisher)

        #expect(publisher.published.count == 1)
        let sent = try #require(publisher.published.first)
        #expect(sent.name == "River walk")
        #expect(sent.trimmed.waypoints == preview.waypoints)
        #expect(sent.trimmed == preview)
        // And the record built from it holds those same points.
        let record = try CommunityRouteService.record(name: sent.name, trimmed: sent.trimmed)
        let json = try #require(record["waypointsJSON"] as? String)
        #expect(try JSONDecoder().decode([WaypointCoord].self, from: Data(json.utf8)) == preview.waypoints)
    }

    @Test("A route that can't be shared reaches no publisher")
    func refusedOutcomeNeverPublishes() async {
        let publisher = RecordingPublisher()
        let short = CustomRoute(id: UUID(), name: "Short", waypoints: Array(route.waypoints.prefix(15)),
                                totalDistance: 310, isLoop: false, createdAt: Date())
        let refused: [(ShareReview, SharedRouteTrim.Outcome)] = [
            (ShareReview(route: nil, hideEnds: false, offset: nil), .notAPath),
            (ShareReview(route: route, hideEnds: true, offset: nil), .offsetUnavailable),
            (ShareReview(route: short, hideEnds: true, offset: offset), .tooShort(fullMeters: 0)),
        ]
        for (review, expected) in refused {
            #expect(review.trimmed == nil)
            if case .tooShort = expected, case .tooShort = review.outcome {} else { #expect(review.outcome == expected) }
            await #expect(throws: SharedRouteTrim.CannotShareError.self) {
                try await review.publish(name: "River walk", with: publisher)
            }
        }
        #expect(publisher.published.isEmpty)
    }
}
