import Foundation

/// Settings for the app's price control (Prognose → Prisstyring), stored in `app_settings`.
/// Only the app changes them; Claude can read them.
public struct PriceControlSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// °C lower in expensive hours.
    public var reduceExpensive: Double
    /// °C lower in very expensive hours.
    public var reduceVeryExpensive: Double
    /// Never set lower than this.
    public var minimumTemperature: Double
    /// +1 °C in up to two of the cheapest hours within the four hours before an expensive block.
    public var preheat: Bool
    /// The setpoint the user last chose; the base temperature when the weekly plan is off.
    public var comfortTemperature: Double?
    /// Per local day only this many of the most expensive hours are lowered (pre-heating is not counted).
    public var maxReducedHoursPerDay: Int

    public init(
        enabled: Bool = false, reduceExpensive: Double = 1.0, reduceVeryExpensive: Double = 2.0, minimumTemperature: Double = 18.0,
        preheat: Bool = false, comfortTemperature: Double? = nil, maxReducedHoursPerDay: Int = 8
    ) {
        self.enabled = enabled
        self.reduceExpensive = reduceExpensive
        self.reduceVeryExpensive = reduceVeryExpensive
        self.minimumTemperature = minimumTemperature
        self.preheat = preheat
        self.comfortTemperature = comfortTemperature
        self.maxReducedHoursPerDay = maxReducedHoursPerDay
    }

    public static let `default` = PriceControlSettings()
    public static let reductionRange: ClosedRange<Double> = 0...4
    public static let minimumRange: ClosedRange<Double> = 16...22
    public static let reducedHoursRange: ClosedRange<Int> = 1...24

    /// Missing keys (settings saved by an older version) take the defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        reduceExpensive = try c.decodeIfPresent(Double.self, forKey: .reduceExpensive) ?? d.reduceExpensive
        reduceVeryExpensive = try c.decodeIfPresent(Double.self, forKey: .reduceVeryExpensive) ?? d.reduceVeryExpensive
        minimumTemperature = try c.decodeIfPresent(Double.self, forKey: .minimumTemperature) ?? d.minimumTemperature
        preheat = try c.decodeIfPresent(Bool.self, forKey: .preheat) ?? d.preheat
        comfortTemperature = try c.decodeIfPresent(Double.self, forKey: .comfortTemperature)
        maxReducedHoursPerDay = try c.decodeIfPresent(Int.self, forKey: .maxReducedHoursPerDay) ?? d.maxReducedHoursPerDay
    }

    /// Norwegian reason the values are refused, or nil.
    public func validationProblem() -> String? {
        let values = [reduceExpensive, reduceVeryExpensive, minimumTemperature]
        guard values.allSatisfy({ $0.isFinite && ($0 * 2).rounded() == $0 * 2 }) else { return "Bruk hele eller halve grader." }
        guard Self.reductionRange.contains(reduceExpensive), Self.reductionRange.contains(reduceVeryExpensive) else {
            return "Senkingen må være 0–4 °C."
        }
        guard Self.minimumRange.contains(minimumTemperature) else { return "Laveste temperatur må være 16–22 °C." }
        guard Self.reducedHoursRange.contains(maxReducedHoursPerDay) else { return "Antall timer som senkes per døgn må være 1–24." }
        return nil
    }

    /// °C to lower in an hour at `level`.
    public func reduction(for level: PriceLevel?) -> Double {
        switch level {
        case .expensive: reduceExpensive
        case .veryExpensive: reduceVeryExpensive
        default: 0
        }
    }
}

/// Where the base temperature (the one price control lowers from) comes from.
public enum PriceControlBaseSource: String, Codable, Sendable {
    /// The setpoint of the weekly plan's event in force.
    case schedule
    /// The setpoint the user last chose.
    case comfort
    /// Neither is known.
    case unknown
}

/// One published hour as the planner sees it.
public struct PriceControlHour: Sendable, Equatable {
    public var start: Date
    /// øre/kWh, same basis as `PriceBreakdown.totalOre`.
    public var totalOre: Double
    public var level: PriceLevel?

    public init(start: Date, totalOre: Double, level: PriceLevel?) {
        self.start = start
        self.totalOre = totalOre
        self.level = level
    }
}

