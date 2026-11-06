import Foundation

/// A device as an integration describes it (types only for now; identity stays `Int deviceId`).
public struct DeviceDescriptor: Sendable, Equatable {
    /// `Integration.id` of the integration that owns the device.
    public var integrationId: String
    public var deviceId: Int
    public var name: String
    public var kind: DeviceKind
    public var capabilities: Set<Capability>

    public init(integrationId: String, deviceId: Int, name: String, kind: DeviceKind, capabilities: Set<Capability>) {
        self.integrationId = integrationId
        self.deviceId = deviceId
        self.name = name
        self.kind = kind
        self.capabilities = capabilities
    }
}
