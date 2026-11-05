import SwiftUI
import CoreLocation
import Charts
import WeatherKit

// MARK: - Route Weather

struct HourlyWeatherPoint: Sendable {
    let date: Date
    let temperatureText: String
    let symbolName: String
    let precipitationChance: Double

    var hourLabel: String {
        Self.label(for: date, now: Date(), calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
    }

    /// "Now" for the current hour, otherwise the hour in the person's 12/24-hour
    /// setting ("3 PM", or "15"). A fixed "ha" format ignored that setting.
    static func label(for date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(date, equalTo: now, toGranularity: .hour) { return "Now" }
        return ForecastPeriod.hour(date, calendar: calendar, locale: locale)
    }
}

/// The words around an hourly forecast: which hours it covers and when it was
/// fetched. Bare hours crossing midnight ("23, 00, 01") read as a list of
/// numbers, so the period names its days.
enum ForecastPeriod {
    private static func style(_ calendar: Calendar, _ locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    }

    /// The hour as the hourly strip shows it: "3 PM" or "15".
    static func hour(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        date.formatted(style(calendar, locale).hour())
    }

    /// A clock time for a sentence: "3 PM" on a 12-hour phone, "15:00" on a
    /// 24-hour one, where a bare "15" would not read as a time.
    private static func time(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let probe = calendar.date(bySettingHour: 13, minute: 0, second: 0, of: date) ?? date
        let is24Hour = hour(probe, calendar: calendar, locale: locale).contains("13")
        return date.formatted(is24Hour ? style(calendar, locale).hour().minute() : style(calendar, locale).hour())
    }

    private static func day(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case -1: return "Yesterday"
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return date.formatted(style(calendar, locale).weekday(.wide))
        }
    }

    /// "Today, 3 PM – 8 PM", or "Today 10 PM – tomorrow 3 AM" when it crosses
    /// midnight. WeatherKit's hourly forecast can begin hours before now (seen
    /// starting at 22:00 the evening before, at 08:53), so "Yesterday" is real.
    static func text(first: Date, last: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let start = time(first, calendar: calendar, locale: locale)
        let end = time(last, calendar: calendar, locale: locale)
        let firstDay = day(first, now: now, calendar: calendar, locale: locale)
        if calendar.isDate(first, inSameDayAs: last) { return "\(firstDay), \(start) – \(end)" }
        let lastDay = day(last, now: now, calendar: calendar, locale: locale)
        let relative = ["Yesterday", "Today", "Tomorrow"]
        let lastDayInSentence = relative.contains(lastDay) ? lastDay.lowercased() : lastDay
        return "\(firstDay) \(start) – \(lastDayInSentence) \(end)"
    }

    /// "2:41 PM", or "14:41".
    static func clock(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        date.formatted(style(calendar, locale).hour().minute())
    }
}

/// Which of WeatherKit's hours the strip shows. Its hourly forecast can begin
/// 10-11 hours before now (22:00 the evening before, seen at 08:53), so taking
/// the first six showed hours already over, and the rain chance described a
/// past hour.
enum UpcomingForecast {
    /// The first `count` points from the start of the current hour on. The
    /// current hour stays, so the strip still opens on "Now".
    nonisolated static func upcomingHours(_ points: [HourlyWeatherPoint], now: Date,
                                          calendar: Calendar, count: Int = 6) -> [HourlyWeatherPoint] {
        let hourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return Array(points.filter { $0.date >= hourStart }.prefix(count))
    }

    /// The rain chance the status reads: the first upcoming hour's, 0 when none.
    nonisolated static func rainChance(of upcoming: [HourlyWeatherPoint]) -> Double {
        upcoming.first?.precipitationChance ?? 0
    }

    /// What `fetchWeather` keeps from all of WeatherKit's hours: the strip and
    /// its rain chance, both from the upcoming hours. Pure, so a test can see
    /// which list the rain chance came from.
    nonisolated static func strip(from points: [HourlyWeatherPoint], now: Date,
                                  calendar: Calendar) -> (hours: [HourlyWeatherPoint], rainChance: Double) {
        let hours = upcomingHours(points, now: now, calendar: calendar)
        return (hours, rainChance(of: hours))
    }
}

struct RouteWeather: Sendable {
    let symbolName: String
    let conditionDescription: String
    let temperatureText: String
    let precipitationChance: Double
    let temperatureCelsius: Double
    let hourlyForecast: [HourlyWeatherPoint]
    /// WeatherKit's own date for the current conditions (`metadata.date`).
    let asOf: Date

