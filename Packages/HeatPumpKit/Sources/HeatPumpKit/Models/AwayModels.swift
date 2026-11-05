import Foundation

/// MELCloud frost protection: the unit keeps the room between `minimum` and `maximum` while it
/// is otherwise off. Limits as the melcloud-api library clamps them: minimum 4–14 °C, maximum
/// 6–16 °C, maximum at least 2 °C above minimum. Whole degrees only (MELCloud's own app uses steps of 1).
public struct FrostProtection: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var minimum: Double
    public var maximum: Double
    /// `FPDefined` as reported (nil when unknown).
    public var defined: Bool?

    public static let minimumRange: ClosedRange<Double> = 4...14
    public static let maximumRange: ClosedRange<Double> = 6...16
    public static let minimumGap = 2.0

    public init(enabled: Bool, minimum: Double, maximum: Double, defined: Bool? = nil) {
        self.enabled = enabled
        self.minimum = minimum
        self.maximum = maximum
        self.defined = defined
    }

    /// Norwegian reason the values are refused, or nil.
    public func validationProblem() -> String? {
        guard minimum.isFinite, maximum.isFinite, minimum == minimum.rounded(), maximum == maximum.rounded() else {
            return "Frostsikringen tar hele grader."
        }
        guard Self.minimumRange.contains(minimum) else { return "Laveste temperatur for frostsikring må være 4–14 °C." }
        guard Self.maximumRange.contains(maximum) else { return "Høyeste temperatur for frostsikring må være 6–16 °C." }
        guard maximum >= minimum + Self.minimumGap else {
            return "Høyeste temperatur må være minst 2 °C over laveste (for eksempel 8 og 10 °C)."
        }
        return nil
    }

    /// "på, 8–12 °C" or "av" (change log and dialogs).
    public var summary: String {
        enabled ? Norwegian.format("på, %.0f–%.0f °C", minimum, maximum) : "av"
    }
}

/// MELCloud holiday mode: the unit follows frost protection between `start` and `end` instead of
/// its normal settings. MELCloud stores the dates as UTC wall clock (see `MELCloudClassicParser`).
public struct HolidayMode: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var start: Date?
    public var end: Date?
    public var defined: Bool?

    /// Longest holiday accepted from the app or Claude.
    public static let maxLength: TimeInterval = 365 * 86_400

    public init(enabled: Bool, start: Date? = nil, end: Date? = nil, defined: Bool? = nil) {
        self.enabled = enabled
        self.start = start
        self.end = end
        self.defined = defined
    }

    public func validationProblem(now: Date) -> String? {
        guard enabled else { return nil }
        guard let start, let end else { return "Feriemodus trenger både start og slutt." }
        guard end > start else { return "Slutten på feriemodus må være etter starten." }
        guard end > now else { return "Slutten på feriemodus kan ikke være passert." }
        guard end.timeIntervalSince(start) <= Self.maxLength else { return "Feriemodus kan vare høyst ett år." }
        return nil
    }

    /// "på, 20. des. 2026, 10:00 → 27. des. 2026, 18:30" or "av".
    public var summary: String {
        guard enabled else { return "av" }
        return "på, " + (start.map(Norwegian.dateTime) ?? "?") + " → " + (end.map(Norwegian.dateTime) ?? "?")
    }
}

/// Frost protection and holiday mode as last read (cached at most hourly).
public struct AwaySettings: Codable, Sendable, Equatable {
    public var frost: FrostProtection?
    public var holiday: HolidayMode?
    /// When MELCloud was last asked (nil when only the device listing's copy is known).
    public var fetchedAt: Date?
    /// `melcloud` (GetSettings) or `listing` (building fields from the device list).
    public var source: String
    /// Norwegian text when reading failed.
    public var message: String?
    /// Set after a write until the next read confirms it.
    public var pendingSince: Date?

    public init(
        frost: FrostProtection? = nil, holiday: HolidayMode? = nil, fetchedAt: Date? = nil, source: String = "melcloud",
        message: String? = nil, pendingSince: Date? = nil
    ) {
        self.frost = frost
        self.holiday = holiday
        self.fetchedAt = fetchedAt
        self.source = source
        self.message = message
        self.pendingSince = pendingSince
    }
}

/// A change to frost protection or holiday mode.
public enum AwayChange: Sendable, Equatable {
    case frostProtection(FrostProtection)
    case holidayMode(HolidayMode)

