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

        switch try store.reserveFetch(key: "prices.\(key.source).\(key.area)", minInterval: Self.priceInterval, now: t, melcloud: false) {
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
        if isDemo { return "Demo: nøkkelen ble ikke testet mot Tibber." }
        guard (try? store.reserveFetch(key: "prices.tibber.test", minInterval: 10, now: now(), melcloud: false)) == .allowed else {
            return "Vent noen sekunder før du tester igjen."
        }
        do {
            let hours = try await TibberPriceProvider(token: token, transport: transport, now: now).test(timeZone: timeZone)
            return "Nøkkelen virker. Fant \(hours) timepriser for i dag."
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
            for p in try store.prices(source: key.source, area: key.area, from: hour, to: to) { spots[p.hour] = p }
        }
        var result: [PriceBreakdown] = []
        while hour < to {
            if let b = PriceCalculator.breakdown(hour: hour, settings: settings, spot: spots[hour], timeZone: timeZone) {
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
        guard let deviceId = try store.latestSnapshot()?.state.deviceId else { return [] }
        return try store.snapshots(deviceId: deviceId, from: from, to: to).compactMap { s in
            s.energy.currentConsumedKWh.map { (s.fetchedAt, $0) }
        }
    }

    /// kWh per hour from the energy counter in snapshots, with cost where prices are known.
    public func hourlyConsumption(from: Date, to: Date) throws -> [HourCost] {
        let samples = try counterSamples(from: from.addingTimeInterval(-CounterSampler.maxGap), to: to)
        let hourly = CounterSampler.hourly(samples, timeZone: timeZone).filter { $0.key >= from && $0.key < to }
        let prices = Dictionary(
            try priceBreakdowns(from: from, to: to).map { ($0.hour, $0) }, uniquingKeysWith: { a, _ in a })
        return hourly.keys.sorted().map { hour in
            let kWh = hourly[hour] ?? 0
            return HourCost(hour: hour, kWh: kWh, cost: prices[hour].map { CostSplit(kWh: kWh, price: $0).rounded() })
        }
    }

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
    /// Demo mode only: fills the last 48 hours with simulated snapshots (every 15 minutes) so
    /// charts, hourly cost and power estimates have data on first launch. Does nothing when the
    /// database already has older snapshots or the backend is not the mock.
    public func seedDemoHistoryIfNeeded() async throws {
        guard let mock = backend as? MockBackend else { return }
        let t = now()
        let existing = try store.snapshots(deviceId: MockBackend.deviceId, from: t.addingTimeInterval(-48 * 3600), to: t.addingTimeInterval(-3600))
        guard existing.isEmpty else { return }
        var at = t.addingTimeInterval(-48 * 3600)
        while at < t.addingTimeInterval(-60) {
            try store.insertSnapshot(await mock.state(at: at))
            at = at.addingTimeInterval(15 * 60)
        }
    }
}