    var statusText: String {
        switch precipitationChance {
        case 0.7...: return "High chance of rain"
        case 0.4...: return "Some rain possible"
        default:     return "Good conditions"
        }
    }

    var statusColor: Color {
        switch precipitationChance {
        case 0.7...: return .orange
        case 0.4...: return .yellow
        default:     return .earthGreen
        }
    }

    var statusSymbol: String {
        precipitationChance >= 0.4 ? "drop.fill" : "checkmark.circle.fill"
    }
}

// MARK: - Route Difficulty

enum RouteDifficulty: String {
    case easy     = "Easy"
    case moderate = "Moderate"
    case hard     = "Hard"
    case expert   = "Expert"

    var color: Color {
        switch self {
        case .easy:     return .earthGreen
        // accentNotice, not .yellow: system yellow is 1.9:1 on a light card.
        case .moderate: return .accentNotice
        case .hard:     return .earthOrange
        case .expert:   return .red
        }
    }

    var symbol: WktSymbol {
        switch self {
        case .easy:           return .walk
        case .moderate:       return .hiking
        case .hard, .expert:  return .mountain
        }
    }

    /// Expert is the filled mountain, hard the outline.
    var symbolFilled: Bool { self == .expert }

    /// Distance-only estimate used when elevation data is unavailable.
    static func fromDistance(_ meters: Double) -> RouteDifficulty {
        switch meters {
        case 15_000...: return .expert
        case 8_000...:  return .hard
        case 3_000...:  return .moderate
        default:        return .easy
        }
    }

    enum Reason: Equatable { // what decided a level, for the why-line
        case climb(meters: Double)
        case steepness(percent: Double)
        case length
        case nothingMuch
    }

    /// The one rule for a profiled route (`ElevationService.buildProfile`
    /// calls it, so the thresholds exist once). Within a level climb is
    /// named before steepness, and both before length.
    nonisolated static func classify(lengthMeters: Double, climbMeters: Double,
                                     steepestPercent: Double) -> (RouteDifficulty, Reason) {
        if climbMeters >= 500 { return (.expert, .climb(meters: climbMeters)) }
        if steepestPercent > 25 { return (.expert, .steepness(percent: steepestPercent)) }
        if climbMeters >= 300 { return (.hard, .climb(meters: climbMeters)) }
        if steepestPercent > 15 { return (.hard, .steepness(percent: steepestPercent)) }
        if lengthMeters >= 15_000 { return (.hard, .length) }
        if climbMeters >= 100 { return (.moderate, .climb(meters: climbMeters)) }
        if lengthMeters >= 5_000 { return (.moderate, .length) }
        return (.easy, .nothingMuch)
    }

    /// "Hard because of 320 m of climb". Length is never a number here: the
    /// profile's sampled length can differ from the route distance beside it.
    /// Steepness rounds up: an Expert (over 25 %) never reads "25 %".
    nonisolated func why(_ reason: Reason) -> String {
        switch reason {
        case .climb(let meters):      return "\(rawValue) because of \(Int(meters)) m of climb"
        case .steepness(let percent): return "\(rawValue) because one part is \(Int(percent.rounded(.up))) % steep"
        case .length:                 return "\(rawValue) because of its length"
        case .nothingMuch:            return "\(rawValue): short, with little climb"
        }
    }
}

// MARK: - Elevation Models

struct ElevationPoint: Identifiable {
    let id = UUID()
    let distanceKm: Double
    let elevationMeters: Double
}

struct ElevationProfile {
    let points: [ElevationPoint]
    let totalGainMeters: Double
    let totalLossMeters: Double
    let maxElevationMeters: Double
    let minElevationMeters: Double
    /// The steepest sampled grade, in percent: one of `classify`'s inputs.
    let steepestPercent: Double
    let difficulty: RouteDifficulty
    let difficultyReason: RouteDifficulty.Reason
}

// MARK: - Weather Service (WeatherKit)

