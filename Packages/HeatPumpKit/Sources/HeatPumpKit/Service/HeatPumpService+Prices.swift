import Foundation

/// Result of a price update.
public struct PriceSync: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// Norgespris: no price data needed.
        case notNeeded
        /// Everything wanted is stored already.
        case upToDate
        case fetched
        /// Fetched less than an hour ago.
        case skipped
        case failed
    }

    public var status: Status
    public var count: Int = 0
    public var message: String?
    public var nextAllowed: Date?
}

/// Prices for the MCP `get_prices` tool and the app.
public struct PriceOverview: Codable, Sendable, Equatable {
    public var agreement: PriceAgreementKind
    public var agreementName: String
    public var current: PriceBreakdown?
    public var today: [PriceBreakdown]
    /// Empty until tomorrow's prices are published (around 13:00).
    public var tomorrow: [PriceBreakdown]
    /// The three cheapest whole hours from now on, cheapest first.
    public var cheapestAhead: [PriceBreakdown]
    public var sync: PriceSync?
}

extension HeatPumpService {
    static let priceSettingsKey = "priceSettings"
    /// At most one price request per hour per source.
    public static let priceInterval: TimeInterval = 3600
    /// Days of past prices kept up to date.
    public static let priceBackfillDays = 30
    /// Most single-day files fetched in one update from sources without range requests.
    static let maxPriceFilesPerSync = 10

    // MARK: Settings

    public func priceSettings() throws -> PriceSettings {
        try store.setting(PriceSettings.self, key: Self.priceSettingsKey) ?? .default
    }

    public func savePriceSettings(_ settings: PriceSettings) throws {
        try store.saveSetting(settings, key: Self.priceSettingsKey)
    }

    /// Where stored spot prices for `settings` come from (nil for Norgespris).
    func priceKey(_ settings: PriceSettings) -> (source: String, area: String)? {
        if settings.agreement == .norgespris { return nil }
        if isDemo { return ("mock", "NO1") }
        return settings.agreement == .tibber ? ("tibber", "tibber") : ("hvakosterstrommen", settings.area.rawValue)
    }

    // MARK: Fetching

