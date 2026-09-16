import CoreLocation
import Foundation

// MARK: - TrailDataSource
//
// The seam between "where trails come from" and "what the app does with them".
// Today there is one implementation, `BundledTrailSource`, reading a region
// pack from disk. Adding a source later — a second region, a community layer —
// should be one new type conforming to this, not a refactor of every caller.
//
// The rule this protocol enforces: nothing here touches the network. Every
// method answers from data already on the device. A free API tier is a ceiling
// shared by every user of the app, and the route finder must not have one.

protocol TrailDataSource: AnyObject {
    /// What the pack says about itself — region, build date, trail count.
    var packInfo: TrailPackInfo { get }

    /// Every source's attribution, in the order the pack lists them.
    var attributions: [TrailAttribution] { get }

    /// Trails whose geometry comes within `radiusMeters` of `center`, nearest
    /// first, filtered by `query`, at most `limit` results.
    func trails(near center: CLLocationCoordinate2D,
                radiusMeters: Double,
                matching query: TrailQuery,
                limit: Int) throws -> [TrailFeature]

    /// Trails whose bounding box intersects `bounds`, filtered by `query`.
    /// Order is unspecified. Use for a map viewport.
    func trails(in bounds: TrailBounds,
                matching query: TrailQuery,
                limit: Int) throws -> [TrailFeature]

    /// One trail by its in-pack id, or nil.
    func trail(id: Int64) throws -> TrailFeature?
}

/// Errors a pack can raise. Each names what the user or developer can do
/// about it; none should be swallowed silently.
enum TrailPackError: Error, Equatable {
    /// The file could not be opened. Path included so the message is useful.
    case cannotOpen(path: String, detail: String)
    /// The pack's schema is one this build does not understand. A newer app
    /// can read an older pack (within reason); an older app must not guess at
    /// a newer one. The fix is to download a pack this build supports.
    case unsupportedSchema(found: Int, supported: ClosedRange<Int>)
    /// The pack is missing metadata every pack must carry.
    case malformed(detail: String)
    /// A query failed inside SQLite.
    case queryFailed(detail: String)
}
