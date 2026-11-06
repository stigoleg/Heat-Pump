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
    /// "Fetch now" for the timer, at most this often.
    public static let timerManualInterval: TimeInterval = 10 * 60
    static let weeklyTimerNote = L10n.tr("Note: the weekly schedule in MELCloud is on, so the heat pump may change by itself according to the schedule.")
    /// After a refusal (HTTP 4xx) these reads pause this long, unless the user presses "Try again".
    public static let refusalBackoff: TimeInterval = 24 * 3600
    /// A 401 only counts as a refusal of the endpoint when the session read status this recently
    /// (otherwise the session itself may have expired, and the next status read logs in again).
    static let sessionProvenWithin: TimeInterval = 10 * 60
    /// Read-back right after a write, at most this often.
    static let verifyInterval: TimeInterval = 30
    /// Spacing of the read-backs of a saved weekly plan after failed attempts; after the last one
    /// the plan is read at the normal interval again.
    static let timerReadBackSpacing: [TimeInterval] = [30, 120, 600]
    static let awayVerifyKey = "away.verify"
    static let timerVerifyKey = "timer.verify"
    static let timerPresaveKey = "timer.presave"
    /// The read right before a save, at most this often.
    public static let timerPresaveInterval: TimeInterval = 15
    /// The app checks for this text in a "Not sent: …" message, so it must stay one value.
    public static let timerChangedMessage =
        L10n.tr("The weekly schedule has been changed in MELCloud since you started editing. Fetch the schedule again and redo your changes.")
    static let awayRefusedMessage =
        L10n.tr("MELCloud did not allow reading frost protection and holiday mode for this account. The app tries again in a day, or click “Try Again”.")
    static let timerRefusedMessage =
        L10n.tr("MELCloud did not allow reading the weekly schedule for this account. The app tries again in a day, or click “Fetch Now”.")

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
        guard let deviceId = try store.latestSnapshot()?.state.deviceId,
            let driver = backend as? any AwayModesDriver
        else { return nil }
        return driver.awaySettings(fromStoredListing: try store.rawDevice(deviceId: deviceId)?.listing)
    }

    /// Frost protection and holiday mode, read from MELCloud when the cached copy is older than
    /// `maxAge` and the hourly limit allows it. `manual` ("Try again") lifts a refusal pause and
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
            return cached ?? AwaySettings(message: L10n.tr("No status from the heat pump yet."))
        }
        switch try store.reserveFetch(key: Self.awayFetchKey, minInterval: manual ? Self.timerManualInterval : Self.awayInterval, now: t) {
        case .throttled, .blocked, .credentialsRejected:
            return cached ?? AwaySettings(message: L10n.tr("Fetched from MELCloud later (at most once an hour)."))
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
                fallback.message = L10n.format(
                    "Could not read frost protection and holiday mode from MELCloud: %@",
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                return fallback
            }
        }
    }

    /// One read of both settings; keeps what was last sent so the page can compare.
    private func readAway(deviceId: Int, keeping cached: AwaySettings?, at t: Date) async throws -> AwaySettings {
        var fresh = try await driver((any AwayModesDriver).self).fetchAwaySettings(deviceId: deviceId)
        fresh.fetchedAt = fresh.fetchedAt ?? t
        fresh.sentFrost = cached?.sentFrost
        fresh.sentHoliday = cached?.sentHoliday
        fresh.sentAt = cached?.sentAt
        try store.saveSetting(fresh, key: Self.awaySettingsKey)
        return fresh
    }

    /// How the connection reads weekly plans (nil without a weekly schedule), for comparing and
    /// validating plans in the UI.
    public nonisolated var weeklyTimerFormat: (any WeeklyTimerFormat)? {
        (backend as? any WeeklyScheduleDriver)?.weeklyTimerFormat
    }

    public func storedWeeklyTimer() throws -> WeeklyTimer? {
        try store.setting(WeeklyTimer.self, key: Self.weeklyTimerKey)
    }

    /// The weekly timer, read at most every 6 hours (`manual`: "Fetch now", at most every 10 minutes,
    /// and it lifts a refusal pause). `maxAge` reads it when the cached copy is older than that (the
    /// Weekly schedule page uses 10 minutes, so editing starts from a fresh plan), still at most that often.
    public func weeklyTimer(manual: Bool = false, maxAge: TimeInterval? = nil) async throws -> WeeklyTimer? {
        let t = now()
        if manual { try store.clearKeyRefusal(key: Self.timerFetchKey) }
        let cached = try storedWeeklyTimer()
        // A copy cached before seasons were kept has no `fetchedAt`: read it again as soon as allowed.
        let interval =
            maxAge ?? (manual || (cached != nil && cached?.fetchedAt == nil) ? Self.timerManualInterval : Self.timerInterval)
        let pending = cached?.pendingSince != nil
        if !pending, let at = cached?.fetchedAt, t.timeIntervalSince(at) < interval { return cached }
        if try endpointRefusedUntil(Self.timerFetchKey) != nil { return cached }
        guard let deviceId = try store.latestSnapshot()?.state.deviceId else { return cached }
        // A save that could not be read back right away is read back once the spacing allows
        // (30 s, then 2 and 10 minutes after failures).
        let attempts = cached?.pendingAttempts ?? 0
        let (key, spacing) =
            pending
            ? (Self.timerVerifyKey, Self.timerReadBackSpacing[min(attempts, Self.timerReadBackSpacing.count - 1)])
            : (Self.timerFetchKey, interval)
        switch try store.reserveFetch(key: key, minInterval: spacing, now: t) {
        case .throttled, .blocked, .credentialsRejected:
            return cached
        case .allowed:
            do {
                var timer = try await driver((any WeeklyScheduleDriver).self).fetchWeeklyTimer(deviceId: deviceId)
                timer.fetchedAt = timer.fetchedAt ?? t
                try store.saveSetting(timer, key: Self.weeklyTimerKey)
                try store.recordFetchSuccess(key: Self.timerFetchKey, now: t)
                return timer
            } catch {
                _ = try handleAwayError(error, now: t)
                if try isRefusal(error) {
                    try store.recordKeyRefusal(key: Self.timerFetchKey, until: t.addingTimeInterval(Self.refusalBackoff))
                }
                if pending, var failed = cached {
                    failed.pendingAttempts = attempts + 1
                    if attempts + 1 >= Self.timerReadBackSpacing.count {
                        failed.pendingSince = nil
                        failed.pendingAttempts = nil
                    }
                    try store.saveSetting(failed, key: Self.weeklyTimerKey)
                    return failed
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
                result: .rejected, message: L10n.format("Not sent: %@", message), field: change.field, oldValue: change.currentValue(in: current),
                newValue: change.valueDescription, nextAllowed: nextAllowed, blockedUntil: blockedUntil)
        }
        // Dry run first: nothing is counted or asked for a change that would be refused anyway.
        if let problem = change.validationProblem(now: t) { return try reject(problem) }
        guard let deviceId = try store.latestSnapshot()?.state.deviceId else {
            return try reject(L10n.tr("No status from the heat pump yet."))
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
            switch try store.reserveChange([record], budget: policy.changeBudget) {
            case .tooSoon(let next):
                let wait = max(0, next.timeIntervalSince(at))
                if waited + wait > policy.maxWriteWait {
                    return try reject(HeatPumpError.writeTooSoon(nextAllowed: next).errorDescription ?? "", nextAllowed: next)
                }
                waited += wait
                await sleep(wait + 0.05)
            case .exceeded(let next):
                return try reject(HeatPumpError.changeBudgetExceeded(nextAllowed: next).errorDescription ?? "", nextAllowed: next)
            case .reserved(let ids):
                do {
                    try await driver((any AwayModesDriver).self).applyAway(change, deviceId: deviceId)
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
                        message: readBack
                            ? L10n.format(
                                "Sent: %@. Check that MELCloud shows the same (shown on the page).", change.displaySummary(frost: current?.frost))
                            : L10n.format(
                                "Sent: %@. MELCloud confirms at the next fetch (at most once an hour).",
                                change.displaySummary(frost: current?.frost)),
                        field: change.field, oldValue: change.currentValue(in: current), newValue: change.valueDescription)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    try store.finishChange(ids: ids, result: .failed, error: message)
                    let blocked = try handleAwayError(error, now: at)
                    return ChangeOutcome(
                        result: .failed, message: L10n.format("The change failed: %@", message), field: change.field,
                        oldValue: change.currentValue(in: current), newValue: change.valueDescription, blockedUntil: blocked)
                }
            }
        }
    }

    // MARK: Weekly timer

    /// Saves the whole weekly timer (every season) in MELCloud, after validation (nothing counted
    /// when invalid). `base` is the plan the edit started from: right before sending, the plan is
    /// read fresh from MELCloud, and nothing is sent when it differs from `base` or cannot be read
    /// (a save replaces the whole plan, so it must not overwrite changes made elsewhere). One change
    /// in the shared budget, logged as field `weeklyTimer` with short summaries ("On, 6 events").
    /// Reads the plan back when the read-back limit allows it. App only: Claude can read the plan but
    /// not write it.
    public func saveWeeklyTimer(_ timer: WeeklyTimer, base: WeeklyTimer, source: ChangeSource, reason: String) async throws
        -> ChangeOutcome
    {
        let field = "weeklyTimer"
        let oldValue = base.summary
        let newValue = timer.summary
        func reject(_ message: String, nextAllowed: Date? = nil, blockedUntil: Date? = nil) throws -> ChangeOutcome {
            try store.logChange(
                ChangeRecord(
                    timestamp: now(), source: source, field: field, oldValue: oldValue, newValue: newValue, reason: reason,
                    result: .rejected, error: message))
            return ChangeOutcome(
                result: .rejected, message: L10n.format("Not sent: %@", message), field: field, oldValue: oldValue, newValue: newValue,
                nextAllowed: nextAllowed, blockedUntil: blockedUntil)
        }
        let t = now()
        guard let schedule = backend as? any WeeklyScheduleDriver else {
            return try reject(HeatPumpError.notSupported.errorDescription ?? "")
        }
        let format = schedule.weeklyTimerFormat
        guard let snapshot = try store.latestSnapshot() else { return try reject(L10n.tr("No status from the heat pump yet.")) }
        if !base.decoded {
            return try reject(
                L10n.tr("The weekly schedule from MELCloud could not be read completely, so the app does not change it. Fetch the schedule again first."))
        }
        if let problem = timer.validationProblem(limits: snapshot.state.limits, format: format) { return try reject(problem) }
        if try store.credentialsRejected() { return try reject(HeatPumpError.credentialsRejected.errorDescription ?? "") }
        if let block = try store.blockStatus(now: t) {
            return try reject(block.reason.message(until: block.until), blockedUntil: block.until)
        }
        let deviceId = snapshot.state.deviceId
        do {
            let fresh = try await readTimerBeforeSave(deviceId: deviceId)
            if !fresh.hasSameContent(as: base, format: format) { return try reject(Self.timerChangedMessage) }
        } catch let error as HeatPumpError {
            if case .blocked(let until) = error { return try reject(error.errorDescription ?? "", blockedUntil: until) }
            return try reject(error.errorDescription ?? "")
        }
        var waited: TimeInterval = 0
        while true {
            let at = now()
            let record = ChangeRecord(
                timestamp: at, source: source, field: field, oldValue: oldValue, newValue: newValue, reason: reason, result: .pending)
            switch try store.reserveChange([record], budget: policy.changeBudget) {
            case .tooSoon(let next):
                let wait = max(0, next.timeIntervalSince(at))
                if waited + wait > policy.maxWriteWait {
                    return try reject(HeatPumpError.writeTooSoon(nextAllowed: next).errorDescription ?? "", nextAllowed: next)
                }
                waited += wait
                await sleep(wait + 0.05)
            case .exceeded(let next):
                return try reject(HeatPumpError.changeBudgetExceeded(nextAllowed: next).errorDescription ?? "", nextAllowed: next)
            case .reserved(let ids):
                do {
                    try await schedule.saveWeeklyTimer(timer, deviceId: deviceId)
                    try store.finishChange(ids: ids, result: .ok)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    try store.finishChange(ids: ids, result: .failed, error: message)
                    let blocked = try handleAwayError(error, now: at)
                    return ChangeOutcome(
                        result: .failed, message: L10n.format("The weekly schedule was not saved: %@", message), field: field, oldValue: oldValue,
                        newValue: newValue, blockedUntil: blocked)
                }
                // Until it is read back, the cache holds what was sent (as the unit would return it).
                var sent = format.savedForm(of: timer, deviceId: deviceId)
                sent.fetchedAt = at
                sent.maxEvents = timer.maxEvents
                sent.pendingSince = at
                try store.saveSetting(sent, key: Self.weeklyTimerKey)
                var readBack: WeeklyTimer?
                if try store.reserveFetch(key: Self.timerVerifyKey, minInterval: Self.verifyInterval, now: now()) == .allowed,
                    var fresh = try? await schedule.fetchWeeklyTimer(deviceId: deviceId)
                {
                    fresh.fetchedAt = fresh.fetchedAt ?? now()
                    fresh.maxEvents = fresh.maxEvents ?? timer.maxEvents
                    try store.saveSetting(fresh, key: Self.weeklyTimerKey)
                    try store.recordFetchSuccess(key: Self.timerFetchKey, now: now())
                    readBack = fresh
                }
                let confirmed = readBack.map { $0.hasSameContent(as: sent, format: format) }
                let summary = sent.summary.lowercased(with: L10n.locale)
                let message: String =
                    switch confirmed {
                    case true?: L10n.format("The weekly schedule is saved in MELCloud (%@). MELCloud shows the same schedule.", summary)
                    case false?:
                        L10n.format(
                            "The weekly schedule is saved in MELCloud (%@). MELCloud shows a different schedule than the one that was sent. Check in the MELCloud app.",
                            summary)
                    case nil: L10n.format("The weekly schedule is saved in MELCloud (%@). MELCloud confirms at the next fetch.", summary)
                    }
                return ChangeOutcome(result: .ok, message: message, field: field, oldValue: oldValue, newValue: newValue)
            }
        }
    }

    /// Reads the plan right before a save (bypassing the 6-hour interval, but not blocks, the
    /// credential stop, a refusal pause or the 15 s spacing). Every failure is a reason not to send.
    private func readTimerBeforeSave(deviceId: Int) async throws -> WeeklyTimer {
        let t = now()
        if let until = try endpointRefusedUntil(Self.timerFetchKey) {
            throw HeatPumpError.validation(
                L10n.format(
                    "MELCloud did not allow reading the weekly schedule (next try %@), and it is not saved without checking that it is unchanged.",
                    Display.time(until)))
        }
        switch try store.reserveFetch(key: Self.timerPresaveKey, minInterval: Self.timerPresaveInterval, now: t) {
        case .throttled(let next):
            throw HeatPumpError.validation(L10n.format("The weekly schedule was just fetched. Try again after %@.", Display.time(next)))
        case .blocked(let until): throw HeatPumpError.blocked(until: until)
        case .credentialsRejected: throw HeatPumpError.credentialsRejected
        case .allowed: break
        }
        do {
            var fresh = try await driver((any WeeklyScheduleDriver).self).fetchWeeklyTimer(deviceId: deviceId)
            fresh.fetchedAt = fresh.fetchedAt ?? t
            try store.saveSetting(fresh, key: Self.weeklyTimerKey)
            try store.recordFetchSuccess(key: Self.timerFetchKey, now: t)
            return fresh
        } catch {
            _ = try handleAwayError(error, now: t)
            if try isRefusal(error) {
                try store.recordKeyRefusal(key: Self.timerFetchKey, until: t.addingTimeInterval(Self.refusalBackoff))
            }
            throw HeatPumpError.validation(
                L10n.format(
                    "Could not read the weekly schedule from MELCloud before saving, so it was not sent (it may have been changed there): %@",
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }
}
