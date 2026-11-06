import Foundation

/// Stable identity of a device across integrations: `"<integration id>:<native id>"`, e.g.
/// `melcloud-classic:12345` or `demo:100001`. The native id is whatever the integration uses for
/// the unit; only its driver interprets it. Persisted (store rows, `devices.key`, state JSON), so
/// an integration never changes how it forms the native id of an existing device.
public struct DeviceKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// `Integration.id` of the integration the device is reached through.
    public let integration: String
    public let nativeId: String

    public init(integration: String, nativeId: String) {
        self.integration = integration
        self.nativeId = nativeId
    }

    /// Parses `"<integration>:<native id>"`; the native id may itself contain colons.
    public init?(_ string: String) {
        guard let colon = string.firstIndex(of: ":") else { return nil }
        let integration = String(string[..<colon])
        let nativeId = String(string[string.index(after: colon)...])
        guard !integration.isEmpty, !nativeId.isEmpty else { return nil }
        self.init(integration: integration, nativeId: nativeId)
    }

    /// The persisted form.
    public var rawValue: String { "\(integration):\(nativeId)" }

    public var description: String { rawValue }

    public static func < (lhs: DeviceKey, rhs: DeviceKey) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension DeviceKey: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let key = DeviceKey(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a device key: \(string)")
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