actor RouteWeatherService {
    static let shared = RouteWeatherService()
    private init() {}

    func fetchWeather(for coordinate: CLLocationCoordinate2D) async -> RouteWeather? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let weather = try await WeatherService.shared.weather(for: location)
            let current = weather.currentWeather
            let tempFormat = Measurement<UnitTemperature>.FormatStyle.measurement(width: .abbreviated, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0)))
            let tempText = current.temperature.formatted(tempFormat)
            let allHours: [HourlyWeatherPoint] = weather.hourlyForecast.map { h in
                HourlyWeatherPoint(
                    date:               h.date,
                    temperatureText:    h.temperature.formatted(tempFormat),
                    symbolName:         h.symbolName,
                    precipitationChance: h.precipitationChance
                )
            }
            let (hourly, precipChance) = UpcomingForecast.strip(from: allHours, now: Date(),
                                                                calendar: .autoupdatingCurrent)
            return RouteWeather(
                symbolName:           current.symbolName,
                conditionDescription: current.condition.description,
                temperatureText:      tempText,
                precipitationChance:  precipChance,
                temperatureCelsius:   current.temperature.converted(to: .celsius).value,
                hourlyForecast:       hourly,
                asOf:                 current.metadata.date
            )
        } catch {
            #if DEBUG
            print("[WeatherKit] fetchWeather failed: \(error)")
            #endif
            return nil
        }
    }
}

// MARK: - Elevation Service (OpenTopoData — free, no API key, SRTM 90m)

actor ElevationService {
    static let shared = ElevationService()
    private init() {}

    func fetchProfile(for coordinates: [CLLocationCoordinate2D]) async throws -> ElevationProfile {
        guard !coordinates.isEmpty else { throw URLError(.badURL) }

        let sampled   = downsample(coordinates, to: min(coordinates.count, 100))
        let locations = sampled.map { "\($0.latitude),\($0.longitude)" }.joined(separator: "|")
        let encoded   = locations.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? locations
        guard let url = URL(string: "https://api.opentopodata.org/v1/srtm90m?locations=\(encoded)") else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }

        let decoded = try JSONDecoder().decode(OTDResponse.self, from: data)
        guard decoded.status == "OK" else { throw URLError(.badServerResponse) }

        return Self.buildProfile(elevations: decoded.results.map { $0.elevation ?? 0 }, coordinates: sampled)
    }

    private func downsample(_ coords: [CLLocationCoordinate2D], to count: Int) -> [CLLocationCoordinate2D] {
        guard coords.count > count else { return coords }
        let step = Double(coords.count - 1) / Double(count - 1)
        return (0..<count).map { i in coords[Int(round(Double(i) * step))] }
    }

    nonisolated static func buildProfile(elevations: [Double], coordinates: [CLLocationCoordinate2D]) -> ElevationProfile {
        var points: [ElevationPoint] = []
        var gain = 0.0, loss = 0.0, maxGrad = 0.0, cumKm = 0.0

        for i in 0..<elevations.count {
            if i > 0 {
                let a    = CLLocation(latitude: coordinates[i-1].latitude, longitude: coordinates[i-1].longitude)
                let b    = CLLocation(latitude: coordinates[i].latitude,   longitude: coordinates[i].longitude)
                let segM = a.distance(from: b)
                cumKm   += segM / 1_000
                let d    = elevations[i] - elevations[i-1]
                if d > 0 { gain += d } else { loss -= d }
                if segM > 0 { maxGrad = max(maxGrad, abs(d) / segM * 100) }
            }
            points.append(ElevationPoint(distanceKm: cumKm, elevationMeters: elevations[i]))
        }

        let (diff, reason) = RouteDifficulty.classify(lengthMeters: cumKm * 1_000, climbMeters: gain,
                                                      steepestPercent: maxGrad)

        return ElevationProfile(
            points:             points,
            totalGainMeters:    gain,
            totalLossMeters:    loss,
            maxElevationMeters: elevations.max() ?? 0,
            minElevationMeters: elevations.min() ?? 0,
            steepestPercent:    maxGrad,
            difficulty:         diff,
            difficultyReason:   reason
        )
    }
}

private struct OTDResponse: Sendable {
    let results: [OTDResult]
    let status:  String
}
private struct OTDResult: Sendable {
    let elevation: Double?
}

// Explicit nonisolated Decodable inits so these can be decoded from any actor context.
extension OTDResponse: Decodable {
    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decode([OTDResult].self, forKey: .results)
        status  = try c.decode(String.self, forKey: .status)
    }
    private enum CodingKeys: String, CodingKey { case results, status }
}
extension OTDResult: Decodable {
    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        elevation = try c.decodeIfPresent(Double.self, forKey: .elevation)
    }
    private enum CodingKeys: String, CodingKey { case elevation }
}

// MARK: - Weather Widget

struct WeatherWidget: View {
    let weather: RouteWeather
    /// Where the forecast is for, shown above the hourly strip; nil shows none.
    let placeLabel: String?

