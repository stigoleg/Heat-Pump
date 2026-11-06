import Foundation

/// One event of MELCloud's weekly timer (air-to-air): at `minuteOfDay` on `weekday` the unit
/// takes these settings. On the wire `EventDay` is 0 = Sunday … 6 = Saturday.
public struct TimerEvent: Codable, Sendable, Equatable {
    /// 1 = Monday … 7 = Sunday.
    public var weekday: Int
    public var minuteOfDay: Int
    public var power: Bool?
    public var mode: OperationMode?
    public var setTemperature: Double?
    /// 0 = automatic, 1–5.
    public var fanSpeed: Int?
    public var vaneHorizontal: VaneHorizontal?
    public var vaneVertical: VaneVertical?
    /// The wire object as read (nil for events made in the app). Fields the app does not know,
    /// such as a server-side ID, go back unchanged.
    public var raw: JSONValue?

    public init(
        weekday: Int, minuteOfDay: Int, power: Bool? = nil, mode: OperationMode? = nil, setTemperature: Double? = nil,
        fanSpeed: Int? = nil, vaneHorizontal: VaneHorizontal? = nil, vaneVertical: VaneVertical? = nil, raw: JSONValue? = nil
    ) {
        self.weekday = weekday
        self.minuteOfDay = minuteOfDay
        self.power = power
        self.mode = mode
        self.setTemperature = setTemperature
        self.fanSpeed = fanSpeed
        self.vaneHorizontal = vaneHorizontal
        self.vaneVertical = vaneVertical
        self.raw = raw
    }

    /// Exactly as read from MELCloud (not made or changed in the app).
    public var isAsRead: Bool {
        raw.flatMap(MELCloudClassicParser.timerEvent) == self
    }

    /// Same settings (power, mode, temperature, fan, vanes), regardless of day, time and wire object.
    public func sameSettings(as other: TimerEvent) -> Bool {
        power == other.power && mode == other.mode && setTemperature == other.setTemperature && fanSpeed == other.fanSpeed
            && vaneHorizontal == other.vaneHorizontal && vaneVertical == other.vaneVertical
    }

    /// The web client's `eventsMatch`: same time and same settings (one event shown on several days).
    public func matches(_ other: TimerEvent) -> Bool {
        minuteOfDay == other.minuteOfDay && sameSettings(as: other)
    }

    /// "Heat 21 °C", "Off", "On".
    public var summary: String {
        if power == false { return L10n.tr("Off") }
        var parts: [String] = []
        if let mode { parts.append(mode.displayName) }
        if let setTemperature { parts.append(Self.temperatureText(setTemperature)) }
        return parts.isEmpty ? L10n.tr("On") : parts.joined(separator: " ")
    }

    /// `summary` plus fan and vanes: "Heat 21 °C, fan auto, airflow auto/3".
    public var detailText: String {
        guard power != false else { return summary }
        var parts = [summary]
        if let fanSpeed { parts.append(fanSpeed == 0 ? L10n.tr("fan auto") : L10n.format("fan %lld", fanSpeed)) }
        if vaneVertical != nil || vaneHorizontal != nil {
            parts.append(L10n.format("airflow %@/%@", vaneVertical?.displayName ?? "–", vaneHorizontal?.displayName ?? "–"))
        }
        return parts.joined(separator: ", ")
    }

    static func temperatureText(_ value: Double) -> String {
        value == value.rounded() ? Display.format("%.0f °C", value) : Display.format("%.1f °C", value)
    }

    /// "06:30"
    public var timeText: String { Self.timeText(minuteOfDay) }

    public static func timeText(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    /// Weekday names in the user's language, Monday first ("Monday" / "mandag").
    public static let weekdayNames: [String] = mondayFirst(symbolCalendar.weekdaySymbols)
    /// Short weekday names, Monday first, without the abbreviation dot ("Mon" / "man").
    public static let shortWeekdayNames: [String] = mondayFirst(symbolCalendar.shortStandaloneWeekdaySymbols).map {
        $0.hasSuffix(".") ? String($0.dropLast()) : $0
    }
    public var weekdayName: String { (1...7).contains(weekday) ? Self.weekdayNames[weekday - 1] : "?" }

    /// Gregorian calendar in the user's language, for day and month names.
    static var symbolCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = L10n.locale
        return calendar
    }

