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
}
