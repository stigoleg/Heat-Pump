import Foundation

/// What the health rules know about local access.
public struct LocalHealthInput: Sendable {
    public var enabled: Bool
    /// Local readings of the last ~15 days, any order.
    public var samples: [LocalSample]
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    /// Start of the current run of failed reads (nil when the last read worked).
    public var failingSince: Date?

    public init(enabled: Bool, samples: [LocalSample], lastAttempt: Date? = nil, lastSuccess: Date? = nil, failingSince: Date? = nil) {
        self.enabled = enabled
        self.samples = samples
        self.lastAttempt = lastAttempt
        self.lastSuccess = lastSuccess
        self.failingSince = failingSince
    }
}

/// Health rules on local readings. Thresholds are heuristics for a small wall unit, not
/// manufacturer limits; they are documented in `maintenance.md` as such.
public enum LocalHealth {
    public enum Threshold {
        /// Heuristic: on average 4 or more compressor starts per hour over 3 hours of heating is
        /// short cycling (a well-matched unit usually runs long, calm cycles).
        public static let shortCyclingStartsPerHour = 4.0
        /// Heuristic: 6 or more starts in at least 2 of the last 3 hours is a stronger warning.
        public static let strongStartsPerHour = 6
        public static let strongHours = 2
        public static let shortCyclingWindow: TimeInterval = 3 * 3600
        /// At least this much of the window must have readings ≤ 5 min apart.
        public static let shortCyclingMinObserved: TimeInterval = 2.5 * 3600
        /// Heuristic: W per °C (indoor − outdoor) while running, against the 14-day median.
        public static let powerInfoFactor = 1.5
        public static let powerWarningFactor = 2.0
        public static let powerBaselineDays = 14
        public static let powerMinBaselineDays = 7
        /// Readings with the compressor running needed for one value (about an hour at 1/min).
        public static let powerMinRunningReadings = 60
        /// Below this indoor–outdoor difference the ratio is too unstable to compare.
        public static let powerMinDelta = 5.0
        public static let unreachableAfter: TimeInterval = 3600
        /// A local error code is only trusted while the reading is this fresh.
        public static let errorMaxAge: TimeInterval = 15 * 60
    }

    public static func evaluate(_ input: LocalHealthInput, cloudErrorShown: Bool, now: Date, timeZone: TimeZone) -> [HealthFinding] {
        let samples = input.samples.sorted { $0.timestamp < $1.timestamp }
        var findings: [HealthFinding] = []
        findings += activeError(samples.last, cloudErrorShown: cloudErrorShown, now: now)
        findings += cloudConnectOff(samples.last, now: now)
        findings += unreachable(input, now: now)
        findings += shortCycling(samples, now: now)
        findings += powerVsOutdoor(samples, now: now, timeZone: timeZone)
        return findings
    }

    static func activeError(_ latest: LocalSample?, cloudErrorShown: Bool, now: Date) -> [HealthFinding] {
        guard let latest, latest.hasError, let code = latest.errorCode, !cloudErrorShown,
            now.timeIntervalSince(latest.timestamp) < Threshold.errorMaxAge
        else { return [] }
        return [
            HealthFinding(
                code: "active_error_local", severity: .critical, title: "Varmepumpen melder feil nå (lokal)",
                detail: String(format: "Wi-Fi-modulen på hjemmenettet rapporterer feilkode 0x%04X. ", code)
                    + "Koden kommer direkte fra innedelen og er ikke oversatt; MELCloud har ikke meldt feilen ennå. "
                    + ErrorCatalog.caveat,
                recommendation: "Sjekk om driftslampen på innedelen blinker, og tell antall blink. Blinker den, slå av varmepumpen og ring forhandleren. Forsvinner koden av seg selv ved neste avlesning, følg med på om den kommer igjen.")
        ]
    }

    static func cloudConnectOff(_ latest: LocalSample?, now: Date) -> [HealthFinding] {
        guard let latest, latest.cloudConnected == false, now.timeIntervalSince(latest.timestamp) < 3600 else { return [] }
        return [
            HealthFinding(
                code: "local_cloud_connect_off", severity: .warning, title: "MELCloud-tilkoblingen er slått av i modulen",
                detail: "Wi-Fi-modulen sier selv at forbindelsen til MELCloud er slått av (CONNECT = OFF). Da kommer verken status eller endringer fra MELCloud fram, og appen kan bare lese lokalt.",
                recommendation: "Appen endrer aldri denne innstillingen. Start varmepumpen på nytt via sikringen, og sjekk MELCloud-appen. Er tilkoblingen fortsatt av, kontakt forhandleren eller Mitsubishi-support.")
        ]
    }

    static func unreachable(_ input: LocalHealthInput, now: Date) -> [HealthFinding] {
        guard input.enabled, let since = input.failingSince, now.timeIntervalSince(since) > Threshold.unreachableAfter,
            let attempt = input.lastAttempt, now.timeIntervalSince(attempt) < Threshold.unreachableAfter
        else { return [] }
        let last = input.lastSuccess.map { " Sist svar: \(Norwegian.dateTime($0))." } ?? ""
        return [
            HealthFinding(
                code: "local_unreachable", severity: .info, title: "Wi-Fi-modulen svarer ikke på hjemmenettet",
                detail: "Appen har ikke fått kontakt med modulen lokalt siden \(Norwegian.dateTime(since)).\(last) Styring og status via MELCloud virker som før.",
                recommendation: "Ofte har ruteren gitt varmepumpen en ny IP-adresse. Trykk «Finn automatisk» under Innstillinger → Lokal tilkobling, eller skriv inn adressen fra ruterens enhetsliste. Gi gjerne varmepumpen fast IP i ruteren.")
        ]
    }

