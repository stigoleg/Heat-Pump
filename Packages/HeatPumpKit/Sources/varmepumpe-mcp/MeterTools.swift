import Foundation
import HeatPumpKit
import MCP

/// Tools for an energy meter (they appear only while a meter is enabled). The helper never opens
/// a live connection of its own: live power is the newest minute the app stored.
enum MeterTools {
    static let tools: [Tool] = [
        Tool(
            name: "get_meter_status",
            description: "The home's energy meter (e.g. Tibber): the newest live power in W (only while the app runs and the home has a real-time reader such as Tibber Pulse; ageSeconds tells how old it is), today's use so far in kWh with its cost in NOK priced like the rest of the app (electricity contract + grid tariff energy charge − electricity subsidy, split per hour), the price of the current hour, and the newest hour the service has reported. Hourly data from the meter's service arrives 2–3 hours late; the rest of today then comes from the live counter (includesLive). Fetches the hours at most hourly.",
            inputSchema: ["type": "object", "properties": [:]],
            annotations: ToolCatalog.readOnly)
    ]
}

/// Answers a meter tool for one meter (`ToolRouter` picks it).
struct MeterToolHandler: Sendable {
    let service: EnergyMeterService
    let name: String

    func handle(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            switch params.name {
            case "get_meter_status": return try await status()
            default: return ToolOutput.failure(L10n.format("Unknown tool: %@", params.name))
            }
        } catch {
            Log.error("\(params.name): \(error)")
            return ToolOutput.failure(service.describe(error))
        }
    }

    private func status() async throws -> CallTool.Result {
        struct Live: Encodable {
            var watts: Double
            var maxWattsThatMinute: Double
            var at: Date
            var ageSeconds: Int
        }
        struct Hour: Encodable {
            var hour: Date
            var kWh: Double
            var costNok: Double?
        }
        struct Today: Encodable {
            var kWh: Double
            var costNok: Double?
            var cost: CostSplit?
            var hoursCovered: Int
            var includesLive: Bool
            var hours: [Hour]
        }
        struct View: Encodable {
            var device: String
            var key: String
            var service: String
            var hasLivePower: Bool
            var livePower: Live?
            var today: Today
            var priceNowOre: Double?
            var latestReportedHour: Date?
            var sync: HouseSync
            var note: String
        }
        let sync = try await service.syncHours()
        guard let status = try await service.status() else { throw HeatPumpError.deviceNotFound }
        let now = Date()
        func r(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
        let view = View(
            device: name, key: status.device.rawValue, service: service.serviceName, hasLivePower: status.hasLivePower,
            livePower: status.live.map {
                Live(
                    watts: $0.powerW.rounded(), maxWattsThatMinute: $0.maxPowerW.rounded(), at: $0.lastReading,
                    ageSeconds: max(0, Int(now.timeIntervalSince($0.lastReading))))
            },
            today: Today(
                kWh: r(status.today.kWh), costNok: status.today.cost.map { ($0.totalNok * 100).rounded() / 100 }, cost: status.today.cost,
                hoursCovered: status.today.hoursCovered, includesLive: status.today.includesLive,
                hours: status.today.hours.map { Hour(hour: $0.hour, kWh: r($0.kWh), costNok: $0.cost?.totalNok) }),
            priceNowOre: status.priceNowOre.map { ($0 * 10).rounded() / 10 }, latestReportedHour: status.latestHour, sync: sync,
            note: status.hasLivePower
                ? L10n.format(
                    "Live power is read by the app while it runs; a reading older than a few minutes means the app is closed or not connected. %@ reports hourly use 2–3 hours late.",
                    service.serviceName)
                : L10n.format(
                    "This home has no live power (it needs a real-time reader). %@ reports hourly use 2–3 hours late.", service.serviceName))
        return ToolOutput.json(Output(result: view, meta: await Meta.current(meter: service, live: status.live)))
    }
}

extension Meta {
    /// Meta for a meter: when the hours were last fetched, the live reading's age and the
    /// integration's block.
    static func current(meter: EnergyMeterService, live: LiveMinute?) async -> Meta {
        let now = Date()
        let synced = (try? await meter.lastHourSync()) ?? nil
        return Meta(
            fetchedAt: live?.lastReading ?? synced, dataAgeSeconds: (live?.lastReading ?? synced).map { max(0, Int(now.timeIntervalSince($0))) },
            blockedUntil: (try? meter.store.blockedUntil(now: now, integration: meter.integration.id)) ?? nil, nextRefreshAllowed: nil,
            historyLastSynced: synced.map { ["hours": $0] } ?? [:], backend: meter.connection.identifier)
    }
}
