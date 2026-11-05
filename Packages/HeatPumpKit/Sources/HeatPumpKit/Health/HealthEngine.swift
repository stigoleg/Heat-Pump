import Foundation

/// Everything the health rules look at. Built by `HeatPumpService`, or directly in tests.
public struct HealthInput: Sendable {
    public var latestState: DeviceState?
    /// Snapshots, any order; the engine sorts.
    public var snapshots: [DeviceState]
    /// Temperature log points (outdoor temperature source for degree-days).
    public var temperaturePoints: [TemperaturePoint]
    public var errorEvents: [ErrorLogEntry]
    public var energyDays: [EnergyDay]
    public var maintenance: [MaintenanceRecord]
    public var now: Date
    public var timeZone: TimeZone

    public init(
        latestState: DeviceState?, snapshots: [DeviceState] = [], temperaturePoints: [TemperaturePoint] = [],
        errorEvents: [ErrorLogEntry] = [], energyDays: [EnergyDay] = [], maintenance: [MaintenanceRecord] = [],
        now: Date, timeZone: TimeZone = .current
    ) {
        self.latestState = latestState
        self.snapshots = snapshots
        self.temperaturePoints = temperaturePoints
        self.errorEvents = errorEvents
        self.energyDays = energyDays
        self.maintenance = maintenance
        self.now = now
        self.timeZone = timeZone
    }
}

/// Pure health rules. All display text is Norwegian bokmål.
public enum HealthEngine {
    public enum Threshold {
        public static let offlineAfter: TimeInterval = 3600
        public static let wifiWarning = -80
        public static let wifiInfo = -70
        public static let setpointGap = 1.5
        public static let setpointDuration: TimeInterval = 2 * 3600
        public static let recentErrorDays = 30
        public static let degreeDayBase = 17.0
        public static let energyInfoFactor = 1.5
        public static let energyWarningFactor = 2.0
        public static let energyMinBaselineDays = 7
        public static let energyBaselineDays = 14
        public static let airFilterInfoDays = 14
        public static let airFilterWarningDays = 30
        public static let deodorizingFilterDays = 90
    }

    public static func evaluate(_ input: HealthInput) -> HealthReport {
        var findings: [HealthFinding] = []
        if let state = input.latestState {
            findings += activeError(state)
            findings += connectivity(state, now: input.now)
            findings += wifi(state)
            findings += setpointNotReached(input)
            findings += firmware(state)
        } else {
            findings.append(
                HealthFinding(
                    code: "no_data", severity: .info, title: "Ikke nok data ennå",
                    detail: "Det er ikke hentet noen status fra varmepumpen ennå, så helsesjekken er begrenset.",
                    recommendation: "Hent status (oppdater) og kjør helsesjekken igjen om litt."))
        }
        findings += errorLog(input)
        findings += energyAnomaly(input)
        findings += maintenance(input)
        if !findings.contains(where: { $0.severity >= .warning }) && input.latestState != nil {
            findings.append(
                HealthFinding(
                    code: "all_ok", severity: .ok, title: "Varmepumpen ser ut til å fungere normalt",
                    detail: "Ingen feil, advarsler eller avvik er funnet i dataene vi har.",
                    recommendation: "Ingen tiltak nødvendig utover vanlig vedlikehold."))
        }
        return HealthReport(generatedAt: input.now, findings: findings)
    }

    // MARK: Rules

    static func activeError(_ state: DeviceState) -> [HealthFinding] {
        guard state.hasActiveError else { return [] }
        let entry = ErrorCatalog.lookup(errorCode: state.errorCode)
        let code = state.errorCode.map { "Feilkode \($0)." } ?? "MELCloud melder feil uten kode."
        return [
            HealthFinding(
                code: "active_error", severity: .critical, title: "Varmepumpen melder feil nå",
                detail: "\(code) \(entry.title): \(entry.explanation)"
                    + (entry.confidence == .low || entry.confidence == .unknown ? " \(ErrorCatalog.caveat)" : ""),
                recommendation: "Sjekk om driftslampen på innedelen blinker, og tell antall blink. " + entry.recommendation)
        ]
    }

