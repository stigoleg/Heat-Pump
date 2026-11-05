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

    /// Same settings (power, mode, temperature, fan, vanes), regardless of day, time and wire object.
    public func sameSettings(as other: TimerEvent) -> Bool {
        power == other.power && mode == other.mode && setTemperature == other.setTemperature && fanSpeed == other.fanSpeed
            && vaneHorizontal == other.vaneHorizontal && vaneVertical == other.vaneVertical
    }

    /// The web client's `eventsMatch`: same time and same settings (one event shown on several days).
    public func matches(_ other: TimerEvent) -> Bool {
        minuteOfDay == other.minuteOfDay && sameSettings(as: other)
    }

    /// "Varme 21 °C", "Av", "På".
    public var summary: String {
        if power == false { return "Av" }
        var parts: [String] = []
        if let mode { parts.append(mode.displayName) }
        if let setTemperature { parts.append(Self.temperatureText(setTemperature)) }
        return parts.isEmpty ? "På" : parts.joined(separator: " ")
    }

    /// `summary` plus fan and vanes: "Varme 21 °C, vifte auto, spjeld auto/3".
    public var detailText: String {
        guard power != false else { return summary }
        var parts = [summary]
        if let fanSpeed { parts.append("vifte " + (fanSpeed == 0 ? "auto" : "\(fanSpeed)")) }
        if vaneVertical != nil || vaneHorizontal != nil {
            parts.append("spjeld " + (vaneVertical?.displayName ?? "–") + "/" + (vaneHorizontal?.displayName ?? "–"))
        }
        return parts.joined(separator: ", ")
    }

    static func temperatureText(_ value: Double) -> String {
        value == value.rounded() ? Norwegian.format("%.0f °C", value) : Norwegian.format("%.1f °C", value)
    }

    /// "06:30"
    public var timeText: String { Self.timeText(minuteOfDay) }

    public static func timeText(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    public static let weekdayNames = ["mandag", "tirsdag", "onsdag", "torsdag", "fredag", "lørdag", "søndag"]
    public static let shortWeekdayNames = ["man", "tir", "ons", "tor", "fre", "lør", "søn"]
    public var weekdayName: String { (1...7).contains(weekday) ? Self.weekdayNames[weekday - 1] : "?" }

    public static let weekdays: Set<Int> = [1, 2, 3, 4, 5]
    public static let weekend: Set<Int> = [6, 7]
    public static let allDays: Set<Int> = Set(1...7)

    /// "alle dager", "hverdager", "helg", "man–ons, fre".
    public static func daysText(_ days: Set<Int>) -> String {
        if days == allDays { return "alle dager" }
        if days == weekdays { return "hverdager" }
        if days == weekend { return "helg" }
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

    static let monthNames = [
        "januar", "februar", "mars", "april", "mai", "juni", "juli", "august", "september", "oktober", "november", "desember",
    ]

    /// "Vinter (fra 1. oktober)"
    public var displayName: String {
        let title = (name?.isEmpty == false && name != "Default") ? name! : "Sesong"
        let month = (startMonth ?? 1).clamped(to: 1...12)
        return "\(title) (fra \(startDay ?? 1). \(Self.monthNames[month - 1]))"
    }

    /// Events of `day` in time order.
    public func events(on day: Int) -> [TimerEvent] {
        events.filter { $0.weekday == day }.sorted { $0.minuteOfDay < $1.minuteOfDay }
    }
}

/// Ready-made plans for the "Mal" menu (heating mode; temperatures can be edited afterwards).
public enum TimerTemplate: String, CaseIterable, Sendable, Identifiable {
    case nightSetback
    case awayDaytime

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .nightSetback: "Nattsenking"
        case .awayDaytime: "Borte på dagtid"
        }
    }

    public var detail: String {
        switch self {
        case .nightSetback: "Alle dager 22:30 → 19 °C, hverdager 06:30 og helg 08:00 → 21 °C."
        case .awayDaytime: "Hverdager 08:00 → 18 °C og 15:30 → 21 °C."
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
        case enabled, seasons, eventCount, decoded, fetchedAt, maxEvents
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

    /// Same plan as MELCloud would get it (on/off and every season with its events as sent),
    /// regardless of when it was read.
    public func hasSameContent(as other: WeeklyTimer) -> Bool {
        decoded && other.decoded && (enabled == true) == (other.enabled == true)
            && seasons.map(MELCloudClassicParser.timerSeasonJSON) == other.seasons.map(MELCloudClassicParser.timerSeasonJSON)
    }

    /// "På, 6 hendelser" (change log and dialogs).
    public var summary: String {
        let state = enabled == true ? "På" : enabled == false ? "Av" : "Ukjent"
        return "\(state), \(totalEvents) \(totalEvents == 1 ? "hendelse" : "hendelser")"
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

    /// Norwegian reason the plan cannot be saved, or nil. `limits` are the unit's setpoint limits.
    public func validationProblem(limits: TemperatureLimits?) -> String? {
        guard decoded else {
            return "Ukeplanen kunne ikke leses helt, så appen endrer den ikke (det kunne ha slettet hendelser appen ikke forstår)."
        }
        for season in seasons {
            var seen = Set<Int>()
            for event in season.events {
                guard (1...7).contains(event.weekday), (0..<1440).contains(event.minuteOfDay) else {
                    return "Ugyldig dag eller klokkeslett i ukeplanen (00:00–23:59)."
                }
                let at = "\(event.weekdayName) kl. \(event.timeText)"
                guard seen.insert(event.weekday * 1440 + event.minuteOfDay).inserted else {
                    return "To hendelser \(at). Fjern den ene."
                }
                if event.raw == nil, event.power == nil || event.mode == nil || event.setTemperature == nil {
                    return "Hendelsen \(at) mangler av/på, modus eller temperatur."
                }
                if event.power != false, let mode = event.mode, let value = event.setTemperature {
                    let range = (limits ?? TemperatureLimits()).range(for: mode)
                    guard value.isFinite, range.contains(value), (value * 2).rounded() == value * 2 else {
                        return "Temperaturen \(at) må være "
                            + TimerEvent.temperatureText(range.lowerBound) + "–" + TimerEvent.temperatureText(range.upperBound)
                            + " i trinn på 0,5 °C (\(mode.displayName.lowercased()))."
                    }
                }
            }
        }
        if let maxEvents, totalEvents > maxEvents {
            return "Ukeplanen kan ha høyst \(maxEvents) hendelser til sammen, men har \(totalEvents)."
        }
        if enabled == true, totalEvents == 0 {
            return "Ukeplanen kan ikke slås på uten hendelser. Legg til minst én hendelse først."
        }
        return nil
    }

    /// Norwegian lines describing what changes from `old` to this plan, with identical changes on
    /// several days grouped: "Ny: hverdager kl. 06:30 – Varme 21 °C". Empty when nothing changes.
    public func differences(from old: WeeklyTimer) -> [String] {
        var lines: [String] = []
        if (old.enabled == true) != (enabled == true) {
            lines.append(enabled == true ? "Ukeplanen slås på" : "Ukeplanen slås av")
        }
        struct Key: Hashable {
            var season: Int
            var kind: Int
            var minute: Int
            var text: String
        }
        var grouped: [Key: Set<Int>] = [:]
        for index in seasons.indices {
            let before = old.seasons.indices.contains(index) ? old.seasons[index].events : []
            let after = seasons[index].events
            for day in 1...7 {
                let minutes = Set((before + after).filter { $0.weekday == day }.map(\.minuteOfDay))
                for minute in minutes {
                    let o = before.first { $0.weekday == day && $0.minuteOfDay == minute }
                    let n = after.first { $0.weekday == day && $0.minuteOfDay == minute }
                    let key: Key
                    switch (o, n) {
                    case (nil, let n?): key = Key(season: index, kind: 0, minute: minute, text: n.summary)
                    case (let o?, nil): key = Key(season: index, kind: 1, minute: minute, text: o.summary)
                    case (let o?, let n?) where !o.sameSettings(as: n):
                        let detailed = o.summary == n.summary
                        key = Key(
                            season: index, kind: 2, minute: minute,
                            text: (detailed ? o.detailText : o.summary) + " → " + (detailed ? n.detailText : n.summary))
                    default: continue
                    }
                    grouped[key, default: []].insert(day)
                }
            }
        }
        let labels = ["Ny", "Fjernet", "Endret"]
        let sorted = grouped.sorted { a, b in
            (a.key.season, a.key.kind, a.value.min() ?? 0, a.key.minute) < (b.key.season, b.key.kind, b.value.min() ?? 0, b.key.minute)
        }
        for (key, days) in sorted {
            let prefix = seasons.count > 1 ? (seasons[key.season].name ?? "Sesong") + ": " : ""
            lines.append(
                "\(prefix)\(labels[key.kind]): \(TimerEvent.daysText(days)) kl. \(TimerEvent.timeText(key.minute)) – \(key.text)")
        }
        return lines
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
