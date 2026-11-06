import Foundation
import Synchronization

/// Errors surfaced by backends and the service. `errorDescription` is display text (via `L10n`)
/// that names the service as `HeatPumpError.serviceName`.
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
    /// The service still answers 401 after a fresh login.
    case unauthorized
    /// Earlier login was refused; network calls stay stopped until new credentials are saved.
    case credentialsRejected
    case writeTooSoon(nextAllowed: Date)
    /// An optional endpoint (frost protection, holiday mode, weekly timer) refused this account
    /// (HTTP 401/403) although the session works for everything else. Never triggers a new login.
    case endpointRefused(status: Int)

    public var errorDescription: String? {
        let serviceName = Self.serviceName
        return switch self {
        case .missingCredentials:
            L10n.format("No %@ login. Enter your email and password in the app.", serviceName)
        case .invalidCredentials(let detail):
            detail.map { L10n.format("%@ did not accept the login (%@).", serviceName, $0) } ?? L10n.format("%@ did not accept the login.", serviceName)
        case .loginThrottled(let until):
            until.map { L10n.format("%@ is temporarily blocking login (too many attempts) until %@.", serviceName, Display.time($0)) }
                ?? L10n.format("%@ is temporarily blocking login (too many attempts).", serviceName)
        case .rateLimited(let until):
            L10n.format("%@ has temporarily stopped accepting requests (too much traffic) until %@.", serviceName, Display.dateTime(until))
        case .http(let status):
            L10n.format("%@ answered with HTTP error %lld.", serviceName, status)
        case .network(let detail):
            L10n.format("Network error: %@", detail)
        case .decoding(let detail):
            L10n.format("Could not interpret the answer from %@: %@", serviceName, detail)
        case .deviceNotFound:
            L10n.tr("No heat pump found on the account.")
        case .server(let detail):
            L10n.format("%@ rejected the request: %@", serviceName, detail)
        case .validation(let detail):
            detail
        case .changeBudgetExceeded(let next):
            L10n.format(
                "Too many changes in the last hour (max %lld). The next change is allowed after %@.", ChangeBudget.maxChangesPerHour,
                Display.time(next))
        case .blocked(let until):
            L10n.format("Network calls are stopped until %@ because %@ has limited the traffic.", Display.dateTime(until), serviceName)
        case .rejectedByUser:
            L10n.tr("The change was rejected by the user.")
        case .unauthorized:
            L10n.format("%@ refuses access even after a new login. Fetching is paused for an hour.", serviceName)
        case .credentialsRejected:
            L10n.format(
                "%@ did not accept the email or password. Update the login in Settings. The app does not try again until you have done so, so the account is not locked.",
                serviceName)
        case .writeTooSoon(let next):
            L10n.format("Another change was just sent. Try again after %@.", Display.time(next))
        case .endpointRefused(let status):
            L10n.format("%@ did not allow this request for the account (HTTP %lld).", serviceName, status)
        }
    }
}

extension HeatPumpError {
    private static let name = Mutex("")

    /// The service these error texts name. Errors are created far from the service that knows its
    /// integration (backends, the store) and their text is read wherever they are caught, so the
    /// name is the process's: `HeatPumpService.init` sets it to its integration's `displayName`.
    /// One integration per process; empty until a service exists.
    public static var serviceName: String {
        get { name.withLock { $0 } }
        set { name.withLock { $0 = newValue } }
    }
}

extension HeatPumpError {
    /// The service refused the e-mail/password (retrying would risk an account-wide login throttle).
    public var isCredentialProblem: Bool {
        if case .invalidCredentials = self { return true }
        return self == .credentialsRejected
    }
}

extension HeatPumpError {
    /// What a call to a capability the connection does not have throws.
    public static var notSupported: HeatPumpError { .validation(L10n.tr("Not supported by this connection.")) }
}
