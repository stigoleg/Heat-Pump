import Foundation

/// Errors surfaced by backends and the service. `errorDescription` is display text (via `L10n`).
public enum HeatPumpError: Error, Sendable, Equatable, LocalizedError {
    case missingCredentials
    case invalidCredentials(String?)
    case loginThrottled(until: Date?)
    case rateLimited(until: Date)
    case http(status: Int)
    case network(String)
    case decoding(String)
    case deviceNotFound
    case server(String)
    case validation(String)
    case changeBudgetExceeded(nextAllowed: Date)
    case blocked(until: Date)
    case rejectedByUser
    /// MELCloud still answers 401 after a fresh login.
    case unauthorized
    /// Earlier login was refused; network calls stay stopped until new credentials are saved.
    case credentialsRejected
    case writeTooSoon(nextAllowed: Date)
    /// An optional endpoint (frost protection, holiday mode, weekly timer) refused this account
    /// (HTTP 401/403) although the session works for everything else. Never triggers a new login.
    case endpointRefused(status: Int)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            L10n.tr("No MELCloud login. Enter your email and password in the app.")
        case .invalidCredentials(let detail):
            detail.map { L10n.format("MELCloud did not accept the login (%@).", $0) } ?? L10n.tr("MELCloud did not accept the login.")
        case .loginThrottled(let until):
            until.map { L10n.format("MELCloud is temporarily blocking login (too many attempts) until %@.", Display.time($0)) }
                ?? L10n.tr("MELCloud is temporarily blocking login (too many attempts).")
        case .rateLimited(let until):
            L10n.format("MELCloud has temporarily stopped accepting requests (too much traffic) until %@.", Display.dateTime(until))
        case .http(let status):
            L10n.format("MELCloud answered with HTTP error %lld.", status)
        case .network(let detail):
            L10n.format("Network error: %@", detail)
        case .decoding(let detail):
            L10n.format("Could not interpret the answer from MELCloud: %@", detail)
        case .deviceNotFound:
            L10n.tr("No heat pump found on the account.")
        case .server(let detail):
            L10n.format("MELCloud rejected the request: %@", detail)
        case .validation(let detail):
            detail
        case .changeBudgetExceeded(let next):
            L10n.format(
                "Too many changes in the last hour (max %lld). The next change is allowed after %@.", ChangeBudget.maxChangesPerHour,
                Display.time(next))
        case .blocked(let until):
            L10n.format("Network calls are stopped until %@ because MELCloud has limited the traffic.", Display.dateTime(until))
        case .rejectedByUser:
            L10n.tr("The change was rejected by the user.")
        case .unauthorized:
            L10n.tr("MELCloud refuses access even after a new login. Fetching is paused for an hour.")
        case .credentialsRejected:
            L10n.tr("MELCloud did not accept the email or password. Update the login in Settings. The app does not try again until you have done so, so the account is not locked.")
        case .writeTooSoon(let next):
            L10n.format("Another change was just sent. Try again after %@.", Display.time(next))
        case .endpointRefused(let status):
            L10n.format("MELCloud did not allow this request for the account (HTTP %lld).", status)
        }
    }
}

extension HeatPumpError {
    /// MELCloud refused the e-mail/password (retrying would risk an account-wide login throttle).
    public var isCredentialProblem: Bool {
        if case .invalidCredentials = self { return true }
        return self == .credentialsRejected
    }
}

/// A cloud or local API that can read and control one or more heat pumps.
///
/// Implementations keep vendor-specific types internal; everything crossing this
/// boundary is backend-neutral. Rate limiting and caching live in `HeatPumpService`,
/// not in backends.
public protocol HeatPumpBackend: Sendable {
    /// Short identifier, e.g. `melcloud-classic` or `mock`.
    var identifier: String { get }
    func login() async throws
    func listDevices() async throws -> [DeviceSummary]
    func fetchState(deviceId: Int) async throws -> DeviceState
    /// Sends the changes. Returns the device state the backend reported back (MELCloud's
    /// `SetAta` answers with the full device object), or nil when it does not report one.
    func apply(_ changes: ChangeSet) async throws -> DeviceState?
    func fetchErrorLog(deviceId: Int, range: DateInterval) async throws -> [ErrorLogEntry]
    func fetchTemperatureLog(deviceId: Int, range: DateInterval) async throws -> [TemperaturePoint]
    func fetchEnergy(deviceId: Int, range: DateInterval) async throws -> [EnergyDay]
    func fetchSignalStrength(deviceId: Int) async throws -> Int?
    /// Forgets any in-memory session and cached listing (after new credentials are saved).
    func resetSession() async
    /// True when `apply` needs a recent full device object (MELCloud Classic) and therefore a
    /// fresh read before a write if `writeBaseFetchedAt` is too old.
    var requiresFreshStateForWrites: Bool { get }
    /// When the device object a write would be based on was fetched (nil when unknown).
    func writeBaseFetchedAt(deviceId: Int) async -> Date?
    /// Reason the backend would refuse `changes` without contacting the unit, or nil.
    /// With `requireBase` a missing device object counts as a reason.
    func localWriteProblem(_ changes: ChangeSet, requireBase: Bool) async -> String?
    /// Frost protection and holiday mode for the device (two reads).
    func fetchAwaySettings(deviceId: Int) async throws -> AwaySettings
    /// Writes frost protection or holiday mode.
    func applyAway(_ change: AwayChange, deviceId: Int) async throws
    /// The weekly timer with all seasons.
    func fetchWeeklyTimer(deviceId: Int) async throws -> WeeklyTimer
    /// Writes the whole weekly timer (every season) and whether it is on.
    func saveWeeklyTimer(_ timer: WeeklyTimer, deviceId: Int) async throws
    /// MELCloud's firmware update entries for the device (`FirmwareUpdate/List2`).
    func firmwareUpdates(deviceId: Int) async throws -> [FirmwareUpdateStatus]
    /// Starts (approves) the firmware update `id`. Cannot be rolled back.
    func approveFirmwareUpdate(id: Int, deviceId: Int) async throws
    /// Cancels the firmware update `id` while it has not been installed.
    func cancelFirmwareUpdate(id: Int, deviceId: Int) async throws
}

extension HeatPumpBackend {
    public func resetSession() async {}
    public var requiresFreshStateForWrites: Bool { false }
    public func writeBaseFetchedAt(deviceId: Int) async -> Date? { nil }
    public func localWriteProblem(_ changes: ChangeSet, requireBase: Bool) async -> String? { nil }
    public func fetchAwaySettings(deviceId: Int) async throws -> AwaySettings { throw HeatPumpError.validation(unsupported) }
    public func applyAway(_ change: AwayChange, deviceId: Int) async throws { throw HeatPumpError.validation(unsupported) }
    public func fetchWeeklyTimer(deviceId: Int) async throws -> WeeklyTimer { throw HeatPumpError.validation(unsupported) }
    public func saveWeeklyTimer(_ timer: WeeklyTimer, deviceId: Int) async throws { throw HeatPumpError.validation(unsupported) }
    public func firmwareUpdates(deviceId: Int) async throws -> [FirmwareUpdateStatus] { throw HeatPumpError.validation(unsupported) }
    public func approveFirmwareUpdate(id: Int, deviceId: Int) async throws { throw HeatPumpError.validation(unsupported) }
    public func cancelFirmwareUpdate(id: Int, deviceId: Int) async throws { throw HeatPumpError.validation(unsupported) }
    private var unsupported: String { L10n.tr("Not supported by this connection.") }
}
