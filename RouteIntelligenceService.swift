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
        case .moderate: return .yellow
        case .hard:     return .earthOrange
        case .expert:   return .red
        }
    }

    var sfSymbol: String {
        switch self {
        case .easy:     return "figure.walk"
        case .moderate: return "figure.hiking"
        case .hard:     return "mountain.2"
        case .expert:   return "mountain.2.fill"
        }
    }

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
            let tempText = current.temperature.formatted(.measurement(width: .abbreviated, usage: .weather))
            let precipChance = weather.hourlyForecast.first?.precipitationChance ?? 0
            let hourly: [HourlyWeatherPoint] = weather.hourlyForecast.prefix(6).map { h in
                HourlyWeatherPoint(
                    date:               h.date,
                    temperatureText:    h.temperature.formatted(.measurement(width: .abbreviated, usage: .weather)),
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

    var body: some View {
        VStack(spacing: 0) {
            // Current conditions
            HStack(spacing: 14) {
                Image(systemName: weather.symbolName)
                    .font(.title2)
                    .symbolRenderingMode(.multicolor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(weather.conditionDescription)
                        .font(.subheadline.bold())
                        .foregroundColor(.earthCream)
                    Label(weather.statusText, systemImage: weather.statusSymbol)
                        .font(.subheadline)
                        .foregroundColor(weather.statusColor)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(weather.temperatureText)
                        .font(.title3.bold())
                        .foregroundColor(.earthCream)
                    WeatherAttributionLink()
                }
            }
            .padding(14)

            // Hourly strip
            if !weather.hourlyForecast.isEmpty {
                Divider()
                    .background(Color.earthMuted.opacity(0.15))
                    .padding(.horizontal, 14)
                HourlyWeatherRow(points: weather.hourlyForecast)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            }
        }
        .background(Color.earthCard)
        .cornerRadius(12)
    }
}

// MARK: - Difficulty Badge

struct DifficultyBadge: View {
    let difficulty: RouteDifficulty
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: difficulty.sfSymbol)
                .font(compact ? .caption2 : .caption)
            if !compact {
                Text(difficulty.rawValue)
                    .font(.caption.bold())
            }
        }
        .foregroundColor(difficulty.color)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 3 : 5)
        .background(difficulty.color.opacity(0.15))
        .cornerRadius(20)
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
        .padding(14)
        .background(Color.earthCard)
        .cornerRadius(12)
    }

    private func elevStat(_ value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline.bold()).foregroundColor(color)
            Text(label).font(.caption).foregroundColor(.earthMuted)
        }
    }
}
