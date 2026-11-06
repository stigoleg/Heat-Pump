import Foundation

/// What the hub needs from a device's service to speak for its integration's account: sign-in,
/// sign-out and listing the account's devices. `HeatPumpService` and `EnergyMeterService` have it.
protocol DeviceAccount: Actor {
    /// Whether the sign-in values are stored (cached; no keychain read while polling).
    func hasCredentials() -> Bool
    /// Saves the values and checks them with one request under the integration's limits; the
    /// listed devices are registered.
    func signIn(_ values: CredentialValues) async throws -> StateResult
    func signOut() async throws
    /// Lists the account's devices again when the integration's limits allow it (nil: nothing sent).
    func refreshDeviceList() async throws -> [DeviceSummary]?
    /// Forgets the cached `hasCredentials` (another service of the integration signed in or out).
    func forgetCredentialCache()
    /// The device the service is fixed to, if any.
    func currentDevice() throws -> DeviceKey?
}

extension HeatPumpService: DeviceAccount {}

/// One energy meter's entry point (`DeviceHub` holds one per enabled meter, and one without a
/// device for an integration that has no enabled meter yet, which signs in and lists).
///
/// Hourly use is fetched at most hourly per meter across processes (`EnergyContextService.
/// syncMeterHours`, shared with the house's consumption) and priced like everything else in the
/// app. Live power (`live()`) runs only while someone listens; its readings are kept per minute
/// for 48 hours so the trend survives a restart and the MCP helper can read them without a
/// connection of its own.
public actor EnergyMeterService: DeviceAccount {
    /// The connection to the meter's service (shared by every meter of the integration).
    public nonisolated let connection: any EnergyMeterDriver
    public nonisolated let integration: any Integration
    public nonisolated let store: HistoryStore
    public nonisolated let timeZone: TimeZone
    public nonisolated let credentials: (any CredentialProviding)?
    /// Prices for the cost, shared with every device.
    public nonisolated let energy: EnergyContextService
    /// The meter; nil for the integration's account service before a meter is enabled.
    public nonisolated let device: DeviceKey?
    let now: @Sendable () -> Date

    /// The minute being filled from live readings, written at most every `liveWriteInterval`.
    private var minute: (start: Date, sum: Double, count: Int, max: Double, consumption: Double?, last: Date)?
    private var lastWrite: Date?
    private var credentialsStored: Bool?

    /// Shortest gap between two writes of the minute being filled.
    static let liveWriteInterval: TimeInterval = 15

    public init(
        connection: any EnergyMeterDriver, store: HistoryStore, credentials: (any CredentialProviding)? = nil,
        integration: any Integration, energy: EnergyContextService, device: DeviceKey?, timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.connection = connection
        self.store = store
        self.credentials = credentials
        self.integration = integration
        self.energy = energy
        self.device = device
        self.timeZone = timeZone
        self.now = now
    }

    /// The service as texts name it, e.g. "Tibber".
    public nonisolated var serviceName: String { integration.displayName }

    /// Display text for `error`, naming this meter's service.
    public nonisolated func describe(_ error: any Error) -> String {
        if let error = error as? HeatPumpError { return error.description(serviceName: serviceName) }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Account

    public func hasCredentials() -> Bool {
        guard let credentials else { return true }
        if let credentialsStored { return credentialsStored }
        let stored = credentials.hasValues(for: integration.credentialMapping)
        credentialsStored = stored
        return stored
    }

    public func forgetCredentialCache() { credentialsStored = nil }

    public func currentDevice() throws -> DeviceKey? { device }

    /// Saves the values, lifts a "credentials rejected" stop and lists the account's meters (one
    /// request, at most one test per 10 s, not while the integration is blocked). The listed meters
    /// are registered (new ones enabled); the integration's meters the account no longer lists are
    /// disabled.
    public func signIn(_ values: CredentialValues) async throws -> StateResult {
        if let credentials {
            try credentials.saveValues(values, for: integration.credentialMapping)
            credentialsStored = true
        }
        try store.clearCredentialsRejected(integration: integration.id)
        await connection.resetSession()
        return try await list(minInterval: HeatPumpService.signInMinInterval)
    }

    public func signOut() async throws {
        try credentials?.deleteValues(for: integration.credentialMapping)
        credentialsStored = false
        await connection.resetSession()
    }

    /// One listing under the integration's spacing (`minRefreshInterval`), or nil when it was not
    /// allowed or nothing is stored.
    public func refreshDeviceList() async throws -> [DeviceSummary]? {
        guard hasCredentials() else { return nil }
        let t = now()
        guard try reserve(HeatPumpService.stateKey, minInterval: integration.rateLimitPolicy.minRefreshInterval, now: t) == .allowed
        else { return nil }
        do {
            let listed = try await connection.listDevices()
            try store.syncDevices(listed, integration: integration.id)
            try store.recordFetchSuccess(key: HistoryStore.fetchKey(HeatPumpService.stateKey, integration: integration.id), now: t)
            return listed
        } catch let error as HeatPumpError {
            try handle(error, now: t)
            throw error
        }
    }

    private func list(minInterval: TimeInterval) async throws -> StateResult {
        let t = now()
        switch try reserve(HeatPumpService.stateKey, minInterval: minInterval, now: t) {
        case .allowed:
            do {
                let listed = try await connection.listDevices()
                try store.syncDevices(listed, integration: integration.id)
                try store.recordFetchSuccess(key: HistoryStore.fetchKey(HeatPumpService.stateKey, integration: integration.id), now: t)
                guard !listed.isEmpty else { return result(error: describe(HeatPumpError.deviceNotFound)) }
                return StateResult(state: nil, refreshed: true, stale: false)
            } catch let error as HeatPumpError {
                try handle(error, now: t)
                var r = result(error: describe(error.isCredentialProblem ? HeatPumpError.credentialsRejected : error))
                r.needsLogin = error.isCredentialProblem || error == .missingCredentials
                return r
            }
        case .throttled(let next):
            return StateResult(state: nil, refreshed: false, stale: true, nextRefreshAllowed: next)
        case .blocked(let until):
            var r = result(error: nil)
            r.blockedUntil = until
            r.blockMessage = BlockReason.rateLimited.message(until: until, serviceName: serviceName)
            return r
        case .credentialsRejected:
            var r = result(error: describe(HeatPumpError.credentialsRejected))
            r.needsLogin = true
            return r
        }
    }

    private func result(error: String?) -> StateResult {
        StateResult(state: nil, refreshed: false, stale: true, error: error)
    }

    private func reserve(_ name: String, minInterval: TimeInterval, now: Date) throws -> FetchDecision {
        try store.reserveFetch(
            key: HistoryStore.fetchKey(name, integration: integration.id), minInterval: minInterval, now: now,
            blockingIntegration: integration.id)
    }

    /// Records a block for too much traffic, and stops every request after a refused token until
    /// new values are saved (never retried with the same token).
    private func handle(_ error: HeatPumpError, now: Date) throws {
        switch error {
        case .rateLimited(let until): try store.recordBlock(until: until, reason: .rateLimited, integration: integration.id)
        case .invalidCredentials, .credentialsRejected:
            credentialsStored = true
            try store.recordCredentialsRejected(now: now, integration: integration.id)
        default: break
        }
    }

    // MARK: Hourly use

    /// Fetches the meter's missing hours (at most hourly per meter, across processes).
    public func syncHours() async throws -> HouseSync {
        guard let device else { return HouseSync(status: .notConfigured) }
        guard hasCredentials() else { return HouseSync(status: .notConfigured) }
        return try await energy.syncMeterHours(device: device, driver: connection, serviceName: serviceName)
    }

    /// Whether the service refused the stored values (requests stay stopped until new ones are saved).
    public func credentialsRejected() throws -> Bool { try store.credentialsRejected(integration: integration.id) }

    /// When the hours were last fetched.
    public func lastHourSync() throws -> Date? {
        guard let device else { return nil }
        return try store.fetchState(key: HistoryStore.fetchKey(EnergyContextService.meterHoursFetchName, device: device))?.lastSuccess
    }

    /// kWh per hour with `from <= hour < to`, priced like the rest of the app: the reported hours,
    /// and for hours not reported yet the live counter's use where it covers them.
    public func hourly(from: Date, to: Date) throws -> [HourCost] {
        guard let device else { return [] }
        var kWh: [Date: Double] = [:]
        for hour in try store.meterHours(device: device, from: from, to: to) { kWh[hour.hour] = hour.kWh }
        for (hour, used) in try liveHours(device: device, from: from, to: to) where kWh[hour] == nil { kWh[hour] = used }
        let prices = Dictionary(try energy.priceBreakdowns(from: from, to: to).map { ($0.hour, $0) }, uniquingKeysWith: { a, _ in a })
        return kWh.keys.sorted().map { hour in
            let used = kWh[hour] ?? 0
            return HourCost(hour: hour, kWh: used, cost: prices[hour].map { CostSplit(kWh: used, price: $0).rounded() })
        }
    }

    /// Hours with use from the live counter (kWh since midnight): the counter's last reading in
    /// the hour minus its last reading before the hour (zero at midnight, when it restarts). The
    /// hour still running counts up to the newest reading; hours the readings do not bracket are
    /// left out.
    func liveHours(device: DeviceKey, from: Date, to: Date) throws -> [Date: Double] {
        let calendar = WireDate.calendar(timeZone)
        let minutes = try store.liveMinutes(device: device, from: calendar.startOfDay(for: from), to: to)
            .filter { $0.consumptionTodayKWh != nil }
        guard let first = minutes.first, let last = minutes.last,
            var hour = calendar.dateInterval(of: .hour, for: max(from, first.minute))?.start
        else { return [:] }
        func counter(before date: Date, day: Date) -> Double? {
            minutes.last { $0.lastReading < date && $0.lastReading >= day }?.consumptionTodayKWh
        }
        var result: [Date: Double] = [:]
        while hour < to, hour <= last.lastReading {
            let day = calendar.startOfDay(for: hour)
            let start = hour == day ? 0 : counter(before: hour, day: day)
            if let start, let end = counter(before: hour.addingTimeInterval(3600), day: day), end >= start {
                result[hour] = end - start
            }
            hour = hour.addingTimeInterval(3600)
        }
        return result
    }

    /// Use and cost per local day (`from` to `to`), oldest first.
    public func daily(from: Date, to: Date) throws -> [MeterPeriod] {
        let calendar = WireDate.calendar(timeZone)
        let hours = try hourly(from: calendar.startOfDay(for: from), to: to)
        let grouped = Dictionary(grouping: hours) { calendar.startOfDay(for: $0.hour) }
        return grouped.keys.sorted().map { start in MeterPeriod(start: start, hours: grouped[start] ?? []) }
    }

    /// Today so far.
    public func today() throws -> MeterToday {
        let t = now()
        let midnight = WireDate.calendar(timeZone).startOfDay(for: t)
        let hours = try hourly(from: midnight, to: t)
        let live = try device.map { try liveHours(device: $0, from: midnight, to: t) } ?? [:]
        let reported = Set(try device.map { try store.meterHours(device: $0, from: midnight, to: t).map(\.hour) } ?? [])
        let priced = hours.compactMap(\.cost)
        return MeterToday(
            kWh: hours.reduce(0) { $0 + $1.kWh }, cost: priced.isEmpty ? nil : priced.reduce(CostSplit(), +).rounded(), hours: hours,
            hoursCovered: hours.count, includesLive: hours.contains { live[$0.hour] != nil && !reported.contains($0.hour) })
    }

    /// The meter at a glance (stored data only; no network).
    public func status() throws -> MeterStatus? {
        guard let device else { return nil }
        let t = now()
        let hourStart = WireDate.calendar(timeZone).dateInterval(of: .hour, for: t)?.start ?? t
        let price = try energy.priceBreakdowns(from: hourStart, to: hourStart.addingTimeInterval(3600)).first
        let record = try store.devices().first { $0.key == device }
        return MeterStatus(
            device: device, live: try store.latestLiveMinute(device: device), today: try today(), priceNowOre: price?.totalOre,
            latestHour: try store.latestMeterHour(device: device),
            hasLivePower: record.map { connection.capabilities(of: $0.summary).contains(.livePower) } ?? false)
    }

    // MARK: Live power

    /// Live readings and state while the stream is consumed (cancel it to stop). Readings are
    /// stored per minute. Ends at once (`.stopped(.notAvailable)`) for a meter without live data.
    public func live() -> AsyncStream<LivePowerEvent> {
        guard let device, let driver = connection as? any LivePowerDriver,
            let record = try? store.devices().first(where: { $0.key == device }),
            connection.capabilities(of: record.summary).contains(.livePower)
        else {
            return AsyncStream { continuation in
                continuation.yield(.state(.stopped(.notAvailable)))
                continuation.finish()
            }
        }
        let upstream = driver.liveReadings(device: device)
        return AsyncStream { continuation in
            let task = Task {
                for await event in upstream {
                    if case .reading(let reading) = event { try? self.record(reading) }
                    continuation.yield(event)
                }
                try? self.flushMinute()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Adds a reading to its minute; writes the minute when it is complete, and the minute being
    /// filled at most every `liveWriteInterval`.
    func record(_ reading: LivePowerReading) throws {
        let start = Date(timeIntervalSince1970: (reading.at.timeIntervalSince1970 / 60).rounded(.down) * 60)
        if let current = minute, current.start != start { try flushMinute() }
        if var current = minute {
            current.sum += reading.powerW
            current.count += 1
            current.max = max(current.max, reading.powerW)
            current.consumption = reading.consumptionTodayKWh ?? current.consumption
            current.last = reading.at
            minute = current
        } else {
            minute = (start, reading.powerW, 1, reading.powerW, reading.consumptionTodayKWh, reading.at)
        }
        if lastWrite.map({ reading.at.timeIntervalSince($0) >= Self.liveWriteInterval }) ?? true {
            try writeMinute()
            lastWrite = reading.at
        }
    }

    private func flushMinute() throws {
        try writeMinute()
        minute = nil
    }

    private func writeMinute() throws {
        guard let device, let current = minute else { return }
        try store.saveLiveMinute(
            LiveMinute(
                minute: current.start, powerW: current.sum / Double(current.count), maxPowerW: current.max,
                consumptionTodayKWh: current.consumption, lastReading: current.last),
            device: device)
    }

    /// Stored live minutes with `from <= minute < to`.
    public func liveMinutes(from: Date, to: Date) throws -> [LiveMinute] {
        guard let device else { return [] }
        return try store.liveMinutes(device: device, from: from, to: to)
    }

    // MARK: Demo

    /// Demo mode: the last hour of simulated live minutes, so the trend has data on first launch.
    public func seedDemoIfNeeded() throws {
        guard let device, let demo = connection as? any MeterDemoSeeding else { return }
        let t = now()
        // The live stream may already have written the current minute.
        let start = t.addingTimeInterval(-3600)
        guard try store.liveMinutes(device: device, from: start, to: t.addingTimeInterval(-120)).isEmpty else { return }
        for minute in demo.demoLiveMinutes(device: device, from: start, to: t.addingTimeInterval(-60)) {
            try store.saveLiveMinute(minute, device: device)
        }
    }
}

/// Use and cost of one period (a local day).
public struct MeterPeriod: Codable, Sendable, Equatable {
    public var start: Date
    public var kWh: Double
    public var cost: CostSplit?
    public var hours: Int

    public init(start: Date, hours: [HourCost]) {
        self.start = start
        kWh = hours.reduce(0) { $0 + $1.kWh }
        let costs = hours.compactMap(\.cost)
        cost = costs.isEmpty ? nil : costs.reduce(CostSplit(), +).rounded()
        self.hours = hours.count
    }
}

/// Demo data for a simulated meter.
public protocol MeterDemoSeeding: Sendable {
    /// Simulated live minutes from `from` to `to`.
    func demoLiveMinutes(device: DeviceKey, from: Date, to: Date) -> [LiveMinute]
}