    @State private var isExpanded: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    /// `initiallyExpanded` seeds @State once and is deliberately NOT stored: SwiftUI
    /// @State initialised from a parameter does not update when that parameter
    /// changes on a re-render, so keeping it as a property would read as live
    /// configuration while silently ignoring changes.
    /// Every screen opens it collapsed: the one-line row already says whether
    /// conditions are good, and the hours are a tap away.
    init(weather: RouteWeather, placeLabel: String? = nil, initiallyExpanded: Bool = false) {
        self.weather = weather
        self.placeLabel = placeLabel
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var hasForecast: Bool { !weather.hourlyForecast.isEmpty }

    private var conditionText: some View {
        Text(weather.conditionDescription)
            .font(.wktBodyText)
            .foregroundColor(.earthMuted)
            .lineLimit(1)
    }

    /// `wraps`: the last resort when the row is too narrow for one line. It
    /// truncated there ("Good conditi…" at the default size on a 17e); now it
    /// takes a second line instead.
    private func statusLabel(wraps: Bool = false) -> some View {
        Label(weather.statusText, systemImage: weather.statusSymbol)
            .font(.wktLabel)
            .foregroundColor(weather.statusColor)
            // Wraps at the accessibility sizes: on one line "Good conditions"
            // shrank to its check mark and a clipped glyph, and the longest
            // status, "High chance of rain", may need three lines on a 17e.
            .lineLimit(typeSize.isAccessibilitySize ? nil : (wraps ? 2 : 1))
            .fixedSize(horizontal: false, vertical: wraps)
    }

    /// Place, then the hours covered and when WeatherKit's answer is from.
    /// Wraps rather than truncates.
    private var caption: some View {
        let calendar = Calendar.autoupdatingCurrent
        let locale = Locale.autoupdatingCurrent
        let hours = weather.hourlyForecast
        let period = ForecastPeriod.text(first: hours.first?.date ?? weather.asOf,
                                         last: hours.last?.date ?? weather.asOf,
                                         now: Date(), calendar: calendar, locale: locale)
        let freshness = "Updated \(ForecastPeriod.clock(weather.asOf, calendar: calendar, locale: locale))"
        return VStack(alignment: .leading, spacing: 2) {
            if let placeLabel { Text(placeLabel) }
            Text("\(period) · \(freshness)")
        }
        .font(.wktLabel)
        .foregroundColor(.earthMuted)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("routes.weatherCaption")
    }

    var body: some View {
        // At the accessibility sizes the attribution gets a line of its own.
        // Beside the forecast toggle, the row's fixed-size pieces (temperature,
        // status, attribution) added up to more than the screen, and that one
        // row made the whole Routes results panel wider than the window: 401
        // pt on a 390 pt iPhone 17e (measured; with the tile removed the panel
        // was 390). On its own line it stays whole and tappable.
        let row = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 10))
        VStack(spacing: 0) {
            row {
                Button {
                    withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        // Variable-driven symbols from the weather model, as CLAUDE.md allows.
                        Image(systemName: weather.symbolName)
                            .font(.wktSection)
                            .symbolRenderingMode(.multicolor)
                            .frame(width: 26)

                        // Never wraps: in the height-capped results panel the row is
                        // narrow, and "65°F" broke one character per line. The
                        // condition shortens instead.
                        Text(weather.temperatureText)
                            .font(.wktRowTitle)
                            .foregroundColor(.earthCream)
                            .lineLimit(1)
                            .fixedSize()

                        // The condition is the first thing to go when the row is
                        // narrow: the symbol already shows it, and the accessibility
                        // label still says it. Truncated, it read "P…".
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                conditionText.fixedSize()
                                Spacer(minLength: 6)
                                statusLabel().fixedSize()
                            }
                            HStack(spacing: 0) {
                                Spacer(minLength: 6)
                                statusLabel().fixedSize()
                            }
                            HStack(spacing: 0) {
                                Spacer(minLength: 6)
                                statusLabel(wraps: true)
                            }
                        }

                        if hasForecast {
                            Image(wkt: .chevronDown)
                                .wktIcon(.inline, tint: .earthMuted)
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasForecast)
                .accessibilityLabel("\(weather.temperatureText), \(weather.conditionDescription). \(weather.statusText)")
                .accessibilityHint(hasForecast ? (isExpanded ? "Hides the hourly forecast" : "Shows the hourly forecast") : "")

                // Apple requires WeatherKit attribution wherever its data is shown, so
                // this stays visible when collapsed — and sits outside the toggle
                // button so it remains tappable as a link. Higher layout priority
                // than the status label plus fixedSize so it is never the thing the
                // row truncates at large Dynamic Type sizes.
                WeatherAttributionLink()
                    .layoutPriority(2)
                    .fixedSize()
            }
            .padding(.horizontal, WktSpacing.cardPadding)
            .padding(.vertical, 12)