    /// Fetches missing spot prices: the last 30 days, today and, after 13:30, tomorrow.
    /// At most once per hour per source; nothing is fetched when all is stored.
    public func syncPrices() async throws -> PriceSync {
        let settings = try priceSettings()
        guard let key = priceKey(settings) else { return PriceSync(status: .notNeeded) }
        let t = now()
        let calendar = WireDate.calendar(timeZone)
        let today = calendar.startOfDay(for: t)
        var days = (0...Self.priceBackfillDays).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
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
            key: "prices.\(key.source).\(key.area)", minInterval: Self.priceInterval, now: t, blockingIntegration: nil)
        {
        case .throttled(let next):
            return PriceSync(status: .skipped, nextAllowed: next)
        case .blocked, .credentialsRejected:
            return PriceSync(status: .skipped)
        case .allowed:
            guard let provider = priceProvider(settings) else {
                return PriceSync(status: .failed, message: PriceError.missingToken.errorDescription)
            }
            let request = provider.fetchesRangesInOneRequest ? missing : Array(missing.prefix(Self.maxPriceFilesPerSync))
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

    // MARK: Consumption

    func counterSamples(from: Date, to: Date) throws -> [(at: Date, kWh: Double)] {
        guard let device = try currentDevice() else { return [] }
        // Stamped with when the counter was read; repeats of the same reading are dropped.
        var seen = Set<Date>()
        return try store.snapshots(device: device, from: from, to: to).compactMap { s in
            guard let kWh = s.energy.currentConsumedKWh else { return nil }
            let at = s.energy.counterAt ?? s.fetchedAt
            guard seen.insert(at).inserted else { return nil }
            return (at, kWh)
        }
    }

    /// kWh per hour with cost where prices are known. The adapter's local counter (exact,
    /// 0.1 kWh) wins for hours it covers (≥ 55 min); otherwise MELCloud's counter in snapshots,
    /// and a partly covered local hour only when MELCloud has nothing for it.
    public func hourlyConsumption(from: Date, to: Date) throws -> [HourCost] {
        let samples = try counterSamples(from: from.addingTimeInterval(-CounterSampler.maxGap), to: to)
        let cloud = CounterSampler.hourly(samples, timeZone: timeZone).filter { $0.key >= from && $0.key < to }
        let local = try localHourly(from: from, to: to)
        let prices = Dictionary(
            try priceBreakdowns(from: from, to: to).map { ($0.hour, $0) }, uniquingKeysWith: { a, _ in a })
        return Set(cloud.keys).union(local.keys).sorted().compactMap { hour in
            let (kWh, isLocal): (Double, Bool)
            if let l = local[hour], l.covered >= Self.localHourCoverage {
                (kWh, isLocal) = (l.kWh, true)
            } else if let c = cloud[hour] {
                (kWh, isLocal) = (c, false)
            } else if let l = local[hour] {
                (kWh, isLocal) = (l.kWh, true)
            } else {
                return nil
            }
            return HourCost(
                hour: hour, kWh: kWh, cost: prices[hour].map { CostSplit(kWh: kWh, price: $0).rounded() }, measuredLocally: isLocal)
        }
    }

    /// Seconds of an hour the local counter must cover to replace MELCloud's value.
    static let localHourCoverage: TimeInterval = 55 * 60

    /// Average power over the last 20–90 minutes from the energy counter (an estimate; the
    /// counter changes in coarse steps). Nil when there is too little data.
    public func estimatedPowerW() throws -> Double? {
        let t = now()
        return CounterSampler.averagePowerW(try counterSamples(from: t.addingTimeInterval(-90 * 60), to: t), now: t)
    }

    /// Cost per day (`yyyy-MM-dd`), with `isEstimate` when part of the day was priced at the
    /// day's average because hourly kWh were missing.
    func dayCosts(days: [EnergyDay]) throws -> [String: (cost: CostSplit, isEstimate: Bool)] {
        guard let first = days.first?.day, let last = days.last?.day,
            let start = WireDate.parse(first, timeZone: timeZone), let lastDay = WireDate.parse(last, timeZone: timeZone),
            let end = WireDate.calendar(timeZone).date(byAdding: .day, value: 1, to: lastDay)
        else { return [:] }
        let calendar = WireDate.calendar(timeZone)
        let hourly = try hourlyConsumption(from: start, to: end)
        let prices = try priceBreakdowns(from: start, to: end)
        let hourlyByDay = Dictionary(grouping: hourly) { WireDate.day(calendar.startOfDay(for: $0.hour), timeZone: timeZone) }
        let pricesByDay = Dictionary(grouping: prices) { WireDate.day(calendar.startOfDay(for: $0.hour), timeZone: timeZone) }
        var result: [String: (CostSplit, Bool)] = [:]
        for day in days {
            if let cost = PriceCalculator.dayCost(
                dayKWh: day.totalKWh, hourly: hourlyByDay[day.day] ?? [], prices: pricesByDay[day.day] ?? [])
            {
                result[day.day] = cost
            }
        }
        return result
    }
}

extension HeatPumpService {
    /// Demo mode only: fills the last 48 hours with simulated snapshots (every 15 minutes) and 45
    /// days of outdoor temperatures so charts, hourly cost, power and forecast estimates have data
    /// on first launch. Does nothing when the
    /// database already has older snapshots or the backend does not simulate data.
    public func seedDemoHistoryIfNeeded() async throws {
        guard let demo = backend as? any DemoDataSeeding else { return }
        let t = now()
        try seedDemoLocalIfNeeded(demo, now: t)
        // Older outdoor temperatures (the temperature log only goes 7 days back per request), so the
        // degree-day model behind "Estimate tomorrow" has enough days.
        let device = demo.demoDevice
        let older = DateInterval(start: t.addingTimeInterval(-45 * 86_400), end: t.addingTimeInterval(-7 * 86_400))
        if try store.temperaturePoints(device: device, from: older.start, to: older.end).isEmpty {
            try store.upsertTemperaturePoints(try await demo.fetchTemperatureLog(device: device, range: older), device: device)
        }
        let existing = try store.snapshots(device: device, from: t.addingTimeInterval(-48 * 3600), to: t.addingTimeInterval(-3600))
        guard existing.isEmpty else { return }
        var at = t.addingTimeInterval(-48 * 3600)
        while at < t.addingTimeInterval(-60) {
            try store.insertSnapshot(await demo.demoState(at: at))
            at = at.addingTimeInterval(15 * 60)
        }
    }

    /// Demo mode: turns local access on (simulated adapter) the first time, and while it is on
    /// fills the last 7 days with one simulated reading per minute.
    func seedDemoLocalIfNeeded(_ demo: any DemoDataSeeding, now t: Date) throws {
        if try store.setting(LocalSettings.self, key: Self.localSettingsKey) == nil {
            try saveLocalSettings(LocalSettings(enabled: true, host: demo.demoLocalHost))
        }
        let from = t.addingTimeInterval(-7 * 86_400)
        guard try localSettings().enabled,
            try store.localSamples(device: demo.demoDevice, from: from, to: t.addingTimeInterval(-3600)).isEmpty
        else { return }
        try store.insertLocalSamples(
            demo.demoLocalSamples(from: from, to: t.addingTimeInterval(-60), shortCycling: local.simulatedShortCycling),
            device: demo.demoDevice)
    }
}
