import Foundation

/// The user-controllable settings of a unit, used to batch edits in the app.
public struct ControlSettings: Sendable, Equatable {
    public var power: Bool
    public var mode: OperationMode
    public var setTemperature: Double
    public var fanSpeed: Int
    public var vaneVertical: VaneVertical
    public var vaneHorizontal: VaneHorizontal

    public init(_ state: DeviceState) {
        power = state.power
        mode = state.mode ?? .heat
        setTemperature = state.setTemperature ?? 21
        fanSpeed = state.fanSpeed ?? 0
        vaneVertical = state.vaneVertical ?? .auto
        vaneHorizontal = state.vaneHorizontal ?? .auto
    }

    /// Changes needed to go from `base` to these settings, in a stable order.
    public func changes(from base: ControlSettings) -> [DeviceChange] {
        var result: [DeviceChange] = []
        if power != base.power { result.append(.power(power)) }
        if mode != base.mode { result.append(.mode(mode)) }
        if setTemperature != base.setTemperature { result.append(.temperature(setTemperature)) }
        if fanSpeed != base.fanSpeed { result.append(.fanSpeed(fanSpeed)) }
        if vaneVertical != base.vaneVertical { result.append(.vaneVertical(vaneVertical)) }
        if vaneHorizontal != base.vaneHorizontal { result.append(.vaneHorizontal(vaneHorizontal)) }
        return result
    }

    /// Keeps the setpoint inside the limits of the selected mode (after a mode switch).
    public mutating func clampSetpoint(to limits: TemperatureLimits, step: Double = 0.5) {
        let range = limits.range(for: mode)
        let step = step > 0 ? step : 0.5
        setTemperature = min(max((setTemperature / step).rounded() * step, range.lowerBound), range.upperBound)
    }
}
