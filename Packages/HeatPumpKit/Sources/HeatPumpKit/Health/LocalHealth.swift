import Foundation

/// What the health rules know about local access: aggregates computed in SQL, never raw readings.
public struct LocalHealthInput: Sendable {
    public var enabled: Bool
    /// False when the Mac is not on the adapter's network (no judgement about reachability then).
    public var onHomeNetwork: Bool
    public var latest: LocalSample?
    /// The last three hours as three rolling one-hour buckets ending now, oldest first.
    public var recentHours: [LocalPowerBucket]
    /// Hourly buckets over the last ~16 days (power rule).
    public var hourly: [LocalPowerBucket]
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    /// Start of the current run of failed reads (nil when the last read worked).
    public var failingSince: Date?

    public init(
        enabled: Bool, onHomeNetwork: Bool = true, latest: LocalSample? = nil, recentHours: [LocalPowerBucket] = [],
        hourly: [LocalPowerBucket] = [], lastAttempt: Date? = nil, lastSuccess: Date? = nil, failingSince: Date? = nil
    ) {
        self.enabled = enabled
        self.onHomeNetwork = onHomeNetwork
        self.latest = latest
        self.recentHours = recentHours
        self.hourly = hourly
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
        /// Heuristic: energy per degree-hour (average W incl. idle / (indoor − outdoor)) over the
        /// last 24 h against the median of earlier days with a comparable temperature difference.
        public static let powerInfoFactor = 1.5
        public static let powerWarningFactor = 2.0
        public static let powerBaselineDays = 14
        public static let powerMinBaselineDays = 5
        /// Hours (with ≥ 30 readings, heating, ΔT ≥ 5 °C) needed for one value, recent or per day.
        public static let powerMinHours = 6
        public static let powerMinReadingsPerHour = 30
        /// Baseline hours count as comparable within this many °C of the recent average difference.
        public static let powerComparableDelta = 3.0
        /// Below this indoor–outdoor difference the ratio is too unstable to compare.
        public static let powerMinDelta = 5.0
        public static let unreachableAfter: TimeInterval = 3600
        /// A local error code is only trusted while the reading is this fresh.
        public static let errorMaxAge: TimeInterval = 15 * 60
    }

    /// Builds the input from stored readings (two small GROUP BY queries).
    public static func input(
        store: HistoryStore, now: Date, enabled: Bool, onHomeNetwork: Bool = true, latest: LocalSample?,
        lastAttempt: Date? = nil, lastSuccess: Date? = nil, failingSince: Date? = nil
    ) throws -> LocalHealthInput {
        let windowStart = now.addingTimeInterval(-Threshold.shortCyclingWindow)
        return LocalHealthInput(
            enabled: enabled, onHomeNetwork: onHomeNetwork, latest: latest,
            recentHours: try store.localPowerBuckets(from: windowStart, to: now, bucketSeconds: 3600, origin: windowStart),
            hourly: try store.localPowerBuckets(
                from: now.addingTimeInterval(-Double(Threshold.powerBaselineDays + 2) * 86_400), to: now, bucketSeconds: 3600),
            lastAttempt: lastAttempt, lastSuccess: lastSuccess, failingSince: failingSince)
    }

