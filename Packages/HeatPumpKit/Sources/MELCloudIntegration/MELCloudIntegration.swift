import Foundation
import HeatPumpKit

/// Mitsubishi Electric air-to-air heat pumps through MELCloud Classic (`app.melcloud.com`), plus
/// read-only local readings from the unit's Wi-Fi adapter.
public struct MELCloudIntegration: Integration {
    public init() {}

    /// Persisted with error-log entries and away settings; never changes.
    public static let sourceTag = "melcloud"

    public var id: String { "melcloud-classic" }
    public var displayName: String { "MELCloud" }
    public var vendorName: String { "Mitsubishi Electric" }
    public var brandName: String { "Mitsubishi" }
    public var modelName: String? { "Mitsubishi Electric MSZ-RW25VG (MSZ-RW25VG-SC1)" }
    public var unitDescription: String { "Mitsubishi MSZ-RW25VG wall heat pump (MELCloud Classic)" }
    public var sourceTag: String { Self.sourceTag }
    public var errorCodes: any ErrorCodeExplaining { MELCloudErrorCodes() }
    public var healthChecks: any HealthCheckProviding { MELCloudHealthChecks() }
    /// The MSZ-RW owner manual's filters, plus dealer service and anything else.
    public var maintenanceKinds: [MaintenanceKind] { MaintenanceKind.allCases }
    public var knowledge: KnowledgeSource {
        KnowledgeSource(
            names: ["unit-profile", "maintenance", "error-codes", "when-to-call-dealer", "safe-operating-guidance"],
            documents: KnowledgeContent.documents)
    }

    public var credentialFields: [CredentialField] {
        [CredentialField(id: "email", kind: .email, isSecret: false), CredentialField(id: "password", kind: .password, isSecret: true)]
    }

    /// One fetch per minute across app and helper, reports hourly, 12 writes per rolling hour.
    public var rateLimitPolicy: RateLimitPolicy { .standard }

    /// Needs `context.credentials`; the device object is shared through `context.store`.
    public func makeConnection(_ context: IntegrationContext) throws -> any DeviceConnection & ThermostatDriver {
        guard let credentials = context.credentials else { throw HeatPumpError.missingCredentials }
        return MELCloudClassicBackend(credentials: credentials, rawCache: context.store)
    }
}

extension LocalAccess {
    /// The real Wi-Fi adapter over HTTP on the home network.
    public static let network = LocalAccess(
        makeClient: { try LocalSmartClient(host: $0) }, scanner: ARPScanner(),
        currentSubnets: { ARPScanner.localSubnets().map(\.base) })
}
