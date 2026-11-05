import Foundation

/// MELCloud Classic `Device/SetAta` EffectiveFlags bits.
public struct ClassicEffectiveFlags: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let power = ClassicEffectiveFlags(rawValue: 0x01)
    public static let operationMode = ClassicEffectiveFlags(rawValue: 0x02)
    public static let setTemperature = ClassicEffectiveFlags(rawValue: 0x04)
    public static let setFanSpeed = ClassicEffectiveFlags(rawValue: 0x08)
    public static let vaneVertical = ClassicEffectiveFlags(rawValue: 0x10)
    public static let vaneHorizontal = ClassicEffectiveFlags(rawValue: 0x100)
}

/// A MELCloud Classic `OperationMode` value. 9, 10 and 11 are heat, dry and cool with i-See
/// (homebridge-melcloud constants "Heat Isee"/"Dry Isee"/"Cool Isee"); the raw value is kept so a
/// write that does not change the mode sends it back unchanged.
struct CloudOperationMode: Equatable {
    var mode: OperationMode
    var iSee: Bool
    var raw: Int

    init(mode: OperationMode, iSee: Bool, raw: Int) {
        self.mode = mode
        self.iSee = iSee
        self.raw = raw
    }

    init?(raw: Int) {
        switch raw {
        case 9: self.init(mode: .heat, iSee: true, raw: raw)
        case 10: self.init(mode: .dry, iSee: true, raw: raw)
        case 11: self.init(mode: .cool, iSee: true, raw: raw)
        default:
            guard let mode = OperationMode(rawValue: raw) else { return nil }
            self.init(mode: mode, iSee: false, raw: raw)
        }
    }
}

/// Outcome of `Login/ClientLogin`.
enum ClassicLoginOutcome: Equatable {
    case success(contextKey: String, expiry: Date?)
    case throttled(until: Date?)
    case refused(errorId: Int?, message: String?)
}

/// Pure mapping between MELCloud Classic wire JSON and backend-neutral models.
/// Every accessor is tolerant: missing, null or mistyped fields become `nil`.
enum MELCloudClassicParser {
    static let loginThrottleErrorId = 6

    // MARK: Login

    static func parseLogin(_ json: JSONValue, now: Date) -> ClassicLoginOutcome {
        if let loginData = json["LoginData"], let key = loginData["ContextKey"]?.string, !key.isEmpty {
            let expiry = WireDate.parse(loginData["Expiry"]?.string, timeZone: .gmt)
            return .success(contextKey: key, expiry: expiry)
        }
        let errorId = json["ErrorId"]?.int
        if errorId == loginThrottleErrorId {
            let minutes = json["LoginMinutes"]?.double
            let until = minutes.flatMap { $0 > 0 ? now.addingTimeInterval($0 * 60) : nil }
            return .throttled(until: until)
        }
        return .refused(errorId: errorId, message: json["ErrorMessage"]?.string)
    }

    // MARK: Device listing

    /// Flattens Structure → Devices / Areas / Floors → Areas, deduplicated by DeviceID.
    static func listedDevices(_ json: JSONValue) -> [JSONValue] {
        var result: [JSONValue] = []
        var seen = Set<Int>()
        func add(_ devices: JSONValue?) {
            for device in devices?.array ?? [] {
                guard let id = device["DeviceID"]?.int, !seen.contains(id) else { continue }
                // Only air-to-air units (DeviceType 0, or Type 0 on the wrapper).
                let type = device["Type"]?.int ?? device["Device"]?["DeviceType"]?.int ?? 0
                guard type == 0 else { continue }
                seen.insert(id)
                result.append(device)
            }
        }
        for building in json.array ?? [] {
            guard let structure = building["Structure"] else { continue }
            add(structure["Devices"])
            for area in structure["Areas"]?.array ?? [] { add(area["Devices"]) }
            for floor in structure["Floors"]?.array ?? [] {
                add(floor["Devices"])
                for area in floor["Areas"]?.array ?? [] { add(area["Devices"]) }
            }
        }
        return result
    }