    /// Starts and observed time per rolling hour, newest last: [now-3h, now-2h), [now-2h, now-1h), [now-1h, now].
    static func rollingHours(_ samples: [LocalSample], now: Date) -> [(starts: Int, observed: TimeInterval)] {
        (0..<3).reversed().map { k in
            let end = now.addingTimeInterval(-Double(k) * 3600)
            let start = end.addingTimeInterval(-3600)
            return CompressorCycles.starts(in: samples.filter { $0.timestamp >= start && $0.timestamp <= end })
        }
    }

    static func shortCycling(_ samples: [LocalSample], now: Date) -> [HealthFinding] {
        let window = samples.filter { $0.timestamp >= now.addingTimeInterval(-Threshold.shortCyclingWindow) && $0.timestamp <= now }
        let heating = window.filter { $0.power == true && $0.mode == .heat }
        guard !window.isEmpty, Double(heating.count) >= 0.8 * Double(window.count) else { return [] }
        let total = CompressorCycles.starts(in: window)
        guard total.observed >= Threshold.shortCyclingMinObserved else { return [] }
        let perHour = Double(total.starts) / (total.observed / 3600)
        let hours = rollingHours(window, now: now)
        let busyHours = hours.filter { $0.starts >= Threshold.strongStartsPerHour && $0.observed >= 50 * 60 }.count
        let strong = busyHours >= Threshold.strongHours
        guard strong || perHour >= Threshold.shortCyclingStartsPerHour else { return [] }
        let advice =
            "Vanlige årsaker er tett luftfilter, at varmepumpen er stor for rommet (særlig i mildvær), eller at ønsket temperatur eller viften endres ofte. "
            + "Rengjør luftfilteret, la ønsket temperatur ligge fast (unngå store hopp), og bruk gjerne vifte auto. "
            + "Fortsetter det flere dager, også når det er kaldt ute, bør du ringe forhandleren."
        if strong {
            return [
                HealthFinding(
                    code: "short_cycling_strong", severity: .warning, title: "Kompressoren starter og stopper svært ofte",
                    detail: Norwegian.format(
                        "Kompressoren har startet %d ganger de siste 3 timene, med %d eller flere starter i %d av timene. Så korte runder sliter på kompressoren og gir dårligere virkningsgrad.",
                        total.starts, Threshold.strongStartsPerHour, busyHours),
                    recommendation: advice)
            ]
        }
        return [
            HealthFinding(
                code: "short_cycling", severity: .warning, title: "Kompressoren starter og stopper ofte",
                detail: Norwegian.format(
                    "Kompressoren har startet i snitt %.1f ganger i timen de siste 3 timene mens den varmet. Mer enn 3–4 starter i timen over tid regnes som korte runder.",
                    perHour),
                recommendation: advice)
        ]
    }

    /// Average W per °C (indoor − outdoor) while the compressor runs; nil without enough data.
    static func powerRatio(_ samples: [LocalSample]) -> Double? {
        let running = samples.compactMap { s -> (Double, Double)? in
            guard s.isRunning, s.mode == .heat, let watts = s.powerW, let room = s.roomTemperature,
                let outdoor = s.outdoorTemperature, room - outdoor >= Threshold.powerMinDelta
            else { return nil }
            return (Double(watts), room - outdoor)
        }
        guard running.count >= Threshold.powerMinRunningReadings else { return nil }
        let watts = running.map(\.0).reduce(0, +) / Double(running.count)
        let delta = running.map(\.1).reduce(0, +) / Double(running.count)
        return watts / delta
    }

    static func powerVsOutdoor(_ samples: [LocalSample], now: Date, timeZone: TimeZone) -> [HealthFinding] {
        let recentStart = now.addingTimeInterval(-86_400)
        guard let recent = powerRatio(samples.filter { $0.timestamp >= recentStart && $0.timestamp <= now }) else { return [] }
        let calendar = WireDate.calendar(timeZone)
        let older = samples.filter {
            $0.timestamp < recentStart && $0.timestamp >= now.addingTimeInterval(-Double(Threshold.powerBaselineDays + 1) * 86_400)
        }
        let byDay = Dictionary(grouping: older) { calendar.startOfDay(for: $0.timestamp) }
        let baseline = byDay.keys.sorted().suffix(Threshold.powerBaselineDays).compactMap { powerRatio(byDay[$0] ?? []) }
        guard baseline.count >= Threshold.powerMinBaselineDays else { return [] }
        let median = HealthEngine.median(baseline)
        guard median > 0 else { return [] }
        let factor = recent / median
        guard factor > Threshold.powerInfoFactor else { return [] }
        return [
            HealthFinding(
                code: "power_vs_outdoor", severity: factor > Threshold.powerWarningFactor ? .warning : .info,
                title: "Varmepumpen bruker mer strøm enn vanlig for temperaturen",
                detail: Norwegian.format(
                    "Siste døgn har den brukt %.0f W per grad forskjell mellom inne og ute mens kompressoren gikk, %.1f ganger det vanlige (median %.0f W per grad de siste %d dagene).",
                    recent, factor, median, baseline.count),
                recommendation: "Sjekk at luftfilteret er rent og at utedelen ikke er nediset, dekket av snø eller blokkert. Mye avriming i fuktig kuldegrader kan også gi høyere forbruk en periode. Vedvarer det i flere dager, ring forhandleren.")
        ]
    }
}
