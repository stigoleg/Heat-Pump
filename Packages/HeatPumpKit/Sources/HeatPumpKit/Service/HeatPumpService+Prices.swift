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

    // MARK: Settings and prices (shared by every device: `energy`)

    public func priceSettings() throws -> PriceSettings { try energy.priceSettings() }

    public func savePriceSettings(_ settings: PriceSettings) throws { try energy.savePriceSettings(settings) }

    /// Fetches missing spot prices: the last 30 days, today and, after 13:30, tomorrow.
    /// At most once per hour per source; nothing is fetched when all is stored.
    public func syncPrices() async throws -> PriceSync { try await energy.syncPrices() }

    /// Checks a Tibber token with one small request (at most one test per 10 s).
    public func testTibberToken(_ token: String, transport: any HTTPTransport = URLSessionTransport()) async -> String {
        await energy.testTibberToken(token, transport: transport)
    }

    /// Price per kWh for each hour with `from <= hour < to` (hours without spot data are left out).
    public func priceBreakdowns(from: Date, to: Date) throws -> [PriceBreakdown] { try energy.priceBreakdowns(from: from, to: to) }

    /// Hour prices for the local day containing `day`.
    public func prices(day: Date) throws -> [PriceBreakdown] { try energy.prices(day: day) }

    public func priceOverview(sync: Bool = true) async throws -> PriceOverview { try await energy.priceOverview(sync: sync) }

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
    /// Demo mode only: fills the last 48 hours of the served device with simulated snapshots
    /// (every 15 minutes) and 45 days of outdoor temperatures so charts, hourly cost, power and
    /// forecast estimates have data on first launch. Does nothing when the database already has
    /// older snapshots or the backend does not simulate the device.
    public func seedDemoHistoryIfNeeded() async throws {
        guard let demo = backend as? any DemoDataSeeding,
            let device = try currentDevice() ?? demo.demoDevices.first, demo.demoDevices.contains(device)
        else { return }
        let t = now()
        if device == demo.demoDevices.first { try seedDemoLocalIfNeeded(demo, device: device, now: t) }
        // Older outdoor temperatures (the temperature log only goes 7 days back per request), so the
        // degree-day model behind "Estimate tomorrow" has enough days.
        let older = DateInterval(start: t.addingTimeInterval(-45 * 86_400), end: t.addingTimeInterval(-7 * 86_400))
        if try store.temperaturePoints(device: device, from: older.start, to: older.end).isEmpty {
            try store.upsertTemperaturePoints(try await demo.fetchTemperatureLog(device: device, range: older), device: device)
        }
        let existing = try store.snapshots(device: device, from: t.addingTimeInterval(-48 * 3600), to: t.addingTimeInterval(-3600))
        guard existing.isEmpty else { return }
        var at = t.addingTimeInterval(-48 * 3600)
        while at < t.addingTimeInterval(-60) {
            try store.insertSnapshot(await demo.demoState(at: at, device: device))
            at = at.addingTimeInterval(15 * 60)
        }
    }

    /// Demo mode: turns local access on (simulated adapter) for `device` the first time, and while
    /// it is on fills the last 7 days with one simulated reading per minute.
    func seedDemoLocalIfNeeded(_ demo: any DemoDataSeeding, device: DeviceKey, now t: Date) throws {
        if try store.deviceSetting(LocalSettings.self, name: Self.localSettingsKey, device: device) == nil {
            try store.saveDeviceSetting(LocalSettings(enabled: true, host: demo.demoLocalHost), name: Self.localSettingsKey, device: device)
        }
        let from = t.addingTimeInterval(-7 * 86_400)
        guard try store.deviceSetting(LocalSettings.self, name: Self.localSettingsKey, device: device)?.enabled == true,
            try store.localSamples(device: device, from: from, to: t.addingTimeInterval(-3600)).isEmpty
        else { return }
        try store.insertLocalSamples(
            demo.demoLocalSamples(from: from, to: t.addingTimeInterval(-60), shortCycling: local.simulatedShortCycling),
            device: device)
    }
}
