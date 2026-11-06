import Foundation

/// Single entry point for the app and the MCP server.
///
/// Reads come from the shared SQLite cache; the network is touched only when the cache
/// is too old, never more than once per `policy.minRefreshInterval` across all processes, and
/// never while a block is active. Every change is validated, budgeted (`policy.changeBudget`,
/// across processes) and logged.
public actor HeatPumpService {
    public static let historyDays = 90

    static let stateKey = "state"

    /// The connection to the unit. Optional capabilities are reached with `as? any …Driver`.
    public nonisolated let backend: any DeviceConnection & ThermostatDriver
    /// The integration the backend belongs to: its name in texts, error codes, health rules,
    /// maintenance kinds and knowledge documents.
    public nonisolated let integration: any Integration
    /// The integration's rate limits.
    public nonisolated let policy: RateLimitPolicy
    public nonisolated let store: HistoryStore
    public nonisolated let timeZone: TimeZone
    /// Credential store used by `saveCredentials` / `signOut` (nil for the mock backend).
    public nonisolated let credentials: (any CredentialProviding)?
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async -> Void
    private var device: DeviceSummary?
    /// Builds the price source for the current settings (nil for Norgespris or a missing token).
    let priceProvider: @Sendable (PriceSettings) -> (any PriceProvider)?
    /// Read-only access to the Wi-Fi adapter on the home network (unavailable unless injected).
    let local: LocalAccess
    /// Builds the forecast source for the current weather settings (nil: no forecast).
    let weatherProvider: @Sendable (WeatherSettings) -> (any WeatherProviding)?
    /// The house's consumption source (Tibber; nil without a token). Called at most hourly.
    let houseProvider: @Sendable () -> (any HouseConsumptionProviding)?

    public init(
        backend: any DeviceConnection & ThermostatDriver, store: HistoryStore, credentials: (any CredentialProviding)? = nil,
        integration: any Integration, policy: RateLimitPolicy = .standard, timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(max(0, seconds)))
        },
        priceProvider: @escaping @Sendable (PriceSettings) -> (any PriceProvider)? = { _ in nil },
        local: LocalAccess = .unavailable,
        weatherProvider: @escaping @Sendable (WeatherSettings) -> (any WeatherProviding)? = { _ in nil },
        houseProvider: @escaping @Sendable () -> (any HouseConsumptionProviding)? = { nil }
    ) {
        self.priceProvider = priceProvider
        self.houseProvider = houseProvider
        self.weatherProvider = weatherProvider
        self.local = local
        self.backend = backend
        self.integration = integration
        HeatPumpError.serviceName = integration.displayName
        self.policy = policy
        self.store = store
        self.credentials = credentials
        self.timeZone = timeZone
        self.now = now
        self.sleep = sleep
    }

    /// The service as texts name it, e.g. "MELCloud".
    public nonisolated var serviceName: String { integration.displayName }

    /// The integration's error-code explanations.
    public nonisolated var errorCodes: any ErrorCodeExplaining { integration.errorCodes }

    /// Knowledge documents for the MCP resources and the Health page.
    public nonisolated var knowledge: Knowledge { Knowledge(integration: integration) }

    /// Marketing version of the running app or helper (for User-Agent strings).
    public static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }

    // MARK: Credentials

    /// Shortest gap between two sign-in test fetches (each one is a real login attempt).
    public static let signInMinInterval: TimeInterval = 10

    /// Cached answer to "are credentials stored?" so polling never touches the keychain.
    private var credentialsStored: Bool?

    /// Whether credentials are stored. Checked once (without reading the password), then
    /// cached and updated on save, sign-out and refused logins.
    public func hasCredentials() -> Bool {
        guard let credentials else { return true }
        if let credentialsStored { return credentialsStored }
        let stored = credentials.hasValues(for: integration.credentialMapping)
        credentialsStored = stored
        return stored
    }

    /// E-mail of the stored account, for display. Reads only the item's attributes
    /// (no secret); still a keychain call, so on demand (e.g. when Settings opens), not from polling.
    public func accountEmail() -> String? {
        credentials?.storedIdentity(for: integration.credentialMapping)
    }

    /// Saves new sign-in values (`CredentialField.id` → value) and lifts a "credentials rejected"
    /// stop. Does not call the network.
    public func saveCredentials(_ new: CredentialValues) throws {
        guard let credentials else { return }
        try credentials.saveValues(new, for: integration.credentialMapping)
        credentialsStored = true
        try store.clearCredentialsRejected(integration: integration.id)
        device = nil
    }

    /// Saves credentials, forgets the old session and does one test fetch right away
    /// (one login + one fetch). It skips the 60 s refresh spacing but still respects 429 and
    /// login-throttle blocks, is recorded like any fetch, and is itself limited to one per 10 s.
    public func signIn(_ new: CredentialValues) async throws -> StateResult {
        try saveCredentials(new)
        await backend.resetSession()
        return try await fetchState(minInterval: Self.signInMinInterval, cached: try latestSnapshot(), maxAge: 0)
    }

    /// Removes credentials and session from the keychain.
    public func signOut() async throws {
        try credentials?.deleteValues(for: integration.credentialMapping)
        credentialsStored = false
        await backend.resetSession()
        device = nil
    }

    // MARK: Device and store scope

    /// The `fetch_state` key of `name` in this integration's namespace (its blocks, spacing and
    /// last fetches are its own).
    public nonisolated func fetchKey(_ name: String) -> String { HistoryStore.fetchKey(name, integration: integration.id) }

    /// The device this service serves: the one resolved in this process, else the first enabled
    /// one in the registry. No network; nil until a device is known.
    public func currentDevice() throws -> DeviceKey? {
        if let device { return device.key }
        guard let record = try store.devices().first(where: \.enabled) else { return nil }
        device = record.summary
        return record.key
    }

    /// The newest stored snapshot of the served device.
    public func latestSnapshot() throws -> HistoryStore.Snapshot? {
        guard let key = try currentDevice() else { return nil }
        return try store.latestSnapshot(device: key)
    }

    /// The integration's active block.
    func blockStatus(now: Date) throws -> BlockStatus? { try store.blockStatus(now: now, integration: integration.id) }

    /// Whether the integration's service refused the stored credentials.
    func credentialsRejected() throws -> Bool { try store.credentialsRejected(integration: integration.id) }

    /// `reserveFetch` for one of the integration's own keys, honouring its blocks.
    func reserveFetch(_ name: String, minInterval: TimeInterval, now: Date) throws -> FetchDecision {
        try store.reserveFetch(key: fetchKey(name), minInterval: minInterval, now: now, blockingIntegration: integration.id)
    }

    /// True for the simulated backend (`VARMEPUMPE_BACKEND=mock`).
    public nonisolated var isDemo: Bool { backend.identifier == "mock" }

    /// The backend as the optional capability `T` (an `any …` driver protocol), or
    /// `HeatPumpError.notSupported` when it does not have it.
    nonisolated func driver<T>(_ capability: T.Type) throws -> T {
        guard let driver = backend as? T else { throw HeatPumpError.notSupported }
        return driver
    }

    // MARK: State

    /// Cached state unless older than `maxAge` (or `force`). Network refresh is rate limited
    /// globally; when skipped or blocked the cached state is returned with an indicator.
    public func currentState(maxAge: TimeInterval? = nil, force: Bool = false) async throws -> StateResult {
        let maxAge = maxAge ?? policy.maxAge
        let t = now()
        let cached = try latestSnapshot()
        if let cached, !force, !cached.stale, t.timeIntervalSince(cached.state.fetchedAt) < maxAge {
            return result(cached.state, now: t, refreshed: false, stale: false)
        }
        // Without credentials there is nothing to fetch; do not use up the refresh slot.
        guard hasCredentials() else {
            var r = result(
                cached?.state, now: t, refreshed: false, stale: cached != nil,
                error: HeatPumpError.missingCredentials.errorDescription)
            r.needsLogin = true
            return r
        }
        return try await fetchState(minInterval: policy.minRefreshInterval, cached: cached, maxAge: maxAge)
    }

    private func fetchState(minInterval: TimeInterval, cached: HistoryStore.Snapshot?, maxAge: TimeInterval) async throws -> StateResult {
        let t = now()
        switch try reserveFetch(Self.stateKey, minInterval: minInterval, now: t) {
        case .credentialsRejected:
            var r = result(
                cached?.state, now: t, refreshed: false, stale: true,
                error: HeatPumpError.credentialsRejected.errorDescription)
            r.needsLogin = true
            return r
        case .blocked(let until):
            return result(cached?.state, now: t, refreshed: false, stale: true, blockedUntil: until)
        case .throttled(let next):
            // Another process probably just refreshed; prefer its result.
            let latest = try latestSnapshot() ?? cached
            let isStale = latest.map { $0.stale || t.timeIntervalSince($0.state.fetchedAt) >= maxAge } ?? true
            return result(latest?.state, now: t, refreshed: false, stale: isStale, nextRefreshAllowed: next)
        case .allowed:
            do {
                let summary = try await resolveDevice()
                let state = try await backend.fetchState(device: summary.key)
                try store.insertSnapshot(state)
                try store.recordFetchSuccess(key: fetchKey(Self.stateKey), now: t)
                return result(state, now: now(), refreshed: true, stale: false)
            } catch let error as HeatPumpError {
                if error == .missingCredentials { credentialsStored = false }
                let blocked = try handleBlock(error, now: t)
                var r = result(
                    cached?.state, now: t, refreshed: false, stale: true, blockedUntil: blocked,
                    error: blocked == nil
                        ? (error.isCredentialProblem ? HeatPumpError.credentialsRejected : error).errorDescription : nil)
                r.needsLogin = r.needsLogin || error.isCredentialProblem || error == .missingCredentials
                return r
            }
        }
    }

    /// The served device: from this process, else the registry, else the first the backend
    /// lists (every listed device is registered).
    private func resolveDevice() async throws -> DeviceSummary {
        if let device { return device }
        if let record = try store.devices().first(where: \.enabled) {
            device = record.summary
            return record.summary
        }
        let listed = try await backend.listDevices()
        guard let first = listed.first else { throw HeatPumpError.deviceNotFound }
        try store.registerDevices(listed)
        device = first
        return first
    }

    private func result(
        _ state: DeviceState?, now: Date, refreshed: Bool, stale: Bool, blockedUntil: Date? = nil,
        nextRefreshAllowed: Date? = nil, error: String? = nil
    ) -> StateResult {
        let block = (try? blockStatus(now: now)) ?? nil
        let credentialsRejected = (try? credentialsRejected()) ?? false
        let until = blockedUntil ?? block?.until
        var message: String?
        if credentialsRejected {
            message = HeatPumpError.credentialsRejected.errorDescription
        } else if let until {
            message = (block?.reason ?? .rateLimited).message(until: until, serviceName: serviceName)
        }
        return StateResult(
            state: state, fetchedAt: state?.fetchedAt,
            dataAgeSeconds: state.map { max(0, Int(now.timeIntervalSince($0.fetchedAt))) },
            refreshed: refreshed, stale: stale, blockedUntil: until,
            nextRefreshAllowed: nextRefreshAllowed, error: error,
            needsLogin: credentialsRejected, blockReason: until == nil ? nil : (block?.reason ?? .rateLimited),
            blockMessage: message)
    }

    /// Records blocks for rate-limit and credential errors. Returns the block end, if timed.
    @discardableResult
    func handleBlock(_ error: HeatPumpError, now: Date) throws -> Date? {
        switch error {
        case .rateLimited(let until):
            try store.recordBlock(until: until, reason: .rateLimited, integration: integration.id)
            return until
        case .loginThrottled(let until):
            let end = until ?? now.addingTimeInterval(policy.defaultLoginBlock)
            try store.recordBlock(until: end, reason: .loginThrottled, integration: integration.id)
            return end
        case .unauthorized:
            let end = now.addingTimeInterval(policy.unauthorizedBlock)
            try store.recordBlock(until: end, reason: .unauthorized, integration: integration.id)
            return end
        case .invalidCredentials:
            credentialsStored = true
            // Every further login attempt with the same password risks an account-wide
            // throttle that also hits the official app; stop until the user saves new ones.
            try store.recordCredentialsRejected(now: now, integration: integration.id)
            return nil
        default:
            return nil
        }
    }

    // MARK: History backfill

    /// Fetches missing error log, temperature log and energy data. Each report type is
    /// fetched at most once per hour across processes.
    public func syncHistory() async throws -> [ReportSync] {
        let t = now()
        if try credentialsRejected() {
            return ReportKind.allCases.map {
                ReportSync(kind: $0, status: .blocked, count: 0,
                           message: HeatPumpError.credentialsRejected.errorDescription, nextAllowed: nil)
            }
        }
        var deviceState = try latestSnapshot()?.state
        if deviceState == nil { deviceState = try await currentState().state }
        guard let state = deviceState else {
            return ReportKind.allCases.map {
                ReportSync(kind: $0, status: .failed, count: 0, message: L10n.tr("No unit known yet."), nextAllowed: nil)
            }
        }
        var results: [ReportSync] = []
        for kind in ReportKind.allCases {
            let key = "report.\(kind.rawValue)"
            switch try reserveFetch(key, minInterval: policy.reportInterval, now: t) {
            case .credentialsRejected:
                results.append(
                    ReportSync(kind: kind, status: .blocked, count: 0,
                               message: HeatPumpError.credentialsRejected.errorDescription, nextAllowed: nil))
            case .blocked(let until):
                results.append(ReportSync(kind: kind, status: .blocked, count: 0, message: nil, nextAllowed: until))
            case .throttled(let next):
                results.append(ReportSync(kind: kind, status: .skipped, count: 0, message: nil, nextAllowed: next))
            case .allowed:
                do {
                    let count = try await fetchReport(kind, device: state.key, key: key, now: t)
                    try store.recordFetchSuccess(key: fetchKey(key), now: t)
                    results.append(ReportSync(kind: kind, status: .fetched, count: count, message: nil, nextAllowed: nil))
                } catch let error as HeatPumpError {
                    let blocked = try handleBlock(error, now: t)
                    let stopped = blocked != nil || error.isCredentialProblem
                    results.append(
                        ReportSync(kind: kind, status: stopped ? .blocked : .failed, count: 0,
                                   message: error.errorDescription, nextAllowed: blocked))
                }
            }
        }
        return results
    }

    /// Interval from `from` to `to`, or nil when it would be empty/negative (DateInterval traps on that).
    private func interval(_ from: Date, _ to: Date) -> DateInterval? {
        from < to ? DateInterval(start: from, end: to) : nil
    }

    private func fetchReport(_ kind: ReportKind, device: DeviceKey, key: String, now t: Date) async throws -> Int {
        let earliest = t.addingTimeInterval(-Double(Self.historyDays) * 86_400)
        switch kind {
        case .errorLog:
            let lastSuccess = try store.fetchState(key: fetchKey(key))?.lastSuccess
            let from = max(earliest, (lastSuccess ?? earliest).addingTimeInterval(-86_400))
            guard let range = interval(from, t) else { return 0 }
            let entries = try await driver((any ErrorLogReporting).self).fetchErrorLog(device: device, range: range)
            try store.upsertErrorEvents(entries)
            return entries.count
        case .temperatureLog:
            // At most a week per request; the web app asks for short ranges too.
            let reporter = try driver((any TemperatureLogReporting).self)
            let latest = try store.latestTemperaturePointDate(device: device)
            let maxDays = Double(reporter.maxTemperatureLogDays)
            let from = max(t.addingTimeInterval(-maxDays * 86_400), latest ?? .distantPast)
            guard let range = interval(from, t) else { return 0 }
            let points = try await reporter.fetchTemperatureLog(device: device, range: range)
            try store.upsertTemperaturePoints(points, device: device)
            return points.count
        case .energy:
            // One request short enough that the cloud answers per day. The last two stored
            // days are fetched again because the cloud fills energy data in late.
            let reporter = try driver((any EnergyReporting).self)
            let calendar = WireDate.calendar(timeZone)
            let maxDays = reporter.maxEnergyReportDays - 1
            var from = calendar.startOfDay(for: t.addingTimeInterval(-Double(maxDays) * 86_400))
            if let latest = try store.latestEnergyDay(device: device),
                let date = WireDate.parse(latest, timeZone: timeZone)
            {
                from = max(from, date.addingTimeInterval(-2 * 86_400))
            }
            guard let range = interval(from, t) else { return 0 }
            let days = try await reporter.fetchEnergy(device: device, range: range)
            try store.upsertEnergyDays(days, device: device, now: t)
            return days.count
        }
    }

    // MARK: Changes

    /// Latest stored state without touching the network (for example right after a write).
    public func cachedState() throws -> DeviceState? {
        try latestSnapshot()?.state
    }

    /// State to validate against: the expected state after accepted changes when it is newer
    /// than the latest snapshot, otherwise the latest snapshot.
    public func effectiveState() throws -> DeviceState? {
        let snapshot = try latestSnapshot()?.state
        guard let key = try snapshot?.key ?? currentDevice(),
            let expected = try store.expectedState(device: key)
        else { return snapshot }
        if let snapshot, snapshot.fetchedAt > expected.at { return snapshot }
        return expected.state
    }

    /// Validates, budgets, sends and logs one change. Never throws for business reasons;
    /// the outcome says whether it was sent (`ok`), failed, or was rejected.
    public func apply(_ change: DeviceChange, source: ChangeSource, reason: String) async throws -> ChangeOutcome {
        let outcomes = try await apply([change], source: source, reason: reason)
        return outcomes.first ?? ChangeOutcome(result: .rejected, message: L10n.tr("No change."), field: change.field)
    }

    /// Validates and sends several changes. Everything except a second vane axis goes out as
    /// one `SetAta` request (combined EffectiveFlags); vanes are one axis per request.
    /// If any change is invalid, nothing is sent and all are logged as rejected.
    public func apply(_ changes: [DeviceChange], source: ChangeSource, reason: String) async throws -> [ChangeOutcome] {
        switch try await prepare(changes, source: source, reason: reason) {
        case .rejected(let outcomes):
            return outcomes
        case .ready(let start, let normalized):
            return try await sendPrepared(normalized, start: start, source: source, reason: reason)
        }
    }

    /// Like `apply`, but asks `approver` (a human) first. Changes that would be rejected anyway
    /// (invalid, blocked) are logged without asking. A refusal, timeout or missing dialog is
    /// logged as `rejected` and nothing is sent. After approval everything is checked again.
    public func applyWithApproval(
        _ changes: [DeviceChange], source: ChangeSource, reason: String, approver: any ChangeApprover
    ) async throws -> [ChangeOutcome] {
        switch try await prepare(changes, source: source, reason: reason) {
        case .rejected(let outcomes):
            return outcomes
        case .ready(let start, let normalized):
            let request = ApprovalRequest(summaries: normalized.map(\.displaySummary), reason: reason)
            let decision = await approver.requestApproval(request)
            guard decision == .approved else {
                return try rejectAll(
                    normalized, source: source, reason: reason, state: start,
                    error: decision.rejectionText, now: now())
            }
            return try await apply(changes, source: source, reason: reason)
        }
    }

    private enum Prepared {
        case rejected([ChangeOutcome])
        case ready(start: DeviceState, normalized: [DeviceChange])
    }

    /// Validates against the expected state and checks stops/blocks. Rejections are logged.
    private func prepare(_ changes: [DeviceChange], source: ChangeSource, reason: String) async throws -> Prepared {
        guard !changes.isEmpty else { return .rejected([]) }
        let t = now()
        var base = try effectiveState()
        if base == nil {
            _ = try await currentState()
            base = try effectiveState()
        }
        guard let start = base else {
            return .rejected(try rejectAll(
                changes, source: source, reason: reason, state: nil,
                error: L10n.tr("No status from the heat pump yet, so the change cannot be checked."), now: t))
        }

        // Validate in dependency order against the state as it will be.
        var projected = start
        var normalized: [DeviceChange] = []
        for change in changes.sorted(by: { $0.validationOrder < $1.validationOrder }) {
            switch Self.validate(change, against: projected) {
            case .failure(let message):
                return .rejected(
                    try rejectAll(changes, source: source, reason: reason, state: start, error: message.description, now: t))
            case .success(let value):
                normalized.append(value)
                projected = value.applied(to: projected)
            }
        }
        // Refusals the backend would make locally go out before budget, approval or network.
        if let problem = backend.unknownModeProblem, projected.mode == nil {
            return .rejected(try rejectAll(normalized, source: source, reason: reason, state: start, error: problem, now: t))
        }
        var dryRun = ChangeSet(device: start.key)
        for change in normalized { Self.merge(change, into: &dryRun) }
        if let problem = await backend.localWriteProblem(dryRun, requireBase: false) {
            return .rejected(try rejectAll(normalized, source: source, reason: reason, state: start, error: problem, now: t))
        }
        if try credentialsRejected() {
            return .rejected(try rejectAll(
                normalized, source: source, reason: reason, state: start,
                error: HeatPumpError.credentialsRejected.errorDescription ?? "", now: t))
        }
        if let block = try blockStatus(now: t) {
            var outcomes = try rejectAll(
                normalized, source: source, reason: reason, state: start,
                error: block.reason.message(until: block.until, serviceName: serviceName), now: t)
            for i in outcomes.indices { outcomes[i].blockedUntil = block.until }
            return .rejected(outcomes)
        }
        return .ready(start: start, normalized: normalized)
    }

    private func sendPrepared(
        _ normalized: [DeviceChange], start: DeviceState, source: ChangeSource, reason: String
    ) async throws -> [ChangeOutcome] {
        // Split into requests: one with everything but a second vane axis, then that axis.
        var first = normalized.filter { !$0.isVane }
        var requests: [[DeviceChange]] = []
        let vanes = normalized.filter(\.isVane)
        if let firstVane = vanes.first { first.append(firstVane) }
        if !first.isEmpty { requests.append(first) }
        if vanes.count > 1 { requests.append(Array(vanes.dropFirst())) }

        var outcomes: [ChangeOutcome] = []
        var current = start
        if let problem = try await refreshWriteBase(device: start.key) {
            return try rejectAll(normalized, source: source, reason: reason, state: start, error: problem, now: now())
        }
        for (index, request) in requests.enumerated() {
            let sent = try await send(request, base: current, source: source, reason: reason)
            outcomes += sent.outcomes
            current = sent.state
            if sent.outcomes.contains(where: { $0.result != .ok }) {
                // Do not send the rest; log it as not sent.
                for remaining in requests.dropFirst(index + 1) {
                    outcomes += try rejectAll(
                        remaining, source: source, reason: reason, state: current,
                        error: L10n.tr("Not sent because the previous part of the change did not go through."), now: now())
                }
                break
            }
        }
        return outcomes
    }

    /// Reserves spacing + budget for one request (waiting briefly if another write just went
    /// out), sends it and logs the result.
    private func send(
        _ request: [DeviceChange], base: DeviceState, source: ChangeSource, reason: String
    ) async throws -> (outcomes: [ChangeOutcome], state: DeviceState) {
        var changeSet = ChangeSet(device: base.key)
        for change in request { Self.merge(change, into: &changeSet) }
        // Checked against the (now fresh) device object before a budget slot is used.
        if let problem = await backend.localWriteProblem(changeSet, requireBase: true) {
            return (try rejectAll(request, source: source, reason: reason, state: base, error: problem, now: now()), base)
        }
        var waited: TimeInterval = 0
        while true {
            let t = now()
            let records = request.map {
                ChangeRecord(
                    timestamp: t, source: source, field: $0.field, oldValue: $0.currentValue(in: base),
                    newValue: $0.valueDescription, reason: reason, result: .pending)
            }
            switch try store.reserveChange(records, device: base.key, budget: policy.changeBudget) {
            case .tooSoon(let next):
                let wait = max(0, next.timeIntervalSince(t))
                if waited + wait > policy.maxWriteWait {
                    let outcomes = try rejectAll(
                        request, source: source, reason: reason, state: base,
                        error: HeatPumpError.writeTooSoon(nextAllowed: next).errorDescription ?? "", now: t)
                    return (outcomes.map { var o = $0; o.nextAllowed = next; return o }, base)
                }
                waited += wait
                await sleep(wait + 0.05)
                continue
            case .exceeded(let next):
                let outcomes = try rejectAll(
                    request, source: source, reason: reason, state: base,
                    error: HeatPumpError.changeBudgetExceeded(nextAllowed: next).errorDescription ?? "", now: t)
                return (outcomes.map { var o = $0; o.nextAllowed = next; return o }, base)
            case .reserved(let ids):
                do {
                    let reported = try await backend.apply(changeSet)
                    try store.finishChange(ids: ids, result: .ok)
                    var expected = request.reduce(base) { $1.applied(to: $0) }
                    try store.saveExpectedState(expected, at: t)
                    if var reported {
                        // A field the response leaves out keeps its value; the mode never
                        // becomes unknown because of a write.
                        if reported.mode == nil { reported.mode = expected.mode }
                        if reported.setTemperature == nil { reported.setTemperature = expected.setTemperature }
                        try store.insertSnapshot(reported)
                        expected = request.reduce(reported) { $1.applied(to: $0) }
                    }
                    // Not confirmed by the unit yet: the next refresh fetches again.
                    try store.markLatestSnapshotStale(device: base.key)
                    // With MELCloud's weekly timer on, the unit may change again by itself.
                    let timerOn = (try? storedWeeklyTimer())??.enabled == true
                    let outcomes = request.map { change in
                        ChangeOutcome(
                            result: .ok,
                            message: timerOn
                                ? L10n.format(
                                    "Sent: %@. It may take up to a couple of minutes before the heat pump confirms. %@", change.displaySummary,
                                    weeklyTimerNote)
                                : L10n.format("Sent: %@. It may take up to a couple of minutes before the heat pump confirms.", change.displaySummary),
                            field: change.field, oldValue: change.currentValue(in: base), newValue: change.valueDescription)
                    }
                    return (outcomes, expected)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    try store.finishChange(ids: ids, result: .failed, error: message)
                    let blocked = try (error as? HeatPumpError).flatMap { try handleBlock($0, now: t) }
                    let outcomes = request.map { change in
                        ChangeOutcome(
                            result: .failed, message: L10n.format("The change failed: %@", message), field: change.field,
                            oldValue: change.currentValue(in: base), newValue: change.valueDescription, blockedUntil: blocked)
                    }
                    return (outcomes, base)
                }
            }
        }
    }

    /// Some drivers (MELCloud Classic) write the whole device object, so it must be recent. When the
    /// backend's copy is missing or older than `writeBaseMaxAge`, one state fetch is made under
    /// the normal refresh rules. Returns a user-facing reason when the write must not be sent.
    private func refreshWriteBase(device: DeviceKey) async throws -> String? {
        guard backend.requiresFreshStateForWrites else { return nil }
        func isFresh() async -> Bool {
            guard let at = await backend.writeBaseFetchedAt(device: device) else { return false }
            return now().timeIntervalSince(at) < policy.writeBaseMaxAge
        }
        if await isFresh() { return nil }
        let t = now()
        switch try reserveFetch(Self.stateKey, minInterval: policy.minRefreshInterval, now: t) {
        case .credentialsRejected:
            return HeatPumpError.credentialsRejected.errorDescription
        case .blocked(let until):
            return (try blockStatus(now: t)?.reason ?? .rateLimited).message(until: until, serviceName: serviceName)
        case .throttled(let next):
            // Another process may have just fetched and stored the device object.
            if await isFresh() { return nil }
            return L10n.format(
                "The change was not sent because the app must first fetch a fresh status from the heat pump, and it was fetched recently. Try again after %@.",
                Display.time(next))
        case .allowed:
            do {
                let state = try await backend.fetchState(device: device)
                try store.insertSnapshot(state)
                try store.recordFetchSuccess(key: fetchKey(Self.stateKey), now: t)
                if await isFresh() { return nil }
                return L10n.format(
                    "The change was not sent because the answer from %@ lacked a complete status for the heat pump.", serviceName)
            } catch let error as HeatPumpError {
                try handleBlock(error, now: t)
                return L10n.format(
                    "The change was not sent because the status from the heat pump could not be fetched first: %@",
                    error.errorDescription ?? L10n.tr("unknown error"))
            }
        }
    }

    /// Remaining write requests this rolling hour and the earliest time the next may be sent
    /// (5 s spacing and the 12-per-hour budget, across processes).
    public func writeBudget() throws -> WriteBudget {
        let t = now()
        let budget = policy.changeBudget
        // The budget is the account's: the integration of the served device.
        let scope = try currentDevice()?.integration ?? integration.id
        let usage = try store.writeUsage(integration: scope, now: t, window: budget.window)
        let limit = budget.maxChangesPerHour
        var next: Date?
        if usage.used.count >= limit {
            next = usage.used[usage.used.count - limit].addingTimeInterval(budget.window)
        }
        if let last = usage.lastWrite, t.timeIntervalSince(last) < budget.minSpacing {
            next = max(next ?? .distantPast, last.addingTimeInterval(budget.minSpacing))
        }
        return WriteBudget(remaining: max(0, limit - usage.used.count), nextAllowed: next)
    }

    /// Logs a change that was not sent (for example declined by the user in an MCP confirmation).
    @discardableResult
    public func logRejection(_ change: DeviceChange, source: ChangeSource, reason: String, error: String) throws -> ChangeOutcome {
        let outcomes = try rejectAll([change], source: source, reason: reason, state: try effectiveState(), error: error, now: now())
        return outcomes.first ?? ChangeOutcome(result: .rejected, message: L10n.format("Not sent: %@", error), field: change.field)
    }

    private func rejectAll(
        _ changes: [DeviceChange], source: ChangeSource, reason: String, state: DeviceState?, error: String, now t: Date
    ) throws -> [ChangeOutcome] {
        let device = try state?.key ?? currentDevice()
        return try changes.map { change in
            let oldValue = change.currentValue(in: state)
            try store.logChange(
                ChangeRecord(
                    timestamp: t, source: source, field: change.field, oldValue: oldValue,
                    newValue: change.valueDescription, reason: reason, result: .rejected, error: error),
                device: device)
            return ChangeOutcome(
                result: .rejected, message: L10n.format("Not sent: %@", error), field: change.field, oldValue: oldValue,
                newValue: change.valueDescription)
        }
    }

    static func merge(_ change: DeviceChange, into set: inout ChangeSet) {
        switch change {
        case .power(let on): set.power = on
        case .mode(let mode): set.mode = mode
        case .temperature(let celsius): set.setTemperature = celsius
        case .fanSpeed(let speed): set.fanSpeed = speed
        case .vaneVertical(let vane): set.vaneVertical = vane
        case .vaneHorizontal(let vane): set.vaneHorizontal = vane
        }
    }

    /// Checks a change against the device's limits. Setpoints are rounded to the device step
    /// (0.5 °C) and rejected outside the min/max for the mode that will be active.
    public static func validate(_ change: DeviceChange, against state: DeviceState) -> Result<DeviceChange, ValidationFailure> {
        switch change {
        case .temperature(let celsius):
            guard celsius.isFinite else { return .failure(ValidationFailure(L10n.tr("Invalid temperature."))) }
            let mode = state.mode ?? .heat
            let snapped = state.snappedSetpoint(celsius)
            let range = state.limits.range(for: mode)
            guard range.contains(snapped) else {
                return .failure(
                    ValidationFailure(
                        L10n.format(
                            "%.1f °C is outside the allowed range %.0f–%.0f °C for the %@ mode.",
                            celsius, range.lowerBound, range.upperBound, mode.displayName)))
            }
            return .success(.temperature(snapped))
        case .fanSpeed(let speed):
            guard (0...max(state.numberOfFanSpeeds, 1)).contains(speed) else {
                return .failure(ValidationFailure(L10n.format("Fan speed must be 0 (auto) or 1–%lld.", state.numberOfFanSpeeds)))
            }
            if speed == 0 && !state.hasAutomaticFanSpeed {
                return .failure(ValidationFailure(L10n.tr("This unit does not support automatic fan speed.")))
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

    // MARK: Maintenance

    /// Allowed clock skew for "now" maintenance dates.
    static let maintenanceFutureTolerance: TimeInterval = 5 * 60

    /// Records a maintenance task. Rejects dates in the future; `reason` (why it was
    /// recorded, e.g. from Claude) is kept in the note.
    @discardableResult
    public func recordMaintenance(
        kind: MaintenanceKind, date: Date? = nil, note: String? = nil, reason: String? = nil
    ) throws -> MaintenanceRecord {
        let t = now()
        let when = date ?? t
        guard when <= t.addingTimeInterval(Self.maintenanceFutureTolerance) else {
            throw HeatPumpError.validation(L10n.tr("The date cannot be in the future."))
        }
        let parts = [note, reason.map { L10n.format("Reason: %@", $0) }].compactMap { text -> String? in
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        return try store.insertMaintenance(
            MaintenanceRecord(kind: kind, timestamp: when, note: parts.isEmpty ? nil : parts.joined(separator: "\n")),
            device: try currentDevice())
    }

    public func maintenanceStatus() throws -> [MaintenanceStatus] {
        let t = now()
        let records = try store.maintenanceRecords(device: try currentDevice(), limit: 500)
        return integration.maintenanceTasks.map { task in
            let kind = task.kind
            let last = records.filter { $0.kind == kind }.max { $0.timestamp < $1.timestamp }
            let days = last.map { Int(t.timeIntervalSince($0.timestamp) / 86_400) }
            let interval = task.intervalDays
            let status: String
            switch (days, interval) {
            case (_, nil): status = "not_applicable"
            case (nil, _): status = "unknown"
            case (let d?, let i?):
                if let overdue = task.overdueAfterDays, d > overdue {
                    status = "overdue"
                } else {
                    status = d > i ? "due" : "ok"
                }
            }
            let nextDue: Date? =
                if let last, let interval { last.timestamp.addingTimeInterval(Double(interval) * 86_400) } else { nil }
            return MaintenanceStatus(
                kind: kind, displayName: kind.displayName, lastDone: last?.timestamp, daysSince: days,
                recommendedIntervalDays: interval, status: status, note: last?.note, nextDue: nextDue)
        }
    }

    // MARK: Health

    public func healthReport() throws -> HealthReport {
        let t = now()
        let device = try currentDevice()
        let latest = try device.flatMap { try store.latestSnapshot(device: $0) }?.state
        let since = t.addingTimeInterval(-21 * 86_400)
        let input = HealthInput(
            latestState: latest,
            snapshots: try device.map { try store.snapshots(device: $0, from: since, to: t) } ?? [],
            temperaturePoints: try device.map { try store.temperaturePoints(device: $0, from: since, to: t) } ?? [],
            errorEvents: try device.map {
                try store.errorEvents(device: $0, since: t.addingTimeInterval(-Double(Self.historyDays) * 86_400))
            } ?? [],
            energyDays: try device.map {
                try store.energyDays(
                    device: $0, fromDay: WireDate.day(since, timeZone: timeZone), toDay: WireDate.day(t, timeZone: timeZone))
            } ?? [],
            maintenance: try store.maintenanceRecords(device: device, limit: 500),
            now: t, timeZone: timeZone, blockedUntil: try store.blockedUntil(now: t, integration: integration.id),
            local: try localHealthInput(now: t),
            integration: integration)
        return HealthEngine.evaluate(input)
    }

    // MARK: Read helpers

    public func errorLog(days: Int) throws -> [ErrorLogEntry] {
        guard let device = try currentDevice() else { return [] }
        return try store.errorEvents(device: device, since: now().addingTimeInterval(-Double(days) * 86_400))
    }

    public func history(metric: HistoryMetric, from: Date, to: Date) throws -> [HistoryPoint] {
        if metric.isLocal { return try localHistory(metric: metric, from: from, to: to) }
        guard let device = try currentDevice() else { return [] }
        var points: [HistoryPoint] = try store.snapshots(device: device, from: from, to: to).compactMap { s in
            switch metric {
            case .roomTemperature: s.roomTemperature.map { HistoryPoint(timestamp: s.fetchedAt, value: $0, text: nil, source: "snapshot") }
            case .outdoorTemperature: s.outdoorTemperature.map { HistoryPoint(timestamp: s.fetchedAt, value: $0, text: nil, source: "snapshot") }
            case .setTemperature: s.setTemperature.map { HistoryPoint(timestamp: s.fetchedAt, value: $0, text: nil, source: "snapshot") }
            case .mode: HistoryPoint(timestamp: s.fetchedAt, value: s.mode.map { Double($0.legacyCode) }, text: s.mode?.key, source: "snapshot")
            case .power: HistoryPoint(timestamp: s.fetchedAt, value: s.power ? 1 : 0, text: s.power ? "on" : "off", source: "snapshot")
            case .powerW, .compressorHz, .defrost: nil
            }
        }
        if [.roomTemperature, .outdoorTemperature, .setTemperature].contains(metric) {
            points += try store.temperaturePoints(device: device, from: from, to: to).compactMap { p in
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

    /// Temperature history for charts: MELCloud's temperature log, completed with the app's own
    /// snapshots after the last log point. When MELCloud has nothing, snapshots alone are used
    /// (`fromMELCloud` false) so the chart still shows what has been seen while the app ran.
    public func temperatureHistory(from: Date, to: Date) throws -> TemperatureHistory {
        guard let device = try currentDevice() else {
            return TemperatureHistory(points: [], fromService: false)
        }
        let log = try store.temperaturePoints(device: device, from: from, to: to)
        let after = log.last?.timestamp ?? .distantPast
        let own = try store.snapshots(device: device, from: from, to: to).compactMap { s -> TemperaturePoint? in
            guard s.fetchedAt > after, s.roomTemperature != nil || s.outdoorTemperature != nil else { return nil }
            return TemperaturePoint(
                timestamp: s.fetchedAt, room: s.roomTemperature, set: s.power ? s.setTemperature : nil,
                outdoor: s.outdoorTemperature)
        }
        return TemperatureHistory(points: log + own, fromService: !log.isEmpty)
    }

    public func energy(period: EnergyPeriod, from: Date, to: Date) throws -> [EnergyBucket] {
        guard let device = try currentDevice() else { return [] }
        var days = try store.energyDays(
            device: device, fromDay: WireDate.day(from, timeZone: timeZone), toDay: WireDate.day(to, timeZone: timeZone))
        let cloudDays = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        // Days the adapter's local counter covers completely use its exact total.
        let local = try localDayTotals(from: from, to: to)
        if !local.isEmpty {
            var byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
            for (day, kWh) in local {
                let cooling = byDay[day]?.coolingKWh
                byDay[day] = EnergyDay(day: day, totalKWh: kWh, heatingKWh: max(0, kWh - (cooling ?? 0)), coolingKWh: cooling)
            }
            days = byDay.values.sorted { $0.day < $1.day }
        }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        let costs = try dayCosts(days: days)
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
            if let cloud = cloudDays[day.day] {
                var split = bucket.modes ?? EnergyModeSplit()
                split.add(cloud)
                bucket.modes = split
            }
            if let dayCost = costs[day.day] {
                bucket.cost = (bucket.cost ?? CostSplit()) + dayCost.cost
                bucket.isEstimate = bucket.isEstimate || dayCost.isEstimate
            } else if day.totalKWh > 0 {
                bucket.isEstimate = true
            }
            buckets[key] = bucket
        }
        return buckets.values.sorted { $0.period < $1.period }.map { bucket in
            var rounded = bucket
            rounded.totalKWh = (bucket.totalKWh * 100).rounded() / 100
            rounded.heatingKWh = (bucket.heatingKWh * 100).rounded() / 100
            rounded.cost = bucket.cost?.rounded()
            rounded.modes = bucket.modes?.rounded()
            rounded.costNok = bucket.cost.map { ($0.totalNok * 100).rounded() / 100 }
            return rounded
        }
    }

    public func changeLog(limit: Int, source: ChangeSource?) throws -> [ChangeRecord] {
        try store.changes(device: try currentDevice(), limit: limit, source: source)
    }

    /// The integration's fetch status rows, keyed by name without the namespace (`state`,
    /// `global`, `report.energy`, …).
    public func fetchStatus() throws -> [FetchStateRow] {
        try ([Self.stateKey, HistoryStore.globalKey] + ReportKind.allCases.map { "report.\($0.rawValue)" }
            + [Self.awayFetchKey, Self.timerFetchKey])
            .compactMap { name in try store.fetchState(key: fetchKey(name)).map { var row = $0; row.key = name; return row } }
    }
}
