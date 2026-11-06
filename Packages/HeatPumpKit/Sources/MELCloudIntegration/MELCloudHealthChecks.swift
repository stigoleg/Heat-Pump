import Foundation
import HeatPumpKit

/// Rules on what only the MELCloud Wi-Fi adapter reports locally: its raw error code (CN105,
/// untranslated) and whether its link to MELCloud is switched off.
public struct MELCloudHealthChecks: HealthCheckProviding {
    public init() {}

    public func localAdapterFindings(_ input: LocalHealthInput, cloudErrorShown: Bool, now: Date) -> [HealthFinding] {
        activeError(input.latest, cloudErrorShown: cloudErrorShown, now: now) + cloudConnectOff(input.latest, now: now)
    }

    func activeError(_ latest: LocalSample?, cloudErrorShown: Bool, now: Date) -> [HealthFinding] {
        guard let latest, latest.hasError, let code = latest.errorCode, !cloudErrorShown,
            now.timeIntervalSince(latest.timestamp) < LocalHealth.Threshold.errorMaxAge
        else { return [] }
        return [
            HealthFinding(
                code: "active_error_local", severity: .critical, title: L10n.tr("The heat pump is reporting an error now (local)"),
                detail: L10n.format(
                    "The Wi-Fi adapter on the home network reports error code %@. The code comes directly from the indoor unit and is not translated; MELCloud has not reported the error yet. %@",
                    String(format: "0x%04X", code), ErrorCatalog.caveat),
                recommendation: L10n.tr("Check whether the operation lamp on the indoor unit is blinking, and count the blinks. If it blinks, turn off the heat pump and call the dealer. If the code goes away by itself at the next reading, watch whether it comes back."))
        ]
    }

    func cloudConnectOff(_ latest: LocalSample?, now: Date) -> [HealthFinding] {
        guard let latest, latest.cloudConnected == false, now.timeIntervalSince(latest.timestamp) < 3600 else { return [] }
        return [
            HealthFinding(
                code: "local_cloud_connect_off", severity: .warning, title: L10n.tr("The MELCloud connection is turned off in the adapter"),
                detail: L10n.tr("The Wi-Fi adapter itself says the connection to MELCloud is turned off (CONNECT = OFF). Then neither status nor changes from MELCloud get through, and the app can only read locally."),
                recommendation: L10n.tr("The app never changes this setting. Restart the heat pump via the circuit breaker, and check the MELCloud app. If the connection is still off, contact the dealer or Mitsubishi support."))
        ]
    }

    // MARK: Maintenance (MSZ-RW owner manual)

    static let airFilterInfoDays = 14
    static let airFilterWarningDays = 30
    static let deodorizingFilterDays = 90

    /// Filter reminders with the MSZ-RW owner manual's intervals and spare parts.
    public func maintenanceFindings(_ records: [MaintenanceRecord], now: Date) -> [HealthFinding] {
        var findings: [HealthFinding] = []
        func latest(_ kind: MaintenanceKind) -> MaintenanceRecord? {
            records.filter { $0.kind == kind }.max { $0.timestamp < $1.timestamp }
        }
        func days(since date: Date) -> Int { Int(now.timeIntervalSince(date) / 86_400) }

        if let record = latest(.airFilter) {
            let age = days(since: record.timestamp)
            if age > Self.airFilterWarningDays {
                findings.append(
                    HealthFinding(
                        code: "air_filter_overdue", severity: .warning, title: L10n.tr("The air filter should be cleaned now"),
                        detail: L10n.format("It has been %lld days since the air filter was last cleaned. The recommendation is every 2 weeks.", age),
                        recommendation: L10n.tr("Turn off the heat pump, take out the air filter, vacuum or rinse it, and let it dry in the shade before putting it back. Record the cleaning afterwards.")))
            } else if age > Self.airFilterInfoDays {
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

        if let record = latest(.deodorizingFilter) {
            let age = days(since: record.timestamp)
            if age > Self.deodorizingFilterDays {
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

        if let record = latest(.vBlockingFilter), days(since: record.timestamp) > Self.deodorizingFilterDays {
            findings.append(
                HealthFinding(
                    code: "v_blocking_filter_due", severity: .info, title: L10n.tr("The green V-blocking filter should be cleaned"),
                    detail: L10n.format("It has been %lld days since it was cleaned. The recommendation is every 3 months, with a new filter every year.", days(since: record.timestamp)),
                    recommendation: L10n.tr("Vacuum the filter, or rinse it in lukewarm water and dry it in the shade. Spare part: MAC-2490FT-E.")))
        }
        return findings
    }
}
