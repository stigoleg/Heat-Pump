import Foundation

/// Weather forecast from MET Norway (shared, `EnergyContextService`) and this device's expected
/// use tomorrow.
///
/// MET's terms: identifying User-Agent, at most every 10 minutes (we use 1 h, `fetch_state` key
/// `weather`), respect `Expires`, send `If-Modified-Since`. The forecast is stored so the MCP helper
/// and the app share one fetch.
extension HeatPumpService {
    static let weatherSettingsKey = "weatherSettings"
    static let weatherMetaKey = "weatherMeta"
    public static let weatherFetchKey = "weather"
    public static let weatherInterval: TimeInterval = 3600
    /// After a location change the next fetch may come sooner: MET's own minimum spacing.
    public static let weatherNewLocationInterval: TimeInterval = 600
    /// Days of history used for the degree-day model.
    static let forecastModelDays = 45

    // MARK: Settings, location and forecast (shared by every device: `energy`)

    public func weatherSettings() throws -> WeatherSettings { try energy.weatherSettings() }

    /// Saves the settings; refuses coordinates outside the globe and an e-mail without "@".
    public func saveWeatherSettings(_ settings: WeatherSettings) throws { try energy.saveWeatherSettings(settings) }

    /// Typed coordinates win; otherwise the reference (primary) device's location as its service
    /// stores it; the demo uses Oslo.
    public func weatherLocation() throws -> WeatherLocation? { try energy.weatherLocation() }

    /// Fetches the forecast when the stored one has expired, at most hourly across processes.
    public func syncWeather() async throws -> WeatherSync { try await energy.syncWeather() }

    /// Stored forecast hours with `from <= hour < to` and where they are for.
    public func weatherForecast(from: Date, to: Date) throws -> WeatherForecast { try energy.weatherForecast(from: from, to: to) }

    // MARK: Expected use tomorrow

    /// Daily mean outdoor temperature (`yyyy-MM-dd`) for local days with at least 12 hours of data.
    func dailyOutdoorMeans(from: Date, to: Date) throws -> [String: Double] {
        try energy.dailyOutdoorMeans(device: try currentDevice(), from: from, to: to)
    }

    /// The degree-day model from the last 45 complete days with kWh (exact local days where
    /// measured) and an outdoor mean. Nil with fewer than 10 such days.
    public func degreeDayModel() throws -> DegreeDayModel? {
        let t = now()
        let calendar = WireDate.calendar(timeZone)
        let today = calendar.startOfDay(for: t)
        guard let from = calendar.date(byAdding: .day, value: -Self.forecastModelDays, to: today) else { return nil }
        let days = try energy(period: .day, from: from, to: today.addingTimeInterval(-1)).filter { $0.totalKWh > 0 }
        let means = try dailyOutdoorMeans(from: from, to: today)
        let points = days.compactMap { day -> (degreeDays: Double, kWh: Double)? in
            guard let mean = means[day.period] else { return nil }
            return (DegreeDayModel.degreeDays(mean: mean), day.totalKWh)
        }
        return DegreeDayModel.fit(points)
    }

    /// Expected kWh and cost tomorrow from the forecast, the degree-day model and tomorrow's prices
    /// (today's hourly prices when tomorrow's are not out yet). Nil without enough data.
    public func tomorrowEstimate() throws -> TomorrowEstimate? {
        let calendar = WireDate.calendar(timeZone)
        guard let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now())),
            let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { return nil }
        let hours = try store.forecast(from: start, to: end)
        guard hours.count >= 20, let model = try degreeDayModel() else { return nil }
        let temps = hours.map(\.temperature)
        let mean = temps.reduce(0, +) / Double(temps.count)
        let degreeDays = DegreeDayModel.degreeDays(mean: mean)
        let kWh = model.predict(degreeDays: degreeDays)
        let low = max(0, kWh - model.residualStd)
        let high = kWh + model.residualStd

        var prices = Dictionary(try priceBreakdowns(from: start, to: end).map { ($0.hour, $0.totalOre) }, uniquingKeysWith: { a, _ in a })
        var fromToday = false
        if prices.count < 20 {
            // Spot prices for tomorrow come around 13:00; until then today's hours stand in.
            let today = try priceBreakdowns(from: start.addingTimeInterval(-86_400), to: start)
            prices = Dictionary(today.map { ($0.hour.addingTimeInterval(86_400), $0.totalOre) }, uniquingKeysWith: { a, _ in a })
            fromToday = !prices.isEmpty
        }
        let priced = hours.compactMap { h in prices[h.time].map { (temperature: h.temperature, priceOre: $0) } }
        let usable = priced.count >= 20
        func cost(_ value: Double) -> Double? {
            usable ? EnergyForecast.cost(kWh: value, hours: priced).map { ($0 * 10).rounded() / 10 } : nil
        }
        func r(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        return TomorrowEstimate(
            day: WireDate.day(start, timeZone: timeZone), kWh: r(kWh), kWhLow: r(low), kWhHigh: r(high), costNok: cost(kWh),
            costLowNok: cost(low), costHighNok: cost(high), meanOutdoor: r(mean), minOutdoor: temps.min() ?? mean,
            basisDays: model.days, pricesFromToday: usable && fromToday)
    }
}
