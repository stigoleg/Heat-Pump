import Foundation
import HeatPumpKit
import MCP

/// Tools for air quality sensors (they appear only while a sensor is enabled). Read-only: the
/// sensors have nothing to control.
enum AirQualityTools {
    static let tools: [Tool] = [
        Tool(
            name: "get_air_quality",
            description: "The user's indoor air quality sensors (radon monitors and the like): the newest radon short-term average (about the last 24 h) and long-term average in Bq/m³, CO2 (ppm), VOC (ppb), PM2.5/PM1 (µg/m³), humidity (%), temperature (°C), air pressure (hPa) and battery (%), each with a level (good/fair/poor) from the sensor's own thresholds (thresholdsFromDevice) or common defaults, plus findings with advice. With a hub the sensors report every 5 minutes (radon hourly); without one only when the vendor's phone app syncs over Bluetooth, so check recorded. Fetched at most every 5 minutes. Without device every sensor is returned. Radon is judged by the annual average: the Norwegian authority DSA's action level is 100 Bq/m³ and limit 200 Bq/m³, measured for at least two months in the winter half-year; never treat a short-term value as a verdict.",
            inputSchema: ["type": "object", "properties": [:]],
            annotations: ToolCatalog.readOnly),
        Tool(
            name: "get_air_quality_history",
            description: "History of one air quality sensor value from the stored hourly averages (up to two years; the newest hours are fetched at most hourly): per hour, or per day with average, minimum and maximum. Default: the last 7 days per hour; ranges over 14 days default to days. Use it for trends (does CO2 rise at night, does radon follow the weather, has the long-term average changed).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "metric": ["type": "string", "enum": .array(AirQualityMetric.allCases.map { .string($0.rawValue) })],
                    "from": ["type": "string", "description": "ISO 8601 date or date-time (default: 7 days ago)."],
                    "to": ["type": "string", "description": "ISO 8601 date or date-time (default: now)."],
                    "period": ["type": "string", "enum": ["hour", "day"], "description": "Default: hour up to 14 days, else day."],
                ],
                "required": ["metric"],
            ],
            annotations: ToolCatalog.readOnly),
    ]
}

/// Answers an air quality tool for one or more sensors (`ToolRouter` picks them).
struct AirQualityToolHandler: Sendable {
    /// The sensors and their names; `get_air_quality_history` gets exactly one.
    let sensors: [(service: AirQualityService, name: String)]

