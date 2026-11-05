import Foundation

/// Frost protection, holiday mode and the weekly timer (cloud writes).
///
/// Reads: at most hourly (away) and every 6 hours (timer) across processes, cached in
/// `app_settings`. Writes: validated first (nothing counted or asked when invalid), Claude's need the
/// native approval, then they take a slot in the shared 12-per-hour budget with 5 s spacing and are
/// logged in `change_log` (`frostProtection`, `holidayMode`, `weeklyTimer`). Only the app writes the
/// weekly timer.
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
    /// After a refusal (HTTP 4xx) these reads pause this long, unless the user presses "Prøv igjen".
    public static let refusalBackoff: TimeInterval = 24 * 3600
    /// A 401 only counts as a refusal of the endpoint when the session read status this recently
    /// (otherwise the session itself may have expired, and the next status read logs in again).
    static let sessionProvenWithin: TimeInterval = 10 * 60
    /// Read-back right after a write, at most this often.
    static let verifyInterval: TimeInterval = 30
    static let awayVerifyKey = "away.verify"
    static let timerVerifyKey = "timer.verify"
    static let awayRefusedMessage =
        "MELCloud tillot ikke å lese frostsikring og feriemodus for denne kontoen. Appen prøver igjen om et døgn, eller trykk «Prøv igjen»."
    static let timerRefusedMessage =
        "MELCloud tillot ikke å lese ukeplanen for denne kontoen. Appen prøver igjen om et døgn, eller trykk «Hent nå»."

    /// When automatic reads of `key` (`away` or `timer`) are paused after a refusal, or nil.
    public func endpointRefusedUntil(_ key: String) throws -> Date? {
        guard let until = try store.fetchState(key: key)?.blockedUntil, until > now() else { return nil }
        return until
    }

    /// True for answers that mean "this account may not use this endpoint" (not traffic or network).
    func isRefusal(_ error: Error) throws -> Bool {
        guard let error = error as? HeatPumpError else { return false }
        switch error {
        case .endpointRefused(let status):
            // A 401 right after a successful status read is the endpoint, not an expired session.
            if status == 401, let ok = try store.fetchState(key: Self.stateKey)?.lastSuccess {
                return now().timeIntervalSince(ok) < Self.sessionProvenWithin
            }
            return status != 401
        case .http(let status): return (400..<500).contains(status) && status != 429
        default: return false
        }
    }

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
    /// `maxAge` and the hourly limit allows it. `manual` ("Prøv igjen") lifts a refusal pause and
    /// allows a read every 10 minutes.
    public func awaySettings(maxAge: TimeInterval = awayInterval, manual: Bool = false) async throws -> AwaySettings {
        let t = now()
        if manual { try store.clearKeyRefusal(key: Self.awayFetchKey) }
        var cached = try storedAwaySettings()
        if let cached, let at = cached.fetchedAt, t.timeIntervalSince(at) < maxAge, cached.pendingSince == nil, !manual {
            return cached
        }
        if let until = try endpointRefusedUntil(Self.awayFetchKey) {
            var paused = cached ?? AwaySettings()
            paused.refusedUntil = until
            paused.message = Self.awayRefusedMessage
            return paused
        }
        guard let deviceId = try store.latestSnapshot()?.state.deviceId else {
            return cached ?? AwaySettings(message: "Ingen status fra varmepumpen ennå.")
        }
        switch try store.reserveFetch(key: Self.awayFetchKey, minInterval: manual ? Self.timerManualInterval : Self.awayInterval, now: t) {
        case .throttled, .blocked, .credentialsRejected:
            return cached ?? AwaySettings(message: "Hentes fra MELCloud senere (høyst én gang i timen).")
        case .allowed:
            do {
                let fresh = try await readAway(deviceId: deviceId, keeping: cached, at: t)
                try store.recordFetchSuccess(key: Self.awayFetchKey, now: t)
                return fresh
            } catch {
                _ = try handleAwayError(error, now: t)
                if try isRefusal(error) {
                    let until = t.addingTimeInterval(Self.refusalBackoff)
                    try store.recordKeyRefusal(key: Self.awayFetchKey, until: until)
                    cached = cached ?? AwaySettings()
                    cached?.refusedUntil = until
                    cached?.message = Self.awayRefusedMessage
                    return cached ?? AwaySettings()
                }
                var fallback = cached ?? AwaySettings()
                fallback.message = "Kunne ikke lese frostsikring og feriemodus fra MELCloud: "
                    + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                return fallback
            }
        }
    }

    /// One read of both settings; keeps what was last sent so the page can compare.
    private func readAway(deviceId: Int, keeping cached: AwaySettings?, at t: Date) async throws -> AwaySettings {
        var fresh = try await backend.fetchAwaySettings(deviceId: deviceId)
        fresh.fetchedAt = fresh.fetchedAt ?? t
        fresh.sentFrost = cached?.sentFrost
        fresh.sentHoliday = cached?.sentHoliday
        fresh.sentAt = cached?.sentAt
        try store.saveSetting(fresh, key: Self.awaySettingsKey)
        return fresh
    }

    public func storedWeeklyTimer() throws -> WeeklyTimer? {
        try store.setting(WeeklyTimer.self, key: Self.weeklyTimerKey)
    }

    /// The weekly timer, read at most every 6 hours (`manual`: "Hent nå", at most every 10 minutes,
    /// and it lifts a refusal pause).
    public func weeklyTimer(manual: Bool = false) async throws -> WeeklyTimer? {
        let t = now()
        if manual { try store.clearKeyRefusal(key: Self.timerFetchKey) }
        let cached = try storedWeeklyTimer()
        // A copy cached before seasons were kept has no `fetchedAt`: read it again as soon as allowed.
        let interval = manual || (cached != nil && cached?.fetchedAt == nil) ? Self.timerManualInterval : Self.timerInterval
        if let at = cached?.fetchedAt, t.timeIntervalSince(at) < interval { return cached }
        if try endpointRefusedUntil(Self.timerFetchKey) != nil { return cached }
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
                if try isRefusal(error) {
                    try store.recordKeyRefusal(key: Self.timerFetchKey, until: t.addingTimeInterval(Self.refusalBackoff))
                }
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
        var current = try storedAwaySettings()
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
        // Holiday mode may leave the unit off: it needs frost protection known to be on (read at
        // most hourly), and frost protection is not switched off during a holiday.
        current = try await awaySettings()
        if let problem = change.safetyProblem(current: current, now: t) { return try reject(problem) }
        if try store.credentialsRejected() { return try reject(HeatPumpError.credentialsRejected.errorDescription ?? "") }
        if let block = try store.blockStatus(now: t) {
            return try reject(block.reason.message(until: block.until), blockedUntil: block.until)
        }
        if let approver {
            let decision = await approver.requestApproval(
                ApprovalRequest(summaries: [change.displaySummary(frost: current?.frost)], reason: reason))
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
                    updated.sentAt = at
                    try store.saveSetting(updated, key: Self.awaySettingsKey)
                    // Read back once so the page can show what MELCloud stored next to what was sent.
                    var readBack = false
                    if try store.reserveFetch(key: Self.awayVerifyKey, minInterval: Self.verifyInterval, now: now()) == .allowed {
                        readBack = (try? await readAway(deviceId: deviceId, keeping: updated, at: now())) != nil
                    }
                    return ChangeOutcome(
                        result: .ok,
                        message: "Sendt: \(change.displaySummary(frost: current?.frost))."
                            + (readBack ? " Sjekk at MELCloud viser det samme (vises på siden)." : " MELCloud bekrefter ved neste henting (høyst én gang i timen)."),
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

    // MARK: Weekly timer

    /// Saves the whole weekly timer (every season) in MELCloud, after validation (nothing counted
    /// when invalid). One change in the shared budget, logged as field `weeklyTimer` with short
    /// summaries ("På, 6 hendelser"). Reads the plan back when the read-back limit allows it.
    /// App only: Claude can read the plan but not write it.
    public func saveWeeklyTimer(_ timer: WeeklyTimer, source: ChangeSource, reason: String) async throws -> ChangeOutcome {
        let field = "weeklyTimer"
        let old = try storedWeeklyTimer()
        let oldValue = old?.summary
        let newValue = timer.summary
        func reject(_ message: String, nextAllowed: Date? = nil, blockedUntil: Date? = nil) throws -> ChangeOutcome {
            try store.logChange(
                ChangeRecord(
                    timestamp: now(), source: source, field: field, oldValue: oldValue, newValue: newValue, reason: reason,
                    result: .rejected, error: message))
            return ChangeOutcome(
                result: .rejected, message: "Ikke sendt: \(message)", field: field, oldValue: oldValue, newValue: newValue,
                nextAllowed: nextAllowed, blockedUntil: blockedUntil)
        }
        let t = now()
        guard let snapshot = try store.latestSnapshot() else { return try reject("Ingen status fra varmepumpen ennå.") }
        if old?.decoded != true {
            return try reject("Ukeplanen fra MELCloud kunne ikke leses helt, så appen endrer den ikke. Hent planen på nytt først.")
        }
        if let problem = timer.validationProblem(limits: snapshot.state.limits) { return try reject(problem) }
        if try store.credentialsRejected() { return try reject(HeatPumpError.credentialsRejected.errorDescription ?? "") }
        if let block = try store.blockStatus(now: t) {
            return try reject(block.reason.message(until: block.until), blockedUntil: block.until)
        }
        let deviceId = snapshot.state.deviceId
        var waited: TimeInterval = 0
        while true {
            let at = now()
            let record = ChangeRecord(
                timestamp: at, source: source, field: field, oldValue: oldValue, newValue: newValue, reason: reason, result: .pending)
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
                    try await backend.saveWeeklyTimer(timer, deviceId: deviceId)
                    try store.finishChange(ids: ids, result: .ok)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    try store.finishChange(ids: ids, result: .failed, error: message)
                    let blocked = try handleAwayError(error, now: at)
                    return ChangeOutcome(
                        result: .failed, message: "Ukeplanen ble ikke lagret: \(message)", field: field, oldValue: oldValue,
                        newValue: newValue, blockedUntil: blocked)
                }
                // Until it is read back, the cache holds what was sent (as MELCloud would return it).
                var sent = MELCloudClassicParser.weeklyTimer(
                    .object([
                        "Enabled": .bool(timer.enabled == true && timer.totalEvents > 0),
                        "Seasons": MELCloudClassicParser.timerSetBody(timer: timer, deviceId: deviceId)["Seasons"] ?? .array([]),
                    ]))
                sent.fetchedAt = at
                sent.maxEvents = timer.maxEvents
                try store.saveSetting(sent, key: Self.weeklyTimerKey)
                var readBack: WeeklyTimer?
                if try store.reserveFetch(key: Self.timerVerifyKey, minInterval: Self.verifyInterval, now: now()) == .allowed,
                    var fresh = try? await backend.fetchWeeklyTimer(deviceId: deviceId)
                {
                    fresh.fetchedAt = fresh.fetchedAt ?? now()
                    fresh.maxEvents = fresh.maxEvents ?? timer.maxEvents
                    try store.saveSetting(fresh, key: Self.weeklyTimerKey)
                    try store.recordFetchSuccess(key: Self.timerFetchKey, now: now())
                    readBack = fresh
                }
                let confirmed = readBack.map { $0.decoded && $0.differences(from: sent).isEmpty }
                let tail: String =
                    switch confirmed {
                    case true?: " MELCloud viser den samme planen."
                    case false?: " MELCloud viser en annen plan enn den som ble sendt. Sjekk i MELCloud-appen."
                    case nil: " MELCloud bekrefter ved neste henting."
                    }
                return ChangeOutcome(
                    result: .ok, message: "Ukeplanen er lagret i MELCloud (\(sent.summary.lowercased())).\(tail)", field: field,
                    oldValue: oldValue, newValue: newValue)
            }
        }
    }
}
