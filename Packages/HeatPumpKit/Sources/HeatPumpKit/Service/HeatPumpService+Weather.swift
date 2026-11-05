import Foundation

/// Weather forecast from MET Norway and the expected use tomorrow.
///
/// MET's terms: identifying User-Agent, at most every 10 minutes (we use 1 h, `fetch_state` key
/// `weather`), respect `Expires`, send `If-Modified-Since`. The forecast is stored so the MCP helper
/// and the app share one fetch.
extension HeatPumpService {
    static let weatherSettingsKey = "weatherSettings"
    static let weatherMetaKey = "weatherMeta"
    public static let weatherFetchKey = "weather"
    public static let weatherInterval: TimeInterval = 3600
    /// Days of history used for the degree-day model.
    static let forecastModelDays = 45

    // MARK: Settings and location

    public func weatherSettings() throws -> WeatherSettings {
        try store.setting(WeatherSettings.self, key: Self.weatherSettingsKey) ?? .default
    }

    /// Saves the settings; refuses coordinates outside the globe and an e-mail without "@".
    public func saveWeatherSettings(_ settings: WeatherSettings) throws {
        var clean = settings
        if (settings.latitude == nil) != (settings.longitude == nil) {
            throw HeatPumpError.validation("Fyll inn både breddegrad og lengdegrad, eller ingen av dem.")
        }
        if let lat = settings.latitude, let lon = settings.longitude {
            guard (-90...90).contains(lat), (-180...180).contains(lon) else {
                throw HeatPumpError.validation("Breddegrad må være mellom −90 og 90, lengdegrad mellom −180 og 180.")
            }
        }
        let email = settings.contactEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !email.isEmpty, !email.contains("@") || email.contains(" ") {
            throw HeatPumpError.validation("Kontakt-e-posten ser ikke riktig ut.")
        }
        clean.contactEmail = email.isEmpty ? nil : email
        let place = settings.placeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        clean.placeName = place.isEmpty ? nil : place
        try store.saveSetting(clean, key: Self.weatherSettingsKey)
    }

    /// Typed coordinates win; otherwise the MELCloud building location; the demo uses Oslo.
    public func weatherLocation() throws -> WeatherLocation? {
        let settings = try weatherSettings()
        if let lat = settings.latitude, let lon = settings.longitude {
            return WeatherLocation(latitude: lat, longitude: lon, placeName: settings.placeName, source: .manual)
        }
        if let deviceId = try store.latestSnapshot()?.state.deviceId,
            let location = MELCloudClassicParser.buildingLocation(try store.rawDevice(deviceId: deviceId)?.listing)
        {
            return WeatherLocation(latitude: location.latitude, longitude: location.longitude, placeName: settings.placeName, source: .melcloud)
        }
        if isDemo { return WeatherLocation(latitude: 59.91, longitude: 10.75, placeName: settings.placeName, source: .demo) }
        return nil
    }

    func weatherMeta() throws -> WeatherFetchMeta {
        try store.setting(WeatherFetchMeta.self, key: Self.weatherMetaKey) ?? WeatherFetchMeta()
    }

    // MARK: Fetching

    /// Fetches the forecast when the stored one has expired, at most hourly across processes.
    public func syncWeather() async throws -> WeatherSync {
        guard let location = try weatherLocation() else {
            return WeatherSync(status: .noLocation, message: "Ingen posisjon for værvarselet. Legg inn sted under Innstillinger → Vær.")
        }
        let t = now()
        var meta = try weatherMeta()
        let sameLocation = meta.locationKey == location.key
        if sameLocation, let expires = meta.expires, expires > t, meta.lastError == nil {
            return WeatherSync(status: .upToDate)
        }
        switch try store.reserveFetch(key: Self.weatherFetchKey, minInterval: Self.weatherInterval, now: t, melcloud: false) {
        case .throttled(let next):
            return WeatherSync(status: .skipped, nextAllowed: next)
        case .blocked, .credentialsRejected:
            return WeatherSync(status: .skipped)
        case .allowed:
            guard let provider = weatherProvider(try weatherSettings()) else {
                return WeatherSync(status: .failed, message: "Værvarsel er ikke tilgjengelig.")
            }
            do {
                let response = try await provider.fetch(
                    latitude: location.latitude, longitude: location.longitude,
                    ifModifiedSince: sameLocation ? meta.lastModified : nil)
                meta.locationKey = location.key
                meta.expires = response.expires ?? t.addingTimeInterval(Self.weatherInterval)
                meta.lastModified = response.lastModified
                meta.lastError = nil
                if response.status == 304 {
                    try store.saveSetting(meta, key: Self.weatherMetaKey)
                    try store.recordFetchSuccess(key: Self.weatherFetchKey, now: t)
                    return WeatherSync(status: .notModified)
                }
                // Keep at most nine days.
                let hours = response.hours.filter { $0.time < t.addingTimeInterval(9 * 86_400) }
                try store.replaceForecast(hours, fetchedAt: t)
                meta.fetchedAt = t
                try store.saveSetting(meta, key: Self.weatherMetaKey)
                try store.recordFetchSuccess(key: Self.weatherFetchKey, now: t)
                return WeatherSync(status: .fetched, count: hours.count)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                meta.lastError = message
                if case .throttled(let until) = error as? WeatherError { meta.expires = until }
                try store.saveSetting(meta, key: Self.weatherMetaKey)
                return WeatherSync(status: .failed, message: message)
            }
        }
    }

    /// Stored forecast hours with `from <= hour < to` and where they are for.
    public func weatherForecast(from: Date, to: Date) throws -> WeatherForecast {
        WeatherForecast(location: try weatherLocation(), hours: try store.forecast(from: from, to: to), fetchedAt: try weatherMeta().fetchedAt)
    }

    // MARK: Expected use tomorrow

    /// Daily mean outdoor temperature (`yyyy-MM-dd`) for local days with at least 12 hours of data.
    func dailyOutdoorMeans(from: Date, to: Date) throws -> [String: Double] {
        let deviceId = try store.latestSnapshot()?.state.deviceId
        let hourly = try store.hourlyOutdoorMeans(deviceId: deviceId, from: from, to: to)
        let calendar = WireDate.calendar(timeZone)
        let byDay = Dictionary(grouping: hourly) { WireDate.day(calendar.startOfDay(for: $0.key), timeZone: timeZone) }
        return byDay.compactMapValues { hours in
            hours.count >= 12 ? hours.reduce(0) { $0 + $1.value } / Double(hours.count) : nil
        }
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
