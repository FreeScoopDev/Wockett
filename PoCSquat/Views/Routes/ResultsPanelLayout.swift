import CoreGraphics

/// How tall the Routes results panel's list may be. Start sits in a bar under
/// the list (spec fix/route-start-visible), so the list gives up the bar's
/// height and the whole panel covers about as much of the map as before. The
/// floor keeps a usable list at the accessibility sizes, where the bar grows.
enum ResultsPanelLayout {
    static let listShare: CGFloat = 0.45
    static let floorShare: CGFloat = 0.30

    static func scrollCap(container: CGFloat, barHeight: CGFloat) -> CGFloat {
        max(container * floorShare, container * listShare - max(barHeight, 0))
    }
}
