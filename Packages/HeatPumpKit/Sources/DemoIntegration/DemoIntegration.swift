import Foundation
import HeatPumpKit
import MELCloudIntegration

/// Simulated data for demo mode and screenshots (`VARMEPUMPE_BACKEND=mock`): one MELCloud-like
/// heat pump, its Wi-Fi adapter, prices, weather and house consumption. Never touches the network.
public struct DemoIntegration: Integration {
    public init() {}

    /// The simulated unit is a MELCloud unit, so texts, error codes, health rules, maintenance and
    /// knowledge are MELCloud's.
    private var simulated: MELCloudIntegration { MELCloudIntegration() }

    public var id: String { "demo" }
    public var displayName: String { simulated.displayName }
    public var vendorName: String { "Simulated" }
    public var brandName: String { simulated.brandName }
    public var modelName: String? { simulated.modelName }
    public var unitDescription: String { simulated.unitDescription }
    public var sourceTag: String { simulated.sourceTag }
    public var credentialFields: [CredentialField] { [] }
    /// The same limits as MELCloud, so demo mode behaves like the real thing.
    public var rateLimitPolicy: RateLimitPolicy { .standard }
    public var errorCodes: any ErrorCodeExplaining { simulated.errorCodes }
    public var healthChecks: any HealthCheckProviding { simulated.healthChecks }
    public var maintenanceKinds: [MaintenanceKind] { simulated.maintenanceKinds }
    public var knowledge: KnowledgeSource { simulated.knowledge }

    public func makeConnection(_ context: IntegrationContext) throws -> any DeviceConnection & ThermostatDriver {
        MockBackend(timeZone: context.timeZone, now: context.now)
    }
}
