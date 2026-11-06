import Foundation
import HeatPumpKit
import MELCloudIntegration

/// A simulated air-to-air unit (`VARMEPUMPE_DEMO_DEVICES`): MELCloud-style ids, a name and how
/// its use compares with the living room's.
public struct DemoUnit: Sendable, Equatable {
    public var deviceId: Int
    public var name: String
    /// Share of the living room unit's consumption (a smaller room uses less).
    public var scale: Double
    /// Setpoint at start.
    public var setTemperature: Double
    /// Whether the unit reports the simulated error-log entries.
    public var reportsErrors: Bool

    public var key: DeviceKey { DeviceKey(integration: DemoIntegration.id, nativeId: String(deviceId)) }

    /// The `index`th simulated unit: the living room, the bedroom, then numbered units.
    public static func unit(_ index: Int) -> DemoUnit {
        switch index {
        case 0:
            DemoUnit(deviceId: MockBackend.deviceId, name: L10n.tr("Living room (simulated)"), scale: 1, setTemperature: 21, reportsErrors: true)
        case 1:
            DemoUnit(deviceId: MockBackend.deviceId + 1, name: L10n.tr("Bedroom (simulated)"), scale: 0.6, setTemperature: 19, reportsErrors: false)
        default:
            DemoUnit(
                deviceId: MockBackend.deviceId + index, name: L10n.format("Heat pump %lld (simulated)", index + 1), scale: 0.8,
                setTemperature: 20, reportsErrors: false)
        }
    }

    /// The units `VARMEPUMPE_DEMO_DEVICES` asks for: a comma list of device kinds, `heatpump` by
    /// default (`heatpump,heatpump` adds a bedroom unit). Unknown entries are skipped; at least one
    /// unit is always simulated.
    public static func units(environment: [String: String]) -> [DemoUnit] {
        let kinds = (environment["VARMEPUMPE_DEMO_DEVICES"] ?? "heatpump").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let count = kinds.filter { $0 == "heatpump" }.count
        return (0..<max(1, count)).map(unit)
    }
}

