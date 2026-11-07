import Foundation

// A connection to a vendor's cloud or local API, split by capability. The service holds
// `any DeviceConnection & ThermostatDriver` and reaches everything else with `as? any …`; a
// connection without a capability makes the service throw `HeatPumpError.notSupported`.
//
// Implementations keep vendor-specific types internal; everything crossing these protocols is
// vendor-neutral (devices are named by `DeviceKey`; a driver maps it to its native ids), except
// the stored listing (`RawDevice.listing`) and `TimerEvent.raw`, which are opaque payloads only
// the driver that wrote them interprets. Rate limiting and caching live in `HeatPumpService`,
// not in drivers.

/// Signing in and finding the devices on the account.
public protocol DeviceConnection: Sendable {
    /// Short identifier, e.g. `melcloud-classic` or `mock`.
    var identifier: String { get }
    func login() async throws
    func listDevices() async throws -> [DeviceSummary]
    /// Forgets any in-memory session and cached listing (after new credentials are saved).
    func resetSession() async
    /// What the connection can do; by default derived from its conformances.
    var capabilities: Set<Capability> { get }
    /// What one of its devices can do (e.g. live power only where the meter has a real-time
    /// reader); `capabilities` by default.
    func capabilities(of device: DeviceSummary) -> Set<Capability>
    /// The account's devices from a listing the connection fetched for its own needs in the last
    /// hour, without a request (the hub's daily discovery uses it); nil when it has none.
    func recentListing() async -> [DeviceSummary]?
}

extension DeviceConnection {
    public func resetSession() async {}
    public var capabilities: Set<Capability> { Capability.derived(from: self) }
    public func capabilities(of device: DeviceSummary) -> Set<Capability> { capabilities }
    public func recentListing() async -> [DeviceSummary]? { nil }
}

/// Reading and changing power, mode, setpoint, fan and vanes.
public protocol ThermostatDriver: Sendable {
    func fetchState(device: DeviceKey) async throws -> DeviceState
    /// Sends the changes. Returns the device state the backend reported back (MELCloud's
    /// `SetAta` answers with the full device object), or nil when it does not report one.
    func apply(_ changes: ChangeSet) async throws -> DeviceState?
    /// True when `apply` needs a recent full device object and therefore a fresh read before a
    /// write if `writeBaseFetchedAt` is too old.
    var requiresFreshStateForWrites: Bool { get }
    /// When the device object a write would be based on was fetched (nil when unknown).
    func writeBaseFetchedAt(device: DeviceKey) async -> Date?
    /// Reason the backend would refuse `changes` without contacting the unit, or nil.
    /// With `requireBase` a missing device object counts as a reason.
    func localWriteProblem(_ changes: ChangeSet, requireBase: Bool) async -> String?
    /// Why a write is refused while the unit's mode is unknown, or nil when such writes are fine.
    var unknownModeProblem: String? { get }
}

extension ThermostatDriver {
    public var requiresFreshStateForWrites: Bool { false }
    public func writeBaseFetchedAt(device: DeviceKey) async -> Date? { nil }
    public func localWriteProblem(_ changes: ChangeSet, requireBase: Bool) async -> String? { nil }
    public var unknownModeProblem: String? { nil }
}

public protocol ErrorLogReporting: Sendable {
    func fetchErrorLog(device: DeviceKey, range: DateInterval) async throws -> [ErrorLogEntry]
}

public protocol TemperatureLogReporting: Sendable {
    func fetchTemperatureLog(device: DeviceKey, range: DateInterval) async throws -> [TemperaturePoint]
    /// Longest range one request may ask for, in days.
    var maxTemperatureLogDays: Int { get }
}

extension TemperatureLogReporting {
    public var maxTemperatureLogDays: Int { 7 }
}

public protocol EnergyReporting: Sendable {
    func fetchEnergy(device: DeviceKey, range: DateInterval) async throws -> [EnergyDay]
    /// Longest range one request may ask for and still be answered per day, in days.
    var maxEnergyReportDays: Int { get }
}

extension EnergyReporting {
    public var maxEnergyReportDays: Int { 28 }
}

public protocol SignalStrengthReporting: Sendable {
    func fetchSignalStrength(device: DeviceKey) async throws -> Int?
}

/// Frost protection and holiday mode.
public protocol AwayModesDriver: Sendable {
    /// Frost protection and holiday mode for the device (two reads).
    func fetchAwaySettings(device: DeviceKey) async throws -> AwaySettings
    /// Writes frost protection or holiday mode.
    func applyAway(_ change: AwayChange, device: DeviceKey) async throws
    /// The copy a stored device listing (`RawDevice.listing`) carries, read without the network.
    func awaySettings(fromStoredListing listing: JSONValue?) -> AwaySettings?
}

extension AwayModesDriver {
    public func awaySettings(fromStoredListing listing: JSONValue?) -> AwaySettings? { nil }
}

/// The weekly timer.
public protocol WeeklyScheduleDriver: Sendable {
    /// The weekly timer with all seasons.
    func fetchWeeklyTimer(device: DeviceKey) async throws -> WeeklyTimer
    /// Writes the whole weekly timer (every season) and whether it is on.
    func saveWeeklyTimer(_ timer: WeeklyTimer, device: DeviceKey) async throws
    /// How this connection reads the plans it returns (pure; safe to use from the UI).
    var weeklyTimerFormat: any WeeklyTimerFormat { get }
}

