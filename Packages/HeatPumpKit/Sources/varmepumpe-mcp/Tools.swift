import Foundation
import HeatPumpKit
import MCP

enum ToolCatalog {
    static let writeWarning =
        "This CHANGES THE PHYSICAL HEAT PUMP. Only call it after the user has explicitly agreed to this exact change in the conversation. Propose first, then wait for a yes. The call then opens a confirmation dialog on the user's Mac and blocks until they click \(L10n.tr("Approve")) (sent) or \(L10n.tr("Reject")) (not sent); no answer within 120 s counts as rejected."

    static let reasonProperty: Value = [
        "type": "string",
        "description": .string(
            "Why this change is made, in the user's words or a short sentence in \(L10n.language == .norwegian ? "Norwegian bokmål" : "English"). Shown to the user in the approval dialog and logged in the change log."
        ),
    ]

    /// Every tool; `service` names the heat pump service in the descriptions.
    static func all(service: String) -> [Tool] { readTools(service: service) + writeTools(service: service) }

    /// What a device needs for each device tool; tools not listed (`get_prices`, `list_devices`)
    /// are not about one device.
    static let requiredCapability: [String: Capability] = [
        "get_status": .thermostat, "get_health_report": .thermostat, "get_error_log": .errorLog, "get_history": .thermostat,
        "get_energy": .energyLog, "get_live_status": .localTelemetry, "get_forecast": .energyLog,
        "get_house_consumption": .energyLog, "get_away_settings": .awayModes, "get_weekly_timer": .weeklySchedule,
        "get_firmware_status": .firmwareUpdates, "get_maintenance_status": .thermostat, "get_change_log": .thermostat,
        "get_device_info": .thermostat, "refresh": .thermostat, "set_power": .thermostat, "set_mode": .thermostat,
        "set_temperature": .thermostat, "set_fan_speed": .fanSpeed, "set_vanes": .airflow, "set_frost_protection": .awayModes,
        "set_holiday_mode": .awayModes, "start_firmware_update": .firmwareUpdates, "record_maintenance": .thermostat,
        "get_meter_status": .energyLog,
    ]

    /// Tools about an energy meter (`MeterTools`); the other device tools are about a heat pump.
    static let meterTools: Set<String> = ["get_meter_status"]

    /// Whether `device` can answer the device tool `name`: the right kind and the capability.
    static func canAnswer(_ name: String, _ device: DeviceDescriptor) -> Bool {
        guard let capability = requiredCapability[name] else { return true }
        let isMeter = device.kind == .energyMeter
        return meterTools.contains(name) == isMeter && device.capabilities.contains(capability)
    }

    /// The tools for these enabled devices. Before any device is known, and with one device, the
    /// catalog is `all(service:)` minus tools no device can answer (with one heat pump: all of it),
    /// plus the meter tools when a meter is enabled. With two or more, every device tool takes an
    /// optional `device` and `list_devices` is added.
    static func tools(for devices: [DeviceDescriptor], service: String) -> [Tool] {
        let all = all(service: service)
        guard !devices.isEmpty else { return all }
        let available = (all + MeterTools.tools).filter { tool in devices.contains { canAnswer(tool.name, $0) } }
        guard devices.count >= 2 else { return available }
        return [listDevicesTool] + available.map { requiredCapability[$0.name] == nil ? $0 : withDeviceArgument($0) }
    }

    static let listDevicesTool = Tool(
        name: "list_devices",
        description: "The user's devices: key, name, kind, integration (service), capabilities and whether the device was online at the last status. Pass a device's key or name as the device argument of the other tools.",
        inputSchema: ["type": "object", "properties": [:]],
        annotations: Tool.Annotations(readOnlyHint: true, openWorldHint: false))

    static let deviceProperty: Value = [
        "type": "string",
        "description": "Which device: its key or name from list_devices (case-insensitive). Needed when more than one device could answer.",
    ]

    /// `tool` with the optional `device` argument added to its schema.
    static func withDeviceArgument(_ tool: Tool) -> Tool {
        guard case .object(var schema) = tool.inputSchema else { return tool }
        var properties = schema["properties"]?.objectValue ?? [:]
        properties["device"] = deviceProperty
        schema["properties"] = .object(properties)
        return Tool(
            name: tool.name, title: tool.title, description: tool.description, inputSchema: .object(schema),
            annotations: tool.annotations, outputSchema: tool.outputSchema, icons: tool.icons, _meta: tool._meta)
    }

    static let readOnly = Tool.Annotations(readOnlyHint: true, openWorldHint: true)

