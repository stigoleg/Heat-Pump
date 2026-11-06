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
    /// Set while the service blocks our requests; explains why data is old.
    public var blockedUntil: Date?
    /// Local adapter readings and reachability (nil when local access was never used).
    public var local: LocalHealthInput?
    /// Names the service in texts and supplies error codes, maintenance kinds and its own rules.
    public var integration: any Integration

    public init(
        latestState: DeviceState?, snapshots: [DeviceState] = [], temperaturePoints: [TemperaturePoint] = [],
        errorEvents: [ErrorLogEntry] = [], energyDays: [EnergyDay] = [], maintenance: [MaintenanceRecord] = [],
        now: Date, timeZone: TimeZone = .current, blockedUntil: Date? = nil, local: LocalHealthInput? = nil,
        integration: any Integration
    ) {
        self.integration = integration
        self.local = local
        self.latestState = latestState
        self.snapshots = snapshots
        self.temperaturePoints = temperaturePoints
        self.errorEvents = errorEvents
        self.energyDays = energyDays
        self.maintenance = maintenance
        self.now = now
        self.timeZone = timeZone
        self.blockedUntil = blockedUntil
    }
}

/// Pure health rules. All display text goes through `L10n`.
public enum HealthEngine {
    public enum Threshold {
        public static let offlineAfter: TimeInterval = 3600
        /// Our own data older than this is reported as old instead of judging the unit.
        public static let staleDataAfter: TimeInterval = 3600
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
        let serviceName = input.integration.displayName
        if let state = input.latestState {
            findings += activeError(state, errorCodes: input.integration.errorCodes, serviceName: serviceName)
            findings += connectivity(state, now: input.now, blockedUntil: input.blockedUntil, serviceName: serviceName)
            findings += wifi(state, serviceName: serviceName)
            findings += setpointNotReached(input)
            findings += firmware(state, serviceName: serviceName)
        } else {
            findings.append(
                HealthFinding(
                    code: "no_data", severity: .info, title: L10n.tr("Not enough data yet"),
                    detail: L10n.tr("No status has been fetched from the heat pump yet, so the health check is limited."),
                    recommendation: L10n.tr("Fetch the status (refresh) and run the health check again in a little while.")))
        }
        if let local = input.local {
            findings += LocalHealth.evaluate(local, cloudErrorShown: findings.contains { ["active_error", "error_flag"].contains($0.code) },
                                             now: input.now, timeZone: input.timeZone, integration: input.integration)
        }
        findings += errorLog(input)
        findings += energyAnomaly(input, serviceName: serviceName)
        findings += maintenance(input)
        if !findings.contains(where: { $0.severity >= .warning }) && input.latestState != nil {
            findings.append(
                HealthFinding(
                    code: "all_ok", severity: .ok, title: L10n.tr("The heat pump appears to be working normally"),
                    detail: L10n.tr("No errors, warnings or anomalies were found in the data we have."),
                    recommendation: L10n.tr("No action needed beyond regular maintenance.")))
        }
        return HealthReport(generatedAt: input.now, findings: findings)
    }

    // MARK: Rules

    static func activeError(_ state: DeviceState, errorCodes: any ErrorCodeExplaining, serviceName: String) -> [HealthFinding] {
        guard state.hasActiveError else { return [] }
        guard let code = state.errorCode, !DeviceState.noErrorCodes.contains(code) else {
            // HasError without a real code: real but unspecific, so not critical.
            return [
                HealthFinding(
                    code: "error_flag", severity: .warning, title: L10n.format("%@ reports an error without an error code", serviceName),
                    detail: L10n.format(
                        "The heat pump has set an error flag, but %@ gives no error code. So we do not know what the error is about.", serviceName),
                    recommendation: L10n.tr("Check whether the operation lamp on the indoor unit is blinking, and count the blinks. If it blinks, turn off the heat pump and call the dealer. If it does not blink and the heating works, watch whether the error goes away at the next refresh."))
            ]
        }
        let entry = errorCodes.lookup(errorCode: code)
        let uncertain = entry.confidence == .low || entry.confidence == .unknown
        return [
            HealthFinding(
                code: "active_error", severity: .critical, title: L10n.tr("The heat pump is reporting an error now"),
                detail: uncertain
                    ? L10n.format("Error code %@. %@: %@ %@", String(code), entry.title, entry.explanation, errorCodes.caveat)
                    : L10n.format("Error code %@. %@: %@", String(code), entry.title, entry.explanation),
                recommendation: L10n.format("Check whether the operation lamp on the indoor unit is blinking, and count the blinks. %@", entry.recommendation))
        ]
    }

