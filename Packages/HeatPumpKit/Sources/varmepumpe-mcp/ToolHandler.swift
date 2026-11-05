import Foundation
import HeatPumpKit
import MCP

/// Whether the connected client declared MCP elicitation support (set in the initialize hook).
actor ClientCapabilities {
    private(set) var supportsElicitation = false
    func set(supportsElicitation: Bool) { self.supportsElicitation = supportsElicitation }
}

struct ToolHandler: Sendable {
    let service: HeatPumpService
    let server: Server
    let capabilities: ClientCapabilities

    func handle(_ params: CallTool.Parameters) async -> CallTool.Result {
        let args = Arguments(params.arguments)
        do {
            switch params.name {
            case "get_status": return try await getStatus()
            case "get_health_report": return try await getHealthReport()
            case "get_error_log": return try await getErrorLog(args)
            case "get_history": return try await getHistory(args)
            case "get_energy": return try await getEnergy(args)
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
            var buckets: [EnergyBucket]
            var note: String
        }
        let buckets = try await service.energy(period: period, from: from, to: to)
        return try await output(
            View(
                period: period.rawValue, from: WireDate.day(from, timeZone: .current), to: WireDate.day(to, timeZone: .current),
                totalKWh: (buckets.reduce(0) { $0 + $1.totalKWh } * 100).rounded() / 100, buckets: buckets,
                note: "MELCloud oppdaterer energitall med 1,5–3 timers forsinkelse; dager med 0 kWh kan være manglende data."))
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
            name: s.name, deviceId: s.deviceId, buildingId: s.buildingId, serialNumber: s.serialNumber,
            macAddress: s.macAddress, model: "Mitsubishi Electric MSZ-RW25VG (MSZ-RW25VG-SC1)", firmware: s.firmware,
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
        // Make sure a current state exists so the confirmation and the log show old → new.
        _ = try await service.currentState()

        if let declined = await confirm(requested, reason: reason) {
            var outcomes: [ChangeOutcome] = []
            for change in requested {
                outcomes.append(try await service.logRejection(change, source: .claude, reason: reason, error: declined))
            }
            return try await output(outcomes, isError: true)
        }

        var outcomes: [ChangeOutcome] = []
        for change in requested {
            let outcome = try await service.apply(change, source: .claude, reason: reason)
            outcomes.append(outcome)
            if outcome.result != .ok { break }
        }
        return try await output(outcomes, isError: outcomes.contains { $0.result != .ok })
    }

    /// Asks the user through MCP elicitation when the client supports it.
    /// Returns nil when confirmed (or elicitation is unavailable), else a Norwegian reason for rejection.
    private func confirm(_ changes: [DeviceChange], reason: String) async -> String? {
        guard await capabilities.supportsElicitation else { return nil }
        let summary = changes.map(\.displaySummary).joined(separator: ", ")
        let schema = Elicitation.RequestSchema(
            title: "Bekreft endring på varmepumpen",
            properties: [
                "confirm": [
                    "type": "boolean",
                    "title": "Utfør endringen",
                    "description": "Kryss av for å sende endringen til varmepumpen.",
                ]
            ],
            required: ["confirm"])
        do {
            let response = try await server.requestElicitation(
                message: "Claude vil endre varmepumpen: \(summary). Begrunnelse: \(reason)", requestedSchema: schema)
            switch response.action {
            case .accept:
                return response.content?["confirm"]?.boolValue == true ? nil : "Avvist av brukeren i bekreftelsen."
            case .decline:
                return "Avvist av brukeren i bekreftelsen."
            case .cancel:
                return "Bekreftelsen ble avbrutt av brukeren."
            }
        } catch {
            Log.error("elicitation failed: \(error)")
            return "Kunne ikke be brukeren om bekreftelse (\(error.localizedDescription)); endringen ble ikke sendt."
        }
    }

    private func recordMaintenance(_ args: Arguments) async throws -> CallTool.Result {
        guard let kind = args.string("kind").flatMap(MaintenanceKind.init(rawValue:)) else {
            throw ArgumentError(message: "kind må være en av: " + MaintenanceKind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        guard args.string("reason")?.isEmpty == false else { throw ArgumentError(message: "reason er påkrevd") }
        if let text = args.string("date"), args.date("date") == nil {
            throw ArgumentError(message: "Ugyldig dato: \(text)")
        }
        let record = try await service.recordMaintenance(kind: kind, date: args.date("date"), note: args.string("note"))
        return try await output(record)
    }
}