    public var field: String {
        switch self {
        case .frostProtection: "frostProtection"
        case .holidayMode: "holidayMode"
        }
    }

    public var valueDescription: String {
        switch self {
        case .frostProtection(let fp): fp.summary
        case .holidayMode(let hm): hm.summary
        }
    }

    /// Norwegian one-line summary for dialogs and confirmations.
    public var displaySummary: String {
        switch self {
        case .frostProtection(let fp):
            fp.enabled
                ? Norwegian.format("Slå på frostsikring (holder %.0f–%.0f °C når varmepumpen ellers er av)", fp.minimum, fp.maximum)
                : "Slå av frostsikring"
        case .holidayMode(let hm):
            hm.enabled
                ? "Slå på feriemodus fra " + (hm.start.map(Norwegian.dateTime) ?? "?") + " til " + (hm.end.map(Norwegian.dateTime) ?? "?")
                    + " (holder frostsikringens temperatur i perioden)"
                : "Slå av feriemodus"
        }
    }

    public func validationProblem(now: Date) -> String? {
        switch self {
        case .frostProtection(let fp): fp.validationProblem()
        case .holidayMode(let hm): hm.validationProblem(now: now)
        }
    }

    public func currentValue(in settings: AwaySettings?) -> String? {
        switch self {
        case .frostProtection: settings?.frost?.summary
        case .holidayMode: settings?.holiday?.summary
        }
    }

    func applied(to settings: AwaySettings) -> AwaySettings {
        var next = settings
        switch self {
        case .frostProtection(let fp): next.frost = fp
        case .holidayMode(let hm): next.holiday = hm
        }
        return next
    }
}

/// One event of MELCloud's weekly timer, as far as it could be decoded.
public struct TimerEvent: Codable, Sendable, Equatable {
    /// 1 = Monday … 7 = Sunday.
    public var weekday: Int
    public var minuteOfDay: Int
    public var power: Bool?
    public var mode: OperationMode?
    public var setTemperature: Double?

    public init(weekday: Int, minuteOfDay: Int, power: Bool? = nil, mode: OperationMode? = nil, setTemperature: Double? = nil) {
        self.weekday = weekday
        self.minuteOfDay = minuteOfDay
        self.power = power
        self.mode = mode
        self.setTemperature = setTemperature
    }

    /// "Varme 21 °C", "Av", "På".
    public var summary: String {
        if power == false { return "Av" }
        var parts: [String] = []
        if let mode { parts.append(mode.displayName) }
        if let setTemperature {
            parts.append(
                setTemperature == setTemperature.rounded()
                    ? Norwegian.format("%.0f °C", setTemperature) : Norwegian.format("%.1f °C", setTemperature))
        }
        return parts.isEmpty ? "På" : parts.joined(separator: " ")
    }

    /// "06:30"
    public var timeText: String { String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60) }

    public static let weekdayNames = ["mandag", "tirsdag", "onsdag", "torsdag", "fredag", "lørdag", "søndag"]
    public var weekdayName: String { (1...7).contains(weekday) ? Self.weekdayNames[weekday - 1] : "?" }
}

/// MELCloud's weekly timer (`Timer/Get2`), read-only. The event format is undocumented, so events
/// are only listed when every one of them could be decoded; otherwise just the count.
public struct WeeklyTimer: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var events: [TimerEvent]
    public var eventCount: Int
    public var decoded: Bool
    public var fetchedAt: Date?

    public init(enabled: Bool?, events: [TimerEvent], eventCount: Int, decoded: Bool, fetchedAt: Date? = nil) {
        self.enabled = enabled
        self.events = events
        self.eventCount = eventCount
        self.decoded = decoded
        self.fetchedAt = fetchedAt
    }

    /// The first decoded event after `date` (local week), or nil.
    public func nextEvent(after date: Date, timeZone: TimeZone) -> (event: TimerEvent, date: Date)? {
        guard enabled == true, !events.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let candidates = events.compactMap { event -> (TimerEvent, Date)? in
            // Calendar weekday: 1 = Sunday … 7 = Saturday.
            let weekday = event.weekday == 7 ? 1 : event.weekday + 1
            let components = DateComponents(hour: event.minuteOfDay / 60, minute: event.minuteOfDay % 60, weekday: weekday)
            guard let next = calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime) else { return nil }
            return (event, next)
        }
        return candidates.min { $0.1 < $1.1 }
    }
}
