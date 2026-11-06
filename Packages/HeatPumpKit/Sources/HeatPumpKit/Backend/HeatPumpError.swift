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

extension HeatPumpError {
    /// What a call to a capability the connection does not have throws.
    public static var notSupported: HeatPumpError { .validation(L10n.tr("Not supported by this connection.")) }
}