/// Deterministic backend with realistic Norwegian winter data. Selected with
/// `VARMEPUMPE_BACKEND=mock`. All history is a pure function of time, so repeated
/// runs and separate processes see the same past; only writes are per-process. Simulates one
/// unit by default, more with `VARMEPUMPE_DEMO_DEVICES`.
public actor MockBackend: HeatPumpBackend, AwayModesDriver, WeeklyScheduleDriver, FirmwareDriver, DemoDataSeeding {
    public nonisolated let identifier = "mock"

    /// The first simulated unit's MELCloud-style ids; its key is `demo:100001`.
    public static let deviceId = 100_001
    public static let buildingId = 200_001
    public static let device = DeviceKey(integration: DemoIntegration.id, nativeId: String(deviceId))

    /// What one simulated unit holds between calls.
    struct UnitState: Sendable {
        var unit: DemoUnit
        var power = true
        var mode: OperationMode = .heat
        var setTemperature: Double
        var fanSpeed = 0
        var vaneVertical: VaneVertical = .auto
        var vaneHorizontal: VaneHorizontal = .position3
        var frost = FrostProtection(enabled: false, minimum: 8, maximum: 12, defined: true)
        var holiday = HolidayMode(enabled: false, defined: false)
        /// The weekly timer in the wire shape (`Timer/Get2`); a save replaces it, so a read returns it.
        var timerJSON: JSONValue = MockBackend.initialTimer()
        /// When the simulated firmware update was started (nil: still waiting for approval).
        var firmwareApprovedAt: Date?

        init(_ unit: DemoUnit) {
            self.unit = unit
            setTemperature = unit.setTemperature
        }
    }

    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    /// The simulated units, in listing order.
    public nonisolated let units: [DemoUnit]
    private var states: [DeviceKey: UnitState]
    public private(set) var appliedChanges: [ChangeSet] = []
    public private(set) var awayReads = 0
    public private(set) var awayWrites = 0
    public private(set) var timerReads = 0
    public private(set) var timerWrites = 0
    public private(set) var firmwareReads = 0
    public private(set) var firmwareApprovals = 0
    public private(set) var firmwareCancels = 0

    public init(timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() }, units: [DemoUnit] = [.unit(0)]) {
        self.now = now
        self.timeZone = timeZone
        let units = units.isEmpty ? [.unit(0)] : units
        self.units = units
        states = Dictionary(units.map { ($0.key, UnitState($0)) }, uniquingKeysWith: { a, _ in a })
    }

    /// The first unit's frost protection, holiday mode and firmware approval (tests).
    public var frost: FrostProtection { states[Self.device]?.frost ?? FrostProtection(enabled: false, minimum: 8, maximum: 12, defined: true) }
    public var holiday: HolidayMode { states[Self.device]?.holiday ?? HolidayMode(enabled: false, defined: false) }
    public var firmwareApprovedAt: Date? { states[Self.device]?.firmwareApprovedAt }

    /// The state of `device`, or `deviceNotFound` for a device this backend does not simulate.
    private func unitState(_ device: DeviceKey) throws -> UnitState {
        guard let state = states[device] else { throw HeatPumpError.deviceNotFound }
        return state
    }

    /// Simulates the Wi-Fi adapter's local readings and live power too.
    public nonisolated var capabilities: Set<Capability> {
        Capability.derived(from: self).union([.localTelemetry, .livePower])
    }

    /// The weekly timer is kept in MELCloud's wire shape, so MELCloud's format reads it.
    public nonisolated var weeklyTimerFormat: any WeeklyTimerFormat { MELCloudTimerFormat() }

    // MARK: DemoDataSeeding

    public nonisolated var demoDevices: [DeviceKey] { units.map(\.key) }
    public func demoState(at date: Date, device: DeviceKey) -> DeviceState {
        (try? state(at: date, device: device)) ?? state(at: date)
    }
    public nonisolated var demoLocalHost: String { MockLocalSimulation.host }

    public nonisolated func demoLocalSamples(from: Date, to: Date, shortCycling: Bool) -> [LocalSample] {
        MockLocalSimulation.samples(from: from, to: to, shortCycling: shortCycling)
    }

    public func login() async throws {}

    /// The listing, without a network call (demo mode registers it at startup).
    public nonisolated var listing: [DeviceSummary] { Self.listing(units) }

    public static func listing(_ units: [DemoUnit]) -> [DeviceSummary] {
        units.map { DeviceSummary(key: $0.key, name: $0.name, metadata: ["buildingId": String(buildingId)]) }
    }

    public func listDevices() async throws -> [DeviceSummary] { listing }

    public func fetchState(device: DeviceKey) async throws -> DeviceState {
        try state(at: now(), device: device)
    }

    /// Simulated state of the first unit at any time (also used to seed demo history).
    public func state(at t: Date) -> DeviceState {
        // The first unit always exists.
        (try? state(at: t, device: units[0].key)) ?? state(at: t, of: UnitState(units[0]))
    }

    /// Simulated state of `device` at any time.
    public func state(at t: Date, device: DeviceKey) throws -> DeviceState {
        state(at: t, of: try unitState(device))
    }

    private func state(at t: Date, of s: UnitState) -> DeviceState {
        let outdoor = Self.outdoorTemperature(at: t)
        let first = s.unit.key == Self.device
        return DeviceState(
            key: s.unit.key, name: s.unit.name,
            serialNumber: first ? "MOCK0000000" : String(format: "MOCK%07d", s.unit.deviceId - Self.deviceId),
            macAddress: first ? "00:00:5e:00:53:01" : String(format: "00:00:5e:00:53:%02x", (s.unit.deviceId - Self.deviceId + 1) % 256),
            power: s.power, mode: s.mode, setTemperature: s.setTemperature,
            roomTemperature: roomTemperature(at: t, outdoor: outdoor, of: s),
            outdoorTemperature: (outdoor * 2).rounded() / 2,
            fanSpeed: s.fanSpeed, actualFanSpeed: s.power ? 2 : 0, numberOfFanSpeeds: 5, hasAutomaticFanSpeed: true,
            vaneVertical: s.vaneVertical, vaneHorizontal: s.vaneHorizontal,
            hasError: false, errorCode: 8000, offline: false,
            lastCommunication: t.addingTimeInterval(-40), nextCommunication: t.addingTimeInterval(20),
            wifiSignal: -62, hasPendingCommand: false,
            firmware: firmware(at: t, of: s),
            lastServiceDate: nil,
            energy: EnergyCounters(
                currentConsumedKWh: Self.counterKWh(at: t, scale: s.unit.scale), totalHeatingKWh: first ? 1180.2 : 640.5,
                totalCoolingKWh: first ? 54.3 : 12.1),
            limits: TemperatureLimits(minHeat: 10, maxHeat: 31, minCoolDry: 16, maxCoolDry: 31, minAuto: 16, maxAuto: 31),
            temperatureIncrement: 0.5, fetchedAt: t)
    }

    @discardableResult
    public func apply(_ changes: ChangeSet) async throws -> DeviceState? {
        var s = try unitState(changes.device)
        appliedChanges.append(changes)
        if let value = changes.power { s.power = value }
        if let value = changes.mode { s.mode = value }
        if let value = changes.setTemperature { s.setTemperature = value }
        if let value = changes.fanSpeed { s.fanSpeed = value }
        if let value = changes.vaneVertical { s.vaneVertical = value }
        if let value = changes.vaneHorizontal { s.vaneHorizontal = value }
        states[changes.device] = s
        var state = try await fetchState(device: changes.device)
        state.hasPendingCommand = true
        return state
    }

    /// One simulated error every 17 days at 03:12 UTC, anchored to a fixed epoch so entries are stable.
    public func fetchErrorLog(device: DeviceKey, range: DateInterval) async throws -> [ErrorLogEntry] {
        guard try unitState(device).unit.reportsErrors else { return [] }
        let anchor = Date(timeIntervalSince1970: 1_767_236_000)  // 2026-01-01T03:13:20Z
        let period: TimeInterval = 17 * 86_400
        var entries: [ErrorLogEntry] = []
        var k = ((range.start.timeIntervalSince(anchor)) / period).rounded(.down)
        while true {
            let start = anchor.addingTimeInterval(k * period)
            if start > range.end || start > now() { break }
            if start >= range.start {
                entries.append(
                    ErrorLogEntry(
                        device: device, start: start, end: start.addingTimeInterval(240),
                        message: L10n.tr("Communication error between the indoor and outdoor unit (simulated)"), code: nil, source: MELCloudIntegration.sourceTag))
            }
            k += 1
        }
        return entries
    }

    public func fetchTemperatureLog(device: DeviceKey, range: DateInterval) async throws -> [TemperaturePoint] {
        let s = try unitState(device)
        var points: [TemperaturePoint] = []
        let step: TimeInterval = 3600
        var t = (range.start.timeIntervalSince1970 / step).rounded(.up) * step
        let end = min(range.end, now()).timeIntervalSince1970
        while t <= end {
            let date = Date(timeIntervalSince1970: t)
            let outdoor = Self.outdoorTemperature(at: date)
            points.append(
                TemperaturePoint(
                    timestamp: date, room: roomTemperature(at: date, outdoor: outdoor, of: s), set: s.unit.setTemperature,
                    outdoor: (outdoor * 2).rounded() / 2))
            t += step
        }
        return points
    }

    public func fetchEnergy(device: DeviceKey, range: DateInterval) async throws -> [EnergyDay] {
        let scale = try unitState(device).unit.scale
        let calendar = WireDate.calendar(timeZone)
        var day = calendar.startOfDay(for: range.start)
        let last = calendar.startOfDay(for: min(range.end, now()))
        var days: [EnergyDay] = []
        while day <= last {
            let meanOutdoor = stride(from: 0.0, to: 24, by: 1).map {
                Self.outdoorTemperature(at: day.addingTimeInterval($0 * 3600 + 1800))
            }.reduce(0, +) / 24
            let degreeDays = max(0, 17 - meanOutdoor)
            let kWh = (max(0.4, degreeDays * 0.42) * scale * 10).rounded() / 10
            days.append(EnergyDay(day: WireDate.day(day, timeZone: timeZone), totalKWh: kWh, heatingKWh: kWh, coolingKWh: 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    public func fetchSignalStrength(device: DeviceKey) async throws -> Int? { -62 }

    public func fetchAwaySettings(device: DeviceKey) async throws -> AwaySettings {
        let s = try unitState(device)
        awayReads += 1
        return AwaySettings(frost: s.frost, holiday: s.holiday, fetchedAt: now(), source: MELCloudIntegration.sourceTag)
    }

    public func applyAway(_ change: AwayChange, device: DeviceKey) async throws {
        var s = try unitState(device)
        awayWrites += 1
        switch change {
        case .frostProtection(let value): s.frost = value
        case .holidayMode(let value): s.holiday = value
        }
        states[device] = s
    }

    /// Error for the next timer reads (tests).
    private var timerReadError: HeatPumpError?
    private var timerReadFailures = 0
    /// Changes what a save stores, as if MELCloud kept something else (tests).
    private var timerSaveTransform: (@Sendable (JSONValue) -> JSONValue)?

    public func failNextTimerRead(with error: HeatPumpError, times: Int = 1) {
        timerReadError = error
        timerReadFailures = times
    }

    public func transformNextSavedTimer(_ transform: @escaping @Sendable (JSONValue) -> JSONValue) { timerSaveTransform = transform }

    /// Replaces the first unit's plan as if it had been changed in the MELCloud app (tests).
    public func replaceTimer(_ json: JSONValue) { states[Self.device]?.timerJSON = json }

    public func fetchWeeklyTimer(device: DeviceKey) async throws -> WeeklyTimer {
        let s = try unitState(device)
        timerReads += 1
        if let error = timerReadError, timerReadFailures > 0 {
            timerReadFailures -= 1
            throw error
        }
        var timer = MELCloudClassicParser.weeklyTimer(s.timerJSON)
        timer.fetchedAt = now()
        return timer
    }

    /// Stores what `Timer/SetAta2` would receive, built by the same code as the real body.
    public func saveWeeklyTimer(_ timer: WeeklyTimer, device: DeviceKey) async throws {
        let unit = try unitState(device).unit
        let body = MELCloudClassicParser.timerSetBody(timer: timer, deviceId: unit.deviceId)
        let count = body["Seasons"]?.array?.reduce(0) { $0 + ($1["Events"]?.array?.count ?? 0) } ?? 0
        if count > Self.timerMaxEvents {
            let response: JSONValue = .object(["Data": .object(["ErrorCode": .number(2), "MaxEvents": .number(Double(Self.timerMaxEvents))])])
            throw HeatPumpError.server(MELCloudClassicParser.timerSaveError(response) ?? "")
        }
        timerWrites += 1
        // Like MELCloud, new seasons and events get IDs.
        let seasons = (body["Seasons"]?.array ?? []).map { season -> JSONValue in
            guard case .object(var object) = season else { return season }
            if (object["ID"]?.int ?? -1) < 0 { object["ID"] = .number(Double(nextTimerId())) }
            object["Events"] = .array((object["Events"]?.array ?? []).map { event in
                guard case .object(var fields) = event, fields["ID"] == nil else { return event }
                fields["ID"] = .number(Double(nextTimerId()))
                return .object(fields)
            })
            return .object(object)
        }
        var json: JSONValue = .object(["Enabled": body["TimerEnabled"] ?? .bool(false), "Seasons": .array(seasons)])
        if let transform = timerSaveTransform {
            timerSaveTransform = nil
            json = transform(json)
        }
        states[device]?.timerJSON = json
    }

    static let timerMaxEvents = 50
    private var lastTimerId = 1_000

    private func nextTimerId() -> Int {
        lastTimerId += 1
        return lastTimerId
    }

    /// Night setback: weekdays 06:30 → 21 °C, every night 22:30 → 19 °C, weekend 08:00 → 21,5 °C.
    static func initialTimer() -> JSONValue {
        var events: [JSONValue] = []
        var id = 1
        func event(_ day: Int, _ hour: Int, _ minute: Int, _ temperature: Double) -> JSONValue {
            defer { id += 1 }
            return .object([
                "ID": .number(Double(id)), "EventDay": .number(Double(day)), "EventHour": .number(Double(hour)),
                "EventMinute": .number(Double(minute)), "EventTime": .string(String(format: "%02d:%02d:00", hour, minute)),
                "Power": .bool(true), "OperationMode": .number(1), "SetTemperature": .number(temperature), "FanSpeed": .number(0),
                "VaneHorizontal": .number(3), "VaneVertical": .number(0), "Settings": .string("<settings></settings>"), "Name": .string("-"),
            ])
        }
        for day in 1...5 { events.append(event(day, 6, 30, 21)) }
        for day in 0...6 { events.append(event(day, 22, 30, 19)) }
        for day in [6, 0] { events.append(event(day, 8, 0, 21.5)) }
        return .object([
            "Enabled": .bool(true),
            "Seasons": .array([
                .object(["ID": .number(1), "Name": .string("Default"), "StartDay": .number(1), "StartMonth": .number(1), "Events": .array(events)])
            ]),
        ])
    }

    // MARK: Firmware update (simulated: waiting → downloading 4 files → restart → done in 2 minutes)

    static let firmwareUpdateId = 9_001
    static let firmwareFiles = 4

    public func firmwareUpdates(device: DeviceKey) async throws -> [FirmwareUpdateStatus] {
        let s = try unitState(device)
        firmwareReads += 1
        let (phase, approval, files) = firmwareProgress(at: now(), of: s)
        return [
            FirmwareUpdateStatus(
                id: Self.firmwareUpdateId, device: device, currentPhase: phase, approvalStatus: approval, minutesOffline: 0,
                filesDownloaded: files, filesToDownload: Self.firmwareFiles, retries: 0, dateApproved: s.firmwareApprovedAt,
                dateCreated: Date(timeIntervalSince1970: 1_767_236_000), lastCommunication: now().addingTimeInterval(-40))
        ]
    }

    public func approveFirmwareUpdate(id: Int, device: DeviceKey) async throws {
        guard let s = states[device], id == Self.firmwareUpdateId else { throw HeatPumpError.server(L10n.tr("Unknown update")) }
        let current = firmwareProgress(at: now(), of: s)
        guard FirmwareUpdatePhase.from(phase: current.phase, approval: current.approval, minutesOffline: 0).canApprove else { throw HeatPumpError.server(L10n.tr("The update cannot be approved now")) }
        firmwareApprovals += 1
        states[device]?.firmwareApprovedAt = now()
    }

    public func cancelFirmwareUpdate(id: Int, device: DeviceKey) async throws {
        guard states[device] != nil, id == Self.firmwareUpdateId else { throw HeatPumpError.server(L10n.tr("Unknown update")) }
        firmwareCancels += 1
        states[device]?.firmwareApprovedAt = nil
    }

    /// Phase, approval status and files downloaded at `t` (web client numbering).
    private func firmwareProgress(at t: Date, of s: UnitState) -> (phase: Int, approval: Int, files: Int) {
        guard let start = s.firmwareApprovedAt, t >= start else { return (0, 0, 0) }
        let elapsed = t.timeIntervalSince(start)
        switch elapsed {
        case ..<20: return (1, 3, 0)
        case ..<80: return (2, 3, min(Self.firmwareFiles, Int((elapsed - 20) / 15)))
        case ..<100: return (6, 3, Self.firmwareFiles)
        case ..<120: return (7, 3, Self.firmwareFiles)
        default: return (4, 3, Self.firmwareFiles)
        }
    }

    private func firmware(at t: Date, of s: UnitState) -> FirmwareInfo {
        let done = firmwareProgress(at: t, of: s).phase == 4
        return FirmwareInfo(
            deployment: done ? nil : "4711", updateAborted: false, adaptorType: 4, appVersion: done ? 35000 : 34000,
            adapterStatus: "NORMAL", accessLevel: FirmwareInfo.ownerAccessLevel)
    }

    // MARK: Simulation

    /// Lifetime energy counter: the integral of 0.0175 kWh per hour and degree below 17 °C
    /// (same model as `fetchEnergy`), in 0.1 kWh steps like the real counter.
    static func counterKWh(at date: Date, scale: Double) -> Double {
        scale == 1 ? counterKWh(at: date) : ((counterKWh(at: date) - 1000) * scale * 10).rounded(.down) / 10 + 500
    }

    static func counterKWh(at date: Date) -> Double {
        let anchor = 1_767_225_600.0  // 2026-01-01T00:00:00Z
        let h = (date.timeIntervalSince1970 - anchor) / 3600
        // `outdoorTemperature` uses hours since 1970; the weather term must use the same phase
        // (the anchor is not a multiple of 216 h), or the counter drifts from the daily kWh.
        let absolute = date.timeIntervalSince1970 / 3600
        let k = 0.0175
        // 17 - outdoor = 21 - 4 sin(2π(h-8)/24) - 5 sin(2π·absolute/216)
        let integral =
            21 * h + 4 * 24 / (2 * .pi) * cos(2 * .pi * (h - 8) / 24) + 5 * 216 / (2 * .pi) * cos(2 * .pi * absolute / 216)
        return ((1000 + k * integral) * 10).rounded(.down) / 10
    }

    /// Winter outdoor temperature: −4 °C mean, ±4 °C daily swing (warmest 14:00), slow weather swing.
    static func outdoorTemperature(at date: Date) -> Double {
        let hours = date.timeIntervalSince1970 / 3600
        let daily = 4 * sin(2 * .pi * (hours - 8) / 24)
        let weather = 5 * sin(2 * .pi * hours / (24 * 9))
        return -4 + daily + weather
    }

    private func roomTemperature(at date: Date, outdoor: Double, of s: UnitState) -> Double {
        let hours = date.timeIntervalSince1970 / 3600
        let ripple = 0.3 * sin(2 * .pi * hours / 1.7)
        let value = s.power && (s.mode == .heat || s.mode == .auto) ? s.setTemperature - 0.3 + ripple : 16 + 0.1 * outdoor
        return (value * 2).rounded() / 2
    }
}
