import Foundation
import HeatPumpKit
import MCP

/// Logging goes to stderr only; stdout is the MCP channel.
enum Log {
    static func info(_ message: String) { write("info", message) }
    static func error(_ message: String) { write("error", message) }

    private static func write(_ level: String, _ message: String) {
        FileHandle.standardError.write(Data("[varmepumpe-mcp] \(level): \(message)\n".utf8))
    }
}

/// Freshness metadata attached to every tool output.
struct Meta: Encodable {
    var fetchedAt: Date?
    var dataAgeSeconds: Int?
    var blockedUntil: Date?
    var nextRefreshAllowed: Date?
    var historyLastSynced: [String: Date]
    var backend: String

    static func current(service: HeatPumpService, state: StateResult? = nil) async -> Meta {
        let store = service.store
        let now = Date()
        let snapshot = try? await service.latestSnapshot()
        let fetchedAt = state?.fetchedAt ?? snapshot?.state.fetchedAt
        var synced: [String: Date] = [:]
        for kind in ReportKind.allCases {
            guard let key = try? await service.deviceFetchKey("report.\(kind.rawValue)") else { continue }
            if let date = (try? store.fetchState(key: key))??.lastSuccess {
                synced[kind.rawValue] = date
            }
        }
        return Meta(
            fetchedAt: fetchedAt,
            dataAgeSeconds: fetchedAt.map { max(0, Int(now.timeIntervalSince($0))) },
            blockedUntil: state?.blockedUntil ?? (try? store.blockedUntil(now: now, integration: service.integration.id)) ?? nil,
            nextRefreshAllowed: state?.nextRefreshAllowed,
            historyLastSynced: synced,
            backend: service.backend.identifier)
    }
}

struct Output<T: Encodable>: Encodable {
    var result: T
    var meta: Meta
}

enum ToolOutput {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.iso8601)
        }
        return encoder
    }()

    /// JSON text content plus the same object as `structuredContent`.
    static func json<T: Encodable>(_ value: T, isError: Bool = false) -> CallTool.Result {
        do {
            let data = try encoder.encode(value)
            let structured = try JSONDecoder().decode(Value.self, from: data)
            return CallTool.Result(
                content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
                structuredContent: Optional(structured),
                isError: isError ? true : nil)
        } catch {
            return failure(L10n.format("Could not build the response: %@", error.localizedDescription))
        }
    }

    static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: #"{"error":"# + quoted(message) + "}", annotations: nil, _meta: nil)], isError: true)
    }

    private static func quoted(_ text: String) -> String {
        (try? String(decoding: JSONEncoder().encode(text), as: UTF8.self)) ?? "\"\""
    }
}

/// Status shaped for Claude: readable names next to raw values, summary in the user's language.
struct StatusView: Encodable {
    var summary: String
    var power: Bool?
    var mode: String?
    var modeName: String?
    var setTemperature: Double?
    var roomTemperature: Double?
    var outdoorTemperature: Double?
    var fanSpeed: String?
    var actualFanSpeed: Int?
    var vaneVertical: String?
    var vaneHorizontal: String?
    var hasError: Bool?
    var errorCode: Int?
    var offline: Bool?
    var lastCommunication: Date?
    var wifiSignalDbm: Int?
    var hasPendingCommand: Bool?
    var refreshed: Bool
    var stale: Bool
    var refreshError: String?
    var iSee: Bool?
    /// MELCloud's weekly timer: on/off and the next known event (cached, read at most every 6 h).
    var weeklyTimerEnabled: Bool?
    var nextTimerEvent: String?

    /// `serviceName` names the service in the summary.
    init(_ result: StateResult, serviceName: String, noErrorCodes: Set<Int>) {
        refreshed = result.refreshed
        stale = result.stale
        refreshError = result.error
        guard let s = result.state else {
            summary = L10n.tr("No status available yet.") + (result.error.map { " \($0)" } ?? "")
            return
        }
        power = s.power
        mode = s.mode?.key
        modeName = s.mode?.displayName
        iSee = s.iSee
        setTemperature = s.setTemperature
        roomTemperature = s.roomTemperature
        outdoorTemperature = s.outdoorTemperature
        fanSpeed = s.fanSpeed.map { $0 == 0 ? "auto" : String($0) }
        actualFanSpeed = s.actualFanSpeed
        vaneVertical = s.vaneVertical?.key
        vaneHorizontal = s.vaneHorizontal?.key
        hasError = s.hasActiveError(noErrorCodes: noErrorCodes)
        errorCode = s.errorCode
        offline = s.offline
        lastCommunication = s.lastCommunication
        wifiSignalDbm = s.wifiSignal
        hasPendingCommand = s.hasPendingCommand
        var parts: [String] = []
        if s.power {
            parts.append(L10n.format("The heat pump is ON in mode %@.", s.mode?.displayName ?? L10n.tr("unknown")))
        } else {
            parts.append(L10n.tr("The heat pump is OFF."))
        }
        if let room = s.roomTemperature { parts.append(L10n.format("Indoor: %.1f °C.", room)) }
        if let set = s.setTemperature { parts.append(L10n.format("Target: %.1f °C.", set)) }
        if let out = s.outdoorTemperature { parts.append(L10n.format("Outdoor: %.1f °C.", out)) }
        if hasError == true { parts.append(L10n.format("Reports an error (code %@).", s.errorCode.map(String.init) ?? L10n.tr("unknown"))) }
        if s.offline { parts.append(L10n.format("Not connected to %@.", serviceName)) }
        if result.stale { parts.append(L10n.tr("Note: the data may be out of date.")) }
        summary = parts.joined(separator: " ")
    }
}

