import Testing
import CoreLocation
@testable import PoCSquat

/// Pins `EncodedPolyline.decode` to the pack builder's encoder. The vectors
/// below were produced by `encode_polyline` in `tools/build_trail_pack.py`
/// (2026-09-16), and the first is also Google's documented reference example
/// — the builder reproduces it byte-for-byte, so both ends of the format are
/// checked against a third party rather than against each other.
struct EncodedPolylineTests {

    private func close(_ a: CLLocationCoordinate2D, _ lat: Double, _ lon: Double) -> Bool {
        abs(a.latitude - lat) < 1e-6 && abs(a.longitude - lon) < 1e-6
    }

    @Test("Decodes Google's reference example")
    func googleReference() {
        let pts = EncodedPolyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        #expect(pts.count == 3)
        #expect(close(pts[0], 38.5, -120.2))
        #expect(close(pts[1], 40.7, -120.95))
        #expect(close(pts[2], 43.252, -126.453))
    }

    @Test("Handles zero and negative single-unit deltas")
    func negativeAndZeroDeltas() {
        let pts = EncodedPolyline.decode("??@@??")
        #expect(pts.count == 3)
        #expect(close(pts[0], 0, 0))
        #expect(close(pts[1], -0.00001, -0.00001))
        #expect(close(pts[2], -0.00001, -0.00001))
    }

    @Test("Decodes a real fixture row")
    func fixtureRow() {
        // trails.id = 3 in WockettTests/Fixtures/fixture.wktpack ("Dog Park Path").
        let pts = EncodedPolyline.decode("wakyEn~}~M?gN")
        #expect(pts.count == 2)
        #expect(close(pts[0], 35.779, -78.638))
        #expect(close(pts[1], 35.779, -78.63556))
    }

    @Test("An empty string decodes to nothing")
    func empty() {
        #expect(EncodedPolyline.decode("").isEmpty)
    }

    @Test("Truncated input yields the points that were complete, without trapping")
    func truncated() {
        // Google example cut mid-way through the second point's longitude.
        let pts = EncodedPolyline.decode("_p~iF~ps|U_ulLnn")
        #expect(pts.count == 1)
        #expect(close(pts[0], 38.5, -120.2))
    }
}
