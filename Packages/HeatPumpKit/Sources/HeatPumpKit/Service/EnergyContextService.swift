import Foundation

/// What every device shares: electricity prices and their outlook, the weather forecast and the
/// house's consumption. One per hub (`DeviceHub.energy`), used by every device's service, so each
/// source is fetched once whatever the number of devices; the fetches are spaced across processes
/// by the store as before (`prices.*`, `weather`, `house.tibber`, never blocked by an
/// integration).
///
/// Where nothing is configured, the reference device stands in: its location for the weather
/// and its measured outdoor temperatures for the price estimate. That is the primary device
/// (`DeviceHub.primaryDevice`); a lone `HeatPumpService` uses its own.
public final class EnergyContextService: Sendable {
    public let store: HistoryStore
    public let timeZone: TimeZone
    /// Simulated sources (demo mode): the mock price area and Oslo as the fallback location.
    public let isDemo: Bool
    let now: @Sendable () -> Date
    /// Builds the price source for the current settings (nil for Norgespris or a missing token).
    let priceProvider: @Sendable (PriceSettings) -> (any PriceProvider)?
    /// Builds the forecast source for the current weather settings (nil: no forecast).
    let weatherProvider: @Sendable (WeatherSettings) -> (any WeatherProviding)?
    /// The house's consumption source (Tibber; nil without a token). Called at most hourly.
    let houseProvider: @Sendable () -> (any HouseConsumptionProviding)?
    /// The device whose readings stand in for the house (nil until a device is known).
    let referenceDevice: @Sendable () throws -> DeviceKey?
    /// The reference device's location as its integration stores it, or nil.
    let referenceLocation: @Sendable () throws -> (latitude: Double, longitude: Double)?

