import CoreLocation
import Foundation

// MARK: - Encoded polyline
//
// The pack stores each trail's geometry as a Google-style encoded polyline at
// precision 5 (about 1 m), written by `encode_polyline` in
// `tools/build_trail_pack.py`. This is the matching decoder. Precision is a
// property of the pack format, so it is fixed here rather than a parameter:
// a pack built at a different precision would need a schema bump.

enum EncodedPolyline {

    static let precision = 5

    /// Decodes a polyline string into coordinates. Malformed input stops the
    /// decode at the point it went wrong rather than trapping — a corrupt row
    /// in a 70,000-row pack should cost one trail, not the process.
    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        let factor = pow(10.0, Double(precision))
        var coords: [CLLocationCoordinate2D] = []
        var lat: Int64 = 0
        var lon: Int64 = 0
        var index = encoded.utf8.startIndex
        let end = encoded.utf8.endIndex

        func nextDelta() -> Int64? {
            var result: Int64 = 0
            var shift: Int64 = 0
            while true {
                guard index < end else { return nil }
                let byte = Int64(encoded.utf8[index]) - 63
                index = encoded.utf8.index(after: index)
                guard byte >= 0, shift < 64 else { return nil }
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20 { break }
            }
            return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        }

        while index < end {
            guard let dLat = nextDelta(), let dLon = nextDelta() else { break }
            lat += dLat
            lon += dLon
            coords.append(CLLocationCoordinate2D(latitude: Double(lat) / factor,
                                                 longitude: Double(lon) / factor))
        }
        return coords
    }
}
