import Foundation

/// Frost protection, holiday mode (cloud writes) and the weekly timer (read-only).
///
/// Reads: at most hourly (away) and every 6 hours (timer) across processes, cached in
/// `app_settings`. Writes: validated first (nothing counted or asked when invalid), Claude's need the
/// native approval, then they take a slot in the shared 12-per-hour budget with 5 s spacing and are
/// logged in `change_log` (`frostProtection`, `holidayMode`).
extension HeatPumpService {
    static let awaySettingsKey = "awaySettings"
    static let weeklyTimerKey = "weeklyTimer"
    public static let awayFetchKey = "away"
    public static let timerFetchKey = "timer"
    public static let awayInterval: TimeInterval = 3600
    public static let timerInterval: TimeInterval = 6 * 3600
    /// "Hent nå" for the timer, at most this often.
    public static let timerManualInterval: TimeInterval = 10 * 60
    static let weeklyTimerNote = "Merk: ukeplanen i MELCloud er på, så varmepumpen kan endre seg selv etter planen."

    /// These endpoints are unverified: a 401 or other refusal from them must not stop every other
    /// MELCloud call for an hour, so only real traffic limits (429, login throttle) become blocks.
    func handleAwayError(_ error: Error, now t: Date) throws -> Date? {
        guard let error = error as? HeatPumpError else { return nil }
        switch error {
        case .rateLimited, .loginThrottled: return try handleBlock(error, now: t)
        default: return nil
        }
    }

    // MARK: Reading

    /// Cached settings (or the device listing's copy) without touching the network.
    public func storedAwaySettings() throws -> AwaySettings? {
        if let cached = try store.setting(AwaySettings.self, key: Self.awaySettingsKey) { return cached }
        guard let deviceId = try store.latestSnapshot()?.state.deviceId else { return nil }
        return MELCloudClassicParser.awayFromListing(try store.rawDevice(deviceId: deviceId)?.listing)
    }

    /// Frost protection and holiday mode, read from MELCloud when the cached copy is older than
    /// `maxAge` and the hourly limit allows it.
    public func awaySettings(maxAge: TimeInterval = awayInterval) async throws -> AwaySettings {
        let t = now()
        let cached = try storedAwaySettings()
        if let cached, let at = cached.fetchedAt, t.timeIntervalSince(at) < maxAge, cached.pendingSince == nil {
            return cached
        }
        guard let deviceId = try store.latestSnapshot()?.state.deviceId else {
            return cached ?? AwaySettings(message: "Ingen status fra varmepumpen ennå.")
        }
        switch try store.reserveFetch(key: Self.awayFetchKey, minInterval: Self.awayInterval, now: t) {
        case .throttled, .blocked, .credentialsRejected:
            return cached ?? AwaySettings(message: "Hentes fra MELCloud senere (høyst én gang i timen).")
        case .allowed:
            do {
                var fresh = try await backend.fetchAwaySettings(deviceId: deviceId)
                fresh.fetchedAt = fresh.fetchedAt ?? t
                try store.saveSetting(fresh, key: Self.awaySettingsKey)
                try store.recordFetchSuccess(key: Self.awayFetchKey, now: t)
                return fresh
            } catch {
                _ = try handleAwayError(error, now: t)
                var fallback = cached ?? AwaySettings()
                fallback.message = "Kunne ikke lese frostsikring og feriemodus fra MELCloud: "
                    + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                return fallback
            }
        }
    }

    public func storedWeeklyTimer() throws -> WeeklyTimer? {
        try store.setting(WeeklyTimer.self, key: Self.weeklyTimerKey)
    }

