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
        // The status is handled in locationManagerDidChangeAuthorization, which
        // CoreLocation calls as soon as the delegate is set. Reading
        // `m.authorizationStatus` here instead is a synchronous call to locationd
        // on the main thread, while Home is appearing.
        manager = m
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
        } else if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
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
    // Apple's required attribution URL for WeatherKit. Optional rather than
    // force-unwrapped: SwiftLint 0.57.0, which CI ran until 2026-09-26, flagged the
    // `!` here while 0.65.1 exempts literal URLs, so the two disagreed. A literal
    // https URL cannot fail to parse; the else branch exists so the attribution
    // — required by WeatherKit's terms — is present structurally, not only when
    // the parse succeeds.
    private let url = URL(string: "https://weatherkit.apple.com/legal-attribution.html")

    var body: some View {
        if let url {
            Link(destination: url) { label }
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 3) {
            Image(wkt: .appleLogo)
                .font(.system(size: 9, weight: .semibold))
            Text("Weather")
                .font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Home Weather Status Chip

/// The weather as a status chip in Home's hero card (2026-09-30 redesign):
/// "☀ 72°", "Weather off" or "Weather unavailable". Status is a chip, never a
/// card. The forecast and Apple's attribution are one tap away, in
/// `HomeWeatherDetailSheet`, because WeatherKit's terms need the attribution
/// wherever the data is shown in detail and a 30 pt chip has no room for it.
struct HomeWeatherStatusChip: View {
    let locator: HomeWeatherLocator
    let onShowDetail: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch locator.fetchState {
        case .loaded:
            if let weather = locator.weather {
                WktStatusChip(text: weather.temperatureText, action: onShowDetail) {
                    // Variable-driven symbol from the weather model, as CLAUDE.md allows.
                    Image(systemName: weather.symbolName)
                        .font(.wktLabel)
                        .symbolRenderingMode(.multicolor)
                }
                .accessibilityLabel("\(weather.temperatureText), \(weather.conditionDescription)")
                .accessibilityHint("Shows the forecast")
                .accessibilityIdentifier("home.weatherChip")
            }
        case .denied:
            WktStatusChip(text: "Weather off", textColor: .earthMuted, action: {
                if let url = URL(string: "app-settings:") { openURL(url) }
            }) {
                Image(wkt: .locationOff).wktIcon(.inline, tint: .earthMuted)
            }
            .accessibilityHint("Opens Settings to allow location for weather")
        case .failed:
            WktStatusChip(text: "Weather unavailable", textColor: .earthMuted, action: { locator.retry() }) {
                Image(wkt: .refresh).wktIcon(.inline, tint: .earthGreen)
            }
            .accessibilityHint("Tries again")
        case .idle, .loading:
            EmptyView()
        }
    }
}

// MARK: - Hourly Weather Row (shared between the Home weather sheet and route widget)

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
                        .foregroundColor(point.precipitationChance >= 0.4 ? Color.accentInfo : .earthCream)
                    Text(point.temperatureText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.earthCream)
                    if point.precipitationChance >= 0.3 {
                        Text("\(Int(point.precipitationChance * 100))%")
                            .font(.system(size: 9))
                            .foregroundColor(Color.accentInfo)
                    } else {
                        Spacer().frame(height: 11)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Home Weather Detail Sheet

/// What the weather chip opens: conditions, the hourly strip, a link to
/// Apple Weather, and the WeatherKit attribution.
struct HomeWeatherDetailSheet: View {
    let weather: RouteWeather
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    private var isHot: Bool   { weather.temperatureCelsius > 28 }
    private var isRainy: Bool { weather.precipitationChance >= 0.4 }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: WktSpacing.betweenCards) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: weather.symbolName)
                            .font(.wktHeading(28))
                            .symbolRenderingMode(.multicolor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(weather.temperatureText)
                                .font(.wktMetric)
                                .foregroundColor(.earthCream)
                            Text(advisoryText)
                                .font(.wktBodyText)
                                .foregroundColor(isHot ? .earthOrange : .earthMuted)
                        }
                    }
                    if !weather.hourlyForecast.isEmpty {
                        Rectangle().fill(Color.earthTrack).frame(height: 1)
                        HourlyWeatherRow(points: weather.hourlyForecast)
                    }
                }
                .wktCard()

                HStack {
                    Button("Open Apple Weather") {
                        if let url = URL(string: "weather://") { openURL(url) }
                    }
                    .font(.wktBodyText)
                    .foregroundColor(.earthGreen)
                    Spacer()
                    WeatherAttributionLink()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WktSpacing.screen)
            .padding(.top, 8)
            .background(Color.earthBg.ignoresSafeArea())
            .navigationTitle("Weather")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var advisoryText: String {
        if isHot && isRainy { return "Hot & humid — hydrate often" }
        if isHot             { return "Hot day — stay hydrated" }
        if weather.precipitationChance >= 0.7 { return "High rain chance" }
        if weather.precipitationChance >= 0.4 { return "Rain possible" }
        return weather.conditionDescription
    }
}
