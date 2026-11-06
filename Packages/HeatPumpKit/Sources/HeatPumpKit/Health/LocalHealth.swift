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
        /// Heuristic: more than 3 defrosts an hour, 3 hours in a row, is unusually often (a unit
        /// typically defrosts every 40–90 minutes of running in damp frost).
        public static let defrostsPerHour = 3
        public static let defrostSustainedHours = 3
        /// Heuristic: defrosting more than 20 % of the time over the last day while it is milder than
        /// −5 °C (in harder frost much defrosting is expected).
        public static let defrostShare = 0.2
        public static let defrostShareMinOutdoor = -5.0
        public static let defrostShareMinHours = 6
        /// An hour only counts with this many readings carrying a sub-mode and ≥ 50 min observed.
        public static let defrostMinReadings = 30
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

    /// The integration's own adapter rules first, then the generic ones.
    public static func evaluate(
        _ input: LocalHealthInput, cloudErrorShown: Bool, now: Date, timeZone: TimeZone, integration: any Integration
    ) -> [HealthFinding] {
        var findings: [HealthFinding] = []
        findings += integration.healthChecks.localAdapterFindings(input, cloudErrorShown: cloudErrorShown, now: now)
        findings += unreachable(input, now: now, serviceName: integration.displayName)
        findings += shortCycling(input.recentHours)
        findings += powerVsOutdoor(input.hourly, now: now, timeZone: timeZone)
        findings += frequentDefrost(input.hourly, now: now)
        return findings
    }

    static func unreachable(_ input: LocalHealthInput, now: Date, serviceName: String) -> [HealthFinding] {
        guard input.enabled, input.onHomeNetwork, let since = input.failingSince, now.timeIntervalSince(since) > Threshold.unreachableAfter,
            let attempt = input.lastAttempt, now.timeIntervalSince(attempt) < Threshold.unreachableAfter
        else { return [] }
        let detail =
            input.lastSuccess.map {
                L10n.format(
                    "The app has not reached the adapter locally since %@. Last response: %@. Control and status via %@ work as before.",
                    Display.dateTime(since), Display.dateTime($0), serviceName)
            }
            ?? L10n.format(
                "The app has not reached the adapter locally since %@. Control and status via %@ work as before.", Display.dateTime(since),
                serviceName)
        return [
            HealthFinding(
                code: "local_unreachable", severity: .info, title: L10n.tr("The Wi-Fi adapter is not responding on the home network"),
                detail: detail,
                recommendation: L10n.tr("Often the router has given the heat pump a new IP address. Click “Find Automatically” under Settings → Local connection, or enter the address from the router's device list. Consider giving the heat pump a fixed IP in the router."))
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
        let advice = L10n.tr(
            "Common causes are a clogged air filter, a heat pump that is large for the room (especially in mild weather), or a target temperature or fan setting that changes often. Clean the air filter, keep the target temperature steady (avoid big jumps), and consider fan auto. If it continues for several days, also when it is cold outdoors, you should call the dealer.")
        if strong {
            return [
                HealthFinding(
                    code: "short_cycling_strong", severity: .warning, title: L10n.tr("The compressor starts and stops very often"),
                    detail: L10n.format(
                        "The compressor has started %lld times in the last 3 hours, with %lld or more starts in %lld of the hours. Such short runs wear on the compressor and lower the efficiency.",
                        starts, Threshold.strongStartsPerHour, busyHours),
                    recommendation: advice)
            ]
        }
        return [
            HealthFinding(
                code: "short_cycling", severity: .warning, title: L10n.tr("The compressor starts and stops often"),
                detail: L10n.format(
                    "The compressor has started on average %.1f times an hour in the last 3 hours while heating. More than 3–4 starts an hour over time counts as short cycling.",
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

    /// Unusually frequent or long defrosting over the last 24 hours (dense local readings only).
    static func frequentDefrost(_ hourly: [LocalPowerBucket], now: Date) -> [HealthFinding] {
        let recent = hourly.filter {
            $0.start >= now.addingTimeInterval(-86_400) && $0.phaseCount >= Threshold.defrostMinReadings
                && $0.observedSeconds >= 50 * 60
        }.sorted { $0.start < $1.start }
        let advice = L10n.tr(
            "The outdoor unit may have ice or poor airflow — check that it is free of snow, ice and leaves, and that nothing stands close to it. Do not chip ice off with tools; let it melt or use lukewarm water. If it continues after the outdoor unit has been cleared, call the dealer.")
        var run = 0
        var longest = 0
        var previous: Date?
        for hour in recent {
            let next = previous.map { hour.start.timeIntervalSince($0) <= 3600 } ?? false
            run = hour.defrosts > Threshold.defrostsPerHour ? (next ? run + 1 : 1) : 0
            longest = max(longest, run)
            previous = hour.start
        }
        if longest >= Threshold.defrostSustainedHours {
            return [
                HealthFinding(
                    code: "frequent_defrost", severity: .warning, title: L10n.tr("The outdoor unit defrosts unusually often"),
                    detail: L10n.format(
                        "The heat pump has defrosted more than %lld times an hour for %lld hours in a row in the last day. Normally it defrosts every 40–90 minutes of running in damp cold. The limit is a rule of thumb.",
                        Threshold.defrostsPerHour, longest),
                    recommendation: advice)
            ]
        }
        let mild = recent.filter { ($0.averageOutdoor ?? -99) > Threshold.defrostShareMinOutdoor }
        let observed = mild.reduce(0.0) { $0 + $1.observedSeconds }
        guard mild.count >= Threshold.defrostShareMinHours, observed > 0 else { return [] }
        let share = mild.reduce(0.0) { $0 + $1.defrostSeconds } / observed
        guard share > Threshold.defrostShare else { return [] }
        return [
            HealthFinding(
                code: "defrost_share", severity: .info, title: L10n.tr("The outdoor unit spends a lot of time defrosting"),
                detail: L10n.format(
                    "In the last day the heat pump has been defrosting %.0f %% of the time (%lld hours with readings, milder than −5 °C outdoors). Over 20 %% is a lot; the limit is a rule of thumb.",
                    share * 100, mild.count),
                recommendation: advice)
        ]
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
                title: L10n.tr("The heat pump uses more electricity than usual for the temperature"),
                detail: L10n.format(
                    "In the last day it has used on average %.0f W per degree of difference between indoors and outdoors (%.0f degrees, idle time included), %.1f times the usual at a similar difference (median %.0f W per degree, %lld days).",
                    ratio, recentDelta, factor, median, baseline.count),
                recommendation: L10n.tr("Check that the air filter is clean and that the outdoor unit is not iced up, covered by snow or blocked. A lot of defrosting in damp sub-zero weather can also raise consumption for a while. If it persists for several days, call the dealer."))
        ]
    }
}
