import Foundation
import HeatPumpKit

/// Frost protection, holiday mode and the weekly timer (MELCloud Classic). These endpoints are
/// not verified against the user's account: parsing is tolerant and response shapes (keys and
/// types only) are logged to stderr.
///
/// - `GET FrostProtection/GetSettings?id=<deviceId>&tableName=DeviceLocation` → `FPDefined, FPEnabled,
///   FPMinTemperature, FPMaxTemperature`; `POST FrostProtection/Update {Enabled, MinimumTemperature,
///   MaximumTemperature, DeviceIds}` (melcloud-api `ClassicFrostProtectionPostData`).
/// - `GET HolidayMode/GetSettings?id=<deviceId>&tableName=DeviceLocation` → `HMEnabled, HMStartDate,
///   HMEndDate, StartDate/EndDate {Year…Second}`; `POST HolidayMode/Update {Enabled, StartDate, EndDate,
///   HMTimeZones: [{Devices: [id]}]}` with dates as described at `HolidayWireTime`.
/// - `GET Timer/Get2?deviceId=<id>` → `{Enabled, Seasons[].Events[]}`; `POST Timer/SetAta2 {Devices, Seasons,
///   TimerEnabled, SkipPage1}` → `{Data: {ErrorCode, MaxEvents}}` (shapes from the web client's script).
extension MELCloudClassicParser {
    static func throwIfAttributeErrors(_ json: JSONValue) throws {
        if let errors = json["AttributeErrors"]?.object, !errors.isEmpty {
            let text = errors.map { key, value in
                "\(key): " + (value.array?.compactMap(\.string).joined(separator: ", ") ?? "")
            }.sorted().joined(separator: "; ")
            throw HeatPumpError.server(text)
        }
    }

    static func frostProtection(_ json: JSONValue) throws -> FrostProtection {
        try throwIfAttributeErrors(json)
        guard let enabled = json["FPEnabled"]?.bool, let minimum = json["FPMinTemperature"]?.double,
            let maximum = json["FPMaxTemperature"]?.double
        else { throw HeatPumpError.decoding(L10n.tr("Frost protection: unexpected answer from MELCloud.")) }
        return FrostProtection(enabled: enabled, minimum: minimum, maximum: maximum, defined: json["FPDefined"]?.bool)
    }

    static func holidayMode(_ json: JSONValue) throws -> HolidayMode {
        try throwIfAttributeErrors(json)
        guard let enabled = json["HMEnabled"]?.bool else { throw HeatPumpError.decoding(L10n.tr("Holiday mode: unexpected answer from MELCloud.")) }
        let start = HolidayWireTime.date(string: json["HMStartDate"]?.string) ?? HolidayWireTime.date(components: json["StartDate"])
        let end = HolidayWireTime.date(string: json["HMEndDate"]?.string) ?? HolidayWireTime.date(components: json["EndDate"])
        return HolidayMode(enabled: enabled, start: start, end: end, defined: json["HMDefined"]?.bool)
    }

    /// Frost protection and holiday mode from the building fields the listing carries.
    static func awayFromListing(_ wrapper: JSONValue?) -> AwaySettings? {
        guard let building = wrapper?[buildingKey] else { return nil }
        let frost = try? frostProtection(building)
        let holiday = try? holidayMode(building)
        guard frost != nil || holiday != nil else { return nil }
        return AwaySettings(frost: frost, holiday: holiday, fetchedAt: nil, source: "listing")
    }

    static func frostProtectionBody(_ fp: FrostProtection, deviceId: Int) -> JSONValue {
        .object([
            "Enabled": .bool(fp.enabled), "MinimumTemperature": .number(fp.minimum), "MaximumTemperature": .number(fp.maximum),
            "DeviceIds": .array([.number(Double(deviceId))]),
        ])
    }

    static func holidayModeBody(_ hm: HolidayMode, deviceId: Int) -> JSONValue {
        .object([
            "Enabled": .bool(hm.enabled), "StartDate": hm.start.map(HolidayWireTime.components) ?? .null,
            "EndDate": hm.end.map(HolidayWireTime.components) ?? .null,
            "HMTimeZones": .array([.object(["Devices": .array([.number(Double(deviceId))])])]),
        ])
    }

    /// Update answers: `{Success, AttributeErrors}`. An empty body counts as success.
    static func checkMutation(_ json: JSONValue) throws {
        try throwIfAttributeErrors(json)
        if json["Success"]?.bool == false { throw HeatPumpError.server(L10n.tr("MELCloud rejected the change.")) }
    }