/// The vendor's view of a weekly plan: which events are untouched and what would be sent.
public protocol WeeklyTimerFormat: Sendable {
    /// True when `event` is exactly as read from the unit (not made or changed in the app).
    func isAsRead(_ event: TimerEvent) -> Bool
    /// Day, time and the settings as they would be sent, as one comparable string.
    func contentKey(_ event: TimerEvent) -> String
    /// The plan as the unit will report it after `timer` was saved for `device`.
    func savedForm(of timer: WeeklyTimer, device: DeviceKey) -> WeeklyTimer
}

/// Firmware updates of the unit or its adapter.
public protocol FirmwareDriver: Sendable {
    /// The firmware update entries for the device.
    func firmwareUpdates(device: DeviceKey) async throws -> [FirmwareUpdateStatus]
    /// Starts (approves) the firmware update `id`. Cannot be rolled back.
    func approveFirmwareUpdate(id: Int, device: DeviceKey) async throws
    /// Cancels the firmware update `id` while it has not been installed.
    func cancelFirmwareUpdate(id: Int, device: DeviceKey) async throws
}

/// An energy meter: the hours of use its service reports. Not real time: the newest hours arrive
/// late, so the service asks at most hourly.
public protocol EnergyMeterDriver: DeviceConnection {
    /// The last `lastHours` finished hours of `device`; hours the service has not finished yet are
    /// left out.
    func fetchHours(device: DeviceKey, lastHours: Int) async throws -> [HouseHour]
}

/// Power right now from a meter's live stream. The driver owns the connection: it reconnects by
/// itself within its integration's limits and reports why when it stops for good.
public protocol LivePowerDriver: Sendable {
    /// Readings and state changes for `device` until the stream is cancelled (which closes the
    /// connection when no other stream needs it).
    func liveReadings(device: DeviceKey) -> AsyncStream<LivePowerEvent>
}

/// An air quality sensor (radon, CO2, humidity, …): readings only. Sensors report every few
/// minutes at best (radon hourly), so the service asks for every sensor of the integration in one
/// request at most every `RateLimitPolicy.minRefreshInterval`.
public protocol AirQualityDriver: DeviceConnection {
    /// The newest readings of `devices` (at most `maxDevicesPerRequest`) in one request. Devices the
    /// vendor has no reading for are left out.
    func fetchLatest(devices: [DeviceKey]) async throws -> [AirQualityReading]
    /// How many devices one `fetchLatest` may ask for.
    var maxDevicesPerRequest: Int { get }
    /// The levels the vendor rates `device`'s values by (the user's own settings or the vendor's
    /// defaults), or nil when it has none (the core's `AirQualityThresholds.standard` apply).
    func fetchThresholds(device: DeviceKey) async throws -> AirQualityThresholds?
}

extension AirQualityDriver {
    public var maxDevicesPerRequest: Int { 50 }
    public func fetchThresholds(device: DeviceKey) async throws -> AirQualityThresholds? { nil }
}

/// An air quality sensor's history as hourly averages.
public protocol AirQualityLogReporting: Sendable {
    /// Hourly averages of `device` for the hours that start in `range`, oldest first. The hour
    /// still running may be a partial average.
    func fetchHourly(device: DeviceKey, range: DateInterval) async throws -> [AirQualityHour]
    /// Longest range one request may ask for, in days.
    var maxAirQualityLogDays: Int { get }
}

extension AirQualityLogReporting {
    public var maxAirQualityLogDays: Int { 30 }
}

/// What the vendor's answers say about its request budget (rate limit headers): the service stops
/// asking before the budget runs out instead of waiting for a refusal.
public protocol RequestBudgetReporting: Sendable {
    /// The newest budget the vendor reported, or nil when it reported none.
    func requestBudget() async -> RequestBudget?
}

/// A vendor's request budget for the current window.
public struct RequestBudget: Sendable, Equatable {
    public var limit: Int
    public var remaining: Int
    /// When the window has room again.
    public var resetsAt: Date

    public init(limit: Int, remaining: Int, resetsAt: Date) {
        self.limit = limit
        self.remaining = remaining
        self.resetsAt = resetsAt
    }
}

/// Where the unit is, from the stored device listing.
public protocol DeviceLocationReporting: Sendable {
    func location(fromStoredListing listing: JSONValue?) -> (latitude: Double, longitude: Double)?
}

/// The unit's hardware (MAC) address, from the stored device listing. Used to find the unit on
/// the home network; never shown.
public protocol HardwareAddressReporting: Sendable {
    func hardwareAddress(fromStoredListing listing: JSONValue?) -> String?
}

/// Demo data: lets the service fill an empty database with simulated history on first launch.
public protocol DemoDataSeeding: TemperatureLogReporting {
    /// Every simulated device; the first one has the simulated Wi-Fi adapter.
    var demoDevices: [DeviceKey] { get }
    /// Simulated state of `device` at any time.
    func demoState(at date: Date, device: DeviceKey) async -> DeviceState
    /// Address of the first device's simulated Wi-Fi adapter.
    var demoLocalHost: String { get }
    /// Simulated local readings every minute from `from` to `to`.
    func demoLocalSamples(from: Date, to: Date, shortCycling: Bool) -> [LocalSample]
}

/// Demo data for a simulated air quality sensor.
public protocol AirQualityDemoSeeding: Sendable {
    /// Simulated hourly averages from `from` to `to`.
    func demoHours(device: DeviceKey, from: Date, to: Date) -> [AirQualityHour]
}

/// The capabilities every cloud heat pump connection had before they were split (eases test doubles).
public typealias HeatPumpBackend = DeviceConnection & ThermostatDriver & ErrorLogReporting & TemperatureLogReporting
    & EnergyReporting & SignalStrengthReporting