/// A stretch of whole hours with one setpoint.
public struct PlannedStep: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case normal, reduce, preheat
    }

    public var start: Date
    public var end: Date
    public var target: Double
    public var base: Double
    public var kind: Kind
    /// The highest level in the step (reduce) or the lowest (preheat, normal).
    public var level: PriceLevel?
    /// Highest price in the step (reduce), else the lowest, øre/kWh.
    public var priceOre: Double
    /// "Svært dyrt (2,45 kr/kWh)".
    public var reason: String

    public func contains(_ date: Date) -> Bool { start <= date && date < end }

    /// "17–19: senkes til 19 °C – Svært dyrt (2,45 kr/kWh)"; a weekday is added when the step
    /// does not start on the same day as `now`.
    public func summary(now: Date, timeZone: TimeZone) -> String {
        let calendar = WireDate.calendar(timeZone)
        var span = String(format: "%02d–%02d", calendar.component(.hour, from: start), calendar.component(.hour, from: end))
        if !calendar.isDate(start, inSameDayAs: now) {
            let weekday = calendar.component(.weekday, from: start)  // 1 = Sunday
            span = TimerEvent.shortWeekdayNames[(weekday + 5) % 7] + " " + span
        }
        let temperature = TimerEvent.temperatureText(target)
        switch kind {
        case .reduce: return "\(span): senkes til \(temperature) – \(reason)"
        case .preheat: return "\(span): forvarmes til \(temperature) – \(reason)"
        case .normal: return "\(span): vanlig temperatur \(temperature)"
        }
    }
}

/// Builds the plan from published prices. Pure: it only lowers or raises the setpoint relative to
/// the base, never below the minimum, and never touches power or mode.
public enum PriceControlPlanner {
    public static let preheatWindowHours = 4
    public static let preheatHours = 2
    public static let preheatRaise = 1.0

    /// Steps for the hours in `hours` that have a base temperature (`base` nil: the plan does not
    /// apply, for example when the weekly plan has the unit off), without the steps that ended by
    /// `now`. Pass hours from before `now` too: a step keeps the start it was planned with, which is
    /// how the engine knows it is the same step. The hour under way takes the base in force at
    /// `now` (a weekly-plan event can fire mid-hour). Per day in `timeZone` only the
    /// `maxReducedHoursPerDay` most expensive qualifying hours are lowered.
    public static func plan(
        hours: [PriceControlHour], base: (Date) -> Double?, settings: PriceControlSettings, now: Date, timeZone: TimeZone = .current
    ) -> [PlannedStep] {
        let selection = select(hours: hours, base: base, settings: settings, now: now, timeZone: timeZone)
        var steps: [PlannedStep] = []
        for (hour, b) in selection.hours {
            guard let b else { continue }
            var kind = PlannedStep.Kind.normal
            var target = b
            if selection.lowered.contains(hour.start) {
                target = max(b - settings.reduction(for: hour.level), settings.minimumTemperature)
                kind = .reduce
            } else if selection.preheat.contains(hour.start) {
                target = b + preheatRaise
                kind = .preheat
            }
            let end = hour.start.addingTimeInterval(3600)
            if var last = steps.last, last.end == hour.start, last.kind == kind, last.target == target, last.base == b {
                if kind == .reduce, hour.totalOre > last.priceOre {
                    last.priceOre = hour.totalOre
                    if let level = hour.level, (last.level.map { rank(level) > rank($0) } ?? true) { last.level = level }
                } else if kind != .reduce, hour.totalOre < last.priceOre {
                    last.priceOre = hour.totalOre
                }
                last.end = end
                last.reason = reason(kind: kind, level: last.level, priceOre: last.priceOre)
                steps[steps.count - 1] = last
            } else {
                steps.append(
                    PlannedStep(
                        start: hour.start, end: end, target: target, base: b, kind: kind, level: hour.level, priceOre: hour.totalOre,
                        reason: reason(kind: kind, level: hour.level, priceOre: hour.totalOre)))
            }
        }
        return steps.filter { $0.end > now }
    }

    /// Expensive hours from `now` on that are not lowered because of the daily limit.
    public static func hoursOverDailyLimit(
        hours: [PriceControlHour], base: (Date) -> Double?, settings: PriceControlSettings, now: Date, timeZone: TimeZone = .current
    ) -> Int {
        let selection = select(hours: hours, base: base, settings: settings, now: now, timeZone: timeZone)
        return selection.qualifying.subtracting(selection.lowered).filter { $0.addingTimeInterval(3600) > now }.count
    }

