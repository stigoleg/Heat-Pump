import Foundation

extension DeviceChange {
    /// Rebuilds a change from its `change_log` field and machine value.
    public init?(field: String, value: String?) {
        guard let value else { return nil }
        switch field {
        case "power": self = .power(value == "on")
        case "mode":
            guard let mode = OperationMode(key: value) else { return nil }
            self = .mode(mode)
        case "setTemperature":
            guard let celsius = Double(value) else { return nil }
            self = .temperature(celsius)
        case "fanSpeed":
            if value == "auto" { self = .fanSpeed(0); return }
            guard let speed = Int(value) else { return nil }
            self = .fanSpeed(speed)
        case "vaneVertical":
            guard let vane = VaneVertical(key: value) else { return nil }
            self = .vaneVertical(vane)
        case "vaneHorizontal":
            guard let vane = VaneHorizontal(key: value) else { return nil }
            self = .vaneHorizontal(vane)
        default: return nil
        }
    }

    /// Value text, e.g. "Heat", "21.5 °C", "On".
    public var displayValue: String {
        switch self {
        case .power(let on): on ? L10n.tr("On") : L10n.tr("Off")
        case .mode(let mode): mode.displayName
        case .temperature(let celsius): Display.format("%.1f °C", celsius)
        case .fanSpeed(let speed): speed == 0 ? L10n.tr("Auto") : String(speed)
        case .vaneVertical(let vane): vane.displayName
        case .vaneHorizontal(let vane): vane.displayName
        }
    }

    /// Field label.
    public static func fieldName(_ field: String) -> String {
        switch field {
        case "power": L10n.tr("On/off")
        case "mode": L10n.tr("Mode")
        case "setTemperature": L10n.tr("Target temperature")
        case "fanSpeed": L10n.tr("Fan speed")
        case "vaneVertical": L10n.tr("Vertical airflow")
        case "vaneHorizontal": L10n.tr("Horizontal airflow")
        case "weeklyTimer": L10n.tr("Weekly schedule")
        default: field
        }
    }
}

extension ChangeRecord {
    /// One-line summary, e.g. "Change target temperature to 21.5 °C".
    public var displaySummary: String {
        DeviceChange(field: field, value: newValue)?.displaySummary ?? "\(DeviceChange.fieldName(field)): \(newValue ?? "–")"
    }

    public var oldDisplayValue: String {
        DeviceChange(field: field, value: oldValue)?.displayValue ?? oldValue ?? "–"
    }

    public var newDisplayValue: String {
        DeviceChange(field: field, value: newValue)?.displayValue ?? newValue ?? "–"
    }
}

extension ChangeResult {
    public var displayName: String {
        switch self {
        case .pending: L10n.tr("Sending")
        case .ok: L10n.tr("Sent")
        case .failed: L10n.tr("Failed")
        case .rejected: L10n.tr("Rejected")
        }
    }
}

extension ChangeSource {
    public var displayName: String {
        switch self {
        case .app: L10n.tr("App")
        case .claude: "Claude"
        case .automation: L10n.tr("Price control")
        }
    }
}
