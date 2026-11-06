import Foundation

/// The kind of equipment a device is (types only for now; one heat pump is all the app shows).
public enum DeviceKind: String, Sendable, Codable, CaseIterable {
    case airToAirHeatPump
    case energyMeter
}
