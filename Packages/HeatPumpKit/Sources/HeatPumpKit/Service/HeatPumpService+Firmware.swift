import Foundation

/// Firmware updates of the Wi-Fi adapter (MELCloud Classic, unverified endpoints).
///
/// Reads: `FirmwareUpdate/List2` only when the account owns the unit and an update is waiting or
/// running (as MELCloud's web client does), at most every 60 s, or every 15 s while one runs;
/// cached in `app_settings`. Starting needs the owner, an update MELCloud offers and a unit that is
/// online; Claude's start needs the native approval. Start and cancel take a slot in the shared
/// 12-per-hour budget and are logged in `change_log` (`firmware`). Firmware cannot be rolled back.
extension HeatPumpService {
    static let firmwareStatusKey = "firmwareStatus"
    public static let firmwareFetchKey = "firmware"
    public static let firmwareInterval: TimeInterval = 60
    /// While an update runs (and for "Refresh status") MELCloud is asked at most this often.
    public static let firmwareActiveInterval: TimeInterval = 15
    /// A start or cancel is based on a list at most this old.
    static let firmwareActionMaxAge: TimeInterval = 60
    static let firmwareField = "firmware"
    static let firmwareRefusedMessage =
        L10n.tr("MELCloud did not allow reading the firmware status for this account. The app tries again in a day, or click “Refresh Status”.")

    public func storedFirmwareStatus() throws -> FirmwareStatus? {
        try store.setting(FirmwareStatus.self, key: Self.firmwareStatusKey)
    }

    // MARK: Reading

