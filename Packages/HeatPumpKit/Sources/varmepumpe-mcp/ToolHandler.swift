import Foundation
import HeatPumpKit
import MCP

struct ToolHandler: Sendable {
    let service: HeatPumpService
    /// Asks the user (native dialog) before any change reaches the heat pump.
    let approver: any ChangeApprover

    func handle(_ params: CallTool.Parameters) async -> CallTool.Result {
        let args = Arguments(params.arguments)
        do {
            switch params.name {
            case "get_status": return try await getStatus()
            case "get_health_report": return try await getHealthReport()
            case "get_error_log": return try await getErrorLog(args)
            case "get_history": return try await getHistory(args)
            case "get_energy": return try await getEnergy(args)
            case "get_prices": return try await getPrices()
            case "get_live_status": return try await getLiveStatus()
            case "get_maintenance_status": return try await output(try await service.maintenanceStatus())
            case "get_change_log": return try await getChangeLog(args)
            case "get_device_info": return try await getDeviceInfo()
            case "refresh": return try await refresh(args)
            case "set_power", "set_mode", "set_temperature", "set_fan_speed", "set_vanes":
                return try await write(params.name, args)
            case "record_maintenance": return try await recordMaintenance(args)
            default: return ToolOutput.failure("Ukjent verktøy: \(params.name)")
            }
        } catch let error as ArgumentError {
            return ToolOutput.failure(error.message)
        } catch {
            Log.error("\(params.name): \(error)")
            return ToolOutput.failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func output<T: Encodable>(_ value: T, state: StateResult? = nil, isError: Bool = false) async throws -> CallTool.Result {
        ToolOutput.json(Output(result: value, meta: await Meta.current(service: service, state: state)), isError: isError)
    }

    /// Runs the hourly-limited history sync; failures are logged, not fatal for reads.
    private func syncQuietly() async {
        do {
            _ = try await service.syncHistory()
        } catch {
            Log.error("syncHistory: \(error)")
        }
    }

    // MARK: Read tools

    private func getStatus() async throws -> CallTool.Result {
        let state = try await service.currentState()
        return try await output(StatusView(state), state: state)
    }

    private func getHealthReport() async throws -> CallTool.Result {
        let state = try await service.currentState()
        await syncQuietly()
        return try await output(try await service.healthReport(), state: state)
    }

    private func getErrorLog(_ args: Arguments) async throws -> CallTool.Result {
        await syncQuietly()
        let days = min(max(args.int("days") ?? 90, 1), 365)
        let entries = try await service.errorLog(days: days)
        struct View: Encodable {
            var days: Int
            var count: Int
            var entries: [ErrorLogEntry]
            var caveat: String
        }
        return try await output(View(days: days, count: entries.count, entries: entries, caveat: ErrorCatalog.caveat))
    }

    private func getHistory(_ args: Arguments) async throws -> CallTool.Result {
        guard let metric = args.string("metric").flatMap(HistoryMetric.init(rawValue:)) else {
            throw ArgumentError(message: "metric må være en av: " + HistoryMetric.allCases.map(\.rawValue).joined(separator: ", "))
        }
        await syncQuietly()
        let to = args.date("to") ?? Date()
        let from = args.date("from") ?? to.addingTimeInterval(-86_400)
        struct View: Encodable {
            var metric: String
            var from: Date
            var to: Date
            var count: Int
            var points: [HistoryPoint]
        }
        let points = try await service.history(metric: metric, from: from, to: to)
        return try await output(View(metric: metric.rawValue, from: from, to: to, count: points.count, points: points))
    }

    private func getEnergy(_ args: Arguments) async throws -> CallTool.Result {
        guard let period = args.string("period").flatMap(EnergyPeriod.init(rawValue:)) else {
            throw ArgumentError(message: "period må være day, week eller month")
        }
        await syncQuietly()
        let to = args.date("to") ?? Date()
        let defaultDays: Double =
            switch period {
            case .day: 14
            case .week: 56
            case .month: 365
            }
        let from = args.date("from") ?? to.addingTimeInterval(-defaultDays * 86_400)
        struct View: Encodable {
            var period: String
            var from: String
            var to: String
            var totalKWh: Double
            var costNok: Double?
            var isEstimate: Bool
            var cost: CostSplit?
            var agreement: String
            var buckets: [EnergyBucket]
            var note: String
        }
        _ = try? await service.syncPrices()
        let buckets = try await service.energy(period: period, from: from, to: to)
        let costs = buckets.compactMap(\.cost)
        let total = costs.isEmpty ? nil : costs.reduce(CostSplit(), +).rounded()
        return try await output(
            View(
                period: period.rawValue, from: WireDate.day(from, timeZone: .current), to: WireDate.day(to, timeZone: .current),
                totalKWh: (buckets.reduce(0) { $0 + $1.totalKWh } * 100).rounded() / 100,
                costNok: total.map { ($0.totalNok * 100).rounded() / 100 },
                isEstimate: buckets.contains { $0.isEstimate }, cost: total,
                agreement: try await service.priceSettings().agreement.displayName, buckets: buckets,
                note: "MELCloud oppdaterer energitall med 1,5–3 timers forsinkelse; dager med 0 kWh kan være manglende data. "
                    + "Kostnad = kWh × (strømpris + nettleiens energiledd − strømstøtte), i kroner inkl. mva. "
                    + "Kapasitetsleddet i nettleien er ikke med. isEstimate betyr at deler av døgnet er priset med "
                    + "døgnets snittpris fordi forbruk per time mangler."))
    }

    private func getPrices() async throws -> CallTool.Result {
        let overview = try await service.priceOverview()
        struct Hour: Encodable {
            var hour: String
            var totalOre: Double
            var energyOre: Double
            var gridOre: Double
            var supportOre: Double
        }
        struct View: Encodable {
            var agreement: String
            var agreementName: String
            var current: Hour?
            var cheapestAhead: [Hour]
            var today: [Hour]
            var tomorrow: [Hour]?
            var sync: PriceSync?
            var note: String
        }
        func hour(_ b: PriceBreakdown) -> Hour {
            func r(_ v: Double) -> Double { (v * 10).rounded() / 10 }
            return Hour(
                hour: b.hour.formatted(Date.ISO8601FormatStyle(timeZone: .current)), totalOre: r(b.totalOre), energyOre: r(b.energyOre), gridOre: r(b.gridOre),
                supportOre: r(b.supportOre))
        }
        return try await output(
            View(
                agreement: overview.agreement.rawValue, agreementName: overview.agreementName,
                current: overview.current.map(hour), cheapestAhead: overview.cheapestAhead.map(hour),
                today: overview.today.map(hour), tomorrow: overview.tomorrow.isEmpty ? nil : overview.tomorrow.map(hour),
                sync: overview.sync,
                note: "Priser i øre/kWh inkl. mva: strøm + nettleie (energiledd) − strømstøtte. "
                    + "Morgendagens priser kommer rundt kl. 13. Kapasitetsledd er ikke med."))
    }

    private func getLiveStatus() async throws -> CallTool.Result {
        let summary = try await service.liveSummary(maxAge: 60)
        struct Reading: Encodable {
            var timestamp: Date
            var ageSeconds: Int?
            var powerW: Int?
            var compressorHz: Int?
            var compressorRunning: Bool
            var roomTemperature: Double?
            var outdoorTemperature: Double?
            var setTemperature: Double?
            var power: Bool?
            var mode: String?
            var modeName: String?
            var fanSpeed: String?
            var errorCode: String?
            var hasError: Bool
            var energyCounterKWh: Double?
            var adapterVersion: String?
            var rssiDbm: Int?
            var cloudConnected: Bool?
            var phase: String?
            var phaseText: String?
            var phaseExplanation: String?
            var subMode: Int?
            var stage: Int?
            var autoSubMode: Int?
            var runtimeHoursIndoorUnit: Int?
        }
        struct View: Encodable {
            var enabled: Bool
            var reading: Reading?
            var refreshed: Bool
            var message: String?
            var lastSuccess: Date?
            var consecutiveFailures: Int
            var lastError: String?
            var startsLastHour: Int
            var startsLast3Hours: Int
            var startsLast24Hours: Int
            var observedHoursLast24: Double
            var powerLast60Minutes: LiveSummary.PowerStats?
            var defrostsLast24Hours: Int?
            var defrostMinutesLast24Hours: Double?
            var note: String
        }
        let live = summary.live
        let reading = live.sample.map { s in
            Reading(
                timestamp: s.timestamp, ageSeconds: live.ageSeconds, powerW: s.powerW, compressorHz: s.compressorHz,
                compressorRunning: s.isRunning, roomTemperature: s.roomTemperature, outdoorTemperature: s.outdoorTemperature,
                setTemperature: s.setTemperature, power: s.power, mode: s.mode?.key, modeName: s.mode?.displayName,
                fanSpeed: s.fanSpeed.map { $0 == 0 ? "auto" : String($0) },
                errorCode: s.errorCode.map { String(format: "0x%04X", $0) }, hasError: s.hasError, energyCounterKWh: s.energyKWh,
                adapterVersion: s.adapterVersion, rssiDbm: s.rssi, cloudConnected: s.cloudConnected,
                phase: s.phase?.rawValue, phaseText: s.phase?.statusLine, phaseExplanation: s.phase?.explanation,
                subMode: s.subMode, stage: s.stage, autoSubMode: s.autoSubMode, runtimeHoursIndoorUnit: s.runtimeHours)
        }
        return try await output(
            View(
                enabled: live.reachability.enabled, reading: reading, refreshed: live.refreshed, message: live.message,
                lastSuccess: live.reachability.lastSuccess, consecutiveFailures: live.reachability.consecutiveFailures,
                lastError: live.reachability.lastError, startsLastHour: summary.startsLastHour,
                startsLast3Hours: summary.startsLast3Hours, startsLast24Hours: summary.startsLast24Hours,
                observedHoursLast24: summary.observedHoursLast24, powerLast60Minutes: summary.powerLast60Minutes,
                defrostsLast24Hours: summary.defrostsLast24Hours, defrostMinutesLast24Hours: summary.defrostMinutesLast24Hours,
                note: "Lest lokalt fra Wi-Fi-modulen (kun lesing). Effekten gjelder hele varmepumpen. "
                    + "Kompressorstarter og avriminger telles bare når appen eller Claude har lest minst hvert 5. minutt; "
                    + "observedHoursLast24 sier hvor mye av døgnet som er dekket. Feilkode 0x8000 betyr ingen feil. "
                    + "phase: off/defrost/preheat/warmup/standby/resting/heating/cooling/drying/fan/running. "
                    + "Avriming (defrost) er normalt i fuktig kulde, typisk 3–10 minutter hvert 40.–90. driftsminutt. "
                    + "stage og autoSubMode er rå verdier med usikker betydning. runtimeHoursIndoorUnit er innedelens "
                    + "egen teller (trolig total driftstid), ikke verifisert mot produsenten."))
    }

    private func getChangeLog(_ args: Arguments) async throws -> CallTool.Result {
        let limit = min(max(args.int("limit") ?? 20, 1), 500)
        let source = args.string("source").flatMap(ChangeSource.init(rawValue:))
        return try await output(try await service.changeLog(limit: limit, source: source))
    }

    private func getDeviceInfo() async throws -> CallTool.Result {
        let state = try await service.currentState()
        guard let s = state.state else {
            return try await output(StatusView(state), state: state, isError: true)
        }
        let view = DeviceInfoView(
            name: s.name, deviceId: s.deviceId, buildingId: s.buildingId, model: "Mitsubishi Electric MSZ-RW25VG (MSZ-RW25VG-SC1)", firmware: FirmwareView(s.firmware),
            lastServiceDate: s.lastServiceDate, numberOfFanSpeeds: s.numberOfFanSpeeds,
            hasAutomaticFanSpeed: s.hasAutomaticFanSpeed, temperatureIncrement: s.temperatureIncrement,
            limits: s.limits, energyCounters: s.energy, wifiSignalDbm: s.wifiSignal,
            knowledge: Knowledge.all().map(\.uri))
        return try await output(view, state: state)
    }

    private func refresh(_ args: Arguments) async throws -> CallTool.Result {
        let state = try await service.currentState(force: args.bool("force") ?? false)
        let reports = try await service.syncHistory()
        struct View: Encodable {
            var status: StatusView
            var reports: [ReportSync]
        }
        return try await output(View(status: StatusView(state), reports: reports), state: state)
    }

    // MARK: Write tools

    private func changes(for tool: String, _ args: Arguments) throws -> [DeviceChange] {
        switch tool {
        case "set_power":
            guard let on = args.bool("on") else { throw ArgumentError(message: "on (true/false) mangler") }
            return [.power(on)]
        case "set_mode":
            guard let mode = args.string("mode").flatMap(OperationMode.init(key:)) else {
                throw ArgumentError(message: "mode må være heat, dry, cool, fan eller auto")
            }
            return [.mode(mode)]
        case "set_temperature":
            guard let celsius = args.double("celsius") else { throw ArgumentError(message: "celsius mangler") }
            return [.temperature(celsius)]
        case "set_fan_speed":
            guard let speed = args.int("speed") else { throw ArgumentError(message: "speed mangler") }
            return [.fanSpeed(speed)]
        case "set_vanes":
            var result: [DeviceChange] = []
            if let key = args.string("vertical") {
                guard let vane = VaneVertical(key: key) else { throw ArgumentError(message: "Ugyldig vertical: \(key)") }
                result.append(.vaneVertical(vane))
            }
            if let key = args.string("horizontal") {
                guard let vane = VaneHorizontal(key: key) else { throw ArgumentError(message: "Ugyldig horizontal: \(key)") }
                result.append(.vaneHorizontal(vane))
            }
            guard !result.isEmpty else { throw ArgumentError(message: "Oppgi vertical og/eller horizontal") }
            return result
        default:
            throw ArgumentError(message: "Ukjent verktøy \(tool)")
        }
    }

    private func write(_ tool: String, _ args: Arguments) async throws -> CallTool.Result {
        guard let reason = args.string("reason")?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            throw ArgumentError(message: "reason er påkrevd for alle endringer")
        }
        let requested = try changes(for: tool, args)
        // Make sure a current state exists so the dialog and the log show old → new.
        _ = try await service.currentState()
        // Every pump write waits for the user's answer in the helper's own dialog,
        // whatever the MCP client or its permission mode is.
        let outcomes = try await service.applyWithApproval(requested, source: .claude, reason: reason, approver: approver)
        return try await output(outcomes, isError: outcomes.contains { $0.result != .ok })
    }

    private func recordMaintenance(_ args: Arguments) async throws -> CallTool.Result {
        guard let kind = args.string("kind").flatMap(MaintenanceKind.init(rawValue:)) else {
            throw ArgumentError(message: "kind må være en av: " + MaintenanceKind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        guard args.string("reason")?.isEmpty == false else { throw ArgumentError(message: "reason er påkrevd") }
        if let text = args.string("date"), args.date("date") == nil {
            throw ArgumentError(message: "Ugyldig dato: \(text)")
        }
        let record = try await service.recordMaintenance(
            kind: kind, date: args.date("date"), note: args.string("note"), reason: args.string("reason"))
        return try await output(record)
    }
}