    public static func evaluate(_ input: LocalHealthInput, cloudErrorShown: Bool, now: Date, timeZone: TimeZone) -> [HealthFinding] {
        var findings: [HealthFinding] = []
        findings += activeError(input.latest, cloudErrorShown: cloudErrorShown, now: now)
        findings += cloudConnectOff(input.latest, now: now)
        findings += unreachable(input, now: now)
        findings += shortCycling(input.recentHours)
        findings += powerVsOutdoor(input.hourly, now: now, timeZone: timeZone)
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
        guard input.enabled, input.onHomeNetwork, let since = input.failingSince, now.timeIntervalSince(since) > Threshold.unreachableAfter,
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

    static func shortCycling(_ hours: [LocalPowerBucket]) -> [HealthFinding] {
        let count = hours.reduce(0) { $0 + $1.count }
        guard count > 0 else { return [] }
        let heating = hours.reduce(0.0) { $0 + ($1.heatingShare ?? 0) * Double($1.count) } / Double(count)
        let observed = hours.reduce(0.0) { $0 + $1.observedSeconds }
        let starts = hours.reduce(0) { $0 + $1.starts }
        guard heating >= 0.8, observed >= Threshold.shortCyclingMinObserved else { return [] }
        let perHour = Double(starts) / (observed / 3600)
        let busyHours = hours.filter { $0.starts >= Threshold.strongStartsPerHour && $0.observedSeconds >= 50 * 60 }.count
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
                        starts, Threshold.strongStartsPerHour, busyHours),
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

    /// An hour that says something about consumption: mostly readings, heating, and a clear
    /// indoor–outdoor difference.
    static func usable(_ h: LocalPowerBucket) -> Bool {
        h.count >= Threshold.powerMinReadingsPerHour && (h.heatingShare ?? 0) >= 0.8 && h.averageW != nil
            && (h.averageDelta ?? 0) >= Threshold.powerMinDelta
    }

    /// Energy per degree-hour in W/°C: Σ average W / Σ (indoor − outdoor) over the hours. Average
    /// W includes the time the compressor stood still, so short runs in mild weather are not
    /// mistaken for high consumption.
    static func wattsPerDegree(_ hours: [LocalPowerBucket]) -> Double? {
        let delta = hours.reduce(0.0) { $0 + ($1.averageDelta ?? 0) }
        guard delta > 0 else { return nil }
        return hours.reduce(0.0) { $0 + ($1.averageW ?? 0) } / delta
    }

    static func powerVsOutdoor(_ hourly: [LocalPowerBucket], now: Date, timeZone: TimeZone) -> [HealthFinding] {
        let recentStart = now.addingTimeInterval(-86_400)
        let recent = hourly.filter { $0.start >= recentStart && usable($0) }
        guard recent.count >= Threshold.powerMinHours, let ratio = wattsPerDegree(recent) else { return [] }
        let recentDelta = recent.reduce(0.0) { $0 + ($1.averageDelta ?? 0) } / Double(recent.count)
        // Only hours with a comparable indoor–outdoor difference are a fair baseline: the same
        // unit uses more per degree when it is very cold, and much less when it only idles.
        let calendar = WireDate.calendar(timeZone)
        let comparable = hourly.filter {
            $0.start < recentStart && $0.start >= now.addingTimeInterval(-Double(Threshold.powerBaselineDays + 1) * 86_400)
                && usable($0) && abs(($0.averageDelta ?? 0) - recentDelta) <= Threshold.powerComparableDelta
        }
        let byDay = Dictionary(grouping: comparable) { calendar.startOfDay(for: $0.start) }
        let baseline = byDay.values.filter { $0.count >= Threshold.powerMinHours }.compactMap(wattsPerDegree)
        guard baseline.count >= Threshold.powerMinBaselineDays else { return [] }
        let median = HealthEngine.median(baseline)
        guard median > 0 else { return [] }
        let factor = ratio / median
        guard factor > Threshold.powerInfoFactor else { return [] }
        return [
            HealthFinding(
                code: "power_vs_outdoor", severity: factor > Threshold.powerWarningFactor ? .warning : .info,
                title: "Varmepumpen bruker mer strøm enn vanlig for temperaturen",
                detail: Norwegian.format(
                    "Siste døgn har den brukt i snitt %.0f W per grad forskjell mellom inne og ute (%.0f grader, stopp medregnet), %.1f ganger det vanlige ved tilsvarende forskjell (median %.0f W per grad, %d dager).",
                    ratio, recentDelta, factor, median, baseline.count),
                recommendation: "Sjekk at luftfilteret er rent og at utedelen ikke er nediset, dekket av snø eller blokkert. Mye avriming i fuktig kuldegrader kan også gi høyere forbruk en periode. Vedvarer det i flere dager, ring forhandleren.")
        ]
    }
}
