import Foundation
import HeatPumpKit

/// Mitsubishi Electric air-to-air heat pumps through MELCloud Classic (`app.melcloud.com`), plus
/// read-only local readings from the unit's Wi-Fi adapter.
public struct MELCloudIntegration: Integration {
    public init() {}

    public var id: String { "melcloud-classic" }
    public var displayName: String { "MELCloud" }
    public var vendorName: String { "Mitsubishi Electric" }

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