    /// Keys and value types (two levels deep), never values, for stderr diagnostics.
    static func redactedShape(_ json: JSONValue, depth: Int = 0) -> String {
        switch json {
        case .object(let object):
            guard depth < 2 else { return "object(\(object.count))" }
            return "{" + object.keys.sorted().map { "\($0):\(redactedShape(object[$0] ?? .null, depth: depth + 1))" }
                .joined(separator: ",") + "}"
        case .array(let array):
            return "array(\(array.count))" + (array.first.map { depth < 2 ? redactedShape($0, depth: depth + 1) : "" } ?? "")
        case .null: return "null"
        case .bool: return "bool"
        case .number: return "number"
        case .string: return "string"
        }
    }

    // MARK: Weekly timer

    /// `Timer/Get2`: `{Enabled, Seasons: [{ID, Name, StartDay, StartMonth, Events}]}`. Events are
    /// listed only when every event of every season decodes (see `WeeklyTimer`).
    package static func weeklyTimer(_ json: JSONValue) -> WeeklyTimer {
        var seasons: [TimerSeason] = []
        var count = 0
        var decoded = true
        for season in json["Seasons"]?.array ?? [] {
            let raw = season["Events"]?.array ?? []
            let events = raw.compactMap(timerEvent)
            count += raw.count
            if events.count != raw.count || season.object == nil { decoded = false }
            seasons.append(
                TimerSeason(
                    id: season["ID"]?.int, name: season["Name"]?.string, startDay: season["StartDay"]?.int,
                    startMonth: season["StartMonth"]?.int, events: events, raw: season))
        }
        if json["Seasons"]?.array == nil { decoded = false }
        return WeeklyTimer(
            enabled: json["Enabled"]?.bool, seasons: decoded ? seasons : [], eventCount: count, decoded: decoded,
            maxEvents: json["MaxEvents"]?.int)
    }

    /// An air-to-air event as the web client builds it (`copyEvent`): `EventDay` (0 = Sunday …
    /// 6 = Saturday), `EventHour`, `EventMinute` (or `EventTime` "HH:mm:ss"), `Power`,
    /// `OperationMode`, `SetTemperature`, `FanSpeed`, `VaneHorizontal`, `VaneVertical`.
    static func timerEvent(_ json: JSONValue) -> TimerEvent? {
        func value(_ key: String) -> JSONValue? {
            guard let value = json[key], !value.isNull else { return nil }
            return value
        }
        guard let day = value("EventDay")?.int, (0...6).contains(day) else { return nil }
        var minute: Int?
        if let hour = value("EventHour")?.int, let min = value("EventMinute")?.int, (0..<24).contains(hour), (0..<60).contains(min) {
            minute = hour * 60 + min
        } else if let text = value("EventTime")?.string {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            if parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) { minute = parts[0] * 60 + parts[1] }
        }
        guard let minute else { return nil }
        return TimerEvent(
            weekday: day == 0 ? 7 : day, minuteOfDay: minute, power: value("Power")?.bool,
            mode: value("OperationMode")?.int.flatMap { CloudOperationMode(raw: $0)?.mode },
            setTemperature: value("SetTemperature")?.double, fanSpeed: value("FanSpeed")?.int,
            vaneHorizontal: value("VaneHorizontal")?.int.flatMap(VaneHorizontal.init(rawValue:)),
            vaneVertical: value("VaneVertical")?.int.flatMap(VaneVertical.init(rawValue:)), raw: json)
    }

    /// `Timer/SetAta2` body: every season with its events. All fields of untouched events and
    /// seasons go back as read; with no events at all the plan is switched off (as the web client does).
    /// `enabled` must be known (`validationProblem` refuses nil); it is never guessed as off here.
    package static func timerSetBody(timer: WeeklyTimer, deviceId: Int) -> JSONValue {
        let seasons = timer.seasons.map(timerSeasonJSON)
        let hasEvents = timer.seasons.contains { !$0.events.isEmpty }
        return .object([
            "Devices": .array([.number(Double(deviceId))]), "Seasons": .array(seasons),
            "TimerEnabled": timer.enabled.map { .bool($0 && hasEvents) } ?? .null, "SkipPage1": .bool(true),
        ])
    }

    static func timerSeasonJSON(_ season: TimerSeason) -> JSONValue {
        var object = season.raw?.object ?? [:]
        if object["ID"] == nil { object["ID"] = season.id.map { .number(Double($0)) } ?? .number(-1) }
        if object["Name"] == nil { object["Name"] = .string(season.name ?? "Default") }
        if object["StartDay"] == nil { object["StartDay"] = .number(Double(season.startDay ?? 1)) }
        if object["StartMonth"] == nil { object["StartMonth"] = .number(Double(season.startMonth ?? 1)) }
        object["Events"] = .array(season.events.map(timerEventJSON))
        return .object(object)
    }

    /// An event as read goes back unchanged; an edited one keeps its unknown fields (and the
    /// i-See variant of an unchanged mode); a new one gets the web client's `Settings` and `Name`.
    static func timerEventJSON(_ event: TimerEvent) -> JSONValue {
        if let raw = event.raw, timerEvent(raw) == event { return raw }
        var object = event.raw?.object ?? ["Settings": .string("<settings></settings>"), "Name": .string("-")]
        let isNew = event.raw == nil
        let hour = event.minuteOfDay / 60
        let minute = event.minuteOfDay % 60
        object["EventDay"] = .number(Double(event.weekday == 7 ? 0 : event.weekday))
        object["EventHour"] = .number(Double(hour))
        object["EventMinute"] = .number(Double(minute))
        object["EventTime"] = .string(String(format: "%02d:%02d:00", hour, minute))
        if let power = event.power { object["Power"] = .bool(power) } else if isNew { object["Power"] = .bool(true) }
        if let mode = event.mode {
            if object["OperationMode"]?.int.flatMap(CloudOperationMode.init(raw:))?.mode != mode {
                object["OperationMode"] = .number(Double(mode.rawValue))
            }
        }
        if let value = event.setTemperature { object["SetTemperature"] = .number(value) }
        if let value = event.fanSpeed { object["FanSpeed"] = .number(Double(value)) } else if isNew { object["FanSpeed"] = .number(0) }
        if let value = event.vaneHorizontal {
            object["VaneHorizontal"] = .number(Double(value.rawValue))
        } else if isNew {
            object["VaneHorizontal"] = .number(0)
        }
        if let value = event.vaneVertical {
            object["VaneVertical"] = .number(Double(value.rawValue))
        } else if isNew {
            object["VaneVertical"] = .number(0)
        }
        return .object(object)
    }

    /// MELCloud's web-client texts for `Timer/SetAta2` `Data.ErrorCode` (index = code; out of range → 0).
    static let timerErrorMessages = [
        L10n.tr("An unknown error occurred while saving the weekly schedule."),
        L10n.tr("The seasons are not valid. Check the start dates."),
        L10n.tr("You cannot have more than the allowed number of events in the weekly schedule (in total for all seasons)."),
    ]

    /// The error text of a `Timer/SetAta2` answer, or nil for success (`ErrorCode` -1, or no `Data`).
    package static func timerSaveError(_ json: JSONValue) -> String? {
        guard let data = json["Data"], !data.isNull, let code = data["ErrorCode"]?.int, code != -1 else { return nil }
        let index = timerErrorMessages.indices.contains(code) ? code : 0
        if index == 2, let max = data["MaxEvents"]?.string {
            return L10n.format("You cannot have more than %@ events in the weekly schedule (in total for all seasons).", max)
        }
        return timerErrorMessages[index]
    }
}