    /// Hours in order with their base, the hours that would be lowered (`qualifying`), those that
    /// are within the daily limit (`lowered`), and those to pre-heat.
    static func select(
        hours: [PriceControlHour], base: (Date) -> Double?, settings: PriceControlSettings, now: Date, timeZone: TimeZone
    ) -> (hours: [(PriceControlHour, Double?)], qualifying: Set<Date>, lowered: Set<Date>, preheat: Set<Date>) {
        let sorted = hours.sorted { $0.start < $1.start }
        let withBase = sorted.map { hour -> (PriceControlHour, Double?) in
            let underWay = hour.start <= now && now < hour.start.addingTimeInterval(3600)
            return (hour, base(underWay ? now : hour.start))
        }
        let expensive: Set<PriceLevel> = [.expensive, .veryExpensive]

        // Lowered: per local day, the most expensive hours that would be lowered, up to the limit.
        let qualifying = withBase.filter { hour, b in
            guard let b else { return false }
            return settings.reduction(for: hour.level) > 0 && b > settings.minimumTemperature
        }.map(\.0)
        let calendar = WireDate.calendar(timeZone)
        var lowered = Set<Date>()
        for (_, day) in Dictionary(grouping: qualifying, by: { calendar.startOfDay(for: $0.start) }) {
            let chosen = day.sorted { $0.totalOre != $1.totalOre ? $0.totalOre > $1.totalOre : $0.start < $1.start }
                .prefix(max(settings.maxReducedHoursPerDay, 0))
            lowered.formUnion(chosen.map(\.start))
        }

        // Pre-heat: the cheapest two non-expensive hours in the four before each expensive block.
        var preheat = Set<Date>()
        if settings.preheat {
            let byStart = Dictionary(sorted.map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
            for hour in sorted where hour.level.map(expensive.contains) == true {
                let previous = byStart[hour.start.addingTimeInterval(-3600)]
                guard previous?.level.map(expensive.contains) != true else { continue }  // not a block start
                let window = (1...preheatWindowHours).compactMap { byStart[hour.start.addingTimeInterval(-Double($0) * 3600)] }
                    .filter { $0.level.map(expensive.contains) != true }
                for candidate in window.sorted(by: { $0.totalOre < $1.totalOre }).prefix(preheatHours) {
                    preheat.insert(candidate.start)
                }
            }
        }
        return (withBase, Set(qualifying.map(\.start)), lowered, preheat)
    }

    static func rank(_ level: PriceLevel) -> Int { PriceLevel.allCases.firstIndex(of: level) ?? 0 }

    static func reason(kind: PlannedStep.Kind, level: PriceLevel?, priceOre: Double) -> String {
        let price = Display.format("%.2f kr/kWh", priceOre / 100)
        switch kind {
        case .reduce: return "\(level?.adjective ?? "Dyrt") (\(price))"
        case .preheat: return "Forvarming før dyre timer (\(price))"
        case .normal: return "Vanlig temperatur"
        }
    }
}

/// What the controller remembers between ticks; stored so a restart can reconcile.
public struct PriceControlMemory: Codable, Sendable, Equatable {
    /// Setpoint the controller sent below or above the base and still owns (to be set back), or nil.
    public var lastSent: Double?
    /// When the controller last got a setpoint through (sends and restores).
    public var lastSentAt: Date?
    /// The step the controller has dealt with (sent, found in place, or paused for).
    public var appliedStep: PlannedStep?
    /// The user changed the setpoint: no action until this step boundary.
    public var pausedUntil: Date?
    /// The setpoint the controller expects the unit to have (sent, set back or found in place);
    /// another one means someone else changed it.
    public var expected: Double?
    /// When `expected` was last set.
    public var expectedAt: Date?
    /// Every write the controller attempted (sends and restores, also failed ones) in the last hour.
    public var writes: [Date]
    /// The step whose send did not go through, how many attempts failed, and why.
    public var failedStep: PlannedStep?
    public var failures: Int
    public var problem: String?

    public init(
        lastSent: Double? = nil, lastSentAt: Date? = nil, appliedStep: PlannedStep? = nil, pausedUntil: Date? = nil,
        expected: Double? = nil, expectedAt: Date? = nil, writes: [Date] = []
    ) {
        self.lastSent = lastSent
        self.lastSentAt = lastSentAt
        self.appliedStep = appliedStep
        self.pausedUntil = pausedUntil
        self.expected = expected
        self.expectedAt = expectedAt
        self.writes = writes
        self.failures = 0
    }

