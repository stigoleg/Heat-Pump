import Foundation
import HeatPumpKit

/// Simulated data for demo mode and screenshots (`VARMEPUMPE_BACKEND=mock`): one MELCloud-like
/// heat pump, its Wi-Fi adapter, prices, weather and house consumption. Never touches the network.
public struct DemoIntegration: Integration {
    public init() {}

    public var id: String { "demo" }
    public var displayName: String { "MELCloud" }
    public var vendorName: String { "Simulated" }
    public var credentialFields: [CredentialField] { [] }
    /// The same limits as MELCloud, so demo mode behaves like the real thing.
    public var rateLimitPolicy: RateLimitPolicy { .standard }

    public func makeConnection(_ context: IntegrationContext) throws -> any DeviceConnection & ThermostatDriver {
        MockBackend(timeZone: context.timeZone, now: context.now)
    }
}
