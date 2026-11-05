import Foundation

/// Deterministic backend with realistic Norwegian winter data. Selected with
/// `VARMEPUMPE_BACKEND=mock`. All history is a pure function of time, so repeated
/// runs and separate processes see the same past; only writes are per-process.
public actor MockBackend: HeatPumpBackend {
    public nonisolated let identifier = "mock"

    public static let deviceId = 100_001
    public static let buildingId = 200_001

    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private var power = true
    private var mode: OperationMode = .heat
    private var setTemperature = 21.0
    private var fanSpeed = 0
    private var vaneVertical: VaneVertical = .auto
    private var vaneHorizontal: VaneHorizontal = .position3
    public private(set) var appliedChanges: [ChangeSet] = []

    public init(timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        self.timeZone = timeZone
    }

    public func login() async throws {}

    public func listDevices() async throws -> [DeviceSummary] {
        [DeviceSummary(deviceId: Self.deviceId, buildingId: Self.buildingId, name: "Stue (simulert)")]
    }

    public func fetchState(deviceId: Int) async throws -> DeviceState {
        guard deviceId == Self.deviceId else { throw HeatPumpError.deviceNotFound }
        return state(at: now())
    }

    /// Simulated state at any time (also used to seed demo history).
    public func state(at t: Date) -> DeviceState {
        let outdoor = Self.outdoorTemperature(at: t)
        return DeviceState(
            deviceId: Self.deviceId, buildingId: Self.buildingId, name: "Stue (simulert)",
            serialNumber: "MOCK0000000", macAddress: "00:00:5e:00:53:01",
            power: power, mode: mode, setTemperature: setTemperature,
            roomTemperature: roomTemperature(at: t, outdoor: outdoor),
            outdoorTemperature: (outdoor * 2).rounded() / 2,
            fanSpeed: fanSpeed, actualFanSpeed: power ? 2 : 0, numberOfFanSpeeds: 5, hasAutomaticFanSpeed: true,
            vaneVertical: vaneVertical, vaneHorizontal: vaneHorizontal,
            hasError: false, errorCode: 8000, offline: false,
            lastCommunication: t.addingTimeInterval(-40), nextCommunication: t.addingTimeInterval(20),
            wifiSignal: -62, hasPendingCommand: false,
            firmware: FirmwareInfo(deployment: nil, updateAborted: false, adaptorType: 4),
            lastServiceDate: nil,
            energy: EnergyCounters(
                currentConsumedKWh: Self.counterKWh(at: t), totalHeatingKWh: 1180.2, totalCoolingKWh: 54.3),
            limits: TemperatureLimits(minHeat: 10, maxHeat: 31, minCoolDry: 16, maxCoolDry: 31, minAuto: 16, maxAuto: 31),
            temperatureIncrement: 0.5, fetchedAt: t)
    }

    @discardableResult
    public func apply(_ changes: ChangeSet) async throws -> DeviceState? {
        guard changes.deviceId == Self.deviceId else { throw HeatPumpError.deviceNotFound }
        appliedChanges.append(changes)
        if let value = changes.power { power = value }
        if let value = changes.mode { mode = value }
        if let value = changes.setTemperature { setTemperature = value }
        if let value = changes.fanSpeed { fanSpeed = value }
        if let value = changes.vaneVertical { vaneVertical = value }
        if let value = changes.vaneHorizontal { vaneHorizontal = value }
        var state = try await fetchState(deviceId: changes.deviceId)
        state.hasPendingCommand = true
        return state
    }

    /// One simulated error every 17 days at 03:12 UTC, anchored to a fixed epoch so entries are stable.
    public func fetchErrorLog(deviceId: Int, range: DateInterval) async throws -> [ErrorLogEntry] {
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
                        deviceId: Self.deviceId, start: start, end: start.addingTimeInterval(240),
                        message: "Kommunikasjonsfeil mellom innedel og utedel (simulert)", code: nil, source: "melcloud"))
            }
            k += 1
        }
        return entries
    }

    public func fetchTemperatureLog(deviceId: Int, range: DateInterval) async throws -> [TemperaturePoint] {
        var points: [TemperaturePoint] = []
        let step: TimeInterval = 3600
        var t = (range.start.timeIntervalSince1970 / step).rounded(.up) * step
        let end = min(range.end, now()).timeIntervalSince1970
        while t <= end {
            let date = Date(timeIntervalSince1970: t)
            let outdoor = Self.outdoorTemperature(at: date)
            points.append(
                TemperaturePoint(
                    timestamp: date, room: roomTemperature(at: date, outdoor: outdoor), set: 21,
                    outdoor: (outdoor * 2).rounded() / 2))
            t += step
        }
        return points
    }

    public func fetchEnergy(deviceId: Int, range: DateInterval) async throws -> [EnergyDay] {
        let calendar = WireDate.calendar(timeZone)
        var day = calendar.startOfDay(for: range.start)
        let last = calendar.startOfDay(for: min(range.end, now()))
        var days: [EnergyDay] = []
        while day <= last {
            let meanOutdoor = stride(from: 0.0, to: 24, by: 1).map {
                Self.outdoorTemperature(at: day.addingTimeInterval($0 * 3600 + 1800))
            }.reduce(0, +) / 24
            let degreeDays = max(0, 17 - meanOutdoor)
            let kWh = (max(0.4, degreeDays * 0.42) * 10).rounded() / 10
            days.append(EnergyDay(day: WireDate.day(day, timeZone: timeZone), totalKWh: kWh, heatingKWh: kWh, coolingKWh: 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    public func fetchSignalStrength(deviceId: Int) async throws -> Int? { -62 }

    // MARK: Simulation

    /// Lifetime energy counter: the integral of 0.0175 kWh per hour and degree below 17 °C
    /// (same model as `fetchEnergy`), in 0.1 kWh steps like the real counter.
    static func counterKWh(at date: Date) -> Double {
        let anchor = 1_767_225_600.0  // 2026-01-01T00:00:00Z
        let h = (date.timeIntervalSince1970 - anchor) / 3600
        let k = 0.0175
        // 17 - outdoor = 21 - 4 sin(2π(h-8)/24) - 5 sin(2πh/216)
        let integral = 21 * h + 4 * 24 / (2 * .pi) * cos(2 * .pi * (h - 8) / 24) + 5 * 216 / (2 * .pi) * cos(2 * .pi * h / 216)
        return ((1000 + k * integral) * 10).rounded(.down) / 10
    }

    /// Winter outdoor temperature: −4 °C mean, ±4 °C daily swing (warmest 14:00), slow weather swing.
    static func outdoorTemperature(at date: Date) -> Double {
        let hours = date.timeIntervalSince1970 / 3600
        let daily = 4 * sin(2 * .pi * (hours - 8) / 24)
        let weather = 5 * sin(2 * .pi * hours / (24 * 9))
        return -4 + daily + weather
    }

    private func roomTemperature(at date: Date, outdoor: Double) -> Double {
        let hours = date.timeIntervalSince1970 / 3600
        let ripple = 0.3 * sin(2 * .pi * hours / 1.7)
        let value = power && (mode == .heat || mode == .auto) ? setTemperature - 0.3 + ripple : 16 + 0.1 * outdoor
        return (value * 2).rounded() / 2
    }
}
