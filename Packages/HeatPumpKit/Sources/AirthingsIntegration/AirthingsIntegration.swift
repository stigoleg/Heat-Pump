import Foundation
import HeatPumpKit

/// Airthings air quality sensors (radon, CO2, humidity, …) through the Consumer API with the
/// user's own API client (client ID and secret from Airthings' developer dashboard). One device
/// per sensor; hubs relay data and are not listed. Read-only: the Renew purifier's control
/// endpoint is not used.
public struct AirthingsIntegration: Integration {
    public init() {}

    /// `Integration.id`; the integration part of every device's `DeviceKey` (`airthings:<serial number>`).
    /// Persisted: never change it once released.
    public static let id = "airthings"
    static let displayName = "Airthings"
    /// Device metadata: the device type (`WAVE_PLUS`, `VIEW_PLUS`, …) and the home it is filed under.
    static let typeKey = "type"
    static let homeKey = "home"

    public var id: String { Self.id }
    /// The service name in every text ("Airthings did not accept the login.").
    public var displayName: String { Self.displayName }
    public var vendorName: String { "Airthings" }
    public var unitDescription: String { "Airthings air quality sensor (radon, CO2, humidity and more; read-only)" }

    /// The API client's values; stored as `airthings/clientId` and `airthings/clientSecret`.
    public var credentialFields: [CredentialField] {
        [
            CredentialField(id: "clientId", kind: .clientId, isSecret: false),
            // The help goes under the last field, so it reads as being about both.
            CredentialField(
                id: "clientSecret", kind: .clientSecret, isSecret: true, helpURL: AirthingsAPI.dashboardURL,
                help: L10n.format(
                    "Sign in at the link below with your %@ account, open My Applications and create an application (client credentials). Copy its client ID and secret here.",
                    Self.displayName)),
        ]
    }

    /// The hourly budget per client is not documented (120 is assumed; the answers' headers tell).
    /// Every sensor's newest values in one request at most every 5 minutes (12 an hour, as often as
    /// a hub reports), the history per sensor hourly and the thresholds per sensor daily, the
    /// device list at sign-in and daily: with 5 sensors about 17 requests an hour. No writes.
    public var rateLimitPolicy: RateLimitPolicy {
        RateLimitPolicy(
            maxAge: 300, minRefreshInterval: 300, reportInterval: 3600, defaultLoginBlock: 30 * 60, unauthorizedBlock: 3600,
            maxWriteWait: 0, writeBaseMaxAge: 0, changeBudget: ChangeBudgetPolicy(maxChangesPerHour: 0, window: 3600, minSpacing: 0))
    }

    /// Sensors have no error codes.
    public var errorCodes: any ErrorCodeExplaining { NoErrorCodes() }

    public var knowledge: KnowledgeSource {
        KnowledgeSource(names: ["air-quality"], documents: KnowledgeContent.documents)
    }

    /// Reads the credentials lazily, when a token is requested.
    public func makeConnection(_ context: IntegrationContext) throws -> any DeviceConnection {
        guard let credentials = context.credentials else { throw HeatPumpError.missingCredentials }
        let mapping = credentialMapping
        return AirthingsConnection(credentials: { try? credentials.loadValues(for: mapping) }, now: context.now)
    }
}