    /// Firmware version, whether an update waits and MELCloud's update list. `force` ("Oppdater
    /// status") allows a read every 15 s and, unless `liftRefusal` is false, lifts a refusal pause
    /// (only a person should do that, not Claude). Never throws for MELCloud errors; they end up
    /// in `message`.
    public func firmwareStatus(force: Bool = false, liftRefusal: Bool? = nil) async throws -> FirmwareStatus {
        let t = now()
        if liftRefusal ?? force { try store.clearKeyRefusal(key: Self.firmwareFetchKey) }
        let state = try store.latestSnapshot()?.state
        let cached = try storedFirmwareStatus()
        var status = Self.firmwareBase(state, cached: cached)
        func done(_ status: FirmwareStatus) -> FirmwareStatus { Self.decorated(status, state: state) }
        guard let state else {
            status.message = L10n.tr("No status from the heat pump yet.")
            return done(status)
        }
        let active = status.isInProgress(now: t)
        // Like MELCloud's web client: only the owner, and only with an update waiting or running.
        guard status.isOwner == true, status.updateAvailable || active else { return done(status) }
        let interval = active || force ? Self.firmwareActiveInterval : Self.firmwareInterval
        if let at = status.fetchedAt, t.timeIntervalSince(at) < interval { return done(status) }
        if try endpointRefusedUntil(Self.firmwareFetchKey) != nil {
            status.message = Self.firmwareRefusedMessage
            return done(status)
        }
        switch try store.reserveFetch(key: Self.firmwareFetchKey, minInterval: interval, now: t) {
        case .throttled:
            break
        case .credentialsRejected:
            status.message = HeatPumpError.credentialsRejected.errorDescription
        case .blocked(let until):
            status.message = try store.blockStatus(now: t)?.reason.message(until: until)
                ?? HeatPumpError.blocked(until: until).errorDescription
        case .allowed:
            do {
                status.updates = try await backend.firmwareUpdates(deviceId: state.deviceId)
                status.fetchedAt = t
                try store.saveSetting(status, key: Self.firmwareStatusKey)
                try store.recordFetchSuccess(key: Self.firmwareFetchKey, now: t)
                // Finished: the next status read should show the new version.
                if status.phase == .complete, cached?.isInProgress(now: t) == true {
                    try store.markLatestSnapshotStale(deviceId: state.deviceId)
                }
            } catch {
                _ = try handleAwayError(error, now: t)
                if try isRefusal(error) {
                    try store.recordKeyRefusal(key: Self.firmwareFetchKey, until: t.addingTimeInterval(Self.refusalBackoff))
                    status.message = Self.firmwareRefusedMessage
                } else {
                    status.message = L10n.format(
                        "Could not read the firmware status from MELCloud: %@",
                        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }
        return done(status)
    }

    /// The cached list with version, waiting update and ownership from the latest snapshot.
    static func firmwareBase(_ state: DeviceState?, cached: FirmwareStatus?) -> FirmwareStatus {
        var status = cached ?? FirmwareStatus()
        status.message = nil
        if let state {
            status.currentVersion = state.firmware.version
            status.updateAvailable = state.firmware.updateAvailable
            status.isOwner = state.firmware.isOwner
        }
        return status
    }

    static func decorated(_ status: FirmwareStatus, state: DeviceState?) -> FirmwareStatus {
        var status = status
        status.startProblem = firmwareUnitProblem(state) ?? firmwareListProblem(status)
        status.canCancel = status.current.map { $0.phase.canCancel && $0.id != nil } ?? false
        return status
    }

    /// Why the unit itself rules out starting an update (no list needed), or nil.
    static func firmwareUnitProblem(_ state: DeviceState?) -> String? {
        guard let state else { return L10n.tr("No status from the heat pump yet.") }
        switch state.firmware.isOwner {
        case nil:
            return L10n.tr("MELCloud has not said whether the account owns the unit. Refresh the status and try again.")
        case false:
            return L10n.tr("Only the owner of the unit in MELCloud can start a firmware update.")
        case true:
            break
        }
        if !state.firmware.updateAvailable { return L10n.tr("No firmware update is waiting for the unit.") }
        if state.offline { return offlineMessage }
        return nil
    }

    static let offlineMessage = L10n.tr("The unit is disconnected from MELCloud. The update can be started when it is connected again.")

    /// Why MELCloud's update list rules out starting, or nil.
    static func firmwareListProblem(_ status: FirmwareStatus) -> String? {
        guard let current = status.current else {
            return L10n.tr("Has not received the update list from MELCloud yet. Refresh the status and try again.")
        }
        if current.unitOffline { return offlineMessage }
        guard current.phase.canApprove else { return L10n.format("The update cannot be started now: %@", current.displayText) }
        guard current.id != nil else { return L10n.tr("MELCloud gave no id for the update.") }
        return nil
    }

    /// Lines for the approval dialog (and the app's confirmation sheet).
    public static func firmwareApprovalSummaries(version: String?) -> [String] {
        [version.map { L10n.format("Start a firmware update of the Wi-Fi adapter (now version %@)", $0) }
            ?? L10n.tr("Start a firmware update of the Wi-Fi adapter")]
            + FirmwareStatus.warnings
    }

    // MARK: Writing

    /// Checks owner, waiting update, connection and MELCloud's list, (for Claude) asks `approver`,
    /// reserves a write slot and approves the update. Never throws for business reasons; every
    /// attempt is logged.
    public func startFirmwareUpdate(
        source: ChangeSource, reason: String, approver: (any ChangeApprover)? = nil
    ) async throws -> ChangeOutcome {
        let t = now()
        let state = try store.latestSnapshot()?.state
        let oldValue = state?.firmware.version ?? L10n.tr("unknown version")
        let newValue = L10n.tr("update started")
        func reject(_ message: String, nextAllowed: Date? = nil, blockedUntil: Date? = nil) throws -> ChangeOutcome {
            try firmwareReject(message, source: source, reason: reason, old: oldValue, new: newValue, nextAllowed: nextAllowed, blockedUntil: blockedUntil)
        }
        // Nothing is read, counted or asked for a start that would be refused anyway.
        if let problem = Self.firmwareUnitProblem(state) { return try reject(problem) }
        guard let deviceId = state?.deviceId else { return try reject(L10n.tr("No status from the heat pump yet.")) }
        if try store.credentialsRejected() { return try reject(HeatPumpError.credentialsRejected.errorDescription ?? "") }
        if let block = try store.blockStatus(now: t) {
            return try reject(block.reason.message(until: block.until), blockedUntil: block.until)
        }
        // A fresh list: the start must be based on what MELCloud offers right now.
        var status = try await firmwareStatus(force: true, liftRefusal: source == .app)
        guard let at = status.fetchedAt, now().timeIntervalSince(at) < Self.firmwareActionMaxAge else {
            return try reject(status.message ?? L10n.tr("Did not get a fresh firmware status from MELCloud. Try again in a little while."))
        }
        if let problem = Self.firmwareListProblem(status) { return try reject(problem) }
        guard var updateId = status.current?.id else { return try reject(L10n.tr("MELCloud gave no id for the update.")) }
        if let approver {
            let decision = await approver.requestApproval(
                ApprovalRequest(summaries: Self.firmwareApprovalSummaries(version: state?.firmware.version), reason: reason))
            guard decision == .approved else { return try reject(decision.rejectionText) }
            // The dialog may have been open for minutes and the update cannot be undone: check
            // everything again against the newest state before sending.
            let after = try store.latestSnapshot()?.state
            if let problem = Self.firmwareUnitProblem(after) { return try reject(problem) }
            if try store.credentialsRejected() { return try reject(HeatPumpError.credentialsRejected.errorDescription ?? "") }
            if let block = try store.blockStatus(now: now()) {
                return try reject(block.reason.message(until: block.until), blockedUntil: block.until)
            }
            status = try await firmwareStatus(force: true, liftRefusal: false)
            guard let again = status.fetchedAt, now().timeIntervalSince(again) < Self.firmwareActionMaxAge else {
                return try reject(status.message ?? L10n.tr("Did not get a fresh firmware status from MELCloud. Try again in a little while."))
            }
            if let problem = Self.firmwareListProblem(status) { return try reject(problem) }
            guard let id = status.current?.id else { return try reject(L10n.tr("MELCloud gave no id for the update.")) }
            updateId = id
        }
        return try await sendFirmwareAction(
            source: source, reason: reason, old: oldValue, new: newValue,
            send: { try await self.backend.approveFirmwareUpdate(id: updateId, deviceId: deviceId) },
            succeeded: { at in
                status.startedAt = at
                status.fetchedAt = nil  // read again on the next poll
                try? self.store.saveSetting(status, key: Self.firmwareStatusKey)
                return L10n.tr("The firmware update has started. Follow it under Health → Firmware. It can take a while, and the Wi-Fi adapter restarts along the way.")
            })
    }

    /// Cancels a running update while MELCloud still allows it (app only). Logged and budgeted like a start.
    public func cancelFirmwareUpdate(source: ChangeSource, reason: String) async throws -> ChangeOutcome {
        let t = now()
        let state = try store.latestSnapshot()?.state
        let oldValue = state?.firmware.version ?? L10n.tr("unknown version")
        let newValue = L10n.tr("update cancelled")
        func reject(_ message: String, nextAllowed: Date? = nil, blockedUntil: Date? = nil) throws -> ChangeOutcome {
            try firmwareReject(message, source: source, reason: reason, old: oldValue, new: newValue, nextAllowed: nextAllowed, blockedUntil: blockedUntil)
        }
        guard let deviceId = state?.deviceId else { return try reject(L10n.tr("No status from the heat pump yet.")) }
        if try store.credentialsRejected() { return try reject(HeatPumpError.credentialsRejected.errorDescription ?? "") }
        if let block = try store.blockStatus(now: t) {
            return try reject(block.reason.message(until: block.until), blockedUntil: block.until)
        }
        var status = try await firmwareStatus(force: true)
        guard let at = status.fetchedAt, now().timeIntervalSince(at) < Self.firmwareActionMaxAge else {
            return try reject(status.message ?? L10n.tr("Did not get a fresh firmware status from MELCloud. Try again in a little while."))
        }
        guard let current = status.current, current.phase.canCancel, let updateId = current.id else {
            return try reject(
                status.current.map { L10n.format("There is no update that can be cancelled now: %@", $0.displayText) }
                    ?? L10n.tr("There is no update that can be cancelled now."))
        }
        return try await sendFirmwareAction(
            source: source, reason: reason, old: oldValue, new: newValue,
            send: { try await self.backend.cancelFirmwareUpdate(id: updateId, deviceId: deviceId) },
            succeeded: { _ in
                status.startedAt = nil
                status.fetchedAt = nil
                try? self.store.saveSetting(status, key: Self.firmwareStatusKey)
                return L10n.tr("The cancellation has been sent to MELCloud. The status is updated in a little while.")
            })
    }

    private func firmwareReject(
        _ message: String, source: ChangeSource, reason: String, old: String, new: String, nextAllowed: Date?, blockedUntil: Date?
    ) throws -> ChangeOutcome {
        try store.logChange(
            ChangeRecord(
                timestamp: now(), source: source, field: Self.firmwareField, oldValue: old, newValue: new, reason: reason,
                result: .rejected, error: message))
        return ChangeOutcome(
            result: .rejected, message: L10n.format("Not sent: %@", message), field: Self.firmwareField, oldValue: old, newValue: new,
            nextAllowed: nextAllowed, blockedUntil: blockedUntil)
    }

    /// Reserves a slot (waiting briefly for the 5 s spacing), sends and logs the result.
    private func sendFirmwareAction(
        source: ChangeSource, reason: String, old: String, new: String,
        send: () async throws -> Void, succeeded: (Date) -> String
    ) async throws -> ChangeOutcome {
        var waited: TimeInterval = 0
        while true {
            let at = now()
            let record = ChangeRecord(
                timestamp: at, source: source, field: Self.firmwareField, oldValue: old, newValue: new, reason: reason, result: .pending)
            switch try store.reserveChange([record]) {
            case .tooSoon(let next):
                let wait = max(0, next.timeIntervalSince(at))
                if waited + wait > Self.maxWriteWait {
                    return try firmwareReject(
                        HeatPumpError.writeTooSoon(nextAllowed: next).errorDescription ?? "", source: source, reason: reason, old: old,
                        new: new, nextAllowed: next, blockedUntil: nil)
                }
                waited += wait
                await sleep(wait + 0.05)
            case .exceeded(let next):
                return try firmwareReject(
                    HeatPumpError.changeBudgetExceeded(nextAllowed: next).errorDescription ?? "", source: source, reason: reason,
                    old: old, new: new, nextAllowed: next, blockedUntil: nil)
            case .reserved(let ids):
                do {
                    try await send()
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    try store.finishChange(ids: ids, result: .failed, error: message)
                    let blocked = try handleAwayError(error, now: at)
                    return ChangeOutcome(
                        result: .failed, message: L10n.format("The change failed: %@", message), field: Self.firmwareField, oldValue: old,
                        newValue: new, blockedUntil: blocked)
                }
                try store.finishChange(ids: ids, result: .ok)
                return ChangeOutcome(result: .ok, message: succeeded(at), field: Self.firmwareField, oldValue: old, newValue: new)
            }
        }
    }
}
