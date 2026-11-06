import Foundation
import HeatPumpKit

/// Demo forecast: `MockBackend`'s outdoor model continued into the future. Like MET: hourly for
/// 60 hours, then one entry per 6 hours up to nine days, with made-up showers and symbols.
public struct MockWeatherProvider: WeatherProviding {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func fetch(latitude: Double, longitude: Double, ifModifiedSince: String?) async throws -> WeatherResponse {
        let start = (now().timeIntervalSince1970 / 3600).rounded(.down) * 3600
        let first = Int(start / 3600)
        let offsets = Array(0..<60) + (60..<(9 * 24)).filter { (first + $0) % 6 == 0 }
        let hours = offsets.map { h -> ForecastHour in
            let t = Date(timeIntervalSince1970: start + Double(h) * 3600)
            let temperature = (MockBackend.outdoorTemperature(at: t) * 10).rounded() / 10
            // Showers on some days, from smooth waves so every run shows the same weather.
            let wave = sin(t.timeIntervalSince1970 / 86_400 * 1.7) + 0.4 * sin(t.timeIntervalSince1970 / 18_000)
            let rain = max(0, (wave - 0.6) * 1.2)
            let symbol =
                rain > 0.3 ? (temperature < 0 ? "snow" : "rain")
                : wave > 0.2 ? "cloudy" : wave > -0.4 ? "partlycloudy_day" : "clearsky_day"
            return ForecastHour(
                time: t, temperature: temperature, windSpeed: 2 + 2 * abs(sin(Double(h) / 7)), humidity: 85,
                cloudFraction: 60, precipitation: h < 60 ? (rain * 10).rounded() / 10 : nil, symbol: symbol,
                precipitation6h: (rain * 60).rounded() / 10)
        }
        return WeatherResponse(status: 200, hours: hours, lastModified: nil, expires: now().addingTimeInterval(1800))
    }
}

/// Demo: a household base load with morning and evening peaks plus the simulated heat pump.
public struct MockHouseConsumptionProvider: HouseConsumptionProviding {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func fetchConsumption(lastHours: Int) async throws -> [HouseHour] {
        let current = (now().timeIntervalSince1970 / 3600).rounded(.down) * 3600
        return (1...min(max(lastHours, 1), 744)).map { back -> HouseHour in
            let start = Date(timeIntervalSince1970: current - Double(back) * 3600)
            let hourOfDay = Double(Calendar.current.component(.hour, from: start))
            let base = 0.35 + 0.9 * exp(-pow((hourOfDay - 7.5) / 1.5, 2)) + 1.3 * exp(-pow((hourOfDay - 18) / 2.2, 2))
            let pump = stride(from: 0.0, to: 3600, by: 900).map { MockLocalSimulation.averageW(at: start.addingTimeInterval($0 + 450)) }
                .reduce(0, +) / 4 / 1000
            let kWh = ((base + pump) * 100).rounded() / 100
            let ore = 85 + 35 * sin(start.timeIntervalSince1970 / 86_400 * 0.9) + 40 * exp(-pow((hourOfDay - 18) / 2.0, 2))
            return HouseHour(hour: start, kWh: kWh, costNok: (kWh * ore * 1.25).rounded() / 100, unitPriceOre: ore * 1.25)
        }
    }
}

/// Deterministic Norwegian winter price curve for `VARMEPUMPE_BACKEND=mock`: cheap nights,
/// morning and evening peaks, a different level each day. Spot in NO1 (25 % VAT).
public struct MockPriceProvider: PriceProvider {
    public let source = "mock"
    public let area = "NO1"
    public let fetchesRangesInOneRequest = true

    public init() {}

    public func fetchPrices(days: [Date], timeZone: TimeZone) async throws -> [HourPrice] {
        let calendar = WireDate.calendar(timeZone)
        return days.flatMap { day -> [HourPrice] in
            let start = calendar.startOfDay(for: day)
            let dayIndex = start.timeIntervalSince1970 / 86_400
            let level = 85 + 35 * sin(dayIndex * 0.9) + 15 * sin(dayIndex * 0.37)
            return (0..<24).compactMap { h -> HourPrice? in
                guard let hour = calendar.date(byAdding: .hour, value: h, to: start) else { return nil }
                let hh = Double(h)
                let morning = 45 * exp(-pow((hh - 8) / 1.6, 2))
                let evening = 60 * exp(-pow((hh - 18) / 2.0, 2))
                let night: Double = hh < 5 ? -25 : 0
                let spot = max(5, level + morning + evening + night)
                let rounded = (spot * 100).rounded() / 100
                return HourPrice(hour: hour, area: area, source: source, spotOre: rounded, totalOre: rounded * 1.25)
            }
        }
    }
}
