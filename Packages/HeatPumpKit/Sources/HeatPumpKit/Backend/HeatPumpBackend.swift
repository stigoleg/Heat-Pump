import Foundation

/// Errors surfaced by backends and the service. `errorDescription` is Norwegian display text.
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
            "Mangler innlogging til MELCloud. Legg inn e-post og passord i appen."
        case .invalidCredentials(let detail):
            "MELCloud godtok ikke innloggingen" + (detail.map { " (\($0))" } ?? "") + "."
        case .loginThrottled(let until):
            "MELCloud blokkerer innlogging midlertidig (for mange forsøk)"
                + (until.map { " til \(Norwegian.time($0))" } ?? "") + "."
        case .rateLimited(let until):
            "MELCloud har midlertidig stengt for flere forespørsler (for mye trafikk) til \(Norwegian.dateTime(until))."
        case .http(let status):
            "MELCloud svarte med HTTP-feil \(status)."
        case .network(let detail):
            "Nettverksfeil: \(detail)"
        case .decoding(let detail):
            "Kunne ikke tolke svaret fra MELCloud: \(detail)"
        case .deviceNotFound:
            "Fant ingen varmepumpe på kontoen."
        case .server(let detail):
            "MELCloud avviste forespørselen: \(detail)"
        case .validation(let detail):
            detail
        case .changeBudgetExceeded(let next):
            "For mange endringer siste time (maks \(ChangeBudget.maxChangesPerHour)). Neste endring tillatt etter \(Norwegian.time(next))."
        case .blocked(let until):
            "Nettverkskall er stoppet til \(Norwegian.dateTime(until)) fordi MELCloud har begrenset trafikken."
        case .rejectedByUser:
            "Endringen ble avvist av brukeren."
        case .unauthorized:
            "MELCloud avviser tilgangen selv etter ny innlogging. Henting er satt på pause i en time."
        case .credentialsRejected:
            "MELCloud godtok ikke e-post eller passord. Oppdater innloggingen i Innstillinger. Appen prøver ikke igjen før du har gjort det, så kontoen ikke blir sperret."
        case .writeTooSoon(let next):
            "En annen endring ble nettopp sendt. Prøv igjen etter \(Norwegian.time(next))."
        case .endpointRefused(let status):
            "MELCloud tillot ikke denne forespørselen for kontoen (HTTP \(status))."
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
    /// Norwegian reason the backend would refuse `changes` without contacting the unit, or nil.
    /// With `requireBase` a missing device object counts as a reason.
    func localWriteProblem(_ changes: ChangeSet, requireBase: Bool) async -> String?
    /// Frost protection and holiday mode for the device (two reads).
    func fetchAwaySettings(deviceId: Int) async throws -> AwaySettings
    /// Writes frost protection or holiday mode.
    func applyAway(_ change: AwayChange, deviceId: Int) async throws
    /// The weekly timer (read-only).
    func fetchWeeklyTimer(deviceId: Int) async throws -> WeeklyTimer
}

extension HeatPumpBackend {
    public func resetSession() async {}
    public var requiresFreshStateForWrites: Bool { false }
    public func writeBaseFetchedAt(deviceId: Int) async -> Date? { nil }
    public func localWriteProblem(_ changes: ChangeSet, requireBase: Bool) async -> String? { nil }
    public func fetchAwaySettings(deviceId: Int) async throws -> AwaySettings { throw HeatPumpError.validation(unsupported) }
    public func applyAway(_ change: AwayChange, deviceId: Int) async throws { throw HeatPumpError.validation(unsupported) }
    public func fetchWeeklyTimer(deviceId: Int) async throws -> WeeklyTimer { throw HeatPumpError.validation(unsupported) }
    private var unsupported: String { "Støttes ikke av denne tilkoblingen." }
}