    /// Judges connectivity at the time of the snapshot. When our own data is old (the service
    /// blocks us, no internet), only says the data is old: the unit may be perfectly fine.
    static func connectivity(_ state: DeviceState, now: Date, blockedUntil: Date?, serviceName: String) -> [HealthFinding] {
        let dataAge = now.timeIntervalSince(state.fetchedAt)
        if dataAge > Threshold.staleDataAfter {
            let why =
                blockedUntil.map { L10n.format("%@ has temporarily blocked updates until %@.", serviceName, Display.dateTime($0)) }
                ?? L10n.tr("Fetching a new status has not succeeded (for example without internet).")
            return [
                HealthFinding(
                    code: "stale_data", severity: .info, title: L10n.tr("The data is old"),
                    detail: L10n.format("The latest status is from %@. %@ The assessments below apply to that time.", Display.dateTime(state.fetchedAt), why),
                    recommendation: L10n.tr("No action needed on the heat pump. The app fetches a new status automatically when it can."))
            ]
        }
        let silentFor = state.lastCommunication.map { state.fetchedAt.timeIntervalSince($0) }
        guard state.offline || (silentFor ?? 0) > Threshold.offlineAfter else { return [] }
        let detail =
            state.lastCommunication.map {
                L10n.format(
                    "The Wi-Fi adapter had not reported in for over an hour when the status was fetched. Last contact: %@. The heat pump can still heat as normal, but we cannot see what it is doing.",
                    Display.dateTime($0))
            }
            ?? L10n.tr("The Wi-Fi adapter had not reported in for over an hour when the status was fetched. The heat pump can still heat as normal, but we cannot see what it is doing.")
        return [
            HealthFinding(
                code: "offline", severity: .warning, title: L10n.format("The heat pump has no contact with %@", serviceName),
                detail: detail,
                recommendation: L10n.tr("Check that the router and the internet work, and that the heat pump has power. If that does not help, switch off the circuit breaker for the heat pump for one minute and switch it back on."))
        ]
    }

