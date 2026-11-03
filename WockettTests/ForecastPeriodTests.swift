import Testing
import Foundation
@testable import PoCSquat

/// The route weather's hours follow the person's 12/24-hour setting, and a
/// forecast crossing midnight names both days (spec fix/route-weather-block).
/// A fixed "ha" format ignored a US phone with 24-Hour Time on, and bare
/// hours crossing midnight ("23, 00, 01") read as a list of numbers.
///
/// Expected strings are what `Date.FormatStyle` gives, pinned from a run:
/// a 12-hour time has a narrow no-break space (U+202F) before AM/PM, written
/// here as `\u{202F}`.
struct ForecastPeriodTests {

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private static let us = Locale(identifier: "en_US")
    private static let gb = Locale(identifier: "en_GB")
    /// A US phone with Settings → General → Date & Time → 24-Hour Time on.
    private static let us24: Locale = {
        var components = Locale.Components(locale: Locale(identifier: "en_US"))
        components.hourCycle = .zeroToTwentyThree
        return Locale(components: components)
    }()

    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private static func label(_ date: Date, now: Date, _ locale: Locale) -> String {
        HourlyWeatherPoint.label(for: date, now: now, calendar: calendar, locale: locale)
    }

    // MARK: Hour labels

    @Test func hourLabelsAt23And00InTwelveHourUS() {
        let now = Self.at(3, 12)
        #expect(Self.label(Self.at(3, 23), now: now, Self.us) == "11\u{202F}PM")
        #expect(Self.label(Self.at(4, 0), now: now, Self.us) == "12\u{202F}AM")
    }

    @Test func hourLabelsAt23And00InBritishEnglish() {
        let now = Self.at(3, 12)
        #expect(Self.label(Self.at(3, 23), now: now, Self.gb) == "23")
        #expect(Self.label(Self.at(4, 0), now: now, Self.gb) == "00")
    }

    @Test func hourLabelsFollowAUSPhoneSetTo24Hour() {
        let now = Self.at(3, 12)
        #expect(Self.label(Self.at(3, 23), now: now, Self.us24) == "23")
        #expect(Self.label(Self.at(4, 0), now: now, Self.us24) == "00")
    }

    @Test func currentHourReadsNow() {
        let now = Self.at(3, 15, 41)
        for locale in [Self.us, Self.gb, Self.us24] {
            #expect(Self.label(Self.at(3, 15), now: now, locale) == "Now")
            #expect(Self.label(Self.at(3, 16), now: now, locale) != "Now")
        }
    }

    // MARK: Period

    private static func period(_ first: Date, _ last: Date, now: Date, _ locale: Locale) -> String {
        ForecastPeriod.text(first: first, last: last, now: now, calendar: calendar, locale: locale)
    }

    @Test func rangeWithinToday() {
        let now = Self.at(3, 15, 10)
        #expect(Self.period(Self.at(3, 15), Self.at(3, 20), now: now, Self.us) == "Today, 3\u{202F}PM – 8\u{202F}PM")
        #expect(Self.period(Self.at(3, 15), Self.at(3, 20), now: now, Self.gb) == "Today, 15:00 – 20:00")
        #expect(Self.period(Self.at(3, 15), Self.at(3, 20), now: now, Self.us24) == "Today, 15:00 – 20:00")
    }

    @Test func rangeCrossingMidnightNamesBothDays() {
        let now = Self.at(3, 22, 30)
        #expect(Self.period(Self.at(3, 22), Self.at(4, 3), now: now, Self.us) == "Today 10\u{202F}PM – tomorrow 3\u{202F}AM")
        #expect(Self.period(Self.at(3, 22), Self.at(4, 3), now: now, Self.gb) == "Today 22:00 – tomorrow 03:00")
        #expect(Self.period(Self.at(3, 22), Self.at(4, 3), now: now, Self.us24) == "Today 22:00 – tomorrow 03:00")
    }

    /// WeatherKit's hourly forecast was seen starting the evening before
    /// (22:00 at 08:53 on an iPhone 17e simulator), so the caption must say so.
    @Test func rangeStartingYesterdaySaysYesterday() {
        let now = Self.at(4, 8, 53)
        #expect(Self.period(Self.at(3, 22), Self.at(4, 3), now: now, Self.us) == "Yesterday 10\u{202F}PM – today 3\u{202F}AM")
        #expect(Self.period(Self.at(3, 22), Self.at(4, 3), now: now, Self.gb) == "Yesterday 22:00 – today 03:00")
    }

    @Test func updatedTimeFollowsTheHourSetting() {
        let asOf = Self.at(3, 14, 41)
        #expect(ForecastPeriod.clock(asOf, calendar: Self.calendar, locale: Self.us) == "2:41\u{202F}PM")
        #expect(ForecastPeriod.clock(asOf, calendar: Self.calendar, locale: Self.gb) == "14:41")
        #expect(ForecastPeriod.clock(asOf, calendar: Self.calendar, locale: Self.us24) == "14:41")
    }
}
