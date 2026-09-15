import Foundation

// MARK: - TipProduct
//
// The tip jar's three products, defined in exactly one place.
//
// Product IDs are PERMANENT. App Store Connect will never let one be renamed or
// reused, so these deliberately do not inherit the app's bundle ID
// (`Scoops.PoCSquat`), which still carries the name of the squat-counter
// prototype this app grew out of. Product IDs only have to be unique within the
// developer account, not match the bundle ID.

enum TipProduct: String, CaseIterable, Identifiable, Sendable {
    case small  = "wockett.tip.small"
    case medium = "wockett.tip.medium"
    case large  = "wockett.tip.large"

    var id: String { rawValue }

    /// Display order, smallest first.
    static var ordered: [TipProduct] { [.small, .medium, .large] }

    static func from(productID: String) -> TipProduct? {
        TipProduct(rawValue: productID)
    }

    // MARK: Supporter points
    //
    // Why points and not dollars.
    //
    // The promise is "tip roughly the Big Supporter amount in total and any
    // future paid features are yours". Summing actual money cannot express that
    // correctly:
    //
    //   * App Store prices are per-storefront. A US $19.99 tip is some other
    //     number in GBP, EUR or AUD, and there is no reliable client-side way to
    //     convert. Wockett is already planning UK/AU/NZ/IE availability, so this
    //     is not hypothetical.
    //   * Even in USD the arithmetic is unkind: two medium tips is $9.98, which
    //     would miss a $9.99 threshold by a cent. Nobody would accept that
    //     explanation.
    //
    // Points are currency-independent and track the intent instead. The tiers are
    // weighted roughly in proportion to their US prices, and the threshold is set
    // so that every combination a reasonable person would call "about ten dollars
    // of support" qualifies:
    //
    //   large (1)              = 8 points  -> qualifies
    //   medium x 2 ($9.98)     = 4 points  -> qualifies
    //   small  x 4 ($11.96)    = 4 points  -> qualifies
    //   medium + small x 2     = 4 points  -> qualifies
    //   medium x 1 ($4.99)     = 2 points  -> does not
    //
    // If the tier prices ever change, re-weigh these rather than adding special
    // cases at the call site.
    var supporterPoints: Int {
        switch self {
        case .small:  return 1
        case .medium: return 2
        case .large:  return 8
        }
    }

    // MARK: Copy
    //
    // Prices are deliberately absent here. The only correct price string is
    // `Product.displayPrice` from StoreKit, which is already localised and
    // storefront-correct. Hardcoding "$2.99" anywhere in the UI would be wrong
    // for every user outside the US.

    var title: String {
        switch self {
        case .small:  return "Small tip"
        case .medium: return "Medium tip"
        case .large:  return "Big supporter"
        }
    }

    var blurb: String {
        switch self {
        case .small:  return "Buys a coffee. Genuinely appreciated."
        case .medium: return "Covers a good chunk of the yearly running costs."
        case .large:  return "Covers the whole year, and then some."
        }
    }
}