/// The one place that converts holiday-mode times to and from MELCloud Classic's wire format.
///
/// Interpretation: **UTC wall clock** (an instant written as its UTC date and time, without offset).
/// Evidence, all from melcloud-api (OlivierZal), none verified against this account:
/// - `utils.ts` `toUtcWallClock`: "Projects a caller-local wall-clock datetime onto the UTC wall clock
///   the MELCloud wires store" (and `toZonedWallClock` for reading back) — the library's helper for
///   datetimes it sends.
/// - Against it: `api_classic.ts` (error log) says "Classic timestamps are building-local wall clock",
///   and `ClassicHolidayModeData` carries a `TimeZone` number (an optional `TimeZone` may also go in
///   `HMTimeZones`). That comment is about read timestamps of the error log, not holiday writes.
/// The first live write must be compared with the MELCloud app; the Borte page shows the times read
/// back from MELCloud next to what was sent, so an offset (e.g. one hour in winter) is visible.
enum HolidayWireTime {
    static let zone = TimeZone.gmt

    /// `{Year, Month, Day, Hour, Minute, Second}` for an update body.
    static func components(_ date: Date) -> JSONValue {
        let c = WireDate.calendar(zone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return .object([
            "Year": .number(Double(c.year ?? 0)), "Month": .number(Double(c.month ?? 0)), "Day": .number(Double(c.day ?? 0)),
            "Hour": .number(Double(c.hour ?? 0)), "Minute": .number(Double(c.minute ?? 0)), "Second": .number(Double(c.second ?? 0)),
        ])
    }

    static func date(components json: JSONValue?) -> Date? {
        guard let json, let year = json["Year"]?.int, year > 1, let month = json["Month"]?.int, let day = json["Day"]?.int else {
            return nil
        }
        let c = DateComponents(
            year: year, month: month, day: day, hour: json["Hour"]?.int ?? 0, minute: json["Minute"]?.int ?? 0,
            second: json["Second"]?.int ?? 0)
        return WireDate.calendar(zone).date(from: c)
    }

    /// `HMStartDate`/`HMEndDate` strings (an explicit offset in the string wins).
    static func date(string: String?) -> Date? {
        WireDate.parse(string, timeZone: zone)
    }
}