    static func connectivity(_ state: DeviceState, now: Date) -> [HealthFinding] {
        let silentFor = state.lastCommunication.map { now.timeIntervalSince($0) }
        guard state.offline || (silentFor ?? 0) > Threshold.offlineAfter else { return [] }
        let since = state.lastCommunication.map { "Siste kontakt: \(Norwegian.dateTime($0))." } ?? ""
        return [
            HealthFinding(
                code: "offline", severity: .warning, title: "Varmepumpen har ikke kontakt med MELCloud",
                detail: "Wi-Fi-modulen har ikke rapportert inn på over en time. \(since) Varmepumpen kan fortsatt varme som normalt, men vi ser ikke hva den gjør.",
                recommendation: "Sjekk at ruteren og internett virker, og at varmepumpen har strøm. Hjelper ikke det, slå av sikringen til varmepumpen i ett minutt og slå den på igjen.")
        ]
    }

    static func wifi(_ state: DeviceState) -> [HealthFinding] {
        // MELCloud reports dBm (negative). Ignore values that do not look like dBm.
        guard let rssi = state.wifiSignal, rssi < 0 else { return [] }
        if rssi < Threshold.wifiWarning {
            return [
                HealthFinding(
                    code: "wifi_weak", severity: .warning, title: "Svakt Wi-Fi-signal",
                    detail: "Signalstyrken er \(rssi) dBm, som er svakt. Det kan gi brudd i kontakten med MELCloud.",
                    recommendation: "Flytt ruteren nærmere, eller sett opp en Wi-Fi-forsterker/mesh-node nær innedelen.")
            ]
        }
        if rssi < Threshold.wifiInfo {
            return [
                HealthFinding(
                    code: "wifi_fair", severity: .info, title: "Middels Wi-Fi-signal",
                    detail: "Signalstyrken er \(rssi) dBm. Det fungerer som regel, men er ikke sterkt.",
                    recommendation: "Ingen tiltak nødvendig nå. Hvis kontakten faller ut, vurder bedre Wi-Fi-dekning ved innedelen.")
            ]
        }
        return []
    }

    static func setpointNotReached(_ input: HealthInput) -> [HealthFinding] {
        let sorted = input.snapshots.sorted { $0.fetchedAt < $1.fetchedAt }
        // Trailing run of snapshots where the unit heats but the room stays ≥ 1.5 °C below setpoint.
        var run: [DeviceState] = []
        for snapshot in sorted.reversed() {
            guard snapshot.power, snapshot.mode == .heat,
                let room = snapshot.roomTemperature, let set = snapshot.setTemperature,
                set - room >= Threshold.setpointGap
            else { break }
            run.insert(snapshot, at: 0)
        }
        guard run.count >= 2, let first = run.first, let last = run.last,
            last.fetchedAt.timeIntervalSince(first.fetchedAt) >= Threshold.setpointDuration,
            input.now.timeIntervalSince(last.fetchedAt) < 3 * 3600
        else { return [] }
        let hours = Int(last.fetchedAt.timeIntervalSince(first.fetchedAt) / 3600)
        let outdoor = last.outdoorTemperature.map { Norwegian.format(" Ute er det %.0f °C.", $0) } ?? ""
        return [
            HealthFinding(
                code: "setpoint_not_reached", severity: .warning, title: "Rommet når ikke ønsket temperatur",
                detail: Norwegian.format(
                    "I minst %d timer har romtemperaturen ligget %.1f °C eller mer under ønsket temperatur (nå %.1f °C mot %.1f °C).",
                    hours, Threshold.setpointGap, last.roomTemperature ?? 0, last.setTemperature ?? 0) + outdoor,
                recommendation: "Det kan være helt normalt når det er veldig kaldt ute, eller rett etter at temperaturen er skrudd opp. Sjekk at luftfilteret er rent, at ingenting blokkerer luftstrømmen, og at utedelen ikke er dekket av snø eller is. Vedvarer det i milde perioder, ring forhandleren.")
        ]
    }

