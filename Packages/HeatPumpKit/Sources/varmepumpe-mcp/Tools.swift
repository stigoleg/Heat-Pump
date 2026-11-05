import Foundation
import HeatPumpKit
import MCP

enum ToolCatalog {
    static let writeWarning =
        "This CHANGES THE PHYSICAL HEAT PUMP. Only call it after the user has explicitly agreed to this exact change in the conversation. Propose first, then wait for a yes. The call then opens a confirmation dialog on the user's Mac and blocks until they click Godkjenn (sent) or Avvis (not sent); no answer within 120 s counts as rejected."

    static let reasonProperty: Value = [
        "type": "string",
        "description": "Why this change is made, in the user's words or a short Norwegian sentence. Logged in the change log.",
    ]

    static var all: [Tool] { readTools + writeTools }

    static let readOnly = Tool.Annotations(readOnlyHint: true, openWorldHint: true)

    static let readTools: [Tool] = [
        Tool(
            name: "get_status",
            description: "Current state of the heat pump (power, mode, temperatures, fan, vanes, errors, connectivity). Served from cache when younger than 10 minutes; never hits MELCloud more than once per minute. Check meta.dataAgeSeconds and meta.blockedUntil.",
            inputSchema: ["type": "object", "properties": [:]],
            annotations: readOnly),
        Tool(
            name: "get_health_report",
            description: "Health assessment with prioritized findings (severity ok/info/warning/critical, Norwegian title/detail/recommendation, machine-readable code). Syncs history at most once per hour.",
            inputSchema: ["type": "object", "properties": [:]],
            annotations: readOnly),
        Tool(
            name: "get_error_log",
            description: "Error log entries from MELCloud (stored locally), newest first.",
            inputSchema: [
                "type": "object",
                "properties": ["days": ["type": "integer", "minimum": 1, "maximum": 365, "description": "Look-back in days (default 90)."]],
            ],
            annotations: readOnly),
        Tool(
            name: "get_history",
            description: "Time series for one metric from polled snapshots and the MELCloud temperature log. power_w (W), compressor_hz and defrost come from the local Wi-Fi adapter readings (only when local access is on; long ranges are averaged per bucket, source \"local\"). defrost gives minutes of defrost per hour (value) and the number of defrosts that hour (text). Timestamps are ISO 8601.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "metric": ["type": "string", "enum": .array(HistoryMetric.allCases.map { .string($0.rawValue) })],
                    "from": ["type": "string", "description": "ISO 8601 date or date-time (default: 24 h ago)."],
                    "to": ["type": "string", "description": "ISO 8601 date or date-time (default: now)."],
                ],
                "required": ["metric"],
            ],
            annotations: readOnly),
        Tool(
            name: "get_energy",
            description: "Energy use in kWh aggregated per day, ISO week or month, with cost in NOK (costNok, split into electricity/grid tariff/strømstøtte, isEstimate when part of a day is priced at the day's average). MELCloud energy data lags 1.5–3 h and can contain zeros.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "period": ["type": "string", "enum": ["day", "week", "month"]],
                    "from": ["type": "string", "description": "ISO 8601 date (default depends on period)."],
                    "to": ["type": "string", "description": "ISO 8601 date (default: today)."],
                ],
                "required": ["period"],
            ],
            annotations: readOnly),
        Tool(
            name: "get_prices",
            description: "Electricity price per kWh for the user's agreement (Norgespris or spot via Tibber/hvakosterstrommen.no): current hour, today, tomorrow (after about 13:00), and the three cheapest hours ahead. Prices in øre/kWh incl. VAT = electricity + grid tariff energy part − strømstøtte. Use for price-aware advice; small pre-heating before expensive hours is fine, avoid big swings and frequent on/off.",
            inputSchema: ["type": "object", "properties": [:]],
            annotations: readOnly),
        Tool(
            name: "get_live_status",
            description: "Live readings from the Wi-Fi adapter on the home network (read-only, unofficial local endpoint; must be switched on in the app): power in W, compressor frequency (Hz) and whether it runs, room/outdoor temperature, setpoint and mode as the unit itself reports them, error code (0x8000 = none), adapter firmware and Wi-Fi signal, what it is doing now (phase: heating, resting, defrost, preheat …, with a Norwegian explanation), age of the reading, compressor starts and defrosts in the last 1/3/24 h and min/avg/max W over the last 60 min. Reads the adapter at most every 20 s (reuses a reading younger than 60 s). Control still goes through MELCloud (set_* tools). Many starts per hour while heating (≥ 4/h over 3 h) is short cycling.",
            inputSchema: ["type": "object", "properties": [:]],
            annotations: Tool.Annotations(readOnlyHint: true, openWorldHint: false)),
        Tool(
            name: "get_maintenance_status",
            description: "When each filter/maintenance task was last recorded, the recommended interval from the owner manual, and whether it is due.",
            inputSchema: ["type": "object", "properties": [:]],
            annotations: Tool.Annotations(readOnlyHint: true, openWorldHint: false)),
        Tool(
            name: "get_change_log",
            description: "Recent changes to the heat pump (from the app or Claude) with old/new value, reason and result (ok/failed/rejected/pending).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Default 20."],
                    "source": ["type": "string", "enum": ["app", "claude"]],
                ],
            ],
            annotations: Tool.Annotations(readOnlyHint: true, openWorldHint: false)),
        Tool(
            name: "get_device_info",
            description: "Static device information: model, IDs, firmware, setpoint limits per mode, fan speeds, energy counters, and the list of knowledge resources.",
            inputSchema: ["type": "object", "properties": [:]],
            annotations: readOnly),
        Tool(
            name: "refresh",
            description: "Refresh state from MELCloud (force=true bypasses the 10-minute cache but is still limited to once per 60 s across app and MCP, and never runs while MELCloud has blocked us) and sync history reports (each at most hourly).",
            inputSchema: ["type": "object", "properties": ["force": ["type": "boolean", "description": "Default false."]]],
            annotations: readOnly),
    ]

    static func writeAnnotations(destructive: Bool = false, idempotent: Bool = true) -> Tool.Annotations {
        Tool.Annotations(readOnlyHint: false, destructiveHint: destructive, idempotentHint: idempotent, openWorldHint: true)
    }

    static let writeTools: [Tool] = [
        Tool(
            name: "set_power",
            description: "Turn the heat pump on or off. \(writeWarning) Turning it off in winter can let the house cool down.",
            inputSchema: [
                "type": "object",
                "properties": ["on": ["type": "boolean"], "reason": reasonProperty],
                "required": ["on", "reason"],
            ],
            annotations: writeAnnotations(destructive: true)),
        Tool(
            name: "set_mode",
            description: "Set operation mode (heat, dry, cool, fan, auto). \(writeWarning)",
            inputSchema: [
                "type": "object",
                "properties": [
                    "mode": ["type": "string", "enum": .array(OperationMode.allCases.map { .string($0.key) })],
                    "reason": reasonProperty,
                ],
                "required": ["mode", "reason"],
            ],
            annotations: writeAnnotations()),
        Tool(
            name: "set_temperature",
            description: "Set target temperature in °C. Rounded to 0.5 °C; rejected outside the device's limits for the current mode (see get_device_info). \(writeWarning)",
            inputSchema: [
                "type": "object",
                "properties": ["celsius": ["type": "number"], "reason": reasonProperty],
                "required": ["celsius", "reason"],
            ],
            annotations: writeAnnotations()),
        Tool(
            name: "set_fan_speed",
            description: "Set fan speed: 0 = auto, 1…N (N from get_device_info, usually 5). \(writeWarning)",
            inputSchema: [
                "type": "object",
                "properties": ["speed": ["type": "integer", "minimum": 0, "maximum": 5], "reason": reasonProperty],
                "required": ["speed", "reason"],
            ],
            annotations: writeAnnotations()),
        Tool(
            name: "set_vanes",
            description: "Set vane (airflow direction) positions. Each axis is sent as a separate request. \(writeWarning)",
            inputSchema: [
                "type": "object",
                "properties": [
                    "vertical": ["type": "string", "enum": .array(VaneVertical.allCases.map { .string($0.key) })],
                    "horizontal": ["type": "string", "enum": .array(VaneHorizontal.allCases.map { .string($0.key) })],
                    "reason": reasonProperty,
                ],
                "required": ["reason"],
            ],
            annotations: writeAnnotations()),
        Tool(
            name: "record_maintenance",
            description: "Record that a maintenance task was done (e.g. the user cleaned the air filter). Does not touch the heat pump, but writes to the shared history; only call it when the user said the task was done.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "enum": .array(MaintenanceKind.allCases.map { .string($0.rawValue) })],
                    "date": ["type": "string", "description": "ISO 8601 date or date-time, not in the future (default: now)."],
                    "note": ["type": "string"],
                    "reason": reasonProperty,
                ],
                "required": ["kind", "reason"],
            ],
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
    ]
}

/// Typed access to tool arguments.
struct Arguments {
    let raw: [String: Value]

    init(_ raw: [String: Value]?) { self.raw = raw ?? [:] }

    func string(_ key: String) -> String? { raw[key]?.stringValue }
    func bool(_ key: String) -> Bool? { raw[key]?.boolValue }
    func int(_ key: String) -> Int? {
        if let value = raw[key]?.intValue { return value }
        if let value = raw[key]?.doubleValue { return Int(exactly: value) }
        return raw[key]?.stringValue.flatMap(Int.init)
    }
    func double(_ key: String) -> Double? {
        if let value = raw[key]?.doubleValue { return value }
        if let value = raw[key]?.intValue { return Double(value) }
        return raw[key]?.stringValue.flatMap(Double.init)
    }
    func date(_ key: String) -> Date? { WireDate.parse(string(key), timeZone: .current) }
}

struct ArgumentError: Error {
    let message: String
}
