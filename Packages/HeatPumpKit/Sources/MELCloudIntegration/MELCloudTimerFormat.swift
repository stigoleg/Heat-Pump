import Foundation
import HeatPumpKit

/// MELCloud Classic's weekly timer wire format (`Timer/Get2`, `Timer/SetAta2`).
public struct MELCloudTimerFormat: WeeklyTimerFormat {
    public init() {}

    public func isAsRead(_ event: TimerEvent) -> Bool {
        event.raw.flatMap(MELCloudClassicParser.timerEvent) == event
    }

    /// Day, time, power, mode, temperature, fan and vanes as they would be sent.
    public func contentKey(_ event: TimerEvent) -> String {
        let wire = MELCloudClassicParser.timerEventJSON(event)
        let fields: [String] = [
            "\(event.weekday)", "\(event.minuteOfDay)", wire["Power"]?.bool.map { "\($0)" } ?? "-",
            wire["OperationMode"]?.int.map { "\($0)" } ?? "-", wire["SetTemperature"]?.double.map { "\($0)" } ?? "-",
            wire["FanSpeed"]?.int.map { "\($0)" } ?? "-", wire["VaneHorizontal"]?.int.map { "\($0)" } ?? "-",
            wire["VaneVertical"]?.int.map { "\($0)" } ?? "-",
        ]
        return fields.joined(separator: ",")
    }

    /// The `Timer/SetAta2` body read back as `Timer/Get2` would return it.
    public func savedForm(of timer: WeeklyTimer, deviceId: Int) -> WeeklyTimer {
        let body = MELCloudClassicParser.timerSetBody(timer: timer, deviceId: deviceId)
        return MELCloudClassicParser.weeklyTimer(
            .object(["Enabled": body["TimerEnabled"] ?? .null, "Seasons": body["Seasons"] ?? .array([])]))
    }
}

// MELCloud's format as the default for code that only ever sees MELCloud plans.
extension TimerEvent {
    /// Exactly as read from MELCloud (not made or changed in the app).
    package var isAsRead: Bool { MELCloudTimerFormat().isAsRead(self) }
}

extension WeeklyTimer {
    package func hasSameContent(as other: WeeklyTimer) -> Bool {
        hasSameContent(as: other, format: MELCloudTimerFormat())
    }

    package func validationProblem(limits: TemperatureLimits?) -> String? {
        validationProblem(limits: limits, format: MELCloudTimerFormat())
    }
}
