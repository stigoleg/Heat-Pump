import Foundation

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
/// - `GET Timer/Get2?deviceId=<id>` → `{Enabled, Seasons[].Events[]}` (event schema undocumented).
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
        else { throw HeatPumpError.decoding("Frostsikring: uventet svar fra MELCloud.") }
        return FrostProtection(enabled: enabled, minimum: minimum, maximum: maximum, defined: json["FPDefined"]?.bool)
    }

    static func holidayMode(_ json: JSONValue) throws -> HolidayMode {
        try throwIfAttributeErrors(json)
        guard let enabled = json["HMEnabled"]?.bool else { throw HeatPumpError.decoding("Feriemodus: uventet svar fra MELCloud.") }
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
        if json["Success"]?.bool == false { throw HeatPumpError.server("MELCloud avviste endringen.") }
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

    static func weeklyTimer(_ json: JSONValue) -> WeeklyTimer {
        var raw: [JSONValue] = []
        for season in json["Seasons"]?.array ?? [] { raw += season["Events"]?.array ?? [] }
        raw += json["Events"]?.array ?? []
        let events = raw.compactMap(timerEvent)
        let decoded = !raw.isEmpty && events.count == raw.count
        return WeeklyTimer(enabled: json["Enabled"]?.bool, events: decoded ? events : [], eventCount: raw.count, decoded: decoded)
    }

    /// Tries the field names seen in MELCloud clients. Days are .NET `DayOfWeek` (0 = Sunday).
    static func timerEvent(_ json: JSONValue) -> TimerEvent? {
        func first(_ keys: String...) -> JSONValue? {
            for key in keys { if let value = json[key], !value.isNull { return value } }
            return nil
        }
        guard let day = first("Day", "DayOfWeek", "Weekday")?.int, (0...7).contains(day) else { return nil }
        var minute: Int?
        if let time = first("Time", "StartTime") {
            if case .string(let text) = time {
                let parts = text.split(separator: ":").compactMap { Int($0) }
                if parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) { minute = parts[0] * 60 + parts[1] }
            } else if let value = time.int, (0..<1440).contains(value) {
                minute = value
            }
        } else if let hour = first("Hour")?.int, (0..<24).contains(hour) {
            minute = hour * 60 + (first("Minute")?.int ?? 0)
        }
        guard let minute else { return nil }
        let powerValue = first("Power", "PowerOn")
        let power = powerValue?.bool ?? powerValue?.int.map { $0 != 0 }
        return TimerEvent(
            weekday: day == 0 ? 7 : day, minuteOfDay: minute, power: power,
            mode: first("OperationMode", "Mode")?.int.flatMap { CloudOperationMode(raw: $0)?.mode },
            setTemperature: first("SetTemperature", "Temperature", "SetPoint")?.double)
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
