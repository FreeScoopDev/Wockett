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
        if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .hour) { return "Now" }
        let f = DateFormatter()
        f.dateFormat = "ha"
        return f.string(from: date)  // e.g. "3PM"
    }
}

struct RouteWeather: Sendable {
    let symbolName: String
    let conditionDescription: String
    let temperatureText: String
    let precipitationChance: Double
    let temperatureCelsius: Double
    let hourlyForecast: [HourlyWeatherPoint]

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
    let difficulty: RouteDifficulty
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
            let precipChance = weather.hourlyForecast.first?.precipitationChance ?? 0
            let hourly: [HourlyWeatherPoint] = weather.hourlyForecast.prefix(6).map { h in
                HourlyWeatherPoint(
                    date:               h.date,
                    temperatureText:    h.temperature.formatted(tempFormat),
                    symbolName:         h.symbolName,
                    precipitationChance: h.precipitationChance
                )
            }
            return RouteWeather(
                symbolName:           current.symbolName,
                conditionDescription: current.condition.description,
                temperatureText:      tempText,
                precipitationChance:  precipChance,
                temperatureCelsius:   current.temperature.converted(to: .celsius).value,
                hourlyForecast:       hourly
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

        return buildProfile(elevations: decoded.results.map { $0.elevation ?? 0 }, coordinates: sampled)
    }

    private func downsample(_ coords: [CLLocationCoordinate2D], to count: Int) -> [CLLocationCoordinate2D] {
        guard coords.count > count else { return coords }
        let step = Double(coords.count - 1) / Double(count - 1)
        return (0..<count).map { i in coords[Int(round(Double(i) * step))] }
    }

    private func buildProfile(elevations: [Double], coordinates: [CLLocationCoordinate2D]) -> ElevationProfile {
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

        let totalM = cumKm * 1_000
        let diff: RouteDifficulty
        if      gain >= 500 || maxGrad > 25                      { diff = .expert }
        else if totalM >= 15_000 || gain >= 300 || maxGrad > 15  { diff = .hard }
        else if totalM >= 5_000  || gain >= 100                  { diff = .moderate }
        else                                                      { diff = .easy }

        return ElevationProfile(
            points:             points,
            totalGainMeters:    gain,
            totalLossMeters:    loss,
            maxElevationMeters: elevations.max() ?? 0,
            minElevationMeters: elevations.min() ?? 0,
            difficulty:         diff
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

    @State private var isExpanded: Bool

    /// `initiallyExpanded` seeds @State once and is deliberately NOT stored: SwiftUI
    /// @State initialised from a parameter does not update when that parameter
    /// changes on a re-render, so keeping it as a property would read as live
    /// configuration while silently ignoring changes. The Routes results panel is
    /// height-capped and passes false to keep route cards above the fold; screens
    /// with room to spare take the default.
    init(weather: RouteWeather, initiallyExpanded: Bool = true) {
        self.weather = weather
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var hasForecast: Bool { !weather.hourlyForecast.isEmpty }

    private var conditionText: some View {
        Text(weather.conditionDescription)
            .font(.wktBodyText)
            .foregroundColor(.earthMuted)
            .lineLimit(1)
    }

    private var statusLabel: some View {
        Label(weather.statusText, systemImage: weather.statusSymbol)
            .font(.wktLabel)
            .foregroundColor(weather.statusColor)
            .lineLimit(1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
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
                                statusLabel.fixedSize()
                            }
                            HStack(spacing: 0) {
                                Spacer(minLength: 6)
                                statusLabel.fixedSize()
                            }
                            HStack(spacing: 0) {
                                Spacer(minLength: 6)
                                statusLabel
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

    private var yDomain: ClosedRange<Double> {
        let pad = max((profile.maxElevationMeters - profile.minElevationMeters) * 0.3, 15)
        return (profile.minElevationMeters - pad)...(profile.maxElevationMeters + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                elevStat("+\(Int(profile.totalGainMeters))m", label: "gain",  color: .earthGreen)
                elevStat("-\(Int(profile.totalLossMeters))m", label: "loss",  color: .earthOrange)
                Spacer()
                DifficultyBadge(difficulty: profile.difficulty)
            }

            Chart(profile.points) { pt in
                AreaMark(
                    x: .value("Dist", pt.distanceKm),
                    y: .value("Elev", pt.elevationMeters)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.earthGreen.opacity(0.4), Color.earthGreen.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Dist", pt.distanceKm),
                    y: .value("Elev", pt.elevationMeters)
                )
                .foregroundStyle(Color.earthGreen)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: yDomain)
            .chartXAxisLabel("km", alignment: .trailing)
            .chartYAxisLabel("m", alignment: .top)
            .frame(height: 110)
        }
        .wktCard()
    }

    private func elevStat(_ value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.wktRowTitle).foregroundColor(color)
            Text(label.prefix(1).uppercased() + label.dropFirst()).font(.wktLabel).foregroundColor(.earthMuted)
        }
        .accessibilityElement(children: .combine)
    }
}
