import Foundation
import HeatPumpKit

/// Mitsubishi Electric air-to-air heat pumps through MELCloud Classic (`app.melcloud.com`), plus
/// read-only local readings from the unit's Wi-Fi adapter.
public struct MELCloudIntegration: Integration {
    public init() {}

    /// Persisted with error-log entries and away settings; never changes.
    public static let sourceTag = "melcloud"
    /// `Integration.id`; the integration part of every MELCloud `DeviceKey`. Persisted.
    public static let id = "melcloud-classic"

    public var id: String { Self.id }
    public var displayName: String { "MELCloud" }
    public var vendorName: String { "Mitsubishi Electric" }
    public var brandName: String { "Mitsubishi" }
    public var modelName: String? { "Mitsubishi Electric MSZ-RW25VG (MSZ-RW25VG-SC1)" }
    public var unitDescription: String { "Mitsubishi MSZ-RW25VG wall heat pump (MELCloud Classic)" }
    public var sourceTag: String { Self.sourceTag }
    public var errorCodes: any ErrorCodeExplaining { MELCloudErrorCodes() }
    public var healthChecks: any HealthCheckProviding { MELCloudHealthChecks() }
    /// The MSZ-RW owner manual's filters (air filter every 2 weeks, overdue after 30 days; the
    /// deodorizing and V-blocking filters every 3 months), plus dealer service and anything else.
    public var maintenanceTasks: [MaintenanceTask] {
        [
            MaintenanceTask(kind: .airFilter, intervalDays: 14, overdueAfterDays: MELCloudHealthChecks.airFilterWarningDays),
            MaintenanceTask(kind: .deodorizingFilter, intervalDays: 90),
            MaintenanceTask(kind: .vBlockingFilter, intervalDays: 90),
            MaintenanceTask(kind: .professionalService),
            MaintenanceTask(kind: .other),
        ]
    }
    public var knowledge: KnowledgeSource {
        KnowledgeSource(
            names: ["unit-profile", "maintenance", "error-codes", "when-to-call-dealer", "safe-operating-guidance"],
            documents: KnowledgeContent.documents)
    }

    public var credentialFields: [CredentialField] {
        [CredentialField(id: "email", kind: .email, isSecret: false), CredentialField(id: "password", kind: .password, isSecret: true)]
    }

    /// The keychain items earlier versions created, kept as they are (moving them would lose the
    /// access shared by the app and the helper): e-mail and password as one JSON item
    /// `melcloud-credentials`, the session in `melcloud-context-key`. Dev only: `MELCLOUD_EMAIL`
    /// and `MELCLOUD_PASSWORD` replace them when both are set.
    public var credentialMapping: CredentialMapping { Self.credentialMapping }

    public static let credentialMapping = CredentialMapping(
        integrationId: id, serviceName: "MELCloud",
        items: [CredentialMapping.Item(account: "melcloud-credentials", fields: ["email", "password"])],
        identityField: "email", sessionAccount: "melcloud-context-key",
        environment: ["email": "MELCLOUD_EMAIL", "password": "MELCLOUD_PASSWORD"])

    /// One fetch per minute across app and helper, reports hourly, 12 writes per rolling hour.
    public var rateLimitPolicy: RateLimitPolicy { .standard }

    /// Needs `context.credentials`; the device object is shared through `context.store`.
    public func makeConnection(_ context: IntegrationContext) throws -> any DeviceConnection {
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
