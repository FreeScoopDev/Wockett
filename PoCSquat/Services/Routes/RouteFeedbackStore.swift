import Foundation
import MapKit

// MARK: - Feedback Signal

enum RouteFeedbackSignal: String, Codable {
    case liked, disliked, completed
}

// MARK: - Route Signature
//
// Stable key capturing the meaningful character of a route. Intentionally coarse:
//   - distanceBucket: snapped to nearest 500m (so 1.8 km and 2.0 km are same bucket)
//   - areaTile: lat/lon rounded to 2 d.p. (~1.1 km grid) — same neighbourhood, not exact spot
//   - isLoop / activityMode: structural differences that meaningfully change experience

struct RouteSignature: Hashable, Codable {
    let distanceBucket: Int   // Int(totalDistance / 500) * 500
    let isLoop: Bool
    let activityMode: String  // ActivityMode.rawValue
    let areaTile: String      // "\(lat2dp)_\(lon2dp)"

    var key: String { "\(distanceBucket)_\(isLoop)_\(activityMode)_\(areaTile)" }

    static func from(route: NavigableRoute) -> RouteSignature? {
        guard let origin = route.waypoints.first else { return nil }
        return make(totalDistance: route.totalDistance, isLoop: route.isLoop,
                    activityMode: route.activityMode.rawValue, origin: origin)
    }

    static func from(route: SuggestedRoute, activityMode: ActivityMode,
                     origin: CLLocationCoordinate2D) -> RouteSignature {
        make(totalDistance: route.totalDistance, isLoop: route.isLoop,
             activityMode: activityMode.rawValue, origin: origin)
    }

    private static func make(totalDistance: Double, isLoop: Bool,
                              activityMode: String,
                              origin: CLLocationCoordinate2D) -> RouteSignature {
        RouteSignature(
            distanceBucket: (Int(totalDistance) / 500) * 500,
            isLoop: isLoop,
            activityMode: activityMode,
            areaTile: "\((origin.latitude * 100).rounded() / 100)_\((origin.longitude * 100).rounded() / 100)"
        )
    }
}

// MARK: - Route Feedback

struct RouteFeedback: Codable {
    var liked: Int = 0
    var disliked: Int = 0
    var completed: Int = 0

    // Confidence-weighted: single votes count less than a pattern of 3+
    var weightedScore: Double {
        let total = liked + disliked
        guard total > 0 else { return 0 }
        let raw = Double(liked - disliked) / Double(total)
        let confidence = min(1.0, Double(total) / 3.0)
        return raw * confidence
    }
}

// MARK: - Route Feedback Store

final class RouteFeedbackStore {
    static let shared = RouteFeedbackStore()

    private let udKey = "wkt_routeFeedback_v1"
    private var feedback: [String: RouteFeedback] = [:]

    init() { load() }

    // MARK: - Record

    func record(_ signal: RouteFeedbackSignal, for signature: RouteSignature) {
        var f = feedback[signature.key] ?? RouteFeedback()
        switch signal {
        case .liked:     f.liked     += 1
        case .disliked:  f.disliked  += 1
        case .completed: f.completed += 1
        }
        feedback[signature.key] = f
        persist()
    }

    // MARK: - Score

    func score(for signature: RouteSignature) -> Double {
        feedback[signature.key]?.weightedScore ?? 0
    }

    func existingFeedback(for signature: RouteSignature) -> RouteFeedback? {
        feedback[signature.key]
    }

    // MARK: - Sort

    // Re-ranks routes by learned preference. Strongly liked routes bubble up;
    // strongly disliked ones sink. Routes without history keep their original order.
    func sortedByFeedback(_ routes: [SuggestedRoute],
                          origin: CLLocationCoordinate2D,
                          activityMode: ActivityMode) -> [SuggestedRoute] {
        routes.sorted { a, b in
            let sigA = RouteSignature.from(route: a, activityMode: activityMode, origin: origin)
            let sigB = RouteSignature.from(route: b, activityMode: activityMode, origin: origin)
            let sA = score(for: sigA)
            let sB = score(for: sigB)
            guard abs(sA - sB) >= 0.3 else { return false }
            return sA > sB
        }
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(feedback) else { return }
        UserDefaults.standard.set(data, forKey: udKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([String: RouteFeedback].self, from: data)
        else { return }
        feedback = decoded
    }

    // MARK: - CloudKit sync stub
    //
    // TODO: When CloudKit sync is approved, implement:
    //   1. Add "RouteFeedbackRecord" type in CloudKit Console with fields:
    //      signatureKey (String), liked (Int64), disliked (Int64), completed (Int64), authorID (String)
    //   2. On app launch, fetch aggregate feedback for the user's areaTile neighbourhood
    //   3. Merge remote counts with local feedback (sum both sides) for a combined score
    //   4. After each local record() call, fire-and-forget upsert to CloudKit
    //
    // The local data model (RouteFeedback, RouteSignature, signal types) is already
    // CloudKit-ready — no changes needed to what's stored, only the transport layer.
    func syncToCloudKit() async throws {
        // Not yet implemented — local-only storage
    }
}