    static func firmware(_ state: DeviceState) -> [HealthFinding] {
        var findings: [HealthFinding] = []
        if let deployment = state.firmware.deployment, !deployment.isEmpty {
            findings.append(
                HealthFinding(
                    code: "firmware_pending", severity: .info, title: "Programvareoppdatering venter",
                    detail: "MELCloud har en oppdatering klar for Wi-Fi-modulen (\(deployment)).",
                    recommendation: "Ingen tiltak nødvendig. Oppdateringen installeres automatisk når modulen er på nett."))
        }
        if state.firmware.updateAborted {
            findings.append(
                HealthFinding(
                    code: "firmware_aborted", severity: .info, title: "Programvareoppdatering ble avbrutt",
                    detail: "Siste oppdatering av Wi-Fi-modulen ble ikke fullført.",
                    recommendation: "Sørg for stabilt Wi-Fi. Prøv eventuelt å starte varmepumpen på nytt via sikringen. Vedvarer det, kontakt forhandleren."))
        }
        return findings
    }

    static func errorLog(_ input: HealthInput) -> [HealthFinding] {
        guard !input.errorEvents.isEmpty else { return [] }
        let cutoff = input.now.addingTimeInterval(-Double(Threshold.recentErrorDays) * 86_400)
        let recent = input.errorEvents.filter { $0.start >= cutoff }.sorted { $0.start > $1.start }
        if let latest = recent.first {
            let entry = ErrorCatalog.lookup(errorCode: latest.code.flatMap(Int.init), message: latest.message)
            return [
                HealthFinding(
                    code: "recent_error_log", severity: .warning,
                    title: "Feil registrert siste \(Threshold.recentErrorDays) dager",
                    detail: "\(recent.count) feil i feilloggen. Siste: «\(latest.message)» \(Norwegian.dateTime(latest.start)).",
                    recommendation: "Gjentar feilen seg, eller blinker driftslampen, bør du ringe forhandleren. "
                        + "Én enkelt kort feil som har gått over av seg selv er ofte ufarlig. " + (entry.confidence == .melcloud ? "" : ErrorCatalog.caveat))
            ]
        }
        let latest = input.errorEvents.max { $0.start < $1.start }!
        return [
            HealthFinding(
                code: "old_error_log", severity: .info, title: "Eldre feil i feilloggen",
                detail: "\(input.errorEvents.count) eldre feil. Siste: «\(latest.message)» \(Norwegian.date(latest.start)).",
                recommendation: "Ingen tiltak nå. Nevn dem for forhandleren ved neste service.")
        ]
    }

    static func energyAnomaly(_ input: HealthInput) -> [HealthFinding] {
        let today = WireDate.day(input.now, timeZone: input.timeZone)
        // Daily mean outdoor temperature from snapshots and log points.
        var sums: [String: (Double, Int)] = [:]
        for s in input.snapshots {
            guard let t = s.outdoorTemperature else { continue }
            let day = WireDate.day(s.fetchedAt, timeZone: input.timeZone)
            sums[day, default: (0, 0)] = (sums[day, default: (0, 0)].0 + t, sums[day, default: (0, 0)].1 + 1)
        }
        for p in input.temperaturePoints {
            guard let t = p.outdoor else { continue }
            let day = WireDate.day(p.timestamp, timeZone: input.timeZone)
            sums[day, default: (0, 0)] = (sums[day, default: (0, 0)].0 + t, sums[day, default: (0, 0)].1 + 1)
        }
        // kWh per degree-day for complete days; zero-kWh days are treated as missing data.
        let ratios: [(day: String, ratio: Double)] = input.energyDays
            .filter { $0.day < today && $0.totalKWh > 0 }
            .sorted { $0.day < $1.day }
            .compactMap { day in
                guard let (sum, count) = sums[day.day], count > 0 else { return nil }
                let degreeDays = Threshold.degreeDayBase - sum / Double(count)
                guard degreeDays >= 1 else { return nil }
                return (day.day, day.totalKWh / degreeDays)
            }
        guard let latest = ratios.last else { return [] }
        let baseline = ratios.dropLast().suffix(Threshold.energyBaselineDays).map(\.ratio)
        guard baseline.count >= Threshold.energyMinBaselineDays else { return [] }
        let median = Self.median(baseline)
        guard median > 0 else { return [] }
        let factor = latest.ratio / median
        guard factor > Threshold.energyInfoFactor else { return [] }
        let severity: HealthSeverity = factor > Threshold.energyWarningFactor ? .warning : .info
        return [
            HealthFinding(
                code: "energy_anomaly", severity: severity, title: "Uvanlig høyt strømforbruk",
                detail: Norwegian.format(
                    "%@ brukte varmepumpen %.2f kWh per graddag, %.1f ganger mer enn vanlig (median %.2f siste dager). Graddager er justert for utetemperatur.",
                    latest.day, latest.ratio, factor, median),
                recommendation: "Sjekk at luftfilteret er rent, at utedelen ikke er nediset eller dekket av snø, og at dører/vinduer er lukket. Fortsetter det flere dager, ring forhandleren. Merk at MELCloud av og til rapporterer energitall forsinket eller feil.")
        ]
    }

