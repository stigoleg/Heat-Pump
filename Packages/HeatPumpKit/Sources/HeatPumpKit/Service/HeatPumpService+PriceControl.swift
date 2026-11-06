import Foundation

/// The plan of price control for the next hours and where its base temperature comes from.
public struct PriceControlPlan: Codable, Sendable, Equatable {
    /// Every planned hour from the current one on, normal hours included.
    public var steps: [PlannedStep]
    public var baseSource: PriceControlBaseSource
    /// Why there is no plan, or nil.
    public var note: String?
    /// Expensive hours ahead left at the base because of the daily limit.
    public var overDailyLimit: Int = 0

    /// Steps that lower or raise the temperature.
    public var changes: [PlannedStep] { steps.filter { $0.kind != .normal } }
}

/// Settings, status and plan of price control for Claude (read-only).
public struct PriceControlOverview: Codable, Sendable, Equatable {
    public var settings: PriceControlSettings
    public var status: PriceControlStatus?
    /// True when price control is on and the app reported status within the last 3 minutes.
    public var appRunning: Bool
    public var plan: PriceControlPlan
}

/// What the runner remembers and last reported (`app_settings`, so a restart can reconcile).
struct PriceControlRuntime: Codable, Sendable, Equatable {
    var memory = PriceControlMemory()
    var status: PriceControlStatus?
}

/// Price control: lowers the setpoint in expensive hours (and pre-heats a little before them, when
/// chosen). It runs in the app only, on its poll tick; changes go through `apply` with source
/// `automation` (budget, validation and the change log as for every other change). Claude can read
/// it but not change it.
extension HeatPumpService {
    static let priceControlKey = "priceControl"
    static let priceControlRuntimeKey = "priceControlRuntime"
    /// Hours ahead the plan covers.
    public static let priceControlPlanHours = 36
    /// Hours before the current one the planner also sees, so a step keeps its start.
    static let priceControlLookbackHours = 12
    /// Status older than this means the app is not running.
    static let priceControlStaleAfter: TimeInterval = 180

    // MARK: Settings

    public func priceControlSettings() throws -> PriceControlSettings {
        try store.setting(PriceControlSettings.self, key: Self.priceControlKey) ?? .default
    }

    /// Saves reductions, minimum and pre-heating (the app's settings; `enabled` and the comfort
    /// temperature are kept as stored, use `enablePriceControl` / `disablePriceControl`).
    public func savePriceControlSettings(_ settings: PriceControlSettings) throws {
        if let problem = settings.validationProblem() { throw HeatPumpError.validation(problem) }
        var stored = try priceControlSettings()
        stored.reduceExpensive = settings.reduceExpensive
        stored.reduceVeryExpensive = settings.reduceVeryExpensive
        stored.minimumTemperature = settings.minimumTemperature
        stored.preheat = settings.preheat
        stored.maxReducedHoursPerDay = settings.maxReducedHoursPerDay
        try store.saveSetting(stored, key: Self.priceControlKey)
    }

    func priceControlRuntime() throws -> PriceControlRuntime {
        try store.setting(PriceControlRuntime.self, key: Self.priceControlRuntimeKey) ?? PriceControlRuntime()
    }

    func savePriceControlRuntime(_ runtime: PriceControlRuntime) throws {
        try store.saveSetting(runtime, key: Self.priceControlRuntimeKey)
    }

    /// Last status the app reported.
    public func priceControlStatus() throws -> PriceControlStatus? {
        try priceControlRuntime().status
    }

    // MARK: Plan

    /// Base temperature per hour: the weekly plan's setpoint (heat and on; nil otherwise) when the
    /// plan is on and readable, else the comfort temperature.
    func priceControlBase(_ settings: PriceControlSettings) throws -> (source: PriceControlBaseSource, base: @Sendable (Date) -> Double?) {
        let zone = timeZone
        if let timer = try storedWeeklyTimer(), timer.enabled == true, timer.decoded, !timer.events.isEmpty {
            return (.schedule, { date in
                guard let event = timer.event(inForceAt: date, timeZone: zone)?.event, event.power != false,
                    event.mode == nil || event.mode == .heat
                else { return nil }
                return event.setTemperature
            })
        }
        guard let comfort = settings.comfortTemperature else { return (.unknown, { _ in nil }) }
        return (.comfort, { _ in comfort })
    }

