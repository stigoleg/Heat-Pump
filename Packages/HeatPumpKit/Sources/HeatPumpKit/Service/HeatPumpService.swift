import Foundation

/// Single entry point for the app and the MCP server.
///
/// Reads come from the shared SQLite cache; the network is touched only when the cache
/// is too old, never more than once per 60 s across all processes, and never while a
/// MELCloud block is active. Every change is validated, budgeted (12 per rolling hour
/// across processes) and logged.
public actor HeatPumpService {
    public static let defaultMaxAge: TimeInterval = 10 * 60
    public static let minRefreshInterval: TimeInterval = 60
    public static let reportInterval: TimeInterval = 3600
    public static let historyDays = 90
    /// Used when a login throttle does not say how long it lasts.
    public static let defaultLoginBlock: TimeInterval = 30 * 60

    static let stateKey = "state"

    public nonisolated let backend: any HeatPumpBackend
    public nonisolated let store: HistoryStore
    public nonisolated let timeZone: TimeZone
    private let now: @Sendable () -> Date
    private var device: DeviceSummary?

    public init(
        backend: any HeatPumpBackend, store: HistoryStore, timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.backend = backend
        self.store = store
        self.timeZone = timeZone
        self.now = now
    }

    /// Backend from `VARMEPUMPE_BACKEND` (`mock` or default MELCloud Classic), DB from
    /// `VARMEPUMPE_DB_PATH` or Application Support, credentials from the keychain.
    public static func makeDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> HeatPumpService {
        let store = try HistoryStore(path: HistoryStore.defaultPath(environment: environment))
        let backend: any HeatPumpBackend =
            environment["VARMEPUMPE_BACKEND"]?.lowercased() == "mock"
            ? MockBackend()
            : MELCloudClassicBackend(credentials: KeychainCredentialStore(environment: environment))
        return HeatPumpService(backend: backend, store: store)
    }

    // MARK: State

    /// Cached state unless older than `maxAge` (or `force`). Network refresh is rate limited
    /// globally; when skipped or blocked the cached state is returned with an indicator.
    public func currentState(maxAge: TimeInterval = defaultMaxAge, force: Bool = false) async throws -> StateResult {
        let t = now()
        let cached = try store.latestSnapshot()
        if let cached, !force, !cached.stale, t.timeIntervalSince(cached.state.fetchedAt) < maxAge {
            return result(cached.state, now: t, refreshed: false, stale: false)
        }
        switch try store.reserveFetch(key: Self.stateKey, minInterval: Self.minRefreshInterval, now: t) {
        case .blocked(let until):
            return result(cached?.state, now: t, refreshed: false, stale: true, blockedUntil: until)
        case .throttled(let next):
            // Another process probably just refreshed; prefer its result.
            let latest = try store.latestSnapshot() ?? cached
            let isStale = latest.map { $0.stale || t.timeIntervalSince($0.state.fetchedAt) >= maxAge } ?? true
            return result(latest?.state, now: t, refreshed: false, stale: isStale, nextRefreshAllowed: next)
        case .allowed:
            do {
                let summary = try await resolveDevice(cached: cached?.state)
                let state = try await backend.fetchState(deviceId: summary.deviceId)
                try store.insertSnapshot(state)
                try store.recordFetchSuccess(key: Self.stateKey, now: t)
                return result(state, now: now(), refreshed: true, stale: false)
            } catch let error as HeatPumpError {
                let blocked = try handleBlock(error, now: t)
                return result(
                    cached?.state, now: t, refreshed: false, stale: true, blockedUntil: blocked,
                    error: error.errorDescription)
            }
        }
    }

    private func resolveDevice(cached: DeviceState?) async throws -> DeviceSummary {
        if let device { return device }
        if let cached {
            let summary = DeviceSummary(deviceId: cached.deviceId, buildingId: cached.buildingId, name: cached.name)
            device = summary
            return summary
        }
        guard let first = try await backend.listDevices().first else { throw HeatPumpError.deviceNotFound }
        device = first
        return first
    }

    private func result(
        _ state: DeviceState?, now: Date, refreshed: Bool, stale: Bool, blockedUntil: Date? = nil,
        nextRefreshAllowed: Date? = nil, error: String? = nil
    ) -> StateResult {
        StateResult(
            state: state, fetchedAt: state?.fetchedAt,
            dataAgeSeconds: state.map { max(0, Int(now.timeIntervalSince($0.fetchedAt))) },
            refreshed: refreshed, stale: stale, blockedUntil: blockedUntil ?? (try? store.blockedUntil(now: now)) ?? nil,
            nextRefreshAllowed: nextRefreshAllowed, error: error)
    }

    /// Records a global block for rate-limit style errors. Returns the block end, if any.
    @discardableResult
    private func handleBlock(_ error: HeatPumpError, now: Date) throws -> Date? {
        switch error {
        case .rateLimited(let until):
            try store.recordBlock(until: until)
            return until
        case .loginThrottled(let until):
            let end = until ?? now.addingTimeInterval(Self.defaultLoginBlock)
            try store.recordBlock(until: end)
            return end
        default:
            return nil
        }
    }

    // MARK: History backfill

    /// Fetches missing error log, temperature log and energy data. Each report type is
    /// fetched at most once per hour across processes.
    public func syncHistory() async throws -> [ReportSync] {
        let t = now()
        var deviceState = try store.latestSnapshot()?.state
        if deviceState == nil { deviceState = try await currentState().state }
        guard let state = deviceState else {
            return ReportKind.allCases.map {
                ReportSync(kind: $0, status: .failed, count: 0, message: "Ingen enhet kjent ennå.", nextAllowed: nil)
            }
        }
        var results: [ReportSync] = []
        for kind in ReportKind.allCases {
            let key = "report.\(kind.rawValue)"
            switch try store.reserveFetch(key: key, minInterval: Self.reportInterval, now: t) {
            case .blocked(let until):
                results.append(ReportSync(kind: kind, status: .blocked, count: 0, message: nil, nextAllowed: until))
            case .throttled(let next):
                results.append(ReportSync(kind: kind, status: .skipped, count: 0, message: nil, nextAllowed: next))
            case .allowed:
                do {
                    let count = try await fetchReport(kind, deviceId: state.deviceId, key: key, now: t)
                    try store.recordFetchSuccess(key: key, now: t)
                    results.append(ReportSync(kind: kind, status: .fetched, count: count, message: nil, nextAllowed: nil))
                } catch let error as HeatPumpError {
                    let blocked = try handleBlock(error, now: t)
                    results.append(
                        ReportSync(kind: kind, status: blocked == nil ? .failed : .blocked, count: 0,
                                   message: error.errorDescription, nextAllowed: blocked))
                }
            }
        }
        return results
    }

    private func fetchReport(_ kind: ReportKind, deviceId: Int, key: String, now t: Date) async throws -> Int {
        let earliest = t.addingTimeInterval(-Double(Self.historyDays) * 86_400)
        switch kind {
        case .errorLog:
            let lastSuccess = try store.fetchState(key: key)?.lastSuccess
            let from = max(earliest, (lastSuccess ?? earliest).addingTimeInterval(-86_400))
            let entries = try await backend.fetchErrorLog(deviceId: deviceId, range: DateInterval(start: from, end: t))
            try store.upsertErrorEvents(entries)
            return entries.count
        case .temperatureLog:
            let latest = try store.latestTemperaturePointDate(deviceId: deviceId)
            let from = max(t.addingTimeInterval(-30 * 86_400), latest ?? .distantPast)
            let points = try await backend.fetchTemperatureLog(deviceId: deviceId, range: DateInterval(start: from, end: t))
            try store.upsertTemperaturePoints(points, deviceId: deviceId)
            return points.count
        case .energy:
            // Re-fetch the last two stored days: MELCloud fills energy data in late.
            let calendar = WireDate.calendar(timeZone)
            var from = calendar.startOfDay(for: t.addingTimeInterval(-60 * 86_400))
            if let latest = try store.latestEnergyDay(deviceId: deviceId),
                let date = WireDate.parse(latest, timeZone: timeZone)
            {
                from = max(from, date.addingTimeInterval(-2 * 86_400))
            }
            let days = try await backend.fetchEnergy(deviceId: deviceId, range: DateInterval(start: from, end: t))
            try store.upsertEnergyDays(days, deviceId: deviceId, now: t)
            return days.count
        }
    }

    // MARK: Changes

    /// Validates, budgets, sends and logs one change. Never throws for business reasons;
    /// the outcome says whether it was sent (`ok`), failed, or was rejected.
    public func apply(_ change: DeviceChange, source: ChangeSource, reason: String) async throws -> ChangeOutcome {
        let t = now()
        var state = try store.latestSnapshot()?.state
        if state == nil { state = try await currentState().state }
        let oldValue = change.currentValue(in: state)
        guard let state else {
            return try reject(change, source: source, reason: reason, oldValue: nil, error: "Ingen status fra varmepumpen ennå, så endringen kan ikke kontrolleres.", now: t)
        }
        let normalized: DeviceChange
        switch Self.validate(change, against: state) {
        case .failure(let message):
            return try reject(change, source: source, reason: reason, oldValue: oldValue, error: message.description, now: t)
        case .success(let value):
            normalized = value
        }
        if let until = try store.blockedUntil(now: t) {
            var outcome = try reject(
                normalized, source: source, reason: reason, oldValue: oldValue,
                error: HeatPumpError.blocked(until: until).errorDescription ?? "Blokkert", now: t)
            outcome.blockedUntil = until
            return outcome
        }
        let pending = ChangeRecord(
            timestamp: t, source: source, field: normalized.field, oldValue: oldValue,
            newValue: normalized.valueDescription, reason: reason, result: .pending)
        switch try store.reserveChange(pending) {
        case .exceeded(let next):
            var outcome = try reject(
                normalized, source: source, reason: reason, oldValue: oldValue,
                error: HeatPumpError.changeBudgetExceeded(nextAllowed: next).errorDescription ?? "", now: t)
            outcome.nextAllowed = next
            return outcome
        case .reserved(let id):
            do {
                try await backend.apply(Self.changeSet(normalized, for: state))
                try store.finishChange(id: id, result: .ok)
                try store.markLatestSnapshotStale(deviceId: state.deviceId)
                return ChangeOutcome(
                    result: .ok, message: "Sendt: \(normalized.displaySummary). Det kan ta opptil et par minutter før varmepumpen bekrefter.",
                    field: normalized.field, oldValue: oldValue, newValue: normalized.valueDescription)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                try store.finishChange(id: id, result: .failed, error: message)
                let blocked = try (error as? HeatPumpError).flatMap { try handleBlock($0, now: t) }
                return ChangeOutcome(
                    result: .failed, message: "Endringen feilet: \(message)", field: normalized.field,
                    oldValue: oldValue, newValue: normalized.valueDescription, blockedUntil: blocked)
            }
        }
    }

    /// Logs a change that was not sent (for example declined by the user in an MCP confirmation).
    @discardableResult
    public func logRejection(_ change: DeviceChange, source: ChangeSource, reason: String, error: String) throws -> ChangeOutcome {
        let oldValue = change.currentValue(in: try store.latestSnapshot()?.state)
        return try reject(change, source: source, reason: reason, oldValue: oldValue, error: error, now: now())
    }

    private func reject(
        _ change: DeviceChange, source: ChangeSource, reason: String, oldValue: String?, error: String, now t: Date
    ) throws -> ChangeOutcome {
        try store.logChange(
            ChangeRecord(
                timestamp: t, source: source, field: change.field, oldValue: oldValue,
                newValue: change.valueDescription, reason: reason, result: .rejected, error: error))
        return ChangeOutcome(
            result: .rejected, message: "Ikke sendt: \(error)", field: change.field, oldValue: oldValue,
            newValue: change.valueDescription)
    }

    /// Checks a change against the device's limits. Setpoints are rounded to the device step
    /// (0.5 °C) and rejected outside the min/max for the mode that will be active.
    public static func validate(_ change: DeviceChange, against state: DeviceState) -> Result<DeviceChange, ValidationFailure> {
        switch change {
        case .temperature(let celsius):
            guard celsius.isFinite else { return .failure(ValidationFailure("Ugyldig temperatur.")) }
            let mode = state.mode ?? .heat
            let step = state.temperatureIncrement > 0 ? state.temperatureIncrement : 0.5
            let snapped = (celsius / step).rounded() * step
            let range = state.limits.range(for: mode)
            guard range.contains(snapped) else {
                return .failure(
                    ValidationFailure(
                        Norwegian.format(
                            "%.1f °C er utenfor det tillatte området %.0f–%.0f °C for modus %@.",
                            celsius, range.lowerBound, range.upperBound, mode.displayName)))
            }
            return .success(.temperature(snapped))
        case .fanSpeed(let speed):
            guard (0...max(state.numberOfFanSpeeds, 1)).contains(speed) else {
                return .failure(ValidationFailure("Viftehastighet må være 0 (auto) eller 1–\(state.numberOfFanSpeeds)."))
            }
            if speed == 0 && !state.hasAutomaticFanSpeed {
                return .failure(ValidationFailure("Denne enheten støtter ikke automatisk viftehastighet."))
            }
            return .success(change)
        case .power, .mode, .vaneVertical, .vaneHorizontal:
            return .success(change)
        }
    }

    public struct ValidationFailure: Error, Sendable, Equatable, CustomStringConvertible {
        public var description: String
        init(_ description: String) { self.description = description }
    }

    static func changeSet(_ change: DeviceChange, for state: DeviceState) -> ChangeSet {
        var set = ChangeSet(deviceId: state.deviceId, buildingId: state.buildingId)
        switch change {
        case .power(let on): set.power = on
        case .mode(let mode): set.mode = mode
        case .temperature(let celsius): set.setTemperature = celsius
        case .fanSpeed(let speed): set.fanSpeed = speed
        case .vaneVertical(let vane): set.vaneVertical = vane
        case .vaneHorizontal(let vane): set.vaneHorizontal = vane
        }
        return set
    }

    // MARK: Maintenance

    @discardableResult
    public func recordMaintenance(kind: MaintenanceKind, date: Date? = nil, note: String? = nil) throws -> MaintenanceRecord {
        try store.insertMaintenance(MaintenanceRecord(kind: kind, timestamp: date ?? now(), note: note))
    }

    public func maintenanceStatus() throws -> [MaintenanceStatus] {
        let t = now()
        let records = try store.maintenanceRecords(limit: 500)
        return MaintenanceKind.allCases.map { kind in
            let last = records.filter { $0.kind == kind }.max { $0.timestamp < $1.timestamp }
            let days = last.map { Int(t.timeIntervalSince($0.timestamp) / 86_400) }
            let interval = kind.recommendedIntervalDays
            let status: String
            switch (days, interval) {
            case (_, nil): status = "not_applicable"
            case (nil, _): status = "unknown"
            case (let d?, let i?):
                if kind == .airFilter {
                    status = d > HealthEngine.Threshold.airFilterWarningDays ? "overdue" : d > i ? "due" : "ok"
                } else {
                    status = d > i ? "due" : "ok"
                }
            }
            return MaintenanceStatus(
                kind: kind, displayName: kind.displayName, lastDone: last?.timestamp, daysSince: days,
                recommendedIntervalDays: interval, status: status, note: last?.note)
        }
    }

    // MARK: Health

    public func healthReport() throws -> HealthReport {
        let t = now()
        let latest = try store.latestSnapshot()?.state
        let since = t.addingTimeInterval(-21 * 86_400)
        let deviceId = latest?.deviceId
        let input = HealthInput(
            latestState: latest,
            snapshots: try deviceId.map { try store.snapshots(deviceId: $0, from: since, to: t) } ?? [],
            temperaturePoints: try deviceId.map { try store.temperaturePoints(deviceId: $0, from: since, to: t) } ?? [],
            errorEvents: try store.errorEvents(deviceId: deviceId, since: t.addingTimeInterval(-Double(Self.historyDays) * 86_400)),
            energyDays: try deviceId.map {
                try store.energyDays(
                    deviceId: $0, fromDay: WireDate.day(since, timeZone: timeZone), toDay: WireDate.day(t, timeZone: timeZone))
            } ?? [],
            maintenance: try store.maintenanceRecords(limit: 500),
            now: t, timeZone: timeZone)
        return HealthEngine.evaluate(input)
    }

    // MARK: Read helpers

    public func errorLog(days: Int) throws -> [ErrorLogEntry] {
        try store.errorEvents(since: now().addingTimeInterval(-Double(days) * 86_400))
    }

    public func history(metric: HistoryMetric, from: Date, to: Date) throws -> [HistoryPoint] {
        guard let deviceId = try store.latestSnapshot()?.state.deviceId else { return [] }
        var points: [HistoryPoint] = try store.snapshots(deviceId: deviceId, from: from, to: to).compactMap { s in
            switch metric {
            case .roomTemperature: s.roomTemperature.map { HistoryPoint(timestamp: s.fetchedAt, value: $0, text: nil, source: "snapshot") }
            case .outdoorTemperature: s.outdoorTemperature.map { HistoryPoint(timestamp: s.fetchedAt, value: $0, text: nil, source: "snapshot") }
            case .setTemperature: s.setTemperature.map { HistoryPoint(timestamp: s.fetchedAt, value: $0, text: nil, source: "snapshot") }
            case .mode: HistoryPoint(timestamp: s.fetchedAt, value: s.mode.map { Double($0.rawValue) }, text: s.mode?.key, source: "snapshot")
            case .power: HistoryPoint(timestamp: s.fetchedAt, value: s.power ? 1 : 0, text: s.power ? "on" : "off", source: "snapshot")
            }
        }
        if [.roomTemperature, .outdoorTemperature, .setTemperature].contains(metric) {
            points += try store.temperaturePoints(deviceId: deviceId, from: from, to: to).compactMap { p in
                let value: Double? =
                    switch metric {
                    case .roomTemperature: p.room
                    case .outdoorTemperature: p.outdoor
                    default: p.set
                    }
                return value.map { HistoryPoint(timestamp: p.timestamp, value: $0, text: nil, source: "log") }
            }
        }
        return points.sorted { $0.timestamp < $1.timestamp }
    }

    public func energy(period: EnergyPeriod, from: Date, to: Date) throws -> [EnergyBucket] {
        guard let deviceId = try store.latestSnapshot()?.state.deviceId else { return [] }
        let days = try store.energyDays(
            deviceId: deviceId, fromDay: WireDate.day(from, timeZone: timeZone), toDay: WireDate.day(to, timeZone: timeZone))
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        var buckets: [String: EnergyBucket] = [:]
        for day in days {
            let key: String
            switch period {
            case .day: key = day.day
            case .month: key = String(day.day.prefix(7))
            case .week:
                guard let date = WireDate.parse(day.day, timeZone: timeZone),
                    let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start
                else { continue }
                key = WireDate.day(start, timeZone: timeZone)
            }
            var bucket = buckets[key] ?? EnergyBucket(period: key, totalKWh: 0, heatingKWh: 0, days: 0)
            bucket.totalKWh += day.totalKWh
            bucket.heatingKWh += day.heatingKWh ?? 0
            bucket.days += 1
            buckets[key] = bucket
        }
        return buckets.values.sorted { $0.period < $1.period }.map { bucket in
            var rounded = bucket
            rounded.totalKWh = (bucket.totalKWh * 100).rounded() / 100
            rounded.heatingKWh = (bucket.heatingKWh * 100).rounded() / 100
            return rounded
        }
    }

    public func changeLog(limit: Int, source: ChangeSource?) throws -> [ChangeRecord] {
        try store.changes(limit: limit, source: source)
    }

    public func fetchStatus() throws -> [FetchStateRow] {
        try ([Self.stateKey, HistoryStore.globalKey] + ReportKind.allCases.map { "report.\($0.rawValue)" })
            .compactMap { try store.fetchState(key: $0) }
    }
}