    /// Calendar symbols start on Sunday; the app's weeks start on Monday.
    private static func mondayFirst(_ symbols: [String]) -> [String] {
        Array(symbols.dropFirst()) + symbols.prefix(1)
    }

    public static let weekdays: Set<Int> = [1, 2, 3, 4, 5]
    public static let weekend: Set<Int> = [6, 7]
    public static let allDays: Set<Int> = Set(1...7)

    /// "every day", "weekdays", "weekends", "Mon–Wed, Fri".
    public static func daysText(_ days: Set<Int>) -> String {
        if days == allDays { return L10n.tr("every day") }
        if days == weekdays { return L10n.tr("weekdays") }
        if days == weekend { return L10n.tr("weekends") }
        let sorted = days.filter { (1...7).contains($0) }.sorted()
        var parts: [String] = []
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 { end += 1 }
            if end - index >= 2 {
                parts.append(shortWeekdayNames[sorted[index] - 1] + "–" + shortWeekdayNames[sorted[end] - 1])
            } else {
                parts += sorted[index...end].map { shortWeekdayNames[$0 - 1] }
            }
            index = end + 1
        }
        return parts.joined(separator: ", ")
    }
}

/// One season of the weekly timer: its events apply from `startDay`.`startMonth` until the next
/// season starts. A plan with one season is "Default" from 1 January.
public struct TimerSeason: Codable, Sendable, Equatable {
    public var id: Int?
    public var name: String?
    public var startDay: Int?
    public var startMonth: Int?
    public var events: [TimerEvent]
    /// The wire object as read (nil for a season made in the app); its other fields go back unchanged.
    public var raw: JSONValue?

    public init(
        id: Int? = nil, name: String? = nil, startDay: Int? = nil, startMonth: Int? = nil, events: [TimerEvent] = [],
        raw: JSONValue? = nil
    ) {
        self.id = id
        self.name = name
        self.startDay = startDay
        self.startMonth = startMonth
        self.events = events
        self.raw = raw
    }

    /// The single season the web client creates for a new plan (new seasons get negative IDs).
    public static let defaultSeason = TimerSeason(id: -1, name: "Default", startDay: 1, startMonth: 1)

    /// "Winter (from 1 October)"
    public var displayName: String {
        let title = (name?.isEmpty == false && name != "Default") ? name! : L10n.tr("Season")
        return L10n.format("%@ (from %@)", title, startText)
    }

    /// The start as day and month in the user's language ("1 October", "1. oktober").
    var startText: String {
        let month = (startMonth ?? 1).clamped(to: 1...12)
        let day = (startDay ?? 1).clamped(to: 1...31)
        let calendar = TimerEvent.symbolCalendar
        // A leap year, so 29 February exists.
        guard let date = calendar.date(from: DateComponents(year: 2000, month: month, day: day)) else {
            return "\(day). \(calendar.monthSymbols[month - 1])"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMMM")
        return formatter.string(from: date)
    }

    /// What identifies a season across reads: name and start date (IDs may be assigned later).
    var identity: String { "\(name ?? "Default")|\(startDay ?? 1).\(startMonth ?? 1)" }

    /// Events of `day` in time order.
    public func events(on day: Int) -> [TimerEvent] {
        events.filter { $0.weekday == day }.sorted { $0.minuteOfDay < $1.minuteOfDay }
    }
}

/// Ready-made plans for the "Template" menu (heating mode; temperatures can be edited afterwards).
public enum TimerTemplate: String, CaseIterable, Sendable, Identifiable {
    case nightSetback
    case awayDaytime

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .nightSetback: L10n.tr("Night setback")
        case .awayDaytime: L10n.tr("Away during the day")
        }
    }

    public var detail: String {
        switch self {
        case .nightSetback: L10n.tr("Every day 22:30 → 19 °C, weekdays 06:30 and weekends 08:00 → 21 °C.")
        case .awayDaytime: L10n.tr("Weekdays 08:00 → 18 °C and 15:30 → 21 °C.")
        }
    }

    /// (days, minute of day, temperature) for each event of the template.
    public var entries: [(days: Set<Int>, minuteOfDay: Int, temperature: Double)] {
        switch self {
        case .nightSetback:
            [(TimerEvent.allDays, 22 * 60 + 30, 19), (TimerEvent.weekdays, 6 * 60 + 30, 21), (TimerEvent.weekend, 8 * 60, 21)]
        case .awayDaytime:
            [(TimerEvent.weekdays, 8 * 60, 18), (TimerEvent.weekdays, 15 * 60 + 30, 21)]
        }
    }
}