    static func wifi(_ state: DeviceState, serviceName: String) -> [HealthFinding] {
        // The adapter reports dBm (negative). Ignore values that do not look like dBm.
        guard let rssi = state.wifiSignal, rssi < 0 else { return [] }
        if rssi < Threshold.wifiWarning {
            return [
                HealthFinding(
                    code: "wifi_weak", severity: .warning, title: L10n.tr("Weak Wi-Fi signal"),
                    detail: L10n.format(
                        "The signal strength is %lld dBm, which is weak. It can cause dropouts in the connection to %@.", rssi, serviceName),
                    recommendation: L10n.tr("Move the router closer, or set up a Wi-Fi extender or mesh node near the indoor unit."))
            ]
        }
        if rssi < Threshold.wifiInfo {
            return [
                HealthFinding(
                    code: "wifi_fair", severity: .info, title: L10n.tr("Fair Wi-Fi signal"),
                    detail: L10n.format("The signal strength is %lld dBm. It usually works, but it is not strong.", rssi),
                    recommendation: L10n.tr("No action needed now. If the connection drops, consider better Wi-Fi coverage near the indoor unit."))
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
        // One numeric argument per key (the hour count drives the plural); temperatures go in as text.
        let gap = Display.format("%.1f °C", Threshold.setpointGap)
        let room = Display.format("%.1f °C", last.roomTemperature ?? 0)
        let target = Display.format("%.1f °C", last.setTemperature ?? 0)
        let detail =
            last.outdoorTemperature.map {
                L10n.format(
                    "For at least %lld hours the room temperature has been %@ or more below the target temperature (now %@ vs. %@). It is %@ outdoors.",
                    hours, gap, room, target, Display.format("%.0f °C", $0))
            }
            ?? L10n.format(
                "For at least %lld hours the room temperature has been %@ or more below the target temperature (now %@ vs. %@).",
                hours, gap, room, target)
        return [
            HealthFinding(
                code: "setpoint_not_reached", severity: .warning, title: L10n.tr("The room is not reaching the target temperature"),
                detail: detail,
                recommendation: L10n.tr("This can be perfectly normal when it is very cold outdoors, or right after the temperature has been turned up. Check that the air filter is clean, that nothing blocks the airflow, and that the outdoor unit is not covered by snow or ice. If it persists in mild weather, call the dealer."))
        ]
    }

    static func firmware(_ state: DeviceState, serviceName: String) -> [HealthFinding] {
        var findings: [HealthFinding] = []
        // The deployment id is internal to the service and never shown; the version is.
        if state.firmware.updateAvailable {
            let detail =
                state.firmware.version.map { L10n.format("The adapter has firmware %@. %@ has a newer version ready.", $0, serviceName) }
                ?? L10n.format("%@ has a newer firmware version ready for the adapter.", serviceName)
            findings.append(
                HealthFinding(
                    code: "firmware_pending", severity: .info, title: L10n.tr("Update available for the Wi-Fi adapter"),
                    detail: detail,
                    recommendation:
                        L10n.format(
                            "Start the update under Health → Firmware in this app (or in the %@ app) while the heat pump has power and good Wi-Fi. Do not cut the power and do not use the remote control while it runs. Firmware cannot be rolled back.",
                            serviceName)))
        }
        if state.firmware.updateAborted {
            findings.append(
                HealthFinding(
                    code: "firmware_aborted", severity: .info, title: L10n.tr("Firmware update was aborted"),
                    detail: L10n.tr("The last update of the Wi-Fi adapter did not complete."),
                    recommendation: L10n.tr("Make sure Wi-Fi is stable and try again under Health → Firmware. If needed, restart the heat pump via the circuit breaker first. If it persists, contact the dealer.")))
        }
        return findings
    }

    static func errorLog(_ input: HealthInput) -> [HealthFinding] {
        guard !input.errorEvents.isEmpty else { return [] }
        let cutoff = input.now.addingTimeInterval(-Double(Threshold.recentErrorDays) * 86_400)
        let recent = input.errorEvents.filter { $0.start >= cutoff }.sorted { $0.start > $1.start }
        if let latest = recent.first {
            let errorCodes = input.integration.errorCodes
            let entry = errorCodes.lookup(errorCode: latest.code.flatMap(Int.init), message: latest.message)
            return [
                HealthFinding(
                    code: "recent_error_log", severity: .warning,
                    title: L10n.format("Errors recorded in the last %lld days", Threshold.recentErrorDays),
                    detail: L10n.format("%lld errors in the error log. Latest: “%@” %@.", recent.count, latest.message, Display.dateTime(latest.start)),
                    recommendation: entry.confidence == .serviceText
                        ? L10n.tr("If the error repeats, or the operation lamp blinks, you should call the dealer. A single short error that went away by itself is often harmless.")
                        : L10n.format("If the error repeats, or the operation lamp blinks, you should call the dealer. A single short error that went away by itself is often harmless. %@", errorCodes.caveat))
            ]
        }
        guard let latest = input.errorEvents.max(by: { $0.start < $1.start }) else { return [] }
        return [
            HealthFinding(
                code: "old_error_log", severity: .info, title: L10n.tr("Older errors in the error log"),
                detail: L10n.format("%lld older errors. Latest: “%@” %@.", input.errorEvents.count, latest.message, Display.date(latest.start)),
                recommendation: L10n.tr("No action now. Mention them to the dealer at the next service."))
        ]
    }

    static func energyAnomaly(_ input: HealthInput, serviceName: String) -> [HealthFinding] {
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
                code: "energy_anomaly", severity: severity, title: L10n.tr("Unusually high electricity use"),
                detail: L10n.format(
                    "On %@ the heat pump used %.2f kWh per degree day, %.1f times more than usual (median %.2f over recent days). Degree days are adjusted for the outdoor temperature.",
                    latest.day, latest.ratio, factor, median),
                recommendation: L10n.format(
                    "Check that the air filter is clean, that the outdoor unit is not iced up or covered by snow, and that doors and windows are closed. If it continues for several days, call the dealer. Note that %@ sometimes reports energy figures late or wrong.",
                    serviceName))
        ]
    }

