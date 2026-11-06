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

    /// The values to send for a request that may leave out `minimum`/`maximum`: missing ones keep
    /// the current range. Nil when a value is missing and the current range is unknown (the caller
    /// must then ask for it explicitly instead of guessing and overwriting the user's range).
    public static func resolving(enabled: Bool, minimum: Double?, maximum: Double?, current: FrostProtection?) -> FrostProtection? {
        guard let low = minimum ?? current?.minimum, let high = maximum ?? current?.maximum else { return nil }
        return FrostProtection(enabled: enabled, minimum: low, maximum: high)
    }

    /// "på, 8–12 °C" or "av" (change log and dialogs).
    public var summary: String {
        enabled ? Display.format("på, %.0f–%.0f °C", minimum, maximum) : "av"
    }
}

/// MELCloud holiday mode: the unit follows frost protection between `start` and `end` instead of
/// its normal settings (it may otherwise stand off, so frost protection must be on first). The
/// wire format of the dates is described at `HolidayWireTime`.
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
        return "på, " + (start.map(Display.dateTime) ?? "?") + " → " + (end.map(Display.dateTime) ?? "?")
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
    /// Set after a write until a read confirms it.
    public var pendingSince: Date?
    /// What the app or Claude last sent, kept so the page can show it next to what MELCloud reads back.
    public var sentFrost: FrostProtection?
    public var sentHoliday: HolidayMode?
    public var sentAt: Date?
    /// MELCloud refused to let this account read the settings (HTTP 4xx); no new read until then,
    /// unless the user presses "Prøv igjen".
    public var refusedUntil: Date?

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

    /// True while holiday mode is on now or later.
    func holidayActive(now: Date) -> Bool {
        guard let holiday, holiday.enabled else { return false }
        return holiday.end.map { $0 > now } ?? true
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

    /// Norwegian one-line summary for confirmations, with the values that will be sent.
    public var displaySummary: String {
        switch self {
        case .frostProtection(let fp):
            fp.enabled
                ? Display.format("Slå på frostsikring: holder %.0f–%.0f °C når varmepumpen ellers er av", fp.minimum, fp.maximum)
                : Display.format("Slå av frostsikring (området %.0f–%.0f °C lagres uendret)", fp.minimum, fp.maximum)
        case .holidayMode(let hm):
            hm.enabled
                ? "Slå på feriemodus fra " + (hm.start.map(Display.dateTime) ?? "?") + " til " + (hm.end.map(Display.dateTime) ?? "?")
                : "Slå av feriemodus"
        }
    }

    /// Recommended lowest frost-protection temperature; lower is allowed but warned about.
    public static let recommendedFrostMinimum = 8.0

    /// The summary for the approval dialog and the log, stating the frost range that will apply
    /// during a holiday (from the current settings).
    public func displaySummary(frost: FrostProtection?) -> String {
        guard case .holidayMode(let hm) = self, hm.enabled else { return displaySummary }
        guard let frost, frost.enabled else { return displaySummary + " – frostsikring er IKKE på" }
        var text = displaySummary + Display.format(
            " – i perioden holder varmepumpen frostsikringens område %.0f–%.0f °C", frost.minimum, frost.maximum)
        if frost.minimum < Self.recommendedFrostMinimum {
            text += Display.format(" (laveste %.0f °C er lavt; 8 °C eller mer anbefales)", frost.minimum)
        }
        return text
    }

    /// Norwegian reason this change is unsafe with the current settings, or nil. Holiday mode may
    /// leave the unit off, so it is only switched on while frost protection is known to be on, and
    /// frost protection is not switched off during a holiday.
    public func safetyProblem(current: AwaySettings?, now: Date) -> String? {
        switch self {
        case .holidayMode(let hm) where hm.enabled:
            guard let frost = current?.frost else {
                return "Feriemodus ble ikke slått på fordi appen ikke vet om frostsikring er på (innstillingene kunne ikke leses fra MELCloud). I feriemodus kan varmepumpen stå av. Slå på frostsikring først (for eksempel 8–12 °C), og prøv igjen."
            }
            guard frost.enabled else {
                return "Feriemodus ble ikke slått på fordi frostsikring er av. I feriemodus kan varmepumpen stå av, og da er det frostsikringen som hindrer at huset blir for kaldt. Slå på frostsikring først (for eksempel 8–12 °C)."
            }
            return nil
        case .frostProtection(let fp) where !fp.enabled:
            guard current?.holidayActive(now: now) == true else { return nil }
            return "Frostsikring ble ikke slått av fordi feriemodus er på. Uten frostsikring kan huset bli kaldt mens varmepumpen står av. Slå av feriemodus først."
        default:
            return nil
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
        case .frostProtection(let fp):
            next.frost = fp
            next.sentFrost = fp
        case .holidayMode(let hm):
            next.holiday = hm
            next.sentHoliday = hm
        }
        return next
    }
}
