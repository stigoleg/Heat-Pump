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
    static func state(listing: JSONValue?, get: JSONValue?, fetchedAt: Date) throws -> DeviceState {
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
        let currentWh = value("CurrentEnergyConsumed")?.double
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
            mode: value("OperationMode")?.int.flatMap(OperationMode.init(rawValue:)),
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
                adaptorType: value("AdaptorType")?.int),
            lastServiceDate: WireDate.parse(value("LastServiceDate")?.string, timeZone: .current),
            energy: EnergyCounters(
                currentConsumedKWh: currentWh.map { $0 / 1000 },
                totalHeatingKWh: value("TotalHeatingConsumed")?.double,
                totalCoolingKWh: value("TotalCoolingConsumed")?.double,
                totalAutoKWh: value("TotalAutoConsumed")?.double,
                totalDryKWh: value("TotalDryConsumed")?.double,
                totalFanKWh: value("TotalFanConsumed")?.double),
            limits: limits,
            temperatureIncrement: value("TemperatureIncrement")?.double ?? 0.5,
            fetchedAt: fetchedAt)
    }

    // MARK: SetAta

    /// Builds the minimal `Device/SetAta` body: id, flags, pending marker and changed fields only.
    static func setAtaPayload(_ changes: ChangeSet) -> [String: JSONValue] {
        var flags = ClassicEffectiveFlags()
        var body: [String: JSONValue] = [
            "DeviceID": .number(Double(changes.deviceId)),
            "HasPendingCommand": .bool(true),
        ]
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
        return body
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

    /// Series order assumed for ATA `Report/GetTemperatureLog2`.
    /// Not verified against a live account; adjust here if the real order differs.
    enum TemperatureSeries: Int { case set = 0, room = 1, outdoor = 2 }

    /// `Report/GetTemperatureLog2` → `{ Labels: [timestamp], Data: [[series values]] }`.
    static func temperatureLog(_ json: JSONValue, timeZone: TimeZone) -> [TemperaturePoint] {
        let labels = json["Labels"]?.array ?? []
        let series = json["Data"]?.array ?? []
        func value(_ s: TemperatureSeries, _ index: Int) -> Double? {
            guard s.rawValue < series.count, let row = series[s.rawValue].array, index < row.count else { return nil }
            return row[index].double
        }
        return labels.enumerated().compactMap { index, label in
            guard let ts = WireDate.parse(label.string, timeZone: timeZone) else { return nil }
            let point = TemperaturePoint(
                timestamp: ts, room: value(.room, index), set: value(.set, index), outdoor: value(.outdoor, index))
            if point.room == nil && point.set == nil && point.outdoor == nil { return nil }
            return point
        }
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
