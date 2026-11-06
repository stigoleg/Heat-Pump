import Foundation

/// What a device can do. Mirrors the driver protocols so the UI and MCP can decide what to show
/// without casting.
public enum Capability: String, Sendable, Codable, CaseIterable, Hashable {
    case thermostat
    case fanSpeed
    case airflow
    case temperatureLog
    case energyLog
    case errorLog
    case signalStrength
    case awayModes
    case weeklySchedule
    case firmwareUpdates
    case location
    /// Readings from a local adapter (power, compressor, defrost).
    case localTelemetry
    /// Electrical power right now.
    case livePower

    /// The capabilities `connection` has by its conformances. A thermostat driver controls fan
    /// and airflow too; local telemetry comes from the integration, not the connection.
    public static func derived(from connection: any DeviceConnection) -> Set<Capability> {
        var set: Set<Capability> = []
        if connection is any ThermostatDriver { set.formUnion([.thermostat, .fanSpeed, .airflow]) }
        if connection is any TemperatureLogReporting { set.insert(.temperatureLog) }
        if connection is any EnergyReporting { set.insert(.energyLog) }
        if connection is any ErrorLogReporting { set.insert(.errorLog) }
        if connection is any SignalStrengthReporting { set.insert(.signalStrength) }
        if connection is any AwayModesDriver { set.insert(.awayModes) }
        if connection is any WeeklyScheduleDriver { set.insert(.weeklySchedule) }
        if connection is any FirmwareDriver { set.insert(.firmwareUpdates) }
        if connection is any DeviceLocationReporting { set.insert(.location) }
        return set
    }
}
