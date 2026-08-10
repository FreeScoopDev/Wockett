import SwiftUI
import CoreLocation

// MARK: - Home Weather Locator

@Observable
final class HomeWeatherLocator: NSObject {
    var weather: RouteWeather? = nil
    private var manager: CLLocationManager?

    @MainActor
    func fetchIfAuthorized() {
        guard weather == nil else { return }  // only fetch once per session
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyKilometer
        manager = m
        guard m.authorizationStatus == .authorizedWhenInUse ||
              m.authorizationStatus == .authorizedAlways else { return }
        m.requestLocation()
    }
}

extension HomeWeatherLocator: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        Task { @MainActor in
            self.weather = await RouteWeatherService.shared.fetchWeather(for: loc.coordinate)
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

// MARK: - Home Weather Chip

struct HomeWeatherChip: View {
    let weather: RouteWeather

    private var isHot: Bool   { weather.temperatureCelsius > 28 }
    private var isRainy: Bool { weather.precipitationChance >= 0.4 }

    var body: some View {
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
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.earthCard)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHot ? Color.earthOrange.opacity(0.3) : (isRainy ? Color.blue.opacity(0.3) : Color.clear), lineWidth: 1)
        )
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
