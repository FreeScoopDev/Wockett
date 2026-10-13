import Foundation

/// Links that come from data the app did not write itself (a trail pack's
/// credits, a map result's website). Only `http` and `https` with a host are
/// opened: a tampered pack or record must not be able to make a tap start a
/// call (`tel:`), a text (`sms:`) or another app's custom scheme.
enum RemoteLink {
    static func web(_ string: String?) -> URL? {
        web(string.flatMap(URL.init(string:)))
    }

    static func web(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }
}
