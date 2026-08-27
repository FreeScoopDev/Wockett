import SwiftUI
import CoreLocation

// MARK: - Home Weather Locator

enum WeatherFetchState {
    case idle, loading, loaded, denied, failed
}

@Observable
final class HomeWeatherLocator: NSObject {
    var weather: RouteWeather? = nil
    var fetchState: WeatherFetchState = .idle
    private var manager: CLLocationManager?

    var locationDenied: Bool { fetchState == .denied }

    @MainActor
    func fetchIfAuthorized() {
        guard weather == nil, fetchState != .loading else { return }
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyKilometer
        manager = m
        let status = m.authorizationStatus
        #if DEBUG
        print("[Weather] fetchIfAuthorized — status: \(status.rawValue)")
        #endif
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            fetchState = .loading
            m.requestLocation()
        case .notDetermined:
            m.requestWhenInUseAuthorization()
        case .denied, .restricted:
            fetchState = .denied
        @unknown default:
            break
        }
    }

    @MainActor
    func retry() {
        fetchState = .idle
        weather = nil
        fetchIfAuthorized()
    }
}

extension HomeWeatherLocator: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        Task { @MainActor in
            let result = await RouteWeatherService.shared.fetchWeather(for: loc.coordinate)
            if let result {
                self.weather = result
                self.fetchState = .loaded
            } else {
                self.fetchState = .failed
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        #if DEBUG
        print("[Weather] Auth changed — status: \(status.rawValue)")
        #endif
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            fetchState = .loading
            manager.requestLocation()
        } else if status == .denied || status == .restricted {
            fetchState = .denied
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        #if DEBUG
        print("[Weather] Location error: \(error)")
        #endif
        Task { @MainActor in
            self.fetchState = .failed
        }
    }
}

// MARK: - Apple Weather Attribution (required by WeatherKit terms)

struct WeatherAttributionLink: View {
    // Apple's required attribution URL for WeatherKit
    private let url = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 3) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 9, weight: .semibold))
                Text("Weather")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Weather Status Chips

struct WeatherDeniedChip: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: "app-settings:") {
                openURL(url)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "location.slash.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.earthMuted)
                Text("Enable location for weather")
                    .font(.caption)
                    .foregroundColor(.earthMuted)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.earthMuted.opacity(0.5))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.earthCard)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

struct WeatherFailedChip: View {
    let onRetry: () -> Void

    var body: some View {
        Button(action: onRetry) {
            HStack(spacing: 8) {
                Image(systemName: "cloud.slash")
                    .font(.system(size: 13))
                    .foregroundColor(.earthMuted)
                Text("Weather unavailable")
                    .font(.caption)
                    .foregroundColor(.earthMuted)
                Spacer()
                Text("Retry")
                    .font(.caption.bold())
                    .foregroundColor(.earthGreen)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.earthCard)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hourly Weather Row (shared between home chip and route widget)

struct HourlyWeatherRow: View {
    let points: [HourlyWeatherPoint]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                VStack(spacing: 3) {
                    Text(point.hourLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.earthMuted)
                    Image(systemName: point.symbolName)
                        .font(.system(size: 13))
                        .foregroundColor(point.precipitationChance >= 0.4 ? Color(red: 0.28, green: 0.49, blue: 0.84) : .earthCream)
                    Text(point.temperatureText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.earthCream)
                    if point.precipitationChance >= 0.3 {
                        Text("\(Int(point.precipitationChance * 100))%")
                            .font(.system(size: 9))
                            .foregroundColor(Color(red: 0.28, green: 0.49, blue: 0.84))
                    } else {
                        Spacer().frame(height: 11)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Home Weather Chip

struct HomeWeatherChip: View {
    let weather: RouteWeather
    @Environment(\.openURL) private var openURL

    private var isHot: Bool   { weather.temperatureCelsius > 28 }
    private var isRainy: Bool { weather.precipitationChance >= 0.4 }

    var body: some View {
        VStack(spacing: 0) {
            // Current conditions row
            HStack(spacing: 10) {
                Image(systemName: weather.symbolName)
                    .font(.system(size: 15))
                    .foregroundColor(iconColor)
                Text(weather.temperatureText)
                    .font(.subheadline.bold())
                    .foregroundColor(.earthCream)
                Rectangle()
                    .frame(width: 1, height: 14)
                    .foregroundColor(.earthMuted.opacity(0.3))
                Image(systemName: weather.statusSymbol)
                    .font(.system(size: 11))
                    .foregroundColor(weather.statusColor)
                Text(advisoryText)
                    .font(.caption)
                    .foregroundColor(isHot ? .earthOrange : weather.statusColor)
                    .lineLimit(1)
                Spacer()
                WeatherAttributionLink()
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, weather.hourlyForecast.isEmpty ? 10 : 8)

            // Hourly strip
            if !weather.hourlyForecast.isEmpty {
                Divider()
                    .background(Color.earthMuted.opacity(0.15))
                    .padding(.horizontal, 14)
                HourlyWeatherRow(points: weather.hourlyForecast)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .background(Color.earthCard)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHot ? Color.earthOrange.opacity(0.3) : (isRainy ? Color.blue.opacity(0.3) : Color.clear), lineWidth: 1)
        )
        // Tapping anywhere on the chip (outside the attribution link) opens Apple Weather
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: "weather://") { openURL(url) }
        }
    }

    private var advisoryText: String {
        if isHot && isRainy { return "Hot & humid — hydrate often" }
        if isHot             { return "Hot day — stay hydrated" }
        if weather.precipitationChance >= 0.7 { return "High rain chance" }
        if weather.precipitationChance >= 0.4 { return "Rain possible" }
        return weather.conditionDescription
    }

    private var iconColor: Color {
        if isHot   { return .earthOrange }
        if isRainy { return Color(red: 0.28, green: 0.49, blue: 0.84) }
        return .earthGreen
    }
}