    static func summary(_ wrapper: JSONValue) -> DeviceSummary? {
        guard let id = wrapper["DeviceID"]?.int else { return nil }
        return DeviceSummary(
            deviceId: id, buildingId: wrapper["BuildingID"]?.int ?? 0,
            name: wrapper["DeviceName"]?.string ?? "Varmepumpe")
    }

    /// Builds a state from a `ListDevices` wrapper and/or a `Device/Get` payload.
    /// `Device/Get` values win where both carry the same field.
    /// `listingFetchedAt`: when the listing was fetched; the energy counter (listing-only) is
    /// stamped with it. Nil means the listing's age is unknown and the counter is dropped.
    static func state(listing: JSONValue?, get: JSONValue?, fetchedAt: Date, listingFetchedAt: Date? = nil) throws -> DeviceState {
        let device = listing?["Device"]
        func value(_ keys: String...) -> JSONValue? {
            for key in keys {
                if let v = get?[key], !v.isNull { return v }
                if let v = device?[key], !v.isNull { return v }
                if let v = listing?[key], !v.isNull { return v }
            }
            return nil
        }
        guard let deviceId = value("DeviceID")?.int else {
            throw HeatPumpError.decoding("DeviceID mangler")
        }
        let utc = TimeZone.gmt
        let hasOutdoor = value("HasOutdoorTemperature")?.bool ?? true
        let cloudMode = mode(get: get, device: device, listing: listing)
        // The counter is stamped with the time it was read: Device/Get time if Get has it,
        // otherwise the listing time (unknown → no counter rather than a wrongly timed one).
        let counterFromGet = get?["CurrentEnergyConsumed"].map { !$0.isNull } ?? false
        let counterAt = counterFromGet ? fetchedAt : listingFetchedAt
        let currentWh = counterAt == nil ? nil : value("CurrentEnergyConsumed")?.double
        let limits = TemperatureLimits(
            minHeat: value("MinTempHeat")?.double ?? 10,
            maxHeat: value("MaxTempHeat")?.double ?? 31,
            minCoolDry: value("MinTempCoolDry")?.double ?? 16,
            maxCoolDry: value("MaxTempCoolDry")?.double ?? 31,
            minAuto: value("MinTempAutomatic")?.double ?? 16,
            maxAuto: value("MaxTempAutomatic")?.double ?? 31)
        let firmwareDeployment = value("FirmwareDeployment")?.string.flatMap { $0.isEmpty ? nil : $0 }
        let lastCommunication =
            WireDate.parse(value("LastCommunication")?.string, timeZone: utc)
            ?? WireDate.parse(value("LastTimeStamp")?.string, timeZone: .current)
        return DeviceState(
            deviceId: deviceId,
            buildingId: value("BuildingID")?.int ?? 0,
            name: listing?["DeviceName"]?.string ?? "Varmepumpe",
            serialNumber: value("SerialNumber")?.string,
            macAddress: value("MacAddress")?.string,
            power: value("Power")?.bool ?? false,
            mode: cloudMode?.mode,
            iSee: cloudMode?.iSee,
            setTemperature: value("SetTemperature")?.double,
            roomTemperature: value("RoomTemperature")?.double,
            outdoorTemperature: hasOutdoor ? value("OutdoorTemperature")?.double : nil,
            fanSpeed: value("SetFanSpeed", "FanSpeed")?.int,
            actualFanSpeed: value("ActualFanSpeed")?.int,
            numberOfFanSpeeds: value("NumberOfFanSpeeds")?.int ?? 5,
            hasAutomaticFanSpeed: value("HasAutomaticFanSpeed")?.bool ?? true,
            vaneVertical: value("VaneVertical", "VaneVerticalDirection")?.int.flatMap(VaneVertical.init(rawValue:)),
            vaneHorizontal: value("VaneHorizontal", "VaneHorizontalDirection")?.int.flatMap(VaneHorizontal.init(rawValue:)),
            hasError: value("HasError")?.bool ?? false,
            errorCode: value("ErrorCode")?.int,
            offline: value("Offline")?.bool ?? false,
            lastCommunication: lastCommunication,
            nextCommunication: WireDate.parse(value("NextCommunication")?.string, timeZone: utc),
            wifiSignal: value("WifiSignalStrength")?.int,
            hasPendingCommand: value("HasPendingCommand")?.bool ?? false,
            firmware: FirmwareInfo(
                deployment: firmwareDeployment,
                updateAborted: value("FirmwareUpdateAborted")?.bool ?? false,
                adaptorType: value("AdaptorType")?.int,
                appVersion: value("FirmwareAppVersion")?.int,
                adapterStatus: value("WifiAdapterStatus")?.string.flatMap { $0.isEmpty ? nil : $0 }),
            lastServiceDate: WireDate.parse(value("LastServiceDate")?.string, timeZone: .current),
            energy: EnergyCounters(
                currentConsumedKWh: currentWh.map { $0 / 1000 },
                totalHeatingKWh: value("TotalHeatingConsumed")?.double,
                totalCoolingKWh: value("TotalCoolingConsumed")?.double,
                totalAutoKWh: value("TotalAutoConsumed")?.double,
                totalDryKWh: value("TotalDryConsumed")?.double,
                totalFanKWh: value("TotalFanConsumed")?.double, counterAt: counterAt),
            limits: limits,
            temperatureIncrement: value("TemperatureIncrement")?.double ?? 0.5,
            fetchedAt: fetchedAt)
    }