    func handle(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            switch params.name {
            case "get_air_quality": return try await latest()
            case "get_air_quality_history": return try await history(Arguments(params.arguments))
            default: return ToolOutput.failure(L10n.format("Unknown tool: %@", params.name))
            }
        } catch let error as ArgumentError {
            return ToolOutput.failure(error.message)
        } catch {
            Log.error("\(params.name): \(error)")
            return ToolOutput.failure(sensors.first?.service.describe(error) ?? error.localizedDescription)
        }
    }

    struct Value: Encodable {
        var metric: String
        var name: String
        var value: Double
        var unit: String
        var level: String?
    }

    struct Finding: Encodable {
        var code: String
        var severity: String
        var title: String
        var detail: String
        var recommendation: String
    }

    struct Sensor: Encodable {
        var device: String
        var key: String
        var service: String
        var recorded: Date?
        var ageSeconds: Int?
        var values: [Value]
        var worstLevel: String?
        var thresholdsFromDevice: Bool
        var findings: [Finding]
        var sync: HouseSync
    }

    private func latest() async throws -> CallTool.Result {
        struct View: Encodable {
            var sensors: [Sensor]
            var note: String
        }
        var views: [Sensor] = []
        let now = Date()
        for (service, name) in sensors {
            let sync = try await service.syncLatest()
            guard let status = try await service.status() else {
                views.append(
                    Sensor(
                        device: name, key: service.device?.rawValue ?? "", service: service.serviceName, values: [],
                        thresholdsFromDevice: false, findings: [], sync: sync))
                continue
            }
            views.append(
                Sensor(
                    device: name, key: status.device.rawValue, service: service.serviceName, recorded: status.recorded,
                    ageSeconds: status.recorded.map { max(0, Int(now.timeIntervalSince($0))) },
                    values: status.values.map {
                        Value(metric: $0.metric.rawValue, name: $0.metric.title, value: Self.rounded($0.value, $0.metric), unit: $0.metric.unit, level: $0.level?.rawValue)
                    },
                    worstLevel: status.worstLevel?.rawValue, thresholdsFromDevice: status.thresholdsFromDevice,
                    findings: status.findings.map {
                        Finding(code: $0.code, severity: $0.severity.rawValue, title: $0.title, detail: $0.detail, recommendation: $0.recommendation)
                    },
                    sync: sync))
        }
        let note = L10n.tr(
            "Radon is judged by the annual average: measures are recommended from 100 Bq/m³ and the limit is 200 Bq/m³. Short-term values swing with weather and ventilation.")
        return ToolOutput.json(Output(result: View(sensors: views, note: note), meta: await Meta.current(sensor: sensors.first?.service)))
    }

    private func history(_ arguments: Arguments) async throws -> CallTool.Result {
        guard let (service, name) = sensors.first else { throw HeatPumpError.deviceNotFound }
        guard let raw = arguments.string("metric"), let metric = AirQualityMetric(rawValue: raw) else {
            throw ArgumentError(
                message: L10n.format("metric must be one of: %@.", AirQualityMetric.allCases.map(\.rawValue).joined(separator: ", ")))
        }
        let now = Date()
        let to = arguments.date("to") ?? now
        let from = arguments.date("from") ?? to.addingTimeInterval(-7 * 86_400)
        guard from < to else { throw ArgumentError(message: L10n.tr("from must be before to.")) }
        let perDay = (arguments.string("period") ?? (to.timeIntervalSince(from) > 14 * 86_400 ? "day" : "hour")) == "day"
        _ = try await service.syncHistory()
        let hours = try await service.hours(from: from, to: to).compactMap { hour in hour.values[metric].map { (hour.hour, $0) } }

        struct Point: Encodable {
            var time: Date
            var value: Double
            var min: Double?
            var max: Double?
        }
        struct View: Encodable {
            var device: String
            var key: String
            var metric: String
            var name: String
            var unit: String
            var period: String
            var points: [Point]
        }
        let points: [Point]
        if perDay {
            let calendar = Calendar.current
            let days = Dictionary(grouping: hours) { calendar.startOfDay(for: $0.0) }
            points = days.keys.sorted().map { day in
                let values = days[day, default: []].map(\.1)
                return Point(
                    time: day, value: Self.rounded(values.reduce(0, +) / Double(values.count), metric),
                    min: values.min().map { Self.rounded($0, metric) }, max: values.max().map { Self.rounded($0, metric) })
            }
        } else {
            points = hours.map { Point(time: $0.0, value: Self.rounded($0.1, metric)) }
        }
        let view = View(
            device: name, key: service.device?.rawValue ?? "", metric: metric.rawValue, name: metric.title, unit: metric.unit,
            period: perDay ? "day" : "hour", points: points)
        return ToolOutput.json(Output(result: view, meta: await Meta.current(sensor: service)))
    }

    static func rounded(_ value: Double, _ metric: AirQualityMetric) -> Double {
        metric.fractionDigits == 1 ? (value * 10).rounded() / 10 : value.rounded()
    }
}

extension Meta {
    /// Meta for air quality sensors: when the newest values were fetched and the integration's block.
    static func current(sensor: AirQualityService?) async -> Meta {
        let now = Date()
        let synced = (try? await sensor?.lastSync()) ?? nil
        let blocked = sensor.flatMap { (try? $0.store.blockedUntil(now: now, integration: $0.integration.id)) ?? nil }
        return Meta(
            fetchedAt: synced, dataAgeSeconds: synced.map { max(0, Int(now.timeIntervalSince($0))) }, blockedUntil: blocked,
            nextRefreshAllowed: nil, historyLastSynced: synced.map { ["latest": $0] } ?? [:],
            backend: sensor?.connection.identifier ?? "")
    }
}