    /// Memory saved by an older version decodes with the new fields empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSent = try c.decodeIfPresent(Double.self, forKey: .lastSent)
        lastSentAt = try c.decodeIfPresent(Date.self, forKey: .lastSentAt)
        appliedStep = try c.decodeIfPresent(PlannedStep.self, forKey: .appliedStep)
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        expected = try c.decodeIfPresent(Double.self, forKey: .expected)
        expectedAt = try c.decodeIfPresent(Date.self, forKey: .expectedAt)
        writes = try c.decodeIfPresent([Date].self, forKey: .writes) ?? []
        failedStep = try c.decodeIfPresent(PlannedStep.self, forKey: .failedStep)
        failures = try c.decodeIfPresent(Int.self, forKey: .failures) ?? 0
        problem = try c.decodeIfPresent(String.self, forKey: .problem)
    }

    /// The setpoint the controller now expects (after a send, a restore or finding it in place).
    mutating func expect(_ setpoint: Double, at t: Date) {
        expected = setpoint
        expectedAt = t
    }

    mutating func clearFailure() {
        failedStep = nil
        failures = 0
        problem = nil
    }

    /// Forgets writes older than an hour.
    mutating func pruneWrites(now t: Date) {
        writes.removeAll { t.timeIntervalSince($0) >= 3600 }
    }
}

/// What price control is doing now (shown in the app and the menu bar, read by Claude).
public struct PriceControlStatus: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case off, normal, lowered, raised, paused, waiting, skipped
    }

    public var kind: Kind
    public var text: String
    public var updatedAt: Date
    public var currentStep: PlannedStep?
    /// The next step that lowers or raises the temperature.
    public var nextStep: PlannedStep?
    public var baseSource: PriceControlBaseSource
    /// Last send that did not go through, or nil.
    public var problem: String?

    public init(
        kind: Kind, text: String, updatedAt: Date, currentStep: PlannedStep? = nil, nextStep: PlannedStep? = nil,
        baseSource: PriceControlBaseSource = .unknown, problem: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.updatedAt = updatedAt
        self.currentStep = currentStep
        self.nextStep = nextStep
        self.baseSource = baseSource
        self.problem = problem
    }
}

/// Everything the controller needs for one decision.
public struct PriceControlContext: Sendable {
    public var settings: PriceControlSettings
    /// Latest snapshot from the unit.
    public var state: DeviceState?
    public var steps: [PlannedStep]
    /// Credentials rejected or MELCloud block (Norwegian), or nil.
    public var blockedReason: String?
    public var holidayActive: Bool
    public var frostProtection: Bool
    /// A weekly-plan event within ±10 minutes of now, or nil.
    public var timerEventNear: Date?
    /// When the weekly-plan event in force fired, or nil.
    public var timerFiredAt: Date?
    /// The setpoint of that event (nil: it sets none).
    public var timerSetpoint: Double?
    public var now: Date

    public init(
        settings: PriceControlSettings, state: DeviceState?, steps: [PlannedStep], blockedReason: String? = nil,
        holidayActive: Bool = false, frostProtection: Bool = false, timerEventNear: Date? = nil, timerFiredAt: Date? = nil,
        timerSetpoint: Double? = nil, now: Date
    ) {
        self.settings = settings
        self.state = state
        self.steps = steps
        self.blockedReason = blockedReason
        self.holidayActive = holidayActive
        self.frostProtection = frostProtection
        self.timerEventNear = timerEventNear
        self.timerFiredAt = timerFiredAt
        self.timerSetpoint = timerSetpoint
        self.now = now
    }
}

/// One decision: an optional setpoint to send, the status, and a new comfort temperature when the
/// user changed the setpoint.
public struct PriceControlDecision: Sendable, Equatable {
    public var target: Double?
    /// Change-log reason for `target`.
    public var reason: String?
    public var kind: PriceControlStatus.Kind
    public var text: String
    public var step: PlannedStep?
    public var comfortTemperature: Double?
    /// Why the last send for this step did not go through, or nil.
    public var problem: String?
}