/// Device information for Claude. Serial number and MAC address are deliberately left out.
/// `deviceId` and `buildingId` are the integration's numbers as before device keys: the key's
/// native id and the registry's `buildingId` metadata (0 when unknown).
struct DeviceInfoView: Encodable {
    var name: String
    var deviceId: Int
    var buildingId: Int
    var model: String?
    var firmware: FirmwareView
    var lastServiceDate: Date?
    var numberOfFanSpeeds: Int
    var hasAutomaticFanSpeed: Bool
    var temperatureIncrement: Double
    var limits: TemperatureLimits
    var energyCounters: EnergyCounters
    var wifiSignalDbm: Int?
    /// The indoor unit's own minutes counter in hours (local adapter; likely total running time).
    var runtimeHoursIndoorUnit: Int?
    var knowledge: [String]
}

/// An error-log entry as `get_error_log` has always shown it: `deviceId` is the integration's
/// number (the key's native id).
struct ErrorLogEntryView: Encodable {
    var deviceId: Int
    var start: Date
    var end: Date?
    var message: String
    var code: String?
    var source: String

    init(_ entry: ErrorLogEntry) {
        deviceId = Int(entry.device.nativeId) ?? 0
        start = entry.start
        end = entry.end
        message = entry.message
        code = entry.code
        source = entry.source
    }
}

/// Adapter firmware for `get_device_info` (MELCloud's internal deployment id is left out).
struct FirmwareView: Encodable {
    var version: String?
    var updateAvailable: Bool
    var updateAborted: Bool
    var adapterStatus: String?
    var adaptorType: Int?
    var note: String

    init(_ info: FirmwareInfo) {
        version = info.version
        updateAvailable = info.updateAvailable
        updateAborted = info.updateAborted
        adapterStatus = info.adapterStatus
        adaptorType = info.adaptorType
        note = L10n.tr(
            "Status and starting the update: get_firmware_status and start_firmware_update (requires approval; firmware cannot be rolled back)."
        )
    }
}

/// `get_firmware_status`: what the app shows under Health → Firmware.
struct FirmwareStatusView: Encodable {
    struct Update: Encodable {
        var phase: String
        var status: String
        var filesDownloaded: Int?
        var filesToDownload: Int?
        var retries: Int?
        var minutesOffline: Int?
        var currentPhase: Int?
        var approvalStatus: Int?
        var dateApproved: Date?
        var dateCreated: Date?
    }

    var currentVersion: String?
    var updateAvailable: Bool
    var isOwner: Bool?
    var update: Update?
    var inProgress: Bool
    var canStart: Bool
    var startProblem: String?
    var startedAt: Date?
    var fetchedAt: Date?
    var message: String?
    var warnings: [String]

    init(_ status: FirmwareStatus, serviceName: String, now: Date = Date()) {
        currentVersion = status.currentVersion
        updateAvailable = status.updateAvailable
        isOwner = status.isOwner
        update = status.current.map {
            Update(
                phase: $0.phase.rawValue, status: $0.displayText(serviceName: serviceName), filesDownloaded: $0.filesDownloaded, filesToDownload: $0.filesToDownload,
                retries: $0.retries, minutesOffline: $0.minutesOffline, currentPhase: $0.currentPhase, approvalStatus: $0.approvalStatus,
                dateApproved: $0.dateApproved, dateCreated: $0.dateCreated)
        }
        inProgress = status.isInProgress(now: now)
        canStart = status.canStart
        startProblem = status.startProblem
        startedAt = status.startedAt
        fetchedAt = status.fetchedAt
        message = status.message
        warnings = FirmwareStatus.warnings(serviceName: serviceName)
    }
}
