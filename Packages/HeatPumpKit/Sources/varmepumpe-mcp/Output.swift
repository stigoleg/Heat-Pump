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
        let snapshot = try? store.latestSnapshot()
        let fetchedAt = state?.fetchedAt ?? snapshot?.state.fetchedAt
        var synced: [String: Date] = [:]
        for kind in ReportKind.allCases {
            if let date = (try? store.fetchState(key: "report.\(kind.rawValue)"))??.lastSuccess {
                synced[kind.rawValue] = date
            }
        }
        return Meta(
            fetchedAt: fetchedAt,
            dataAgeSeconds: fetchedAt.map { max(0, Int(now.timeIntervalSince($0))) },
            blockedUntil: state?.blockedUntil ?? (try? store.blockedUntil(now: now)) ?? nil,
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
            return failure("Kunne ikke lage svar: \(error.localizedDescription)")
        }
    }

    static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: #"{"error":"# + quoted(message) + "}", annotations: nil, _meta: nil)], isError: true)
    }

    private static func quoted(_ text: String) -> String {
        (try? String(decoding: JSONEncoder().encode(text), as: UTF8.self)) ?? "\"\""
    }
}

/// Status shaped for Claude: readable names next to raw values, Norwegian summary.
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

    init(_ result: StateResult) {
        refreshed = result.refreshed
        stale = result.stale
        refreshError = result.error
        guard let s = result.state else {
            summary = "Ingen status tilgjengelig ennå." + (result.error.map { " \($0)" } ?? "")
            return
        }
        power = s.power
        mode = s.mode?.key
        modeName = s.mode?.displayName
        setTemperature = s.setTemperature
        roomTemperature = s.roomTemperature
        outdoorTemperature = s.outdoorTemperature
        fanSpeed = s.fanSpeed.map { $0 == 0 ? "auto" : String($0) }
        actualFanSpeed = s.actualFanSpeed
        vaneVertical = s.vaneVertical?.key
        vaneHorizontal = s.vaneHorizontal?.key
        hasError = s.hasActiveError
        errorCode = s.errorCode
        offline = s.offline
        lastCommunication = s.lastCommunication
        wifiSignalDbm = s.wifiSignal
        hasPendingCommand = s.hasPendingCommand
        var parts: [String] = []
        if s.power {
            parts.append("Varmepumpen er PÅ i modus \(s.mode?.displayName ?? "ukjent").")
        } else {
            parts.append("Varmepumpen er AV.")
        }
        if let room = s.roomTemperature { parts.append(Norwegian.format("Inne: %.1f °C.", room)) }
        if let set = s.setTemperature { parts.append(Norwegian.format("Ønsket: %.1f °C.", set)) }
        if let out = s.outdoorTemperature { parts.append(Norwegian.format("Ute: %.1f °C.", out)) }
        if s.hasActiveError { parts.append("Melder feil (kode \(s.errorCode.map(String.init) ?? "ukjent")).") }
        if s.offline { parts.append("Frakoblet MELCloud.") }
        if result.stale { parts.append("Merk: dataene kan være utdaterte.") }
        summary = parts.joined(separator: " ")
    }
}

struct DeviceInfoView: Encodable {
    var name: String
    var deviceId: Int
    var buildingId: Int
    var serialNumber: String?
    var macAddress: String?
    var model: String
    var firmware: FirmwareInfo
    var lastServiceDate: Date?
    var numberOfFanSpeeds: Int
    var hasAutomaticFanSpeed: Bool
    var temperatureIncrement: Double
    var limits: TemperatureLimits
    var energyCounters: EnergyCounters
    var wifiSignalDbm: Int?
    var knowledge: [String]
}