/// The controller's rules. Pure: the app's runner feeds it the latest state each poll tick and
/// sends what it returns.
public enum PriceControlEngine {
    /// No action this close to a weekly-plan event.
    public static let timerMargin: TimeInterval = 600
    /// A snapshot this long after a send is trusted to show the unit's setpoint.
    public static let confirmGrace: TimeInterval = 120
    /// Most writes (sends and restores) the controller makes in a rolling hour; a restore when
    /// control is turned off or the app quits is always allowed.
    public static let maxWritesPerHour = 4
    /// Attempts per step when a send does not go through (the first and one retry).
    public static let maxAttemptsPerStep = 2

    /// The same real step: same setpoint, base and kind, overlapping or adjacent in time (a step
    /// grows when new prices are published and loses its start when it falls out of the window).
    public static func isSameStep(_ a: PlannedStep?, _ b: PlannedStep?) -> Bool {
        guard let a, let b else { return false }
        return a.kind == b.kind && a.target == b.target && a.base == b.base && a.start <= b.end && b.start <= a.end
    }

    public static func evaluate(_ c: PriceControlContext, memory: inout PriceControlMemory) -> PriceControlDecision {
        let step = c.steps.first { $0.contains(c.now) }
        var decision = PriceControlDecision(kind: .skipped, text: "", step: step)
        guard c.settings.enabled else {
            decision.kind = .off
            decision.text = "Prisstyring er av."
            return decision
        }
        guard let state = c.state else {
            decision.text = "Ingen status fra varmepumpen ennå."
            return decision
        }
        memory.pruneWrites(now: c.now)
        // Setpoints closer than the unit's step are the same setpoint.
        let increment = state.setpointIncrement
        func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < increment - 0.001 }

        // A setpoint the controller did not leave: the user (or Claude) changed it, or the weekly plan did.
        let confirmed = !state.hasPendingCommand && memory.lastSentAt.map { state.fetchedAt >= $0.addingTimeInterval(confirmGrace) } ?? true
        if confirmed, state.power, state.mode == .heat, let setpoint = state.setTemperature {
            if let expected = memory.expected ?? memory.lastSent, !same(setpoint, expected) {
                let byPlan = c.timerFiredAt.map { $0 > (memory.expectedAt ?? memory.lastSentAt ?? .distantPast) } == true
                    && c.timerSetpoint.map { same($0, setpoint) } == true
                memory.lastSent = nil
                memory.expect(setpoint, at: c.now)
                memory.clearFailure()
                if byPlan {
                    memory.appliedStep = nil  // the plan set a new base; the step is planned from it
                    memory.pausedUntil = nil
                } else {
                    memory.appliedStep = step
                    memory.pausedUntil = step?.end ?? c.now.addingTimeInterval(3600)
                    decision.comfortTemperature = setpoint
                }
            } else if memory.expected == nil, memory.lastSent == nil, c.settings.comfortTemperature != setpoint {
                decision.comfortTemperature = setpoint
            }
        }