    public init(
        store: HistoryStore, timeZone: TimeZone = .current, isDemo: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() },
        priceProvider: @escaping @Sendable (PriceSettings) -> (any PriceProvider)? = { _ in nil },
        weatherProvider: @escaping @Sendable (WeatherSettings) -> (any WeatherProviding)? = { _ in nil },
        houseProvider: @escaping @Sendable () -> (any HouseConsumptionProviding)? = { nil },
        referenceDevice: @escaping @Sendable () throws -> DeviceKey? = { nil },
        referenceLocation: @escaping @Sendable () throws -> (latitude: Double, longitude: Double)? = { nil }
    ) {
        self.store = store
        self.timeZone = timeZone
        self.isDemo = isDemo
        self.now = now
        self.priceProvider = priceProvider
        self.weatherProvider = weatherProvider
        self.houseProvider = houseProvider
        self.referenceDevice = referenceDevice
        self.referenceLocation = referenceLocation
    }

    // MARK: Price settings

    public func priceSettings() throws -> PriceSettings {
        try store.setting(PriceSettings.self, key: HeatPumpService.priceSettingsKey) ?? .default
    }

    public func savePriceSettings(_ settings: PriceSettings) throws {
        try store.saveSetting(settings, key: HeatPumpService.priceSettingsKey)
    }

    /// Where stored spot prices for `settings` come from (nil for Norgespris).
    func priceKey(_ settings: PriceSettings) -> (source: String, area: String)? {
        if settings.agreement == .norgespris { return nil }
        if isDemo { return ("mock", "NO1") }
        return settings.agreement == .tibber ? ("tibber", "tibber") : ("hvakosterstrommen", settings.area.rawValue)
    }

    // MARK: Fetching prices

    /// Fetches missing spot prices: the last 30 days, today and, after 13:30, tomorrow.
    /// At most once per hour per source; nothing is fetched when all is stored.
    public func syncPrices() async throws -> PriceSync {
        let settings = try priceSettings()
        guard let key = priceKey(settings) else { return PriceSync(status: .notNeeded) }
        let t = now()
        let calendar = WireDate.calendar(timeZone)
        let today = calendar.startOfDay(for: t)
        var days = (0...HeatPumpService.priceBackfillDays).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let parts = calendar.dateComponents([.hour, .minute], from: t)
        if (parts.hour ?? 0) * 60 + (parts.minute ?? 0) >= 13 * 60 + 30,
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
        {
            days.insert(tomorrow, at: 0)
        }
        let missing = try days.filter { day in
            guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
            return try store.prices(source: key.source, area: key.area, from: day, to: end).count < 23
        }
        guard !missing.isEmpty else { return PriceSync(status: .upToDate) }

        switch try store.reserveFetch(
            key: "prices.\(key.source).\(key.area)", minInterval: HeatPumpService.priceInterval, now: t, blockingIntegration: nil)
        {
        case .throttled(let next):
            return PriceSync(status: .skipped, nextAllowed: next)
        case .blocked, .credentialsRejected:
            return PriceSync(status: .skipped)
        case .allowed:
            guard let provider = priceProvider(settings) else {
                return PriceSync(status: .failed, message: PriceError.missingToken.errorDescription)
            }
            let request = provider.fetchesRangesInOneRequest ? missing : Array(missing.prefix(HeatPumpService.maxPriceFilesPerSync))
            do {
                let prices = try await provider.fetchPrices(days: request, timeZone: timeZone)
                try store.upsertPrices(prices)
                try store.recordFetchSuccess(key: "prices.\(key.source).\(key.area)", now: t)
                return PriceSync(status: .fetched, count: prices.count)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return PriceSync(status: .failed, message: message)
            }
        }
    }

    /// Checks a Tibber token with one small request (at most one test per 10 s).
    public func testTibberToken(_ token: String, transport: any HTTPTransport = URLSessionTransport()) async -> String {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { return PriceError.missingToken.errorDescription ?? "" }
        if isDemo { return L10n.tr("Demo: the token was not tested against Tibber.") }
        guard (try? store.reserveFetch(key: "prices.tibber.test", minInterval: 10, now: now(), blockingIntegration: nil)) == .allowed else {
            return L10n.tr("Wait a few seconds before you test again.")
        }
        do {
            let hours = try await TibberPriceProvider(token: token, transport: transport, now: now).test(timeZone: timeZone)
            return L10n.format("The token works. Found %lld hourly prices for today.", hours)
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Prices

    /// Price per kWh for each hour with `from <= hour < to` (hours without spot data are left out).
    public func priceBreakdowns(from: Date, to: Date) throws -> [PriceBreakdown] {
        let settings = try priceSettings()
        let calendar = WireDate.calendar(timeZone)
        guard var hour = calendar.dateInterval(of: .hour, for: from)?.start else { return [] }
        var spots: [Date: HourPrice] = [:]
        if let key = priceKey(settings) {
            let history = hour.addingTimeInterval(-Double(PriceLevel.trailingHours) * 3600)
            for p in try store.prices(source: key.source, area: key.area, from: history, to: to) { spots[p.hour] = p }
        }
        var result: [PriceBreakdown] = []
        while hour < to {
            if var b = PriceCalculator.breakdown(hour: hour, settings: settings, spot: spots[hour], timeZone: timeZone) {
                if let spot = spots[hour] {
                    if let tibber = spot.level.flatMap(PriceLevel.init(tibber:)) {
                        (b.level, b.levelFromTibber) = (tibber, true)
                    } else {
                        // Same bands as Tibber, against the previous 72 hours' spot price.
                        let trailing = (1...PriceLevel.trailingHours).compactMap { spots[hour.addingTimeInterval(-Double($0) * 3600)]?.totalOre }
                        if trailing.count >= PriceLevel.minTrailingHours {
                            b.level = PriceLevel.relative(price: spot.totalOre, average: trailing.reduce(0, +) / Double(trailing.count))
                        }
                    }
                }
                result.append(b)
            }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { break }
            hour = next
        }
        return result
    }

    /// Hour prices for the local day containing `day`.
    public func prices(day: Date) throws -> [PriceBreakdown] {
        let calendar = WireDate.calendar(timeZone)
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return try priceBreakdowns(from: start, to: end)
    }

    public func priceOverview(sync: Bool = true) async throws -> PriceOverview {
        let syncResult = sync ? try await syncPrices() : nil
        let settings = try priceSettings()
        let t = now()
        let calendar = WireDate.calendar(timeZone)
        let today = try prices(day: t)
        let tomorrow = try calendar.date(byAdding: .day, value: 1, to: t).map { try prices(day: $0) } ?? []
        let hourStart = calendar.dateInterval(of: .hour, for: t)?.start ?? t
        let ahead = (today + tomorrow).filter { $0.hour >= hourStart }
        return PriceOverview(
            agreement: settings.agreement, agreementName: settings.agreement.displayName,
            current: today.first { $0.hour == hourStart }, today: today, tomorrow: tomorrow,
            cheapestAhead: Array(ahead.sorted { $0.totalOre < $1.totalOre }.prefix(3)), sync: syncResult)
    }

    // MARK: Price outlook

    /// Published prices from the current hour to the end of day `outlookDays` after today, and an
    /// estimate for the hours after the last published one (spot agreements only).
    public func priceOutlook() throws -> PriceOutlook {
        let settings = try priceSettings()
        let calendar = WireDate.calendar(timeZone)
        let t = now()
        let hourStart = calendar.dateInterval(of: .hour, for: t)?.start ?? t
        let end = calendar.date(byAdding: .day, value: HeatPumpService.outlookDays + 1, to: calendar.startOfDay(for: t)) ?? t
        let known = try priceBreakdowns(from: hourStart, to: end)
        var outlook = PriceOutlook(
            agreement: settings.agreement, known: known, estimate: [], basisDays: nil, temperatureAdjusted: false, end: end)
        guard let key = priceKey(settings) else { return outlook }
        let from = known.last.map { $0.hour.addingTimeInterval(3600) } ?? hourStart
        guard from < end else { return outlook }
        let historyStart =
            calendar.date(byAdding: .day, value: -(HeatPumpService.priceBackfillDays + 1), to: calendar.startOfDay(for: t)) ?? t
        let history = try store.prices(source: key.source, area: key.area, from: historyStart, to: from)
        guard
            let result = PriceEstimator.estimate(
                history: history, dayTemperatures: try dayTemperatures(from: historyStart, to: end), from: from, to: end,
                timeZone: timeZone)
        else {
            outlook.estimateMissing = L10n.format("The estimate needs at least %lld days of stored prices.", PriceEstimator.minDays)
            return outlook
        }
        // Spot excl. VAT → the full price per kWh, like the published hours.
        let vat = history.last.map { PriceCalculator.vatFactor($0, settings: settings) } ?? settings.area.vatFactor
        func total(_ hour: Date, _ spot: Double) -> Double? {
            let price = HourPrice(hour: hour, area: key.area, source: key.source, spotOre: spot, totalOre: spot * vat)
            return PriceCalculator.breakdown(hour: hour, settings: settings, spot: price, timeZone: timeZone)?.totalOre
        }
        outlook.estimate = result.hours.compactMap { h in
            guard let median = total(h.hour, h.median), let low = total(h.hour, h.low), let high = total(h.hour, h.high) else {
                return nil
            }
            return EstimatedPrice(hour: h.hour, totalOre: median, lowOre: min(low, median), highOre: max(high, median))
        }
        outlook.basisDays = result.basisDays
        outlook.temperatureAdjusted = result.temperatureSlope != nil
        return outlook
    }

    /// Daily mean outdoor temperature keyed by local start of day: the reference device's measured
    /// days, then the forecast.
    func dayTemperatures(from: Date, to: Date) throws -> [Date: Double] {
        var result: [Date: Double] = [:]
        for (day, mean) in try dailyOutdoorMeans(device: try referenceDevice(), from: from, to: now()) {
            if let date = WireDate.parse(day, timeZone: timeZone) { result[date] = mean }
        }
        for day in try forecastDays(from: now(), to: to) { result[day.date] = day.mean }
        return result
    }

    /// Daily mean outdoor temperature (`yyyy-MM-dd`) measured by `device` for local days with at
    /// least 12 hours of data.
    func dailyOutdoorMeans(device: DeviceKey?, from: Date, to: Date) throws -> [String: Double] {
        let hourly = try store.hourlyOutdoorMeans(device: device, from: from, to: to)
        let calendar = WireDate.calendar(timeZone)
        let byDay = Dictionary(grouping: hourly) { WireDate.day(calendar.startOfDay(for: $0.key), timeZone: timeZone) }
        return byDay.compactMapValues { hours in
            hours.count >= 12 ? hours.reduce(0) { $0 + $1.value } / Double(hours.count) : nil
        }
    }

    /// Forecast entries grouped per local day (days with at least 4 entries: MET's longer range
    /// has one entry per 6 hours).
    func forecastDays(from: Date, to: Date) throws -> [(date: Date, mean: Double, hours: [ForecastHour])] {
        let calendar = WireDate.calendar(timeZone)
        let start = calendar.startOfDay(for: from)
        let hours = try store.forecast(from: start, to: to)
        return Dictionary(grouping: hours) { calendar.startOfDay(for: $0.time) }
            .filter { $0.value.count >= 4 }
            .map { (date: $0.key, mean: $0.value.reduce(0) { $0 + $1.temperature } / Double($0.value.count), hours: $0.value) }
            .sorted { $0.date < $1.date }
    }

    // MARK: House consumption

    /// Backfills up to 744 hours the first time, then fetches only the hours since the newest
    /// stored one (plus two, which Tibber may complete late). At most once an hour.
    public func syncHouseConsumption() async throws -> HouseSync {
        let t = now()
        switch try store.reserveFetch(
            key: HeatPumpService.houseFetchKey, minInterval: HeatPumpService.houseInterval, now: t, blockingIntegration: nil)
        {
        case .throttled(let next):
            return HouseSync(status: .skipped, nextAllowed: next)
        case .blocked, .credentialsRejected:
            return HouseSync(status: .skipped)
        case .allowed:
            guard let provider = houseProvider() else { return HouseSync(status: .notConfigured) }
            let last: Int
            if let latest = try store.latestHouseHour() {
                last = min(744, max(3, Int((t.timeIntervalSince(latest) / 3600).rounded(.up)) + 2))
            } else {
                last = 744
            }
            do {
                let hours = try await provider.fetchConsumption(lastHours: last)
                try store.upsertHouseHours(hours)
                try store.recordFetchSuccess(key: HeatPumpService.houseFetchKey, now: t)
                return HouseSync(status: .fetched, count: hours.count)
            } catch {
                return HouseSync(status: .failed, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    public func houseHours(from: Date, to: Date) throws -> [HouseHour] {
        try store.houseHours(from: from, to: to)
    }

    // MARK: Weather

    public func weatherSettings() throws -> WeatherSettings {
        try store.setting(WeatherSettings.self, key: HeatPumpService.weatherSettingsKey) ?? .default
    }

    /// Saves the settings; refuses coordinates outside the globe and an e-mail without "@".
    /// When the place changes, the stored forecast hours ahead are dropped (they were for the
    /// old place) so nothing stale is shown until the next fetch.
    public func saveWeatherSettings(_ settings: WeatherSettings) throws {
        var clean = settings
        if (settings.latitude == nil) != (settings.longitude == nil) {
            throw HeatPumpError.validation(L10n.tr("Enter both latitude and longitude, or neither."))
        }
        if let lat = settings.latitude, let lon = settings.longitude {
            guard (-90...90).contains(lat), (-180...180).contains(lon) else {
                throw HeatPumpError.validation(L10n.tr("Latitude must be between −90 and 90, longitude between −180 and 180."))
            }
        }
        let email = settings.contactEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !email.isEmpty, !email.contains("@") || email.contains(" ") {
            throw HeatPumpError.validation(L10n.tr("The contact email does not look right."))
        }
        clean.contactEmail = email.isEmpty ? nil : email
        let place = settings.placeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        clean.placeName = place.isEmpty ? nil : place
        let oldKey = try weatherLocation()?.key
        try store.saveSetting(clean, key: HeatPumpService.weatherSettingsKey)
        if try weatherLocation()?.key != oldKey { try store.clearForecast(from: now()) }
    }

    /// Typed coordinates win; otherwise the reference device's location as its service stores
    /// it; the demo uses Oslo.
    public func weatherLocation() throws -> WeatherLocation? {
        let settings = try weatherSettings()
        if let lat = settings.latitude, let lon = settings.longitude {
            return WeatherLocation(latitude: lat, longitude: lon, placeName: settings.placeName, source: .manual)
        }
        if let location = try referenceLocation() {
            return WeatherLocation(latitude: location.latitude, longitude: location.longitude, placeName: settings.placeName, source: .service)
        }
        if isDemo { return WeatherLocation(latitude: 59.91, longitude: 10.75, placeName: settings.placeName, source: .demo) }
        return nil
    }

    func weatherMeta() throws -> WeatherFetchMeta {
        try store.setting(WeatherFetchMeta.self, key: HeatPumpService.weatherMetaKey) ?? WeatherFetchMeta()
    }

    /// Fetches the forecast when the stored one has expired, at most hourly across processes.
    public func syncWeather() async throws -> WeatherSync {
        guard let location = try weatherLocation() else {
            return WeatherSync(status: .noLocation, message: L10n.tr("No position for the weather forecast. Enter a place under Settings → Weather."))
        }
        let t = now()
        var meta = try weatherMeta()
        let sameLocation = meta.locationKey == location.key
        if sameLocation, let expires = meta.expires, expires > t, meta.lastError == nil {
            return WeatherSync(status: .upToDate)
        }
        let minInterval = sameLocation ? HeatPumpService.weatherInterval : HeatPumpService.weatherNewLocationInterval
        switch try store.reserveFetch(key: HeatPumpService.weatherFetchKey, minInterval: minInterval, now: t, blockingIntegration: nil) {
        case .throttled(let next):
            return WeatherSync(status: .skipped, nextAllowed: next)
        case .blocked, .credentialsRejected:
            return WeatherSync(status: .skipped)
        case .allowed:
            guard let provider = weatherProvider(try weatherSettings()) else {
                return WeatherSync(status: .failed, message: L10n.tr("The weather forecast is not available."))
            }
            do {
                let response = try await provider.fetch(
                    latitude: location.latitude, longitude: location.longitude,
                    ifModifiedSince: sameLocation ? meta.lastModified : nil)
                meta.locationKey = location.key
                meta.expires = response.expires ?? t.addingTimeInterval(HeatPumpService.weatherInterval)
                meta.lastModified = response.lastModified
                meta.lastError = nil
                if response.status == 304 {
                    try store.saveSetting(meta, key: HeatPumpService.weatherMetaKey)
                    try store.recordFetchSuccess(key: HeatPumpService.weatherFetchKey, now: t)
                    return WeatherSync(status: .notModified)
                }
                // Keep at most nine days.
                let hours = response.hours.filter { $0.time < t.addingTimeInterval(9 * 86_400) }
                try store.replaceForecast(hours, fetchedAt: t)
                meta.fetchedAt = t
                try store.saveSetting(meta, key: HeatPumpService.weatherMetaKey)
                try store.recordFetchSuccess(key: HeatPumpService.weatherFetchKey, now: t)
                return WeatherSync(status: .fetched, count: hours.count)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                meta.lastError = message
                if case .throttled(let until) = error as? WeatherError { meta.expires = until }
                try store.saveSetting(meta, key: HeatPumpService.weatherMetaKey)
                return WeatherSync(status: .failed, message: message)
            }
        }
    }

    /// Stored forecast hours with `from <= hour < to` and where they are for.
    public func weatherForecast(from: Date, to: Date) throws -> WeatherForecast {
        WeatherForecast(location: try weatherLocation(), hours: try store.forecast(from: from, to: to), fetchedAt: try weatherMeta().fetchedAt)
    }
}
