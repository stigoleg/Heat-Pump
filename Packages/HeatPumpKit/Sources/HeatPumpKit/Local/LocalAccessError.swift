import Foundation

/// Errors from the local Wi-Fi adapter. `errorDescription` is display text (via `L10n`).
public enum LocalAccessError: Error, Sendable, Equatable, LocalizedError {
    case notEnabled
    case missingHost
    case invalidHost(String)
    case http(status: Int)
    case network(String)
    case badResponse(String)
    case noFrames
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .notEnabled: L10n.tr("Local connection is turned off.")
        case .missingHost: L10n.tr("No IP address has been entered for the Wi-Fi adapter.")
        case .invalidHost(let host): L10n.format("“%@” is not a valid IP address on the home network (for example 192.168.1.50).", host)
        case .http(let status): L10n.format("The Wi-Fi adapter answered with HTTP error %lld.", status)
        case .network(let detail): L10n.format("Could not reach the Wi-Fi adapter: %@", detail)
        case .badResponse(let detail): L10n.format("The answer from the Wi-Fi adapter could not be read: %@", detail)
        case .noFrames: L10n.tr("The Wi-Fi adapter answered, but without readings.")
        case .notConfigured: L10n.tr("Local access is not available in this program.")
        }
    }
}