    /// Only for the maintenance kinds the integration's unit has.
    static func maintenance(_ input: HealthInput) -> [HealthFinding] {
        var findings: [HealthFinding] = []
        let kinds = Set(input.integration.maintenanceKinds)
        func latest(_ kind: MaintenanceKind) -> MaintenanceRecord? {
            input.maintenance.filter { $0.kind == kind }.max { $0.timestamp < $1.timestamp }
        }
        func days(since date: Date) -> Int { Int(input.now.timeIntervalSince(date) / 86_400) }

        if kinds.contains(.airFilter) {
            if let record = latest(.airFilter) {
                let age = days(since: record.timestamp)
                if age > Threshold.airFilterWarningDays {
                    findings.append(
                        HealthFinding(
                            code: "air_filter_overdue", severity: .warning, title: L10n.tr("The air filter should be cleaned now"),
                            detail: L10n.format("It has been %lld days since the air filter was last cleaned. The recommendation is every 2 weeks.", age),
                            recommendation: L10n.tr("Turn off the heat pump, take out the air filter, vacuum or rinse it, and let it dry in the shade before putting it back. Record the cleaning afterwards.")))
                } else if age > Threshold.airFilterInfoDays {
                    findings.append(
                        HealthFinding(
                            code: "air_filter_due", severity: .info, title: L10n.tr("Time to clean the air filter soon"),
                            detail: L10n.format("It has been %lld days since the air filter was last cleaned. The recommendation is every 2 weeks.", age),
                            recommendation: L10n.tr("Clean the air filter within the next few days and record it.")))
                }
            } else {
                findings.append(
                    HealthFinding(
                        code: "air_filter_unknown", severity: .info, title: L10n.tr("No filter cleaning recorded"),
                        detail: L10n.tr("We do not know when the air filter was last cleaned. The manual recommends every 2 weeks."),
                        recommendation: L10n.tr("Clean the air filter and record it, so the app can remind you next time.")))
            }
        }

        if kinds.contains(.deodorizingFilter) {
            if let record = latest(.deodorizingFilter) {
                let age = days(since: record.timestamp)
                if age > Threshold.deodorizingFilterDays {
                    findings.append(
                        HealthFinding(
                            code: "deodorizing_filter_due", severity: .info, title: L10n.tr("The air purifying and deodorizing filters should be cleaned"),
                            detail: L10n.format("It has been %lld days since the air purifying filter and the black deodorizing filter were cleaned. The recommendation is every 3 months.", age),
                            recommendation: L10n.tr("Vacuum the filters (the deodorizing filter can be soaked in lukewarm water at 30–40 °C for about 15 minutes) and dry them in the shade. Spare part if needed: MAC-3010FT-E.")))
                }
            } else {
                findings.append(
                    HealthFinding(
                        code: "deodorizing_filter_unknown", severity: .info, title: L10n.tr("Unknown when the deodorizing filter was last cleaned"),
                        detail: L10n.tr("The air purifying filter and the black deodorizing filter should be cleaned every 3 months."),
                        recommendation: L10n.tr("Clean them at the next filter cleaning and record it.")))
            }
        }

        if kinds.contains(.vBlockingFilter), let record = latest(.vBlockingFilter), days(since: record.timestamp) > Threshold.deodorizingFilterDays {
            findings.append(
                HealthFinding(
                    code: "v_blocking_filter_due", severity: .info, title: L10n.tr("The green V-blocking filter should be cleaned"),
                    detail: L10n.format("It has been %lld days since it was cleaned. The recommendation is every 3 months, with a new filter every year.", days(since: record.timestamp)),
                    recommendation: L10n.tr("Vacuum the filter, or rinse it in lukewarm water and dry it in the shade. Spare part: MAC-2490FT-E.")))
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