    static func maintenance(_ input: HealthInput) -> [HealthFinding] {
        var findings: [HealthFinding] = []
        func latest(_ kind: MaintenanceKind) -> MaintenanceRecord? {
            input.maintenance.filter { $0.kind == kind }.max { $0.timestamp < $1.timestamp }
        }
        func days(since date: Date) -> Int { Int(input.now.timeIntervalSince(date) / 86_400) }

        if let record = latest(.airFilter) {
            let age = days(since: record.timestamp)
            if age > Threshold.airFilterWarningDays {
                findings.append(
                    HealthFinding(
                        code: "air_filter_overdue", severity: .warning, title: "Luftfilteret bør rengjøres nå",
                        detail: "Det er \(age) dager siden luftfilteret sist ble rengjort. Anbefalt er hver 2. uke.",
                        recommendation: "Slå av varmepumpen, ta ut luftfilteret, støvsug eller skyll det, og la det tørke i skyggen før det settes inn igjen. Registrer rengjøringen etterpå."))
            } else if age > Threshold.airFilterInfoDays {
                findings.append(
                    HealthFinding(
                        code: "air_filter_due", severity: .info, title: "Snart tid for å rengjøre luftfilteret",
                        detail: "Det er \(age) dager siden luftfilteret sist ble rengjort. Anbefalt er hver 2. uke.",
                        recommendation: "Rengjør luftfilteret i løpet av de neste dagene og registrer det."))
            }
        } else {
            findings.append(
                HealthFinding(
                    code: "air_filter_unknown", severity: .info, title: "Ingen registrert filterrengjøring",
                    detail: "Vi vet ikke når luftfilteret sist ble rengjort. Bruksanvisningen anbefaler hver 2. uke.",
                    recommendation: "Rengjør luftfilteret og registrer det, så kan appen minne deg på neste gang."))
        }

        if let record = latest(.deodorizingFilter) {
            let age = days(since: record.timestamp)
            if age > Threshold.deodorizingFilterDays {
                findings.append(
                    HealthFinding(
                        code: "deodorizing_filter_due", severity: .info, title: "Luftrenser og luktfilter bør rengjøres",
                        detail: "Det er \(age) dager siden luftrenseren og det svarte luktfilteret ble rengjort. Anbefalt er hver 3. måned.",
                        recommendation: "Støvsug filtrene (luktfilteret kan bløtlegges i lunkent vann 30–40 °C i ca. 15 minutter), tørk i skyggen. Reservedel ved behov: MAC-3010FT-E."))
            }
        } else {
            findings.append(
                HealthFinding(
                    code: "deodorizing_filter_unknown", severity: .info, title: "Ukjent når luktfilteret sist ble rengjort",
                    detail: "Luftrenseren og det svarte luktfilteret skal rengjøres hver 3. måned.",
                    recommendation: "Rengjør dem ved neste filterrengjøring og registrer det."))
        }

        if let record = latest(.vBlockingFilter), days(since: record.timestamp) > Threshold.deodorizingFilterDays {
            findings.append(
                HealthFinding(
                    code: "v_blocking_filter_due", severity: .info, title: "Det grønne V-blokkerende filteret bør rengjøres",
                    detail: "Det er \(days(since: record.timestamp)) dager siden det ble rengjort. Anbefalt er hver 3. måned, og nytt filter hvert år.",
                    recommendation: "Støvsug filteret, eller skyll det i lunkent vann og tørk i skyggen. Reservedel: MAC-2490FT-E."))
        }
        return findings
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
