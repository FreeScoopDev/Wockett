import Foundation

/// Heights on the Routes screens, in the unit their distances use: feet
/// where distance is in miles, metres everywhere else. Until 2026-11 the
/// chart, the saved route's climb and the result cards said metres beside
/// miles. The models keep metres; only the text and the chart's axis change.
enum RouteElevation {
    /// The app's one unit rule, so a height can never disagree with the
    /// distance beside it.
    static var defaultMetric: Bool { !WalkAudioCueService.usesMiles }

    /// "120 m" or "395 ft": the summary's formatter, rounded to the nearest.
    static func text(_ meters: Double, metric: Bool = defaultMetric) -> String {
        SummaryStat.heightText(meters, metric: metric)
    }

    static func gain(_ meters: Double, metric: Bool = defaultMetric) -> String { "+" + text(meters, metric: metric) }
    static func loss(_ meters: Double, metric: Bool = defaultMetric) -> String { "-" + text(meters, metric: metric) }

    static func axisValue(_ meters: Double, metric: Bool = defaultMetric) -> Double {
        metric ? meters : meters / 0.3048
    }

    static func axisUnit(metric: Bool = defaultMetric) -> String { metric ? "m" : "ft" }

    /// The chart's y range: padded in metres (30 % of the range, at least
    /// 15 m) and then converted, so the profile keeps its shape in feet.
    static func axisDomain(min: Double, max: Double, metric: Bool = defaultMetric) -> ClosedRange<Double> {
        let pad = Swift.max((max - min) * 0.3, 15)
        return axisValue(min - pad, metric: metric)...axisValue(max + pad, metric: metric)
    }
}

/// Why a saved route's history is empty: nothing finished yet, or every
/// finished one is left out of route history.
enum RouteHistoryEmpty {
    /// A route's sessions, newest first, without those excluded from route
    /// stats or flagged as a vehicle; `hidden` counts the ones left out.
    static func split(_ all: [WalkSession], route: UUID) -> (shown: [WalkSession], hidden: Int) {
        let mine = all.filter { $0.customRouteId == route }
        let shown = mine.filter { $0.countsTowardRouteStats && !$0.flaggedPossibleVehicle }
        return (shown.sorted { $0.date > $1.date }, mine.count - shown.count)
    }

    static func message(noun: String, routeName: String, hidden: Int) -> String {
        switch hidden {
        case ...0:
            return "No \(noun)s finished on \"\(routeName)\" yet. Finish one and it appears here."
        // Not the route's noun: a walking route can be started as a run.
        case 1:
            return "1 finished activity on \"\(routeName)\" is left out of route history "
                + "(not counted in route stats, or it looked like a trip in a vehicle)."
        default:
            return "\(hidden) finished activities on \"\(routeName)\" are left out of route history "
                + "(not counted in route stats, or they looked like a trip in a vehicle)."
        }
    }
}
