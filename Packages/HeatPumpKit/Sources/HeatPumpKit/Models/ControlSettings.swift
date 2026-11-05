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

/// The fields the user has actually touched in the Kontroll screen. Untouched fields always
/// follow live state, so refreshes and changes from others never become pending "reverts".
public struct ControlEdits: Sendable, Equatable {
    public var power: Bool?
    public var mode: OperationMode?
    public var setTemperature: Double?
    public var fanSpeed: Int?
    public var vaneVertical: VaneVertical?
    public var vaneHorizontal: VaneHorizontal?

    public init() {}

    public var isEmpty: Bool { self == ControlEdits() }

    /// Live settings with the user's edits on top (what the controls show).
    public func displayed(over live: ControlSettings) -> ControlSettings {
        var shown = live
        if let power { shown.power = power }
        if let mode { shown.mode = mode }
        if let setTemperature { shown.setTemperature = setTemperature }
        if let fanSpeed { shown.fanSpeed = fanSpeed }
        if let vaneVertical { shown.vaneVertical = vaneVertical }
        if let vaneHorizontal { shown.vaneHorizontal = vaneHorizontal }
        return shown
    }

    /// Edited fields that differ from live state.
    public func changes(from live: ControlSettings) -> [DeviceChange] {
        displayed(over: live).changes(from: live)
    }

    /// Drops edits that live state has caught up with (for example after a send is confirmed).
    public mutating func prune(against live: ControlSettings) {
        if power == live.power { power = nil }
        if mode == live.mode { mode = nil }
        if setTemperature == live.setTemperature { setTemperature = nil }
        if fanSpeed == live.fanSpeed { fanSpeed = nil }
        if vaneVertical == live.vaneVertical { vaneVertical = nil }
        if vaneHorizontal == live.vaneHorizontal { vaneHorizontal = nil }
    }

    /// After a mode edit: if the shown setpoint is outside the new mode's limits, edit it to the
    /// nearest allowed value. A setpoint that is still valid is left untouched.
    public mutating func clampSetpoint(over live: ControlSettings, limits: TemperatureLimits, step: Double = 0.5) {
        let shown = displayed(over: live)
        var clamped = shown
        clamped.clampSetpoint(to: limits, step: step)
        if clamped.setTemperature != shown.setTemperature { setTemperature = clamped.setTemperature }
    }
}