    /// The plan from the current hour for `priceControlPlanHours` hours, from published prices only.
    /// The planner also sees the hours since the start of the day (at least the last
    /// `priceControlLookbackHours`), so steps keep their start and the daily limit counts the whole day.
    public func priceControlPlan(settings: PriceControlSettings? = nil) throws -> PriceControlPlan {
        let settings = try settings ?? priceControlSettings()
        let t = now()
        let calendar = WireDate.calendar(timeZone)
        let hourStart = calendar.dateInterval(of: .hour, for: t)?.start ?? t
        let from = min(calendar.startOfDay(for: t), hourStart.addingTimeInterval(-Double(Self.priceControlLookbackHours) * 3600))
        let (source, base) = try priceControlBase(settings)
        if try priceSettings().agreement == .norgespris {
            return PriceControlPlan(
                steps: [], baseSource: source,
                note: L10n.tr("With Norgespris the price is the same all day, so price control has nothing to steer by."))
        }
        let hours = try priceBreakdowns(from: from, to: hourStart.addingTimeInterval(Double(Self.priceControlPlanHours) * 3600))
            .map { PriceControlHour(start: $0.hour, totalOre: $0.totalOre, level: $0.level) }
        let steps = PriceControlPlanner.plan(hours: hours, base: base, settings: settings, now: t, timeZone: timeZone)
        let over = PriceControlPlanner.hoursOverDailyLimit(hours: hours, base: base, settings: settings, now: t, timeZone: timeZone)
        var note: String?
        if !hours.contains(where: { $0.start >= hourStart }) {
            note = L10n.tr("No known electricity prices for the next hours yet.")
        } else if source == .unknown {
            note = L10n.tr("No base temperature yet: turn on price control while the heat pump is in heat mode, or use the weekly schedule.")
        }
        return PriceControlPlan(steps: steps, baseSource: source, note: note, overDailyLimit: over)
    }

    // MARK: Running (app only)

    /// One tick of the controller: decides from the latest snapshot and sends at most one setpoint.
    /// Saves memory and status for the next tick, a restart and Claude.
    @discardableResult
    public func runPriceControl() async throws -> PriceControlStatus {
        var settings = try priceControlSettings()
        var runtime = try priceControlRuntime()
        let t = now()
        guard settings.enabled else {
            let status = PriceControlStatus(kind: .off, text: L10n.tr("Price control is off."), updatedAt: t)
            runtime.status = status
            try savePriceControlRuntime(runtime)
            return status
        }
        var plan = try priceControlPlan(settings: settings)
        let context = try priceControlContext(settings: settings, steps: plan.steps, now: t)
        var memory = runtime.memory
        let decision = PriceControlEngine.evaluate(context, memory: &memory)
        if let comfort = decision.comfortTemperature, comfort != settings.comfortTemperature {
            settings.comfortTemperature = comfort
            try store.saveSetting(settings, key: Self.priceControlKey)
            plan = try priceControlPlan(settings: settings)
        }
        var status = PriceControlStatus(
            kind: decision.kind, text: decision.text, updatedAt: t, currentStep: decision.step,
            nextStep: plan.changes.first { $0.start > t }, baseSource: plan.baseSource, problem: decision.problem)
        if let target = decision.target, let step = decision.step {
            memory.writes.append(t)
            let outcome = try await apply(.temperature(target), source: .automation, reason: decision.reason ?? L10n.tr("Price control"))
            if outcome.result == .ok {
                // `target` is already snapped to the unit's step, so it is what went out.
                memory.appliedStep = step
                memory.lastSent = step.kind == .normal ? nil : target
                memory.lastSentAt = t
                memory.expect(target, at: t)
                memory.clearFailure()
            } else {
                // Not marked as dealt with: retried once later in the step (within the limits).
                if !PriceControlEngine.isSameStep(memory.failedStep, step) { memory.clearFailure() }
                memory.failedStep = step
                memory.failures += 1
                memory.problem = outcome.message
                status.kind = .skipped
                status.text = memory.failures < PriceControlEngine.maxAttemptsPerStep
                    ? L10n.tr("Could not change the temperature. Trying again later in this period.")
                    : L10n.format("Could not change the temperature. Trying again at the next change at %@.", Display.time(step.end))
                status.problem = outcome.message
            }
        }
        runtime.memory = memory
        runtime.status = status
        try savePriceControlRuntime(runtime)
        return status
    }

    func priceControlContext(settings: PriceControlSettings, steps: [PlannedStep], now t: Date) throws -> PriceControlContext {
        var blocked: String?
        if try credentialsRejected() {
            blocked = HeatPumpError.credentialsRejected.errorDescription
        } else if let block = try blockStatus(now: t) {
            blocked = block.reason.message(until: block.until, serviceName: serviceName)
        }
        let away = try storedAwaySettings()
        let holiday = away?.holiday
        let holidayActive =
            holiday?.enabled == true && (holiday?.start.map { $0 <= t } ?? true) && (holiday?.end.map { $0 > t } ?? true)
        let timer = try storedWeeklyTimer()
        let inForce = timer?.event(inForceAt: t, timeZone: timeZone)
        var near: Date?
        if let next = timer?.nextEvent(after: t.addingTimeInterval(-PriceControlEngine.timerMargin), timeZone: timeZone),
            next.date <= t.addingTimeInterval(PriceControlEngine.timerMargin)
        {
            near = next.date
        }
        return PriceControlContext(
            settings: settings, state: try latestSnapshot()?.state, steps: steps, blockedReason: blocked,
            holidayActive: holidayActive, frostProtection: away?.frost?.enabled == true, timerEventNear: near,
            timerFiredAt: inForce?.date, timerSetpoint: inForce?.event.setTemperature, now: t)
    }

