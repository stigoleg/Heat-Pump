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

    public init(
        enabled: Bool = false, reduceExpensive: Double = 1.0, reduceVeryExpensive: Double = 2.0, minimumTemperature: Double = 18.0,
        preheat: Bool = false, comfortTemperature: Double? = nil
    ) {
        self.enabled = enabled
        self.reduceExpensive = reduceExpensive
        self.reduceVeryExpensive = reduceVeryExpensive
        self.minimumTemperature = minimumTemperature
        self.preheat = preheat
        self.comfortTemperature = comfortTemperature
    }

    public static let `default` = PriceControlSettings()
    public static let reductionRange: ClosedRange<Double> = 0...4
    public static let minimumRange: ClosedRange<Double> = 16...22

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
    }

    /// Norwegian reason the values are refused, or nil.
    public func validationProblem() -> String? {
        let values = [reduceExpensive, reduceVeryExpensive, minimumTemperature]
        guard values.allSatisfy({ $0.isFinite && ($0 * 2).rounded() == $0 * 2 }) else { return "Bruk hele eller halve grader." }
        guard Self.reductionRange.contains(reduceExpensive), Self.reductionRange.contains(reduceVeryExpensive) else {
            return "Senkingen må være 0–4 °C."
        }
        guard Self.minimumRange.contains(minimumTemperature) else { return "Laveste temperatur må være 16–22 °C." }
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

    /// Steps for every hour in `hours` that has not ended at `now` and has a base temperature
    /// (`base` nil: the plan does not apply, for example when the weekly plan has the unit off).
    public static func plan(
        hours: [PriceControlHour], base: (Date) -> Double?, settings: PriceControlSettings, now: Date
    ) -> [PlannedStep] {
        let upcoming = hours.filter { $0.start.addingTimeInterval(3600) > now }.sorted { $0.start < $1.start }
        let expensive: Set<PriceLevel> = [.expensive, .veryExpensive]

        // Hours to pre-heat: the cheapest two non-expensive hours in the four before each expensive block.
        var preheat = Set<Date>()
        if settings.preheat {
            let byStart = Dictionary(upcoming.map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
            for hour in upcoming where hour.level.map(expensive.contains) == true {
                let previous = byStart[hour.start.addingTimeInterval(-3600)]
                guard previous?.level.map(expensive.contains) != true else { continue }  // not a block start
                let window = (1...preheatWindowHours).compactMap { byStart[hour.start.addingTimeInterval(-Double($0) * 3600)] }
                    .filter { $0.level.map(expensive.contains) != true }
                for candidate in window.sorted(by: { $0.totalOre < $1.totalOre }).prefix(preheatHours) {
                    preheat.insert(candidate.start)
                }
            }
        }

        var steps: [PlannedStep] = []
        for hour in upcoming {
            guard let b = base(hour.start) else { continue }
            var kind = PlannedStep.Kind.normal
            var target = b
            let reduction = settings.reduction(for: hour.level)
            if reduction > 0, b > settings.minimumTemperature {
                target = max(b - reduction, settings.minimumTemperature)
                kind = .reduce
            } else if preheat.contains(hour.start) {
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
        return steps
    }

    static func rank(_ level: PriceLevel) -> Int { PriceLevel.allCases.firstIndex(of: level) ?? 0 }

    static func reason(kind: PlannedStep.Kind, level: PriceLevel?, priceOre: Double) -> String {
        let price = Norwegian.format("%.2f kr/kWh", priceOre / 100)
        switch kind {
        case .reduce: return "\(level?.adjective ?? "Dyrt") (\(price))"
        case .preheat: return "Forvarming før dyre timer (\(price))"
        case .normal: return "Vanlig temperatur"
        }
    }
}

/// What the controller remembers between ticks; stored so a restart can reconcile.
public struct PriceControlMemory: Codable, Sendable, Equatable {
    /// Setpoint the controller last sent (and still owns), or nil.
    public var lastSent: Double?
    public var lastSentAt: Date?
    /// Start of the step the controller has dealt with.
    public var appliedStepStart: Date?
    /// The user changed the setpoint: no action until this step boundary.
    public var pausedUntil: Date?

    public init(lastSent: Double? = nil, lastSentAt: Date? = nil, appliedStepStart: Date? = nil, pausedUntil: Date? = nil) {
        self.lastSent = lastSent
        self.lastSentAt = lastSentAt
        self.appliedStepStart = appliedStepStart
        self.pausedUntil = pausedUntil
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
    public var now: Date

    public init(
        settings: PriceControlSettings, state: DeviceState?, steps: [PlannedStep], blockedReason: String? = nil,
        holidayActive: Bool = false, frostProtection: Bool = false, timerEventNear: Date? = nil, timerFiredAt: Date? = nil, now: Date
    ) {
        self.settings = settings
        self.state = state
        self.steps = steps
        self.blockedReason = blockedReason
        self.holidayActive = holidayActive
        self.frostProtection = frostProtection
        self.timerEventNear = timerEventNear
        self.timerFiredAt = timerFiredAt
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
}

/// The controller's rules. Pure: the app's runner feeds it the latest state each poll tick and
/// sends what it returns.
public enum PriceControlEngine {
    /// No action this close to a weekly-plan event.
    public static let timerMargin: TimeInterval = 600
    /// A snapshot this long after a send is trusted to show the unit's setpoint.
    public static let confirmGrace: TimeInterval = 120
    static let tolerance = 0.25

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

        // A setpoint the controller did not send: the user (or Claude) changed it, or the weekly plan did.
        let confirmed = !state.hasPendingCommand && memory.lastSentAt.map { state.fetchedAt >= $0.addingTimeInterval(confirmGrace) } ?? true
        if confirmed, state.power, state.mode == .heat, let setpoint = state.setTemperature {
            if let sent = memory.lastSent, abs(setpoint - sent) >= tolerance {
                memory.lastSent = nil
                if let fired = c.timerFiredAt, let at = memory.lastSentAt, fired > at {
                    memory.appliedStepStart = nil  // the plan set a new base; apply the step again
                } else {
                    memory.appliedStepStart = step?.start
                    memory.pausedUntil = step?.end ?? c.now.addingTimeInterval(3600)
                    decision.comfortTemperature = setpoint
                }
            } else if memory.lastSent == nil, c.settings.comfortTemperature != setpoint {
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
        if let paused = memory.pausedUntil, paused > c.now {
            decision.kind = .paused
            decision.text = "Pause – du endret temperaturen. Fortsetter kl. \(Norwegian.time(paused))."
            return decision
        }
        memory.pausedUntil = nil
        if memory.appliedStepStart == step.start {
            (decision.kind, decision.text) = status(of: step)
            return decision
        }
        if let near = c.timerEventNear {
            decision.kind = .waiting
            decision.text = "Venter til ukeplanen har endret temperaturen kl. \(Norwegian.time(near))."
            return decision
        }
        guard let setpoint = state.setTemperature else {
            decision.text = "Varmepumpen har ikke meldt ønsket temperatur."
            return decision
        }
        let range = state.limits.range(for: .heat)
        let target = min(max((step.target * 2).rounded() / 2, range.lowerBound), range.upperBound)
        if abs(setpoint - target) < tolerance {
            memory.appliedStepStart = step.start
            memory.lastSent = step.kind == .normal ? nil : target
            (decision.kind, decision.text) = status(of: step)
            return decision
        }
        if let at = memory.lastSentAt, Int(at.timeIntervalSince1970 / 3600) == Int(c.now.timeIntervalSince1970 / 3600) {
            decision.kind = .waiting
            decision.text = "Venter: høyst én endring i timen."
            return decision
        }
        decision.target = target
        decision.reason = "Prisstyring: " + (step.kind == .normal ? "tilbake til vanlig temperatur" : step.reason)
        (decision.kind, decision.text) = status(of: step)
        return decision
    }

    /// Status for a step that is in force.
    public static func status(of step: PlannedStep) -> (PriceControlStatus.Kind, String) {
        let temperature = TimerEvent.temperatureText(step.target)
        switch step.kind {
        case .normal: return (.normal, "Vanlig temperatur (\(temperature)).")
        case .reduce: return (.lowered, "Senket til \(temperature) – \(step.reason).")
        case .preheat: return (.raised, "Forvarmer til \(temperature) før dyre timer.")
        }
    }

    /// The setpoint to send when control stops (off, sleep, quit): the base, when the unit still
    /// has the setpoint the controller sent. Nil when there is nothing to restore.
    public static func restoreTarget(memory: PriceControlMemory, state: DeviceState?, base: Double?) -> Double? {
        guard let sent = memory.lastSent, let base, let setpoint = state?.setTemperature,
            abs(setpoint - sent) < tolerance, abs(base - sent) >= tolerance
        else { return nil }
        return base
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