    /// Operation mode from `Device/Get` when it carries one (an unknown value such as 0 gives
    /// nil: the unit really has no valid mode); otherwise from the listing. Strings are accepted.
    static func mode(get: JSONValue?, device: JSONValue?, listing: JSONValue?) -> CloudOperationMode? {
        for key in ["OperationMode", "OperationModeAta"] {
            if let value = get?[key], !value.isNull { return value.int.flatMap(CloudOperationMode.init(raw:)) }
        }
        for source in [device, listing] {
            for key in ["OperationMode", "OperationModeAta"] {
                if let raw = source?[key]?.int, let mode = CloudOperationMode(raw: raw) { return mode }
            }
        }
        return nil
    }

    // MARK: SetAta

    /// Fields MELCloud resets to defaults (power off, mode 0) when they are missing from a
    /// `Device/SetAta` body. A body without all of them is never sent.
    static let invalidModeMessage =
        "Varmepumpen rapporterer ingen gyldig modus. Velg modus (for eksempel Varme) samtidig med endringen."
    static let missingObjectMessage =
        "Mangler fullstendig status fra varmepumpen, så endringen ble ikke sendt. Oppdater og prøv igjen."

    static let requiredSetAtaKeys = ["Power", "OperationMode", "SetTemperature", "SetFanSpeed", "VaneHorizontal", "VaneVertical"]