    /// Turns price control on: the current setpoint becomes the comfort temperature (when the unit
    /// is on in heat mode and the setpoint is not one the controller left behind), then the first
    /// tick runs. A setpoint left behind (a restore that did not go through) stays the controller's,
    /// so it is set back later and never taken for the user's own; the write history is kept.
    @discardableResult
    public func enablePriceControl() async throws -> PriceControlStatus {
        var settings = try priceControlSettings()
        var memory = try priceControlRuntime().memory
        let state = try latestSnapshot()?.state
        let leftBehind = memory.lastSent.flatMap { sent in
            state?.setTemperature.map { abs($0 - sent) < (state?.setpointIncrement ?? 0.5) - 0.001 } == true ? sent : nil
        }
        if let state, state.power, state.mode == .heat, let setpoint = state.setTemperature, leftBehind == nil {
            settings.comfortTemperature = setpoint
        }
        settings.enabled = true
        try store.saveSetting(settings, key: Self.priceControlKey)
        memory.lastSent = leftBehind
        memory.expected = leftBehind
        memory.expectedAt = leftBehind == nil ? nil : memory.lastSentAt
        memory.appliedStep = nil
        memory.pausedUntil = nil
        memory.clearFailure()
        try savePriceControlRuntime(PriceControlRuntime(memory: memory))
        return try await runPriceControl()
    }

    /// Turns price control off and sets the base temperature back first (when the controller's
    /// last send lowered or raised it). Returns the restore's outcome, or nil when none was needed.
    @discardableResult
    public func disablePriceControl() async throws -> ChangeOutcome? {
        let outcome = try await restorePriceControl(reason: L10n.tr("turned off – back to normal temperature"), always: true)
        var settings = try priceControlSettings()
        settings.enabled = false
        try store.saveSetting(settings, key: Self.priceControlKey)
        var runtime = try priceControlRuntime()
        runtime.status = PriceControlStatus(kind: .off, text: L10n.tr("Price control is off."), updatedAt: now(), problem: outcome?.result == .ok ? nil : outcome?.message)
        try savePriceControlRuntime(runtime)
        return outcome
    }

    /// Sets the base temperature back (before sleep, on quit, when turned off; `reason` follows
    /// "Price control: " in the change log). Counts as one of the controller's writes; unless
    /// `always` (off, quit), it is not sent when the hourly cap is used up. After it the step is
    /// applied again, but not within the same clock hour. When the restore does not go through,
    /// the memory is kept: the lowered setpoint must not be taken for the user's own. Nil when
    /// nothing was sent.
    @discardableResult
    public func restorePriceControl(reason: String, always: Bool = false) async throws -> ChangeOutcome? {
        let settings = try priceControlSettings()
        var runtime = try priceControlRuntime()
        let t = now()
        let (_, base) = try priceControlBase(settings)
        let stepBase = runtime.status?.currentStep.flatMap { $0.contains(t) ? $0.base : nil }
        let state = try latestSnapshot()?.state
        var memory = runtime.memory
        memory.pruneWrites(now: t)
        guard
            let target = PriceControlEngine.restoreTarget(
                memory: memory, state: state, base: base(t) ?? stepBase ?? settings.comfortTemperature),
            always || memory.writes.count < PriceControlEngine.maxWritesPerHour
        else { return nil }
        memory.writes.append(t)
        let outcome = try await apply(.temperature(target), source: .automation, reason: L10n.format("Price control: %@", reason))
        if outcome.result == .ok {
            memory.lastSent = nil
            memory.lastSentAt = t
            memory.expect(target, at: t)
            memory.appliedStep = nil
            memory.pausedUntil = nil
            memory.clearFailure()
        }
        runtime.memory = memory
        try savePriceControlRuntime(runtime)
        return outcome
    }

    /// The user changed the setpoint in the app: it becomes the comfort temperature, and the
    /// controller pauses until the step in force is over.
    public func notePriceControlManualSetpoint(_ value: Double) throws {
        var settings = try priceControlSettings()
        guard settings.enabled else { return }
        let t = now()
        let step = try priceControlPlan(settings: settings).steps.first { $0.contains(t) }
        settings.comfortTemperature = value
        try store.saveSetting(settings, key: Self.priceControlKey)
        var runtime = try priceControlRuntime()
        runtime.memory.lastSent = nil
        runtime.memory.expect(value, at: t)
        runtime.memory.appliedStep = step
        runtime.memory.pausedUntil = step?.end ?? t.addingTimeInterval(3600)
        runtime.memory.clearFailure()
        try savePriceControlRuntime(runtime)
    }

    /// Settings, last status and plan, for Claude.
    public func priceControlOverview() throws -> PriceControlOverview {
        let settings = try priceControlSettings()
        let status = try priceControlStatus()
        let running = settings.enabled && (status.map { now().timeIntervalSince($0.updatedAt) < Self.priceControlStaleAfter } ?? false)
        return PriceControlOverview(settings: settings, status: status, appRunning: running, plan: try priceControlPlan(settings: settings))
    }
}
