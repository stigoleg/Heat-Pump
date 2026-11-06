import Foundation

/// The kind of equipment a device is; it decides the device's service, screens and MCP tools.
public enum DeviceKind: String, Sendable, Codable, CaseIterable {
    case airToAirHeatPump
    case energyMeter
}