            if isExpanded && hasForecast {
                WktDivider()
                    .padding(.horizontal, WktSpacing.cardPadding)
                caption
                    .padding(.horizontal, WktSpacing.cardPadding)
                    .padding(.top, 10)
                HourlyWeatherRow(points: weather.hourlyForecast)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            }
        }
        .wktCardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routes.weatherTile")
    }
}

// MARK: - Difficulty Badge

struct DifficultyBadge: View {
    let difficulty: RouteDifficulty
    var compact: Bool = false

    /// A status chip: the icon alone when `compact` (beside other details on a
    /// card), the icon and the word otherwise.
    var body: some View {
        let icon = Image(wkt: difficulty.symbol)
            .wktIcon(.inline, tint: difficulty.color, filled: difficulty.symbolFilled)
        if compact {
            icon
                .frame(width: 30, height: 30)
                .background(Color.earthRaised, in: Capsule())
                .accessibilityLabel("\(difficulty.rawValue) difficulty")
        } else {
            WktStatusChip(text: difficulty.rawValue, textColor: difficulty.color) { icon }
                .accessibilityLabel("\(difficulty.rawValue) difficulty")
        }
    }
}

// MARK: - Elevation Profile Chart

struct ElevationProfileChart: View {
    let profile: ElevationProfile
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The chart's height: 110 pt at the normal sizes. At the accessibility
    /// sizes the axis labels alone filled 110 pt, so the plot was 7 pt tall
    /// and the profile drew as a flat line under overlapping labels
    /// (measured at Accessibility 2; spec fix/large-text-round2, item 3).
    static func chartHeight(_ size: DynamicTypeSize) -> CGFloat {
        size.isAccessibilitySize ? 220 : 110
    }

    // Miles and feet in the US, like the spoken cues; km and metres elsewhere.
    private var usesMiles: Bool { WalkAudioCueService.usesMiles }

    private func axisDistance(_ km: Double) -> Double {
        usesMiles ? km * 1000 / WalkAudioCueService.metersPerMile : km
    }

    private var yDomain: ClosedRange<Double> {
        RouteElevation.axisDomain(min: profile.minElevationMeters, max: profile.maxElevationMeters)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The difficulty chip goes under the stats at the accessibility
            // sizes; beside them it was squeezed to "Mode / rate".
            if WktNameLayout.stacks(typeSize) {
                HStack(spacing: 16) { gainAndLoss }
                DifficultyBadge(difficulty: profile.difficulty)
            } else {
                HStack(spacing: 16) {
                    gainAndLoss
                    Spacer()
                    DifficultyBadge(difficulty: profile.difficulty)
                }
            }

            Chart(profile.points) { pt in
                AreaMark(
                    x: .value("Dist", axisDistance(pt.distanceKm)),
                    y: .value("Elev", RouteElevation.axisValue(pt.elevationMeters))
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.earthGreen.opacity(0.4), Color.earthGreen.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Dist", axisDistance(pt.distanceKm)),
                    y: .value("Elev", RouteElevation.axisValue(pt.elevationMeters))
                )
                .foregroundStyle(Color.earthGreen)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: yDomain)
            .chartXAxisLabel(usesMiles ? "mi" : "km", alignment: .trailing)
            .chartYAxisLabel(RouteElevation.axisUnit(), alignment: .top)
            .frame(height: Self.chartHeight(typeSize))
        }
        .wktCard()
    }

    @ViewBuilder
    private var gainAndLoss: some View {
        elevStat(RouteElevation.gain(profile.totalGainMeters), label: "gain", color: .earthGreen)
        elevStat(RouteElevation.loss(profile.totalLossMeters), label: "loss", color: .earthOrange)
    }

    private func elevStat(_ value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.wktRowTitle).foregroundColor(color)
            Text(label.prefix(1).uppercased() + label.dropFirst()).font(.wktLabel).foregroundColor(.earthMuted)
        }
        .accessibilityElement(children: .combine)
    }
}