        if let reason = c.blockedReason {
            decision.text = reason
            return decision
        }
        if c.holidayActive {
            decision.text = "Feriemodus er på, så prisstyringen venter."
            return decision
        }
        guard state.power else {
            decision.text = c.frostProtection ? "Varmepumpen er av (frostsikringen passer på)." : "Varmepumpen er av."
            return decision
        }
        guard state.mode == .heat else {
            decision.text = "Prisstyringen virker bare i varmemodus."
            return decision
        }
        guard let step else {
            decision.text = "Ingen plan for denne timen (mangler pris eller grunntemperatur)."
            return decision
        }
        let target = target(for: step, state: state, settings: c.settings)
        if let paused = memory.pausedUntil {
            // Until the step the user changed the setpoint in is over (also when it grew).
            let sameStep = isSameStep(memory.appliedStep, step)
            if paused > c.now || sameStep {
                if sameStep {
                    memory.appliedStep = step
                    memory.pausedUntil = max(paused, step.end)
                }
                decision.kind = .paused
                decision.text = "Pause – du endret temperaturen. Fortsetter kl. \(Display.time(memory.pausedUntil ?? paused))."
                return decision
            }
            memory.pausedUntil = nil
        }
        if isSameStep(memory.appliedStep, step) {
            memory.appliedStep = step
            (decision.kind, decision.text) = status(of: step, target: target)
            return decision
        }
        let failedHere = isSameStep(memory.failedStep, step)
        if !failedHere { memory.clearFailure() }
        if failedHere, memory.failures >= maxAttemptsPerStep {
            decision.text = "Kunne ikke endre temperaturen. Prøver igjen ved neste skifte kl. \(Display.time(step.end))."
            decision.problem = memory.problem
            return decision
        }
        if let near = c.timerEventNear {
            decision.kind = .waiting
            decision.text = "Venter til ukeplanen har endret temperaturen kl. \(Display.time(near))."
            return decision
        }
        guard let setpoint = state.setTemperature else {
            decision.text = "Varmepumpen har ikke meldt ønsket temperatur."
            return decision
        }
        if same(setpoint, target) {
            memory.appliedStep = step
            memory.lastSent = step.kind == .normal ? nil : setpoint
            memory.expect(setpoint, at: c.now)
            memory.clearFailure()
            (decision.kind, decision.text) = status(of: step, target: target)
            return decision
        }
        // At most one write per clock hour (restores count), and a hard cap per rolling hour.
        let hour = { (date: Date) in Int(date.timeIntervalSince1970 / 3600) }
        if let last = memory.writes.max(), hour(last) == hour(c.now) {
            let next = Date(timeIntervalSince1970: Double(hour(c.now) + 1) * 3600)
            if failedHere {
                decision.text = "Kunne ikke endre temperaturen. Prøver igjen kl. \(Display.time(next))."
                decision.problem = memory.problem
            } else {
                decision.kind = .waiting
                decision.text = "Venter: høyst én endring i timen. Neste kl. \(Display.time(next))."
            }
            return decision
        }
        if memory.writes.count >= maxWritesPerHour {
            decision.kind = .waiting
            decision.text = "Venter: prisstyringen har gjort \(maxWritesPerHour) endringer den siste timen."
            decision.problem = failedHere ? memory.problem : nil
            return decision
        }
        decision.target = target
        decision.reason = "Prisstyring: " + (step.kind == .normal ? "tilbake til vanlig temperatur" : step.reason)
        (decision.kind, decision.text) = status(of: step, target: target)
        return decision
    }

    /// The setpoint the unit gets for `step`: snapped to the unit's step as `apply` sends it,
    /// within the heat limits, and a reduction never below the minimum.
    public static func target(for step: PlannedStep, state: DeviceState, settings: PriceControlSettings) -> Double {
        var target = state.snappedSetpoint(step.target)
        if step.kind == .reduce, target < settings.minimumTemperature {
            let increment = state.setpointIncrement
            target = (settings.minimumTemperature / increment).rounded(.up) * increment
        }
        let range = state.limits.range(for: .heat)
        return min(max(target, range.lowerBound), range.upperBound)
    }

    /// Status for a step that is in force.
    public static func status(of step: PlannedStep, target: Double? = nil) -> (PriceControlStatus.Kind, String) {
        let temperature = TimerEvent.temperatureText(target ?? step.target)
        switch step.kind {
        case .normal: return (.normal, "Vanlig temperatur (\(temperature)).")
        case .reduce: return (.lowered, "Senket til \(temperature) – \(step.reason).")
        case .preheat: return (.raised, "Forvarmer til \(temperature) før dyre timer.")
        }
    }

    /// The setpoint to send when control stops (off, sleep, quit): the base, snapped to the unit's
    /// step, when the controller's last send was a reduction or pre-heating and the unit has not
    /// confirmed a different setpoint since (MELCloud can still report the old one for a while
    /// after a send). Nil when there is nothing to restore.
    public static func restoreTarget(memory: PriceControlMemory, state: DeviceState?, base: Double?) -> Double? {
        guard let sent = memory.lastSent, let base, let state else { return nil }
        let increment = state.setpointIncrement
        let target = state.snappedSetpoint(base)
        guard abs(target - sent) >= increment - 0.001 else { return nil }
        let confirmed = !state.hasPendingCommand && memory.lastSentAt.map { state.fetchedAt >= $0.addingTimeInterval(confirmGrace) } ?? true
        if confirmed, let setpoint = state.setTemperature, abs(setpoint - sent) >= increment - 0.001 { return nil }
        return target
    }
}

extension PriceLevel {
    /// "Svært dyrt" (for "timen er …").
    public var adjective: String {
        switch self {
        case .veryCheap: "Svært billig"
        case .cheap: "Billig"
        case .normal: "Normalt"
        case .expensive: "Dyrt"
        case .veryExpensive: "Svært dyrt"
        }
    }
}