    /// Builds the `Device/SetAta` body: the full device object from the last `Device/Get`
    /// (MELCloud takes omitted fields as defaults) with the changes applied, `EffectiveFlags`
    /// set to the changed fields only and `HasPendingCommand` true. Same approach as pymelcloud.
    static func setAtaPayload(_ changes: ChangeSet, raw: JSONValue) throws -> [String: JSONValue] {
        guard var body = raw.object else { throw HeatPumpError.validation(missingObjectMessage) }
        var flags = ClassicEffectiveFlags()
        body["DeviceID"] = .number(Double(changes.deviceId))
        if let power = changes.power {
            body["Power"] = .bool(power)
            flags.insert(.power)
        }
        if let mode = changes.mode {
            body["OperationMode"] = .number(Double(mode.rawValue))
            flags.insert(.operationMode)
        }
        if let temperature = changes.setTemperature {
            body["SetTemperature"] = .number(temperature)
            flags.insert(.setTemperature)
        }
        if let fan = changes.fanSpeed {
            body["SetFanSpeed"] = .number(Double(fan))
            flags.insert(.setFanSpeed)
        }
        if let vane = changes.vaneVertical {
            body["VaneVertical"] = .number(Double(vane.rawValue))
            flags.insert(.vaneVertical)
        }
        if let vane = changes.vaneHorizontal {
            body["VaneHorizontal"] = .number(Double(vane.rawValue))
            flags.insert(.vaneHorizontal)
        }
        body["EffectiveFlags"] = .number(Double(flags.rawValue))
        body["HasPendingCommand"] = .bool(true)

        let missing = requiredSetAtaKeys.filter { body[$0] == nil || body[$0]?.isNull == true }
        guard missing.isEmpty else {
            throw HeatPumpError.validation(
                "Status fra varmepumpen mangler \(missing.joined(separator: ", ")), så endringen ble ikke sendt.")
        }
        // An unknown mode would be sent back as-is and could leave the unit in a bad state. The
        // i-See values 9/10/11 are valid and go back unchanged when the mode is not changed.
        guard let mode = body["OperationMode"]?.int, CloudOperationMode(raw: mode) != nil else {
            throw HeatPumpError.validation(invalidModeMessage)
        }
        return body
    }

    /// New device object after a write: the old object with every non-null field of the
    /// `SetAta` response laid over it. A short or partial response never removes a field.
    static func merged(raw: JSONValue, response: JSONValue) -> JSONValue {
        guard var base = raw.object else { return response }
        for (key, value) in response.object ?? [:] where !value.isNull {
            // An unknown mode in the response must not replace a known one.
            if key == "OperationMode", CloudOperationMode(raw: value.int ?? -1) == nil { continue }
            base[key] = value
        }
        return .object(base)
    }

    // MARK: Reports

