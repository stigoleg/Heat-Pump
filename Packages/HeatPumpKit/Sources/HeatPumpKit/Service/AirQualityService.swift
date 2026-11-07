import Foundation

/// One air quality sensor's entry point (`DeviceHub` holds one per enabled sensor, and one without
/// a device for an integration that has no enabled sensor yet, which signs in and lists).
///
/// Every request is reserved across processes (`HistoryStore.reserveFetch`):
/// - the newest values of every enabled sensor of the integration in one request
///   (`syncLatest`), at most every `minRefreshInterval` per integration; the first sensor's poll
///   fetches for all, the others find it done;
/// - the hourly history per sensor (`syncHistory`) at most every `reportInterval`, only the hours
///   since the last fetch (a year the first time, in pieces of `maxAirQualityLogDays`);
/// - the thresholds per sensor (`syncThresholds`) at most daily, or less often when the vendor
///   allows a longer cache.
///
/// When the vendor reports its request budget (`RequestBudgetReporting`) and less than a tenth is
/// left, every request stops until the window resets, so the budget is never used up.
public actor AirQualityService: DeviceAccount {
    /// The connection to the sensors' service (shared by every sensor of the integration).
    public nonisolated let connection: any AirQualityDriver
    public nonisolated let integration: any Integration
    public nonisolated let store: HistoryStore
    public nonisolated let credentials: (any CredentialProviding)?
    /// The sensor; nil for the integration's account service before a sensor is enabled.
    public nonisolated let device: DeviceKey?
    public nonisolated let timeZone: TimeZone
    let now: @Sendable () -> Date

    private var credentialsStored: Bool?

    /// `fetch_state` name of the integration's newest-values request.
    public static let latestFetchName = "airquality.latest"
    /// `fetch_state` name (per device) of the history request.
    public static let historyFetchName = "airquality.hours"
    /// `fetch_state` name (per device) of the thresholds request.
    public static let thresholdsFetchName = "airquality.thresholds"
    /// Device settings: the thresholds, how far the history has been fetched, and whether a high
    /// long-term radon average is notified.
    static let thresholdsSetting = "airQualityThresholds"
    static let historySetting = "airQualityHistoryThrough"
    static let radonAlertsSetting = "airQualityRadonAlerts"
    /// How far back the history is fetched the first time.
    public static let backfillDays = 365
    /// Thresholds rarely change: at most daily.
    public static let thresholdsInterval: TimeInterval = 86_400
    /// The last hours are fetched again: the vendor finishes them late.
    static let historyOverlap: TimeInterval = 2 * 3600
    /// Share of the vendor's budget kept in reserve (the other process, a manual refresh).
    static let budgetReserve = 0.1

    public init(
        connection: any AirQualityDriver, store: HistoryStore, credentials: (any CredentialProviding)? = nil,
        integration: any Integration, device: DeviceKey?, timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.connection = connection
        self.store = store
        self.credentials = credentials
        self.integration = integration
        self.device = device
        self.timeZone = timeZone
        self.now = now
    }

    /// The service as texts name it.
    public nonisolated var serviceName: String { integration.displayName }

    /// Display text for `error`, naming this sensor's service.
    public nonisolated func describe(_ error: any Error) -> String { listing.describe(error) }

    private nonisolated var listing: DeviceListing {
        DeviceListing(connection: connection, integration: integration, store: store, now: now)
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

    /// Saves the values, lifts a "credentials rejected" stop and lists the account's sensors (one
    /// request, at most one test per 10 s, not while the integration is blocked).
    public func signIn(_ values: CredentialValues) async throws -> StateResult {
        if let credentials {
            try credentials.saveValues(values, for: integration.credentialMapping)
            credentialsStored = true
        }
        try store.clearCredentialsRejected(integration: integration.id)
        await connection.resetSession()
        return try await listing.signInListing(minInterval: HeatPumpService.signInMinInterval)
    }

    public func signOut() async throws {
        try credentials?.deleteValues(for: integration.credentialMapping)
        credentialsStored = false
        await connection.resetSession()
    }

    public func refreshDeviceList() async throws -> [DeviceSummary]? {
        guard hasCredentials() else { return nil }
        do {
            return try await listing.refresh()
        } catch let error as HeatPumpError {
            if error.isCredentialProblem { credentialsStored = true }
            throw error
        }
    }

    /// Whether the service refused the stored values (requests stay stopped until new ones are saved).
    public func credentialsRejected() throws -> Bool { try store.credentialsRejected(integration: integration.id) }

    // MARK: Newest values

    /// The newest values of every enabled sensor of the integration (one request for up to
    /// `maxDevicesPerRequest` sensors), at most every `minRefreshInterval` across processes.
    public func syncLatest() async throws -> HouseSync {
        guard device != nil, hasCredentials() else { return HouseSync(status: .notConfigured) }
        let t = now()
        let key = HistoryStore.fetchKey(Self.latestFetchName, integration: integration.id)
        return try await reserved(key: key, minInterval: integration.rateLimitPolicy.minRefreshInterval, now: t) {
            let sensors = try self.store.devices()
                .filter { $0.enabled && $0.kind == .airQualitySensor && $0.key.integration == self.integration.id }.map(\.key)
            var count = 0
            for start in stride(from: 0, to: sensors.count, by: max(1, self.connection.maxDevicesPerRequest)) {
                let chunk = Array(sensors[start..<min(sensors.count, start + max(1, self.connection.maxDevicesPerRequest))])
                for reading in try await self.connection.fetchLatest(devices: chunk) where chunk.contains(reading.device) {
                    try self.store.saveAirQualityReading(reading, fetchedAt: t)
                    count += 1
                }
            }
            return count
        }
    }

    // MARK: History

    /// The hours since the last fetch (a year back the first time, `maxAirQualityLogDays` per
    /// request), at most every `reportInterval` per sensor across processes.
    public func syncHistory() async throws -> HouseSync {
        guard let device, hasCredentials(), let log = connection as? any AirQualityLogReporting else {
            return HouseSync(status: .notConfigured)
        }
        let t = now()
        let key = HistoryStore.fetchKey(Self.historyFetchName, device: device)
        return try await reserved(key: key, minInterval: integration.rateLimitPolicy.reportInterval, now: t) {
            let range = try self.nextHistoryRange(device: device, maxDays: log.maxAirQualityLogDays, now: t)
            let hours = try await log.fetchHourly(device: device, range: range)
            try self.store.upsertAirQualityHours(hours, device: device, now: t)
            try self.store.saveDeviceSetting(range.end, name: Self.historySetting, device: device)
            return hours.count
        }
    }

    /// From the last fetched hour (less the overlap; a year back the first time) for at most
    /// `maxDays`, up to now. Starts on a whole hour.
    func nextHistoryRange(device: DeviceKey, maxDays: Int, now t: Date) throws -> DateInterval {
        let floor = t.addingTimeInterval(-Double(Self.backfillDays) * 86_400)
        let through = try store.deviceSetting(Date.self, name: Self.historySetting, device: device)
        let from = max(floor, (through ?? floor).addingTimeInterval(-Self.historyOverlap))
        let start = Date(timeIntervalSince1970: (from.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        let end = min(t, start.addingTimeInterval(Double(max(1, maxDays)) * 86_400))
        return DateInterval(start: start, end: max(start, end))
    }

    // MARK: Thresholds

    /// The sensor's thresholds, at most daily (or as long as the vendor allows them to be cached).
    public func syncThresholds() async throws -> HouseSync {
        guard let device, hasCredentials() else { return HouseSync(status: .notConfigured) }
        let t = now()
        let stored = try store.deviceSetting(AirQualityThresholds.self, name: Self.thresholdsSetting, device: device)
        let interval = max(Self.thresholdsInterval, stored?.maxAge ?? 0)
        let key = HistoryStore.fetchKey(Self.thresholdsFetchName, device: device)
        return try await reserved(key: key, minInterval: interval, now: t) {
            guard let thresholds = try await self.connection.fetchThresholds(device: device) else { return 0 }
            try self.store.saveDeviceSetting(thresholds, name: Self.thresholdsSetting, device: device)
            return thresholds.ranges.count
        }
    }

    // MARK: Requests

    /// Runs `fetch` when the reservation allows it, records its success, blocks, refused values
    /// and a nearly used-up budget, and reports how it went.
    private func reserved(
        key: String, minInterval: TimeInterval, now t: Date, fetch: () async throws -> Int
    ) async throws -> HouseSync {
        switch try store.reserveFetch(key: key, minInterval: minInterval, now: t, blockingIntegration: integration.id) {
        case .throttled(let next):
            return HouseSync(status: .skipped, nextAllowed: next)
        case .blocked, .credentialsRejected:
            return HouseSync(status: .skipped)
        case .allowed:
            do {
                let count = try await fetch()
                try store.recordFetchSuccess(key: key, now: t)
                try await keepBudgetReserve()
                return HouseSync(status: .fetched, count: count)
            } catch let error as HeatPumpError {
                try listing.handle(error, now: t)
                if error.isCredentialProblem { credentialsStored = true }
                return HouseSync(status: .failed, message: describe(error))
            }
        }
    }

    /// Blocks the integration until its window resets when less than `budgetReserve` of the
    /// vendor's budget is left.
    private func keepBudgetReserve() async throws {
        guard let reporter = connection as? any RequestBudgetReporting, let budget = await reporter.requestBudget() else { return }
        let reserve = max(2, Int((Double(budget.limit) * Self.budgetReserve).rounded(.up)))
        guard budget.remaining <= reserve, budget.resetsAt > now() else { return }
        try store.recordBlock(until: budget.resetsAt, reason: .rateLimited, integration: integration.id)
    }

    // MARK: Reading stored data

    /// The thresholds the sensor's values are rated by: the vendor's for this sensor, else the
    /// standard ones.
    public func thresholds() throws -> AirQualityThresholds {
        guard let device else { return .standard }
        return try store.deviceSetting(AirQualityThresholds.self, name: Self.thresholdsSetting, device: device) ?? .standard
    }

    /// The sensor at a glance (stored data only; no network). Nil before the first fetch.
    public func status() throws -> AirQualityStatus? {
        guard let device, let latest = try store.latestAirQuality(device: device) else { return nil }
        let stored = try store.deviceSetting(AirQualityThresholds.self, name: Self.thresholdsSetting, device: device)
        let thresholds = stored ?? .standard
        let values = AirQualityMetric.allCases.compactMap { metric in
            latest.reading.values[metric].map { AirQualityValue(metric: metric, value: $0, level: thresholds.level(metric, $0)) }
        }
        return AirQualityStatus(
            device: device, recorded: latest.reading.recorded, fetchedAt: latest.fetchedAt, values: values,
            findings: AirQualityHealth.findings(values: values, recorded: latest.reading.recorded, now: now(), serviceName: serviceName),
            thresholdsFromDevice: stored != nil)
    }

    /// Hourly averages with `from <= hour < to`, oldest first.
    public func hours(from: Date, to: Date) throws -> [AirQualityHour] {
        guard let device else { return [] }
        return try store.airQualityHours(device: device, from: from, to: to)
    }

    /// When the newest values were last fetched (by either process).
    public func lastSync() throws -> Date? {
        try store.fetchState(key: HistoryStore.fetchKey(Self.latestFetchName, integration: integration.id))?.lastSuccess
    }

    // MARK: Notifications

    /// Whether a long-term radon average at or above the action level is notified (off until the
    /// user turns it on).
    public func radonAlertsEnabled() throws -> Bool {
        guard let device else { return false }
        return try store.deviceSetting(Bool.self, name: Self.radonAlertsSetting, device: device) ?? false
    }

    public func setRadonAlerts(_ enabled: Bool) throws {
        guard let device else { return }
        try store.saveDeviceSetting(enabled, name: Self.radonAlertsSetting, device: device)
    }

    // MARK: Demo

    /// Demo mode: a year of simulated hours on first launch, so the history has data at once.
    public func seedDemoIfNeeded() throws {
        guard let device, let demo = connection as? any AirQualityDemoSeeding,
            try store.latestAirQualityHour(device: device) == nil
        else { return }
        let t = now()
        let start = Date(timeIntervalSince1970: (t.addingTimeInterval(-Double(Self.backfillDays) * 86_400).timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        try store.upsertAirQualityHours(demo.demoHours(device: device, from: start, to: t), device: device, now: t)
        try store.saveDeviceSetting(t, name: Self.historySetting, device: device)
    }
}