    /// The weekly timer, read at most every 6 hours (`manual`: "Hent nå", at most every 10 minutes).
    public func weeklyTimer(manual: Bool = false) async throws -> WeeklyTimer? {
        let t = now()
        let cached = try storedWeeklyTimer()
        let interval = manual ? Self.timerManualInterval : Self.timerInterval
        if let at = cached?.fetchedAt, t.timeIntervalSince(at) < interval { return cached }
        guard let deviceId = try store.latestSnapshot()?.state.deviceId else { return cached }
        switch try store.reserveFetch(key: Self.timerFetchKey, minInterval: interval, now: t) {
        case .throttled, .blocked, .credentialsRejected:
            return cached
        case .allowed:
            do {
                var timer = try await backend.fetchWeeklyTimer(deviceId: deviceId)
                timer.fetchedAt = timer.fetchedAt ?? t
                try store.saveSetting(timer, key: Self.weeklyTimerKey)
                try store.recordFetchSuccess(key: Self.timerFetchKey, now: t)
                return timer
            } catch {
                _ = try handleAwayError(error, now: t)
                return cached
            }
        }
    }

    // MARK: Writing

    /// Validates, (for Claude) asks `approver`, reserves a write slot and sends one away change.
    /// Never throws for business reasons; the outcome says what happened, and every attempt is logged.
    public func applyAway(
        _ change: AwayChange, source: ChangeSource, reason: String, approver: (any ChangeApprover)? = nil
    ) async throws -> ChangeOutcome {
        let t = now()
        let current = try storedAwaySettings()
        func reject(_ message: String, nextAllowed: Date? = nil, blockedUntil: Date? = nil) throws -> ChangeOutcome {
            try store.logChange(
                ChangeRecord(
                    timestamp: now(), source: source, field: change.field, oldValue: change.currentValue(in: current),
                    newValue: change.valueDescription, reason: reason, result: .rejected, error: message))
            return ChangeOutcome(
                result: .rejected, message: "Ikke sendt: \(message)", field: change.field, oldValue: change.currentValue(in: current),
                newValue: change.valueDescription, nextAllowed: nextAllowed, blockedUntil: blockedUntil)
        }
        // Dry run first: nothing is counted or asked for a change that would be refused anyway.
        if let problem = change.validationProblem(now: t) { return try reject(problem) }
        guard let deviceId = try store.latestSnapshot()?.state.deviceId else {
            return try reject("Ingen status fra varmepumpen ennå.")
        }
        if try store.credentialsRejected() { return try reject(HeatPumpError.credentialsRejected.errorDescription ?? "") }
        if let block = try store.blockStatus(now: t) {
            return try reject(block.reason.message(until: block.until), blockedUntil: block.until)
        }
        if let approver {
            let decision = await approver.requestApproval(ApprovalRequest(summaries: [change.displaySummary], reason: reason))
            guard decision == .approved else { return try reject(decision.rejectionText) }
        }
        var waited: TimeInterval = 0
        while true {
            let at = now()
            let record = ChangeRecord(
                timestamp: at, source: source, field: change.field, oldValue: change.currentValue(in: current),
                newValue: change.valueDescription, reason: reason, result: .pending)
            switch try store.reserveChange([record]) {
            case .tooSoon(let next):
                let wait = max(0, next.timeIntervalSince(at))
                if waited + wait > Self.maxWriteWait {
                    return try reject(HeatPumpError.writeTooSoon(nextAllowed: next).errorDescription ?? "", nextAllowed: next)
                }
                waited += wait
                await sleep(wait + 0.05)
            case .exceeded(let next):
                return try reject(HeatPumpError.changeBudgetExceeded(nextAllowed: next).errorDescription ?? "", nextAllowed: next)
            case .reserved(let ids):
                do {
                    try await backend.applyAway(change, deviceId: deviceId)
                    try store.finishChange(ids: ids, result: .ok)
                    var updated = change.applied(to: current ?? AwaySettings())
                    updated.pendingSince = at
                    try store.saveSetting(updated, key: Self.awaySettingsKey)
                    return ChangeOutcome(
                        result: .ok,
                        message: "Sendt: \(change.displaySummary). MELCloud bekrefter ved neste henting (høyst én gang i timen).",
                        field: change.field, oldValue: change.currentValue(in: current), newValue: change.valueDescription)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    try store.finishChange(ids: ids, result: .failed, error: message)
                    let blocked = try handleAwayError(error, now: at)
                    return ChangeOutcome(
                        result: .failed, message: "Endringen feilet: \(message)", field: change.field,
                        oldValue: change.currentValue(in: current), newValue: change.valueDescription, blockedUntil: blocked)
                }
            }
        }
    }
}