    static func readTools(service: String) -> [Tool] {
        [
            Tool(
                name: "get_status",
                description: "Current state of the heat pump (power, mode, temperatures, fan, vanes, errors, connectivity). Served from cache when younger than 10 minutes; never hits \(service) more than once per minute. Check meta.dataAgeSeconds and meta.blockedUntil.",
                inputSchema: ["type": "object", "properties": [:]],
                annotations: readOnly),
            Tool(
                name: "get_health_report",
                description: "Health assessment with prioritized findings (severity ok/info/warning/critical, title/detail/recommendation in the user's language, machine-readable code). Syncs history at most once per hour.",
                inputSchema: ["type": "object", "properties": [:]],
                annotations: readOnly),
            Tool(
                name: "get_error_log",
                description: "Error log entries from \(service) (stored locally), newest first.",
                inputSchema: [
                    "type": "object",
                    "properties": ["days": ["type": "integer", "minimum": 1, "maximum": 365, "description": "Look-back in days (default 90)."]],
                ],
                annotations: readOnly),
            Tool(
                name: "get_history",
                description: "Time series for one metric from polled snapshots and the \(service) temperature log. power_w (W), compressor_hz and defrost come from the local Wi-Fi adapter readings (only when local access is on; long ranges are averaged per bucket, source \"local\"). defrost gives minutes of defrost per hour (value) and the number of defrosts that hour (text). Timestamps are ISO 8601.",
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
                description: "Energy use in kWh aggregated per day, ISO week or month, with cost in NOK (costNok, split into electricity/grid tariff/electricity subsidy, isEstimate when part of a day is priced at the day's average). \(service) energy data lags 1.5–3 h and can contain zeros.",
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
                description: "Electricity price per kWh for the user's agreement (Norgespris or spot via Tibber/hvakosterstrommen.no): current hour, today, tomorrow (after about 13:00), and the three cheapest hours ahead. Prices in øre/kWh incl. VAT = electricity + grid tariff energy charge − electricity subsidy. For spot agreements also a clearly labelled ESTIMATE (label \"anslag\") for the hours after the published prices up to 7 days ahead (median and 25–75 % band per day and for the next 48 hours; built from the last 4 weeks of prices and the weather forecast; uncertain, not a published price). Also the app's price control (lowers the setpoint in expensive hours while the app runs): settings, status and plan, read-only — Claude cannot turn it on or off or change it. Use for price-aware advice; small pre-heating before expensive hours is fine, avoid big swings and frequent on/off.",
                inputSchema: ["type": "object", "properties": [:]],
                annotations: readOnly),
            Tool(
                name: "get_live_status",
                description: "Live readings from the Wi-Fi adapter on the home network (read-only, unofficial local endpoint; must be switched on in the app): power in W, compressor frequency (Hz) and whether it runs, room/outdoor temperature, setpoint and mode as the unit itself reports them, error code (0x8000 = none), adapter firmware and Wi-Fi signal, what it is doing now (phase: heating, resting, defrost, preheat …, with an explanation in the user's language), age of the reading, compressor starts and defrosts in the last 1/3/24 h and min/avg/max W over the last 60 min. Reads the adapter at most every 20 s (reuses a reading younger than 60 s). Control still goes through \(service) (set_* tools). Many starts per hour while heating (≥ 4/h over 3 h) is short cycling.",
                inputSchema: ["type": "object", "properties": [:]],
                annotations: Tool.Annotations(readOnlyHint: true, openWorldHint: false)),
            Tool(
                name: "get_forecast",
                description: "Weather forecast from MET Norway (yr.no) for the house for the next 48 hours (temperature, wind, precipitation) combined with hourly electricity prices and price levels, the coldest, cheapest and most expensive hours ahead, and the expected heat-pump use and cost tomorrow (degree-day model fitted on at least 10 days of this unit's own history; includes a range). The forecast is fetched at most hourly and only when MET's copy has expired. Location comes from \(service) or the app's settings; coordinates are never returned. Attribution: weather data from MET Norway (see the attribution field). Use for planning: a small pre-heating step (max 1 °C, a few hours before a cold and expensive period) is fine; avoid frequent on/off and big swings.",
                inputSchema: ["type": "object", "properties": [:]],
                annotations: readOnly),
            Tool(
                name: "get_house_consumption",
                description: "The whole house's hourly electricity use from Tibber (only when the user has saved a Tibber token in the app) next to the heat pump's own use, per day: house kWh, heat-pump kWh, the heat pump's share, and Tibber's own cost for the house. The heat pump's kWh are exact when measured by the local adapter (heatPumpMeasured), otherwise estimated from \(service)'s counter. Fetched from Tibber at most hourly; Tibber's data lags a few hours.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "from": ["type": "string", "description": "ISO 8601 date (default: 7 days ago)."],
                        "to": ["type": "string", "description": "ISO 8601 date (default: now)."],
                    ],
                ],
                annotations: readOnly),
            Tool(
                name: "get_away_settings",
                description: "Frost protection (keeps the room between a minimum and maximum temperature while the unit is otherwise off; 4–14 °C / 6–16 °C, max at least 2 °C above min) and holiday mode (start/end; the unit follows frost protection in that period) as \(service) reports them, plus a short view of \(service)'s weekly timer (enabled, events, next event; full plan in get_weekly_timer). Read from \(service) at most hourly (timer every 6 h); cached otherwise.",
                inputSchema: ["type": "object", "properties": [:]],
                annotations: readOnly),
            Tool(
                name: "get_weekly_timer",
                description: "\(service)'s weekly timer (the weekly schedule): whether it is on, every season (start date, whether it is the one in force) with its events (weekday, time, on/off, mode, temperature, fan, vanes), and the next event. The plan runs in \(service), also when the Mac is off; a change made with set_* lasts until the next planned event. Read-only for Claude: the user creates and edits the plan in the app (Weekly schedule page). Read from \(service) at most every 6 h; cached otherwise. decoded=false means only the event count is known.",
                inputSchema: ["type": "object", "properties": [:]],
                annotations: readOnly),
            Tool(
                name: "get_firmware_status",
                description: "Firmware of the Wi-Fi adapter: current version, whether \(service) has an update waiting, whether this account owns the unit (only owners may update), and \(service)'s update status (phase with text in the user's language, files downloaded x/y, minutes offline), plus canStart/startProblem and whether an update is running. \(service) is asked only when an update waits or runs: at most every 60 s, every 15 s while it runs. Updates go through start_firmware_update.",
                inputSchema: ["type": "object", "properties": [:]],
                annotations: readOnly),
            Tool(
                name: "get_maintenance_status",
                description: "When each filter/maintenance task was last recorded, the recommended interval from the owner manual, and whether it is due.",
                inputSchema: ["type": "object", "properties": [:]],
                annotations: Tool.Annotations(readOnlyHint: true, openWorldHint: false)),
            Tool(
                name: "get_change_log",
                description: "Recent changes to the heat pump (from the app, Claude or the app's price control, source automation) with old/new value, reason and result (ok/failed/rejected/pending).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Default 20."],
                        "source": ["type": "string", "enum": ["app", "claude", "automation"]],
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
                description: "Refresh state from \(service) (force=true bypasses the 10-minute cache but is still limited to once per 60 s across app and MCP, and never runs while \(service) has blocked us) and sync history reports (each at most hourly).",
                inputSchema: ["type": "object", "properties": ["force": ["type": "boolean", "description": "Default false."]]],
                annotations: readOnly),
        ]
    }

    static func writeAnnotations(destructive: Bool = false, idempotent: Bool = true) -> Tool.Annotations {
        Tool.Annotations(readOnlyHint: false, destructiveHint: destructive, idempotentHint: idempotent, openWorldHint: true)
    }

    static func writeTools(service: String) -> [Tool] {
        [
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
                name: "set_frost_protection",
                description: "Switch \(service) frost protection on or off and set its range (whole °C; minimum 4–14, maximum 6–16, maximum at least 2 above minimum). Useful before leaving a cold house or cabin. \(writeWarning) Counts toward the 12 writes per hour.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "enabled": ["type": "boolean"],
                        "minimum": ["type": "number", "minimum": 4, "maximum": 14, "description": "°C (default: the current value; required when it is unknown). 8 or more is recommended."],
                        "maximum": ["type": "number", "minimum": 6, "maximum": 16, "description": "°C (default: the current value; required when it is unknown)."],
                        "reason": reasonProperty,
                    ],
                    "required": ["enabled", "reason"],
                ],
                annotations: writeAnnotations()),
            Tool(
                name: "set_holiday_mode",
                description: "Switch \(service) holiday mode on (with start and end, local time) or off. While on, the unit may stand off and only frost protection keeps the house from getting cold, so holiday mode is refused unless frost protection is on (turn it on first with set_frost_protection, 8–12 °C is typical); frost protection cannot be switched off during a holiday. Check get_away_settings first. \(writeWarning) Counts toward the 12 writes per hour.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "enabled": ["type": "boolean"],
                        "start": ["type": "string", "description": "ISO 8601 local date-time, e.g. 2026-12-20T10:00 (required when enabled)."],
                        "end": ["type": "string", "description": "ISO 8601 local date-time (required when enabled; at most a year after start)."],
                        "reason": reasonProperty,
                    ],
                    "required": ["enabled", "reason"],
                ],
                annotations: writeAnnotations()),
            Tool(
                name: "start_firmware_update",
                description: "Start the firmware update \(service) has waiting for the Wi-Fi adapter. Firmware CANNOT be rolled back; the pump must stay powered with good Wi-Fi, nobody may cut the power or use the remote control while it runs, and the adapter restarts (no control for a while). Check get_firmware_status first (canStart). Refused without asking when the account is not the owner, nothing waits, the unit is offline or \(service) does not offer the update now. \(writeWarning) Counts toward the 12 writes per hour. Follow progress with get_firmware_status. Cancelling is only possible in the app.",
                inputSchema: [
                    "type": "object",
                    "properties": ["reason": reasonProperty],
                    "required": ["reason"],
                ],
                annotations: writeAnnotations(destructive: true, idempotent: false)),
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