/// MELCloud's weekly timer (`Timer/Get2`). It runs in MELCloud, also when the Mac is off. Events
/// are only listed (and the plan only editable) when every event of every season could be
/// decoded; otherwise just the count, so the app never overwrites events it does not understand.
public struct WeeklyTimer: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var seasons: [TimerSeason]
    public var eventCount: Int
    public var decoded: Bool
    public var fetchedAt: Date?
    /// MELCloud's limit on events (all seasons together), when known.
    public var maxEvents: Int?
    /// Set when the cache holds a plan as sent that MELCloud has not been read back for yet; the
    /// next `weeklyTimer()` reads it as soon as the read-back spacing allows.
    public var pendingSince: Date?
    /// Failed read-backs of a pending plan so far (they back off, then give up).
    public var pendingAttempts: Int?

    public init(
        enabled: Bool?, seasons: [TimerSeason], eventCount: Int? = nil, decoded: Bool, fetchedAt: Date? = nil, maxEvents: Int? = nil
    ) {
        self.enabled = enabled
        self.seasons = seasons
        self.eventCount = eventCount ?? seasons.reduce(0) { $0 + $1.events.count }
        self.decoded = decoded
        self.fetchedAt = fetchedAt
        self.maxEvents = maxEvents
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, seasons, eventCount, decoded, fetchedAt, maxEvents, pendingSince, pendingAttempts
    }

    private enum LegacyKeys: String, CodingKey {
        case events
    }

    /// A cached copy from before seasons were kept has no wire objects to write back: it is shown
    /// read-only (`decoded` false) and without `fetchedAt`, so it is read again soon.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        eventCount = try container.decodeIfPresent(Int.self, forKey: .eventCount) ?? 0
        maxEvents = try container.decodeIfPresent(Int.self, forKey: .maxEvents)
        pendingSince = try container.decodeIfPresent(Date.self, forKey: .pendingSince)
        pendingAttempts = try container.decodeIfPresent(Int.self, forKey: .pendingAttempts)
        if let seasons = try container.decodeIfPresent([TimerSeason].self, forKey: .seasons) {
            self.seasons = seasons
            decoded = try container.decodeIfPresent(Bool.self, forKey: .decoded) ?? false
            fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt)
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let events = (try? legacy.decodeIfPresent([TimerEvent].self, forKey: .events)) ?? []
            seasons = events.isEmpty ? [] : [TimerSeason(events: events)]
            decoded = false
            fetchedAt = nil
        }
    }

    /// Events of all seasons.
    public var events: [TimerEvent] { seasons.flatMap(\.events) }

    /// Number of events in all seasons (counted from the seasons when they were decoded).
    public var totalEvents: Int { decoded ? seasons.reduce(0) { $0 + $1.events.count } : eventCount }

    /// The same plan in effect: on/off, and per season its name, start and the multiset of events
    /// (day, time, power, mode, temperature, fan, vanes as they would be sent). Server-assigned or
    /// cosmetic fields (IDs, `Name`, `Settings`, `EventTime` formatting), order and read time do not
    /// count, so a plan MELCloud gave IDs after a save still matches what was sent.
    public func hasSameContent(as other: WeeklyTimer) -> Bool {
        decoded && other.decoded && enabled == other.enabled && contentKey == other.contentKey
    }

    private var contentKey: [String] {
        seasons.map { season in
            let events = season.events.map { event -> String in
                let wire = MELCloudClassicParser.timerEventJSON(event)
                let fields: [String] = [
                    "\(event.weekday)", "\(event.minuteOfDay)", wire["Power"]?.bool.map { "\($0)" } ?? "-",
                    wire["OperationMode"]?.int.map { "\($0)" } ?? "-", wire["SetTemperature"]?.double.map { "\($0)" } ?? "-",
                    wire["FanSpeed"]?.int.map { "\($0)" } ?? "-", wire["VaneHorizontal"]?.int.map { "\($0)" } ?? "-",
                    wire["VaneVertical"]?.int.map { "\($0)" } ?? "-",
                ]
                return fields.joined(separator: ",")
            }
            return season.identity + "|" + events.sorted().joined(separator: ";")
        }.sorted()
    }

    /// "On, 6 events" (change log and dialogs).
    public var summary: String {
        switch enabled {
        case true?: L10n.format("On, %lld events", totalEvents)
        case false?: L10n.format("Off, %lld events", totalEvents)
        case nil: L10n.format("Unknown, %lld events", totalEvents)
        }
    }

    /// The season in force on `date`: the one with the latest start on or before that day of the
    /// year, else the latest start (it continues from last year).
    public func activeSeasonIndex(on date: Date, timeZone: TimeZone) -> Int? {
        guard !seasons.isEmpty else { return nil }
        let c = WireDate.calendar(timeZone).dateComponents([.month, .day], from: date)
        let today = (c.month ?? 1) * 100 + (c.day ?? 1)
        let starts = seasons.indices.map { ($0, (seasons[$0].startMonth ?? 1) * 100 + (seasons[$0].startDay ?? 1)) }
        return (starts.filter { $0.1 <= today }.max { $0.1 < $1.1 } ?? starts.max { $0.1 < $1.1 })?.0
    }

    /// The first event of the active season after `date` (local week), or nil.
    public func nextEvent(after date: Date, timeZone: TimeZone) -> (event: TimerEvent, date: Date)? {
        guard enabled == true, decoded, let index = activeSeasonIndex(on: date, timeZone: timeZone) else { return nil }
        let calendar = WireDate.calendar(timeZone)
        let candidates = seasons[index].events.compactMap { event -> (TimerEvent, Date)? in
            // Calendar weekday: 1 = Sunday … 7 = Saturday.
            let weekday = event.weekday == 7 ? 1 : event.weekday + 1
            let components = DateComponents(hour: event.minuteOfDay / 60, minute: event.minuteOfDay % 60, weekday: weekday)
            guard let next = calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime) else { return nil }
            return (event, next)
        }
        return candidates.min { $0.1 < $1.1 }
    }

    /// The event of the active season that last fired at or before `date` (searching back one
    /// week) and when it fired, or nil when the plan is off, unread or empty.
    public func event(inForceAt date: Date, timeZone: TimeZone) -> (event: TimerEvent, date: Date)? {
        guard enabled == true, decoded, let index = activeSeasonIndex(on: date, timeZone: timeZone) else { return nil }
        let calendar = WireDate.calendar(timeZone)
        let candidates = seasons[index].events.compactMap { event -> (TimerEvent, Date)? in
            let weekday = event.weekday == 7 ? 1 : event.weekday + 1
            let components = DateComponents(hour: event.minuteOfDay / 60, minute: event.minuteOfDay % 60, weekday: weekday)
            guard
                let last = calendar.nextDate(
                    after: date.addingTimeInterval(1), matching: components, matchingPolicy: .nextTime, direction: .backward)
            else { return nil }
            return (event, last)
        }
        return candidates.max { $0.1 < $1.1 }
    }

    // MARK: Editing (the web client's semantics)

    /// Makes sure there is a season to edit (a new plan gets the web client's default season).
    public mutating func ensureSeason() {
        if seasons.isEmpty { seasons = [.defaultSeason] }
    }

    /// Days on which `event` (same time and settings) occurs in season `season`.
    public func days(of event: TimerEvent, season: Int) -> Set<Int> {
        guard seasons.indices.contains(season) else { return [] }
        return Set(seasons[season].events.filter { $0.matches(event) }.map(\.weekday))
    }

    /// The web client's `submitEvent`: removes the events matching `original` (same time and
    /// settings, on every day), then puts a copy of `event` on each of `days`; an event already at
    /// that day and time is replaced. A copy keeps the wire object of the event it replaces on
    /// that day, so MELCloud sees an edit rather than a new event.
    public mutating func put(_ event: TimerEvent, on days: Set<Int>, replacing original: TimerEvent? = nil, season: Int = 0) {
        ensureSeason()
        guard seasons.indices.contains(season) else { return }
        var events = seasons[season].events
        var kept: [Int: JSONValue] = [:]
        if let original {
            events.removeAll { item in
                guard item.matches(original) else { return false }
                if let raw = item.raw { kept[item.weekday] = raw }
                return true
            }
        }
        for day in days.sorted() where (1...7).contains(day) {
            events.removeAll { item in
                guard item.weekday == day, item.minuteOfDay == event.minuteOfDay else { return false }
                if kept[day] == nil, let raw = item.raw { kept[day] = raw }
                return true
            }
            var copy = event
            copy.weekday = day
            copy.raw = kept[day]
            events.append(copy)
        }
        seasons[season].events = events
        recount()
    }

    /// Removes `event` (same time and settings) on every day of season `season`.
    public mutating func remove(_ event: TimerEvent, season: Int = 0) {
        guard seasons.indices.contains(season) else { return }
        seasons[season].events.removeAll { $0.matches(event) }
        recount()
    }

    /// Replaces the events of each of `targets` with copies of the events of `day`.
    public mutating func copyDay(_ day: Int, to targets: Set<Int>, season: Int = 0) {
        guard seasons.indices.contains(season) else { return }
        let source = seasons[season].events(on: day)
        for target in targets.sorted() where target != day && (1...7).contains(target) {
            seasons[season].events.removeAll { $0.weekday == target }
            for event in source {
                var copy = event
                copy.weekday = target
                copy.raw = nil
                seasons[season].events.append(copy)
            }
        }
        recount()
    }

    /// Adds the template's events (heating, power on; fan and vanes from `base`), after removing
    /// every event of the season when `replace` is set.
    public mutating func apply(_ template: TimerTemplate, base: TimerEvent, replace: Bool, season: Int = 0) {
        ensureSeason()
        guard seasons.indices.contains(season) else { return }
        if replace { seasons[season].events.removeAll() }
        for entry in template.entries {
            var event = base
            event.minuteOfDay = entry.minuteOfDay
            event.power = true
            event.mode = .heat
            event.setTemperature = entry.temperature
            event.raw = nil
            put(event, on: entry.days, season: season)
        }
    }

    private mutating func recount() {
        eventCount = seasons.reduce(0) { $0 + $1.events.count }
    }

    // MARK: Validation and differences

    /// Reason the plan cannot be saved, or nil. `limits` are the unit's setpoint limits.
    /// New and edited events are checked strictly; events exactly as read from MELCloud pass
    /// through unchanged (MELCloud accepted them, and the app must not make a plan unsavable).
    public func validationProblem(limits: TemperatureLimits?) -> String? {
        guard decoded else {
            return L10n.tr("The weekly schedule could not be read completely, so the app does not change it (that could delete events the app does not understand).")
        }
        guard enabled != nil else {
            return L10n.tr("MELCloud did not say whether the weekly schedule is on. Choose on or off before you save.")
        }
        for season in seasons {
            var seen: [Int: Bool] = [:]
            for event in season.events {
                let edited = !event.isAsRead
                guard (1...7).contains(event.weekday), (0..<1440).contains(event.minuteOfDay) else {
                    return L10n.tr("Invalid day or time in the weekly schedule (00:00–23:59).")
                }
                let key = event.weekday * 1440 + event.minuteOfDay
                if let other = seen[key], other || edited {
                    return L10n.format("Two events on %@ at %@. Remove one of them.", event.weekdayName, event.timeText)
                }
                seen[key] = edited
                guard edited else { continue }
                if event.power == nil || event.mode == nil || event.setTemperature == nil {
                    return L10n.format("The event on %@ at %@ is missing on/off, mode or temperature.", event.weekdayName, event.timeText)
                }
                // The setpoint does not apply in fan mode (or when the event switches the unit off).
                if event.power != false, let mode = event.mode, mode != .fan, let value = event.setTemperature {
                    let range = (limits ?? TemperatureLimits()).range(for: mode)
                    guard value.isFinite, range.contains(value), (value * 2).rounded() == value * 2 else {
                        return L10n.format(
                            "The temperature on %@ at %@ must be %@–%@ in steps of 0.5 °C (%@).", event.weekdayName, event.timeText,
                            TimerEvent.temperatureText(range.lowerBound), TimerEvent.temperatureText(range.upperBound), mode.sentenceName)
                    }
                }
            }
        }
        if let maxEvents, totalEvents > maxEvents {
            return L10n.format("The weekly schedule can have at most %lld events in total, but has %lld.", maxEvents, totalEvents)
        }
        if enabled == true, totalEvents == 0 {
            return L10n.tr("The weekly schedule cannot be turned on without events. Add at least one event first.")
        }
        return nil
    }

    /// Lines describing what changes from `old` to this plan, with identical changes on
    /// several days grouped: "New: weekdays at 06:30 – Heat 21 °C". Empty when nothing changes.
    /// Seasons are matched by name and start date, not position.
    public func differences(from old: WeeklyTimer) -> [String] {
        var lines: [String] = []
        if old.enabled != enabled {
            lines.append(
                enabled == true
                    ? L10n.tr("The weekly schedule is turned on")
                    : enabled == false ? L10n.tr("The weekly schedule is turned off") : L10n.tr("Unknown whether the weekly schedule will be on"))
        }
        // Pairs of (label, events before, events after).
        var pairs: [(label: String, before: [TimerEvent], after: [TimerEvent])] = []
        var unmatched = Array(old.seasons.indices)
        for season in seasons {
            let match = unmatched.firstIndex { old.seasons[$0].identity == season.identity }
            let before = match.map { old.seasons[unmatched[$0]].events } ?? []
            if let match { unmatched.remove(at: match) }
            pairs.append((season.name ?? L10n.tr("Season"), before, season.events))
        }
        for index in unmatched { pairs.append((old.seasons[index].name ?? L10n.tr("Season"), old.seasons[index].events, [])) }
        struct Key: Hashable {
            var pair: Int
            var kind: Int
            var minute: Int
            var text: String
        }
        var grouped: [Key: Set<Int>] = [:]
        for (index, pair) in pairs.enumerated() {
            for day in 1...7 {
                let minutes = Set((pair.before + pair.after).filter { $0.weekday == day }.map(\.minuteOfDay))
                for minute in minutes {
                    let o = pair.before.first { $0.weekday == day && $0.minuteOfDay == minute }
                    let n = pair.after.first { $0.weekday == day && $0.minuteOfDay == minute }
                    let key: Key
                    switch (o, n) {
                    case (nil, let n?): key = Key(pair: index, kind: 0, minute: minute, text: n.summary)
                    case (let o?, nil): key = Key(pair: index, kind: 1, minute: minute, text: o.summary)
                    case (let o?, let n?) where !o.sameSettings(as: n):
                        let detailed = o.summary == n.summary
                        key = Key(
                            pair: index, kind: 2, minute: minute,
                            text: (detailed ? o.detailText : o.summary) + " → " + (detailed ? n.detailText : n.summary))
                    default: continue
                    }
                    grouped[key, default: []].insert(day)
                }
            }
        }
        let sorted = grouped.sorted { a, b in
            (a.key.pair, a.key.kind, a.value.min() ?? 0, a.key.minute) < (b.key.pair, b.key.kind, b.value.min() ?? 0, b.key.minute)
        }
        for (key, days) in sorted {
            let when = TimerEvent.daysText(days)
            let time = TimerEvent.timeText(key.minute)
            if pairs.count > 1 {
                let season = pairs[key.pair].label
                switch key.kind {
                case 0: lines.append(L10n.format("%@: New: %@ at %@ – %@", season, when, time, key.text))
                case 1: lines.append(L10n.format("%@: Removed: %@ at %@ – %@", season, when, time, key.text))
                default: lines.append(L10n.format("%@: Changed: %@ at %@ – %@", season, when, time, key.text))
                }
            } else {
                switch key.kind {
                case 0: lines.append(L10n.format("New: %@ at %@ – %@", when, time, key.text))
                case 1: lines.append(L10n.format("Removed: %@ at %@ – %@", when, time, key.text))
                default: lines.append(L10n.format("Changed: %@ at %@ – %@", when, time, key.text))
                }
            }
        }
        return lines
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
