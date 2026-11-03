import Testing
import Foundation
@testable import PoCSquat

/// The weather strip starts at the current hour (spec
/// fix/route-weather-upcoming-hours). WeatherKit's hourly forecast can begin
/// 10-11 hours before now, so the first six points were hours already over,
/// and the rain chance read from the first one described a past hour.
struct UpcomingHoursTests {

    /// Not UTC, so a helper that used UTC or the device's zone for the hour
    /// start would be caught by the half-hour cases.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")! // UTC+5:30
        return calendar
    }()

    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    /// One point an hour from `first` for `hours` hours; the rain chance is
    /// the point's index / 100, so each point is recognisable.
    private static func forecast(from first: Date, hours: Int) -> [HourlyWeatherPoint] {
        (0..<hours).map { index in
            HourlyWeatherPoint(date: first.addingTimeInterval(Double(index) * 3600),
                               temperatureText: "\(index)°",
                               symbolName: "sun.max",
                               precipitationChance: Double(index) / 100)
        }
    }

    private static func upcoming(_ points: [HourlyWeatherPoint], now: Date, count: Int = 6) -> [HourlyWeatherPoint] {
        UpcomingForecast.upcomingHours(points, now: now, calendar: calendar, count: count)
    }

    // MARK: upcomingHours

    /// The simulator case: at 08:53 the forecast began at 22:00 the evening before.
    @Test func pastPointsAreDroppedAndTheStripStartsAtTheCurrentHour() {
        let now = Self.at(3, 8, 53)
        let points = Self.forecast(from: Self.at(2, 22), hours: 48)
        let hours = Self.upcoming(points, now: now)
        #expect(hours.count == 6)
        #expect(hours.first?.date == Self.at(3, 8))
        #expect(hours.last?.date == Self.at(3, 13))
        #expect(hours.allSatisfy { $0.date >= Self.at(3, 8) })
    }

    @Test func theCurrentHourIsKeptOnTheHour() {
        let now = Self.at(3, 8)
        let hours = Self.upcoming(Self.forecast(from: Self.at(3, 5), hours: 24), now: now)
        #expect(hours.first?.date == Self.at(3, 8))
    }

    @Test func aHalfHourNowKeepsItsHoursPoint() {
        // 08:30 in UTC+5:30 is 03:00 UTC: an hour start in UTC, not here.
        let now = Self.at(3, 8, 30)
        let hours = Self.upcoming(Self.forecast(from: Self.at(3, 7), hours: 10), now: now)
        #expect(hours.first?.date == Self.at(3, 8))
        #expect(hours.first.map { Self.calendar.isDate($0.date, equalTo: now, toGranularity: .hour) } == true)
    }

    @Test func exactlySixFromALongForecast() {
        let now = Self.at(3, 12, 10)
        let hours = Self.upcoming(Self.forecast(from: Self.at(3, 12), hours: 240), now: now)
        #expect(hours.map(\.date) == (0..<6).map { Self.at(3, 12 + $0) })
    }

    @Test func fewerThanSixUpcomingReturnsWhatThereIs() {
        let now = Self.at(3, 20, 15)
        let hours = Self.upcoming(Self.forecast(from: Self.at(3, 10), hours: 13), now: now) // last point 22:00
        #expect(hours.map(\.date) == [Self.at(3, 20), Self.at(3, 21), Self.at(3, 22)])
    }

    @Test func noUpcomingPointsGivesAnEmptyStrip() {
        let now = Self.at(3, 20, 15)
        #expect(Self.upcoming(Self.forecast(from: Self.at(3, 10), hours: 5), now: now).isEmpty)
        #expect(Self.upcoming([], now: now).isEmpty)
    }

    @Test func countIsHonoured() {
        let now = Self.at(3, 8, 53)
        let hours = Self.upcoming(Self.forecast(from: Self.at(2, 22), hours: 48), now: now, count: 3)
        #expect(hours.map(\.date) == [Self.at(3, 8), Self.at(3, 9), Self.at(3, 10)])
    }

    // MARK: Rain chance

    @Test func rainChanceIsTheFirstUpcomingHours() {
        let points = Self.forecast(from: Self.at(3, 8), hours: 3)
        #expect(UpcomingForecast.rainChance(of: Array(points.dropFirst())) == 0.01)
        #expect(UpcomingForecast.rainChance(of: Array(points.dropFirst(2))) == 0.02)
        #expect(UpcomingForecast.rainChance(of: []) == 0)
    }

    /// What `fetchWeather` keeps: the rain chance comes from the current hour
    /// (index 11 from 22:00 the evening before is 09:00), not from 22:00.
    @Test func theStripsRainChanceIsTheCurrentHoursNotAPastOne() {
        let now = Self.at(3, 9, 20)
        let points = Self.forecast(from: Self.at(2, 22), hours: 48)
        let strip = UpcomingForecast.strip(from: points, now: now, calendar: Self.calendar)
        #expect(strip.hours.first?.date == Self.at(3, 9))
        #expect(strip.rainChance == 0.11)
        #expect(strip.hours.count == 6)
    }

    @Test func anEmptyStripHasNoRain() {
        let strip = UpcomingForecast.strip(from: [], now: Self.at(3, 9), calendar: Self.calendar)
        #expect(strip.hours.isEmpty)
        #expect(strip.rainChance == 0)
    }
}
