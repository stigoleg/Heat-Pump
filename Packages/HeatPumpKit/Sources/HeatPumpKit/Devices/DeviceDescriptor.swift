import Foundation

/// A device as the hub serves it: its key, the name to show (the user's own when set), its kind
/// and what it can do.
public struct DeviceDescriptor: Sendable, Equatable {
    public var key: DeviceKey
    public var name: String
    public var kind: DeviceKind
    public var capabilities: Set<Capability>
    /// Disabled devices keep their data but have no service.
    public var isEnabled: Bool

    /// `Integration.id` of the integration that owns the device.
    public var integrationId: String { key.integration }

    public init(key: DeviceKey, name: String, kind: DeviceKind, capabilities: Set<Capability>, isEnabled: Bool = true) {
        self.key = key
        self.name = name
        self.kind = kind
        self.capabilities = capabilities
        self.isEnabled = isEnabled
    }
}