    /// `Report/GetUnitErrorLog2`: an array of entries, or `{ AttributeErrors: … }` on failure.
    static func errorLog(_ json: JSONValue, timeZone: TimeZone) throws -> [ErrorLogEntry] {
        if let attributeErrors = json["AttributeErrors"]?.object {
            let text = attributeErrors.map { key, value in
                "\(key): " + (value.array?.compactMap(\.string).joined(separator: ", ") ?? "")
            }.joined(separator: "; ")
            throw HeatPumpError.server(text)
        }
        return (json.array ?? []).compactMap { entry in
            guard let start = WireDate.parse(entry["StartDate"]?.string, timeZone: timeZone) else { return nil }
            let message = entry["ErrorMessage"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !message.isEmpty else { return nil }
            return ErrorLogEntry(
                deviceId: entry["DeviceId"]?.int ?? entry["DeviceID"]?.int ?? 0,
                start: start,
                end: WireDate.parse(entry["EndDate"]?.string, timeZone: timeZone),
                message: message,
                code: entry["ErrorCode"]?.string,
                source: "melcloud")
        }
    }

    /// Series order for ATA `Report/GetTemperatureLog2` (melcloud-api's ATA legend:
    /// SetTemperature, RoomTemperature, OutdoorTemperature).
    enum TemperatureSeries: Int { case set = 0, room = 1, outdoor = 2 }

    /// Longest range asked for in one `Report/GetTemperatureLog2` request.
    static let maxTemperatureRangeDays = 7

    /// `Report/GetTemperatureLog2` body as the MELCloud web app sends it (melcloud-api
    /// `ClassicTemperatureLogPostData`): DeviceID, local FromDate/ToDate, `Duration` in whole
    /// days (rounded up) and the device's `Location` when known.
    static func temperatureLogBody(deviceId: Int, range: DateInterval, location: Int?, timeZone: TimeZone) -> JSONValue {
        var body: [String: JSONValue] = [
            "DeviceID": .number(Double(deviceId)),
            "FromDate": .string(WireDate.localTimestamp(range.start, timeZone: timeZone)),
            "ToDate": .string(WireDate.localTimestamp(range.end, timeZone: timeZone)),
            "Duration": .number(max(1, (range.duration / 86_400).rounded(.up))),
        ]
        if let location { body["Location"] = .number(Double(location)) }
        return .object(body)
    }

    /// `Report/GetTemperatureLog2` → `{ Labels, LabelType, FromDate, ToDate, Data: [[series]] }`.
    ///
    /// Labels may be full timestamps, times of day ("10:00", LabelType 0) or something else.
    /// Times of day are placed on consecutive days from `FromDate`; anything else is spread
    /// evenly between `FromDate` and `ToDate` (or `range`). `AttributeErrors` throws.
    static func temperatureLog(_ json: JSONValue, range: DateInterval? = nil, timeZone: TimeZone) throws -> [TemperaturePoint] {
        if let attributeErrors = json["AttributeErrors"]?.object, !attributeErrors.isEmpty {
            throw HeatPumpError.server(attributeErrors.keys.sorted().joined(separator: ", "))
        }
        let labels = json["Labels"]?.array ?? []
        let series = json["Data"]?.array ?? []
        func value(_ s: TemperatureSeries, _ index: Int) -> Double? {
            guard s.rawValue < series.count, let row = series[s.rawValue].array, index < row.count else { return nil }
            return row[index].double
        }
        let from = WireDate.parse(json["FromDate"]?.string, timeZone: timeZone) ?? range?.start
        let to = WireDate.parse(json["ToDate"]?.string, timeZone: timeZone) ?? range?.end
        let count = max(labels.count, series.compactMap { $0.array?.count }.max() ?? 0)
        let timestamps = timestamps(labels: labels, count: count, from: from, to: to, timeZone: timeZone)
        return (0..<count).compactMap { index in
            guard let ts = timestamps[index] else { return nil }
            let point = TemperaturePoint(
                timestamp: ts, room: value(.room, index), set: value(.set, index), outdoor: value(.outdoor, index))
            if point.room == nil && point.set == nil && point.outdoor == nil { return nil }
            return point
        }
    }

    private static func timestamps(
        labels: [JSONValue], count: Int, from: Date?, to: Date?, timeZone: TimeZone
    ) -> [Date?] {
        guard count > 0 else { return [] }
        let strings = (0..<count).map { $0 < labels.count ? labels[$0].string : nil }
        let full = strings.map { WireDate.parse($0, timeZone: timeZone) }
        if full.contains(where: { $0 != nil }) && labels.count == count { return full }

        let calendar = WireDate.calendar(timeZone)
        let times = strings.map(timeOfDay)
        if let from, times.allSatisfy({ $0 != nil }) {
            var day = calendar.startOfDay(for: from)
            var previous = -1
            return times.map { minutes -> Date? in
                guard let minutes else { return nil }
                if minutes < previous, let next = calendar.date(byAdding: .day, value: 1, to: day) { day = next }
                previous = minutes
                return day.addingTimeInterval(Double(minutes) * 60)
            }
        }
        guard let from, let to, to > from else { return Array(repeating: nil, count: count) }
        let step = count > 1 ? to.timeIntervalSince(from) / Double(count - 1) : 0
        return (0..<count).map { from.addingTimeInterval(Double($0) * step) }
    }

    /// "HH:mm" or "H:mm[:ss]" → minutes after midnight.
    private static func timeOfDay(_ label: String?) -> Int? {
        guard let parts = label?.split(separator: ":"), parts.count >= 2,
            let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return hour * 60 + minute
    }

    /// Shape of a report response for stderr diagnostics: keys, counts and label format,
    /// with digits masked so no values or identifiers are logged.
    static func reportShape(_ json: JSONValue) -> String {
        guard let object = json.object else {
            return json.array.map { "array(\($0.count))" } ?? (json.isNull ? "empty" : "scalar")
        }
        var parts = ["keys=\(object.keys.sorted().joined(separator: ","))"]
        if let labels = json["Labels"]?.array {
            let sample = labels.first?.string.map { String($0.map { $0.isNumber ? "9" : $0 }) } ?? "-"
            parts.append("labels=\(labels.count) labelFormat=\(sample)")
        }
        if let type = json["LabelType"]?.int { parts.append("labelType=\(type)") }
        if let data = json["Data"]?.array {
            parts.append("series=\(data.count) rows=\(data.map { String($0.array?.count ?? -1) }.joined(separator: "/"))")
        }
        if let errors = json["AttributeErrors"]?.object {
            parts.append("attributeErrors=\(errors.map { "\($0.key): \($0.value.array?.compactMap(\.string).joined(separator: " | ") ?? "")" }.joined(separator: "; "))")
        }
        return parts.joined(separator: " ")
    }

    /// Longest range requested from `EnergyCost/Report`, chosen so MELCloud answers with
    /// daily buckets (longer ranges may come back per month).
    static let maxEnergyRangeDays = 28

    /// `EnergyCost/Report` `LabelType` values that mean monthly buckets.
    static let monthlyLabelTypes: Set<Int> = [2, 3]

    /// `EnergyCost/Report` for ATA: per-mode arrays aligned with `Labels`.
    ///
    /// Only daily data is accepted. Monthly `LabelType`s are dropped. Buckets map to
    /// consecutive days when their count equals the number of days requested; otherwise
    /// `raw` (1) numeric labels are read as day-of-month, which is unambiguous only for
    /// ranges up to 28 days. Anything else is dropped rather than guessed.
    static func energy(_ json: JSONValue, range: DateInterval, timeZone: TimeZone) -> [EnergyDay] {
        let labelType = json["LabelType"]?.int
        if let labelType, monthlyLabelTypes.contains(labelType) { return [] }
        let modes = ["Heating", "Cooling", "Auto", "Dry", "Fan", "Other"]
        let arrays = Dictionary(uniqueKeysWithValues: modes.map { ($0, json[$0]?.array?.map { $0.double ?? 0 } ?? []) })
        let bucketCount = arrays.values.map(\.count).max() ?? 0
        guard bucketCount > 0 else { return [] }
        let calendar = WireDate.calendar(timeZone)
        let firstDay = calendar.startOfDay(for: range.start)
        let dayCount = (calendar.dateComponents([.day], from: firstDay, to: calendar.startOfDay(for: range.end)).day ?? 0) + 1
        guard dayCount > 0 else { return [] }
        let labels = json["Labels"]?.array?.map(\.int) ?? []

        let dates: [Date?]
        if bucketCount == dayCount {
            dates = (0..<bucketCount).map { calendar.date(byAdding: .day, value: $0, to: firstDay) }
        } else if labelType == 1, labels.count == bucketCount, dayCount <= maxEnergyRangeDays {
            let daysInRange = (0..<dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: firstDay) }
            dates = labels.map { label in
                guard let label else { return nil }
                return daysInRange.first { calendar.component(.day, from: $0) == label }
            }
        } else {
            return []
        }

        var days: [EnergyDay] = []
        for (index, date) in dates.enumerated() {
            guard let date else { continue }
            func at(_ mode: String) -> Double {
                let a = arrays[mode] ?? []
                return index < a.count ? a[index] : 0
            }
            let total = modes.reduce(0) { $0 + at($1) }
            days.append(EnergyDay(day: WireDate.day(date, timeZone: timeZone), totalKWh: total, heatingKWh: at("Heating"), coolingKWh: at("Cooling")))
        }
        return days
    }

    // MARK: HTTP helpers

    /// `Retry-After` as seconds or HTTP-date; falls back to now + 2 h.
    static func retryAfter(_ header: String?, now: Date) -> Date {
        let fallback = now.addingTimeInterval(2 * 3600)
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return fallback }
        if let seconds = Double(header) { return now.addingTimeInterval(max(seconds, 0)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header) ?? fallback
    }
}
