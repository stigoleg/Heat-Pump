import Foundation

/// A device as an integration describes it (types only for now).
public struct DeviceDescriptor: Sendable, Equatable {
    public var key: DeviceKey
    public var name: String
    public var kind: DeviceKind
    public var capabilities: Set<Capability>

    /// `Integration.id` of the integration that owns the device.
    public var integrationId: String { key.integration }

    public init(key: DeviceKey, name: String, kind: DeviceKind, capabilities: Set<Capability>) {
        self.key = key
        self.name = name
        self.kind = kind
        self.capabilities = capabilities
    }
}
