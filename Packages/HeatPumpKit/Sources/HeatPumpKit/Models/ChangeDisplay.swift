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

    /// Norwegian value text, e.g. "Varme", "21,5 °C", "På".
    public var displayValue: String {
        switch self {
        case .power(let on): on ? "På" : "Av"
        case .mode(let mode): mode.displayName
        case .temperature(let celsius): Norwegian.format("%.1f °C", celsius)
        case .fanSpeed(let speed): speed == 0 ? "Auto" : String(speed)
        case .vaneVertical(let vane): vane.displayName
        case .vaneHorizontal(let vane): vane.displayName
        }
    }

    /// Norwegian field label.
    public static func fieldName(_ field: String) -> String {
        switch field {
        case "power": "Av/på"
        case "mode": "Modus"
        case "setTemperature": "Ønsket temperatur"
        case "fanSpeed": "Viftehastighet"
        case "vaneVertical": "Vertikalt spjeld"
        case "vaneHorizontal": "Horisontalt spjeld"
        case "weeklyTimer": "Ukeplan"
        default: field
        }
    }
}

extension ChangeRecord {
    /// Norwegian one-line summary, e.g. "Endre ønsket temperatur til 21,5 °C".
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
        case .pending: "Sendes"
        case .ok: "Sendt"
        case .failed: "Feilet"
        case .rejected: "Avvist"
        }
    }
}

extension ChangeSource {
    public var displayName: String {
        switch self {
        case .app: "App"
        case .claude: "Claude"
        }
    }
}
