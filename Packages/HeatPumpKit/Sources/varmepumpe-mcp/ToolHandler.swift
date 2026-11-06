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
            case "get_forecast": return try await getForecast()
            case "get_house_consumption": return try await getHouseConsumption(args)
            case "get_away_settings": return try await getAwaySettings()
            case "get_weekly_timer": return try await getWeeklyTimer()
            case "set_frost_protection", "set_holiday_mode": return try await writeAway(params.name, args)
            case "get_firmware_status": return try await getFirmwareStatus()
            case "start_firmware_update": return try await startFirmwareUpdate(args)
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
        var view = StatusView(state)
        if state.state != nil, let timer = try? await service.weeklyTimer() {
            view.weeklyTimerEnabled = timer.enabled
            if let next = timer.nextEvent(after: Date(), timeZone: .current) {
                view.nextTimerEvent = "\(next.event.weekdayName) \(next.event.timeText): \(next.event.summary)"
            }
            if timer.enabled == true {
                view.summary += " Ukeplanen i MELCloud er på; varmepumpen kan endre seg selv etter planen."
            }
        }
        return try await output(view, state: state)
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
            var byMode: [EnergyModeShare]?
            var buckets: [EnergyBucket]
            var note: String
        }
        _ = try? await service.syncPrices()
        let buckets = try await service.energy(period: period, from: from, to: to)
        let costs = buckets.compactMap(\.cost)
        let total = costs.isEmpty ? nil : costs.reduce(CostSplit(), +).rounded()
        var split = EnergyModeSplit()
        for bucket in buckets {
            guard let modes = bucket.modes else { continue }
            split.heatingKWh += modes.heatingKWh
            split.coolingKWh += modes.coolingKWh
            split.autoKWh += modes.autoKWh
            split.dryKWh += modes.dryKWh
            split.fanKWh += modes.fanKWh
            split.otherKWh += modes.otherKWh
        }
        let byMode = split.shares.map { share -> EnergyModeShare in
            var s = share
            s.kWh = (s.kWh * 100).rounded() / 100
            s.share = (s.share * 1000).rounded() / 1000
            return s
        }
        return try await output(
            View(
                period: period.rawValue, from: WireDate.day(from, timeZone: .current), to: WireDate.day(to, timeZone: .current),
                totalKWh: (buckets.reduce(0) { $0 + $1.totalKWh } * 100).rounded() / 100,
                costNok: total.map { ($0.totalNok * 100).rounded() / 100 },
                isEstimate: buckets.contains { $0.isEstimate }, cost: total,
                agreement: try await service.priceSettings().agreement.displayName, byMode: byMode.isEmpty ? nil : byMode,
                buckets: buckets,
                note: "MELCloud oppdaterer energitall med 1,5–3 timers forsinkelse; dager med 0 kWh kan være manglende data. "
                    + "byMode er MELCloud sin fordeling på modus (varme, kjøling, auto, avfukting, vifte, annet). "
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
            var level: String?
        }
        struct View: Encodable {
            var agreement: String
            var agreementName: String
            var current: Hour?
            var cheapestAhead: [Hour]
            var today: [Hour]
            var tomorrow: [Hour]?
            var sync: PriceSync?
            var estimate: Estimate?
            var priceControl: PriceControl
            var note: String
        }
        struct EstimateHour: Encodable {
            var hour: String
            var medianOre: Double
            var lowOre: Double
            var highOre: Double
        }
        struct EstimateDay: Encodable {
            var day: String
            var meanOre: Double
            var lowOre: Double
            var highOre: Double
            var cheapestHour: String?
            var mostExpensiveHour: String?
        }
        struct Estimate: Encodable {
            var label = "anslag"
            var basisDays: Int?
            var temperatureAdjusted: Bool
            var days: [EstimateDay]
            var next48Hours: [EstimateHour]
            var method: String
        }
        struct Step: Encodable {
            var from: String
            var to: String
            var kind: String
            var targetC: Double
            var baseC: Double
            var reason: String
            var text: String
        }
        struct PriceControl: Encodable {
            var enabled: Bool
            var reduceExpensiveC: Double
            var reduceVeryExpensiveC: Double
            var minimumC: Double
            var preheat: Bool
            var maxReducedHoursPerDay: Int
            var hoursOverDailyLimit: Int
            var baseSource: String
            var comfortC: Double?
            var appRunning: Bool
            var status: String?
            var statusKind: String?
            var statusAt: Date?
            var problem: String?
            var plan: [Step]
            var planNote: String?
            var note: String
        }
        func r(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        func iso(_ date: Date) -> String { date.formatted(Date.ISO8601FormatStyle(timeZone: .current)) }
        func hour(_ b: PriceBreakdown) -> Hour {
            Hour(
                hour: iso(b.hour), totalOre: r(b.totalOre), energyOre: r(b.energyOre), gridOre: r(b.gridOre),
                supportOre: r(b.supportOre), level: b.level?.rawValue)
        }
        let outlook = try await service.priceOutlook()
        var estimate: Estimate?
        if !outlook.estimate.isEmpty {
            let calendar = Calendar.current
            let days = Dictionary(grouping: outlook.estimate) { calendar.startOfDay(for: $0.hour) }.sorted { $0.key < $1.key }
                .map { day, hours in
                    let n = Double(hours.count)
                    return EstimateDay(
                        day: WireDate.day(day, timeZone: .current), meanOre: r(hours.reduce(0) { $0 + $1.totalOre } / n),
                        lowOre: r(hours.reduce(0) { $0 + $1.lowOre } / n), highOre: r(hours.reduce(0) { $0 + $1.highOre } / n),
                        cheapestHour: hours.min { $0.totalOre < $1.totalOre }.map { iso($0.hour) },
                        mostExpensiveHour: hours.max { $0.totalOre < $1.totalOre }.map { iso($0.hour) })
                }
            estimate = Estimate(
                basisDays: outlook.basisDays, temperatureAdjusted: outlook.temperatureAdjusted, days: days,
                next48Hours: outlook.estimate.prefix(48).map {
                    EstimateHour(hour: iso($0.hour), medianOre: r($0.totalOre), lowOre: r($0.lowOre), highOre: r($0.highOre))
                },
                method: PriceOutlook.methodText)
        }
        let control = try await service.priceControlOverview()
        let now = Date()
        let priceControl = PriceControl(
            enabled: control.settings.enabled, reduceExpensiveC: control.settings.reduceExpensive,
            reduceVeryExpensiveC: control.settings.reduceVeryExpensive, minimumC: control.settings.minimumTemperature,
            preheat: control.settings.preheat, maxReducedHoursPerDay: control.settings.maxReducedHoursPerDay,
            hoursOverDailyLimit: control.plan.overDailyLimit, baseSource: control.plan.baseSource.rawValue, comfortC: control.settings.comfortTemperature,
            appRunning: control.appRunning, status: control.status?.text, statusKind: control.status?.kind.rawValue,
            statusAt: control.status?.updatedAt, problem: control.status?.problem,
            plan: control.plan.changes.map {
                Step(
                    from: iso($0.start), to: iso($0.end), kind: $0.kind.rawValue, targetC: $0.target, baseC: $0.base, reason: $0.reason,
                    text: $0.summary(now: now, timeZone: .current))
            },
            planNote: control.plan.note,
            note: "Prisstyringen kjører bare i appen mens Macen er på og våken, og bare i varmemodus. Den senker ønsket "
                + "temperatur i dyre timer (aldri under minimumC, høyst maxReducedHoursPerDay timer per døgn, de dyreste; endrer "
                + "aldri av/på eller modus) og setter den tilbake etterpå. "
                + "Planen bygger bare på publiserte priser, ikke på anslaget. Claude kan lese den, men ikke slå den av eller på "
                + "eller endre innstillingene; det gjør brukeren under Prognose i appen. Endringene vises i endringsloggen med "
                + "source automation. appRunning false betyr at appen ikke har rapportert de siste minuttene.")
        return try await output(
            View(
                agreement: overview.agreement.rawValue, agreementName: overview.agreementName,
                current: overview.current.map(hour), cheapestAhead: overview.cheapestAhead.map(hour),
                today: overview.today.map(hour), tomorrow: overview.tomorrow.isEmpty ? nil : overview.tomorrow.map(hour),
                sync: overview.sync, estimate: estimate, priceControl: priceControl,
                note: "Priser i øre/kWh inkl. mva: strøm + nettleie (energiledd) − strømstøtte. "
                    + "Morgendagens priser kommer rundt kl. 13. Kapasitetsledd er ikke med. "
                    + "level (VERY_CHEAP … VERY_EXPENSIVE) er Tibbers nivå, eller for andre kilder samme grenser regnet mot "
                    + "snittet siste 72 timer (spotpris). Ingen nivå med Norgespris. estimate er et ANSLAG (usikkert), ikke "
                    + "publiserte priser: median og 25–75 %-område i samme grunnlag som totalOre; si alltid at det er et anslag."
                    + (outlook.estimateMissing.map { " Ingen anslag: " + $0 } ?? "")))
    }

    private func getForecast() async throws -> CallTool.Result {
        let sync = try await service.syncWeather()
        _ = try? await service.syncPrices()
        let now = Date()
        let hourStart = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        let end = hourStart.addingTimeInterval(48 * 3600)
        let forecast = try await service.weatherForecast(from: hourStart, to: end)
        let prices = Dictionary(
            try await service.priceBreakdowns(from: hourStart, to: end).map { ($0.hour, $0) }, uniquingKeysWith: { a, _ in a })
        struct Hour: Encodable {
            var time: String
            var temperature: Double
            var windSpeed: Double?
            var precipitationMm: Double?
            var priceOre: Double?
            var priceLevel: String?
        }
        struct View: Encodable {
            var location: String?
            var locationSource: String?
            var fetchedAt: Date?
            var sync: WeatherSync
            var hours: [Hour]
            var coldestHours: [Hour]
            var cheapestHours: [Hour]
            var mostExpensiveHours: [Hour]
            var tomorrow: TomorrowEstimate?
            var tomorrowText: String?
            var attribution: String
            var note: String
        }
        let hours = forecast.hours.map { h in
            Hour(
                time: h.time.formatted(Date.ISO8601FormatStyle(timeZone: .current)), temperature: h.temperature, windSpeed: h.windSpeed,
                precipitationMm: h.precipitation, priceOre: prices[h.time].map { ($0.totalOre * 10).rounded() / 10 },
                priceLevel: prices[h.time]?.level?.rawValue)
        }
        let priced = hours.filter { $0.priceOre != nil }
        let tomorrow = try await service.tomorrowEstimate()
        return try await output(
            View(
                location: forecast.location?.displayName, locationSource: forecast.location?.source.rawValue,
                fetchedAt: forecast.fetchedAt, sync: sync, hours: hours,
                coldestHours: Array(hours.sorted { $0.temperature < $1.temperature }.prefix(3)),
                cheapestHours: Array(priced.sorted { ($0.priceOre ?? 0) < ($1.priceOre ?? 0) }.prefix(3)),
                mostExpensiveHours: Array(priced.sorted { ($0.priceOre ?? 0) > ($1.priceOre ?? 0) }.prefix(3)),
                tomorrow: tomorrow, tomorrowText: tomorrow?.shortText, attribution: WeatherForecast.attribution,
                note: "Anslaget for i morgen er en enkel modell (forbruk mot graddager, basis 17 °C) fra denne varmepumpens "
                    + "egne data, med et usikkerhetsområde (kWhLow–kWhHigh). pricesFromToday betyr at morgendagens priser ikke "
                    + "er kommet ennå og dagens timepriser er brukt. Forvarming: høyst 1 °C opp et par timer før en kald og dyr "
                    + "periode, og tilbake etterpå; unngå hyppige av/på og store hopp."))
    }

    private func getHouseConsumption(_ args: Arguments) async throws -> CallTool.Result {
        let sync = try await service.syncHouseConsumption()
        let to = args.date("to") ?? Date()
        let from = args.date("from") ?? Calendar.current.startOfDay(for: to.addingTimeInterval(-7 * 86_400))
        let summary = try await service.houseShare(from: from, to: to)
        struct Day: Encodable {
            var day: String
            var houseKWh: Double
            var heatPumpKWh: Double
            var heatPumpShare: Double?
            var hoursWithBoth: Int
            var heatPumpMeasured: Bool
            var houseCostNokFromTibber: Double?
        }
        struct View: Encodable {
            var sync: HouseSync
            var yesterdayText: String?
            var days: [Day]
            var note: String
        }
        let days = summary.days.map {
            Day(
                day: $0.day, houseKWh: $0.houseKWh, heatPumpKWh: $0.heatPumpKWh, heatPumpShare: $0.share.map { ($0 * 1000).rounded() / 1000 },
                hoursWithBoth: $0.hoursWithBoth, heatPumpMeasured: $0.heatPumpMeasured, houseCostNokFromTibber: $0.houseCostNok)
        }
        let yesterday = summary.yesterday?.share.map { Display.format("Varmepumpen sto for %.0f %% av strømmen i går.", $0 * 100) }
        return try await output(
            View(
                sync: sync, yesterdayText: yesterday, days: days,
                note: sync.status == .notConfigured && days.isEmpty
                    ? "Krever en Tibber-nøkkel (Innstillinger → Strømpris i appen)."
                    : "Andelen regnes bare over timer der både huset og varmepumpen har tall (minst 20 timer for et døgn). "
                        + "houseCostNokFromTibber er Tibbers egen kostnad for hele huset (kontrolltall); appens egen "
                        + "kostnadsberegning for varmepumpen (get_energy) er uendret."))
    }

    private func getAwaySettings() async throws -> CallTool.Result {
        let away = try await service.awaySettings()
        let timer = try await service.weeklyTimer()
        struct Frost: Encodable {
            var enabled: Bool
            var minimum: Double
            var maximum: Double
            var summary: String
        }
        struct Holiday: Encodable {
            var enabled: Bool
            var start: String?
            var end: String?
            var summary: String
        }
        struct Event: Encodable {
            var weekday: String
            var time: String
            var action: String
        }
        struct Timer: Encodable {
            var enabled: Bool?
            var eventCount: Int
            var decoded: Bool
            var events: [Event]
            var next: String?
            var fetchedAt: Date?
        }
        struct View: Encodable {
            var frostProtection: Frost?
            var holidayMode: Holiday?
            var fetchedAt: Date?
            var source: String
            var pendingConfirmation: Bool
            var message: String?
            var weeklyTimer: Timer?
            var note: String
        }
        let iso = Date.ISO8601FormatStyle(timeZone: .current)
        let next = timer?.nextEvent(after: Date(), timeZone: .current)
        return try await output(
            View(
                frostProtection: away.frost.map { Frost(enabled: $0.enabled, minimum: $0.minimum, maximum: $0.maximum, summary: $0.summary) },
                holidayMode: away.holiday.map {
                    Holiday(enabled: $0.enabled, start: $0.start?.formatted(iso), end: $0.end?.formatted(iso), summary: $0.summary)
                },
                fetchedAt: away.fetchedAt, source: away.source, pendingConfirmation: away.pendingSince != nil, message: away.message,
                weeklyTimer: timer.map { t in
                    Timer(
                        enabled: t.enabled, eventCount: t.eventCount, decoded: t.decoded,
                        events: t.events.map { Event(weekday: $0.weekdayName, time: $0.timeText, action: $0.summary) },
                        next: next.map { "\($0.event.weekdayName) \($0.event.timeText): \($0.event.summary)" }, fetchedAt: t.fetchedAt)
                },
                note: "Frostsikring holder rommet mellom minimum og maksimum når varmepumpen ellers er av. Feriemodus gjør at "
                    + "varmepumpen følger frostsikringen i perioden. Endepunktene er ikke verifisert mot denne kontoen ennå; "
                    + "den første endringen bør brukeren gjøre selv i appen. Hele ukeplanen står i get_weekly_timer; den endres bare "
                    + "i appen (decoded=false betyr at bare antallet er kjent)."))
    }

    private func getWeeklyTimer() async throws -> CallTool.Result {
        let state = try await service.currentState()
        let timer = state.state != nil ? try await service.weeklyTimer() : try await service.storedWeeklyTimer()
        struct Event: Encodable {
            var weekday: String
            var time: String
            var action: String
            var power: Bool?
            var mode: String?
            var setTemperature: Double?
            var fanSpeed: String?
            var vaneVertical: String?
            var vaneHorizontal: String?
        }
        struct Season: Encodable {
            var name: String
            var startsOn: String
            var inForce: Bool
            var events: [Event]
        }
        struct View: Encodable {
            var enabled: Bool?
            var summary: String
            var decoded: Bool
            var eventCount: Int
            var maxEvents: Int?
            var seasons: [Season]
            var next: String?
            var fetchedAt: Date?
            var note: String
        }
        guard let timer else {
            return try await output(
                View(
                    enabled: nil, summary: "Ukeplanen er ikke hentet fra MELCloud ennå.", decoded: false, eventCount: 0, maxEvents: nil,
                    seasons: [], next: nil, fetchedAt: nil, note: "Prøv igjen senere."),
                state: state)
        }
        let now = Date()
        let active = timer.activeSeasonIndex(on: now, timeZone: .current)
        let next = timer.nextEvent(after: now, timeZone: .current)
        let seasons = timer.seasons.indices.map { index in
            let season = timer.seasons[index]
            let events = (1...7).flatMap { season.events(on: $0) }.map { e in
                Event(
                    weekday: e.weekdayName, time: e.timeText, action: e.summary, power: e.power, mode: e.mode?.key,
                    setTemperature: e.setTemperature, fanSpeed: e.fanSpeed.map { $0 == 0 ? "auto" : String($0) },
                    vaneVertical: e.vaneVertical?.key, vaneHorizontal: e.vaneHorizontal?.key)
            }
            return Season(
                name: season.name ?? "Default", startsOn: season.displayName, inForce: index == active, events: events)
        }
        return try await output(
            View(
                enabled: timer.enabled, summary: timer.summary, decoded: timer.decoded, eventCount: timer.totalEvents,
                maxEvents: timer.maxEvents, seasons: seasons,
                next: next.map { "\($0.event.weekdayName) \($0.event.timeText): \($0.event.summary)" }, fetchedAt: timer.fetchedAt,
                note: "Ukeplanen ligger i MELCloud og kjører selv om Macen er av. En endring med set_* varer til neste hendelse i planen. "
                    + "Claude kan bare lese planen; brukeren lager og endrer den i appen (siden Ukeplan)."),
            state: state)
    }

    private func writeAway(_ tool: String, _ args: Arguments) async throws -> CallTool.Result {
        guard let reason = args.string("reason")?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            throw ArgumentError(message: "reason er påkrevd for alle endringer")
        }
        guard let enabled = args.bool("enabled") else { throw ArgumentError(message: "enabled (true/false) mangler") }
        // Current values for the log (old → new); MELCloud is read at most hourly.
        let current = try await service.awaySettings()
        let change: AwayChange
        if tool == "set_frost_protection" {
            // Never guess a range: missing values keep the current ones, and when those are unknown
            // the caller must give both (otherwise the user's range could be overwritten).
            guard let fp = FrostProtection.resolving(
                enabled: enabled, minimum: args.double("minimum"), maximum: args.double("maximum"), current: current.frost)
            else {
                throw ArgumentError(
                    message: "Nåværende frostsikring er ukjent (kunne ikke leses fra MELCloud). Oppgi både minimum og maximum, "
                        + "så det er tydelig hvilket område som sendes.")
            }
            change = .frostProtection(fp)
        } else {
            for key in ["start", "end"] {
                if let text = args.string(key), args.date(key) == nil { throw ArgumentError(message: "Ugyldig dato i \(key): \(text)") }
            }
            change = .holidayMode(
                HolidayMode(
                    enabled: enabled, start: args.date("start") ?? (enabled ? nil : current.holiday?.start),
                    end: args.date("end") ?? (enabled ? nil : current.holiday?.end)))
        }
        // Same native approval dialog as the other set_* tools; never bypassed.
        let outcome = try await service.applyAway(change, source: .claude, reason: reason, approver: approver)
        return try await output(outcome, isError: outcome.result != .ok)
    }

    private func getFirmwareStatus() async throws -> CallTool.Result {
        let state = try await service.currentState()
        return try await output(FirmwareStatusView(try await service.firmwareStatus()), state: state)
    }

    private func startFirmwareUpdate(_ args: Arguments) async throws -> CallTool.Result {
        guard let reason = args.string("reason")?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            throw ArgumentError(message: "reason er påkrevd for alle endringer")
        }
        // Make sure a current state exists (owner, waiting update, connection).
        _ = try await service.currentState()
        // Same native approval dialog as the other set_* tools; never bypassed.
        let outcome = try await service.startFirmwareUpdate(source: .claude, reason: reason, approver: approver)
        return try await output(outcome, isError: outcome.result != .ok)
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
                phase: s.phase?.rawValue, phaseText: s.statusLine, phaseExplanation: s.phase?.explanation,
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
            runtimeHoursIndoorUnit: (try? await service.storedLiveStatus())?.sample?.runtimeHours,
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
