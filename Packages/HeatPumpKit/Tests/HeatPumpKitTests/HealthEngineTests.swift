import Foundation
import Testing
@testable import HeatPumpKit

@Suite("HealthEngine rules")
struct HealthEngineTests {
    let now = Date(timeIntervalSince1970: 1_793_872_800)  // 2026-11-05T10:00:00Z
    let freshFilters: [MaintenanceRecord]

    init() {
        freshFilters = [
            MaintenanceRecord(kind: .airFilter, timestamp: now.addingTimeInterval(-3 * 86_400)),
            MaintenanceRecord(kind: .deodorizingFilter, timestamp: now.addingTimeInterval(-10 * 86_400)),
        ]
    }

    private func evaluate(
        state: DeviceState?, snapshots: [DeviceState] = [], points: [TemperaturePoint] = [],
        errors: [ErrorLogEntry] = [], energy: [EnergyDay] = [], maintenance: [MaintenanceRecord]? = nil
    ) -> HealthReport {
        HealthEngine.evaluate(
            HealthInput(
                latestState: state, snapshots: snapshots, temperaturePoints: points, errorEvents: errors,
                energyDays: energy, maintenance: maintenance ?? freshFilters, now: now, timeZone: .gmt))
    }

    private func codes(_ report: HealthReport) -> Set<String> { Set(report.findings.map(\.code)) }

    private func finding(_ code: String, in report: HealthReport) -> HealthFinding? {
        report.findings.first { $0.code == code }
    }

    @Test func healthyUnitIsOk() {
        let report = evaluate(state: makeState(at: now))
        #expect(report.overall == .ok)
        #expect(codes(report) == ["all_ok"])
        #expect(report.findings.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty && !$0.recommendation.isEmpty })
    }

    @Test func noData() {
        let report = evaluate(state: nil)
        #expect(finding("no_data", in: report)?.severity == .info)
        #expect(!codes(report).contains("all_ok"))
    }

    @Test func activeErrorIsCritical() {
        let byFlag = evaluate(state: makeState(at: now, hasError: true, errorCode: 8000))
        #expect(finding("active_error", in: byFlag)?.severity == .critical)
        #expect(byFlag.overall == .critical)
        let byCode = evaluate(state: makeState(at: now, hasError: false, errorCode: 5101))
        let f = finding("active_error", in: byCode)
        #expect(f?.severity == .critical)
        #expect(f?.detail.contains("5101") == true)
        #expect(f?.detail.contains("Merk:") == true)  // low-confidence caveat
        #expect(f?.recommendation.contains("forhandler") == true)
        #expect(finding("active_error", in: evaluate(state: makeState(at: now, errorCode: 0))) == nil)
    }

    @Test func errorLogRecentAndOld() {
        let recent = ErrorLogEntry(deviceId: 1, start: now.addingTimeInterval(-5 * 86_400), message: "Feil A")
        let old = ErrorLogEntry(deviceId: 1, start: now.addingTimeInterval(-60 * 86_400), message: "Feil B")
        #expect(finding("recent_error_log", in: evaluate(state: makeState(at: now), errors: [recent, old]))?.severity == .warning)
        let onlyOld = evaluate(state: makeState(at: now), errors: [old])
        #expect(finding("old_error_log", in: onlyOld)?.severity == .info)
        #expect(finding("recent_error_log", in: onlyOld) == nil)
    }

    @Test func offlineOrSilent() {
        #expect(finding("offline", in: evaluate(state: makeState(at: now, offline: true)))?.severity == .warning)
        let silent = makeState(at: now, lastCommunication: now.addingTimeInterval(-3700))
        #expect(finding("offline", in: evaluate(state: silent))?.severity == .warning)
        let recent = makeState(at: now, lastCommunication: now.addingTimeInterval(-600))
        #expect(finding("offline", in: evaluate(state: recent)) == nil)
    }

    @Test func wifiThresholds() {
        #expect(finding("wifi_weak", in: evaluate(state: makeState(at: now, wifi: -85)))?.severity == .warning)
        #expect(finding("wifi_fair", in: evaluate(state: makeState(at: now, wifi: -75)))?.severity == .info)
        let good = evaluate(state: makeState(at: now, wifi: -65))
        #expect(finding("wifi_weak", in: good) == nil && finding("wifi_fair", in: good) == nil)
        // Positive values are not dBm; ignore rather than guess.
        #expect(finding("wifi_weak", in: evaluate(state: makeState(at: now, wifi: 40))) == nil)
    }

    @Test func setpointNotReachedNeedsTwoHours() {
        let cold = stride(from: 150.0, through: 0, by: -30).map {
            makeState(at: now.addingTimeInterval(-$0 * 60), set: 22, room: 20.0, outdoor: -18)
        }
        let report = evaluate(state: cold.last, snapshots: cold)
        let f = finding("setpoint_not_reached", in: report)
        #expect(f?.severity == .warning)
        #expect(f?.recommendation.contains("kaldt ute") == true)

        let short = cold.suffix(3)  // 1 hour only
        #expect(finding("setpoint_not_reached", in: evaluate(state: short.last, snapshots: Array(short))) == nil)

        var interrupted = cold
        interrupted[4] = makeState(at: interrupted[4].fetchedAt, set: 22, room: 21.5)
        #expect(finding("setpoint_not_reached", in: evaluate(state: interrupted.last, snapshots: interrupted)) == nil)

        let cooling = cold.map { s -> DeviceState in var c = s; c.mode = .cool; return c }
        #expect(finding("setpoint_not_reached", in: evaluate(state: cooling.last, snapshots: cooling)) == nil)
    }

    private func energyHistory(lastDayKWh: Double, days: Int = 10) -> ([EnergyDay], [TemperaturePoint]) {
        var energy: [EnergyDay] = []
        var points: [TemperaturePoint] = []
        for offset in stride(from: days, through: 1, by: -1) {
            let date = now.addingTimeInterval(-Double(offset) * 86_400)
            let day = WireDate.day(date, timeZone: .gmt)
            // Outdoor −3 °C → 20 degree-days. Normal: 0.5 kWh/DD = 10 kWh.
            energy.append(EnergyDay(day: day, totalKWh: offset == 1 ? lastDayKWh : 10, heatingKWh: nil))
            points.append(TemperaturePoint(timestamp: WireDate.parse(day + "T12:00:00", timeZone: .gmt)!, outdoor: -3))
        }
        // Today (partial) is ignored even if extreme.
        energy.append(EnergyDay(day: WireDate.day(now, timeZone: .gmt), totalKWh: 99))
        return (energy, points)
    }

    @Test func energyAnomaly() {
        let (warn, warnPoints) = energyHistory(lastDayKWh: 25)  // 2.5×
        #expect(finding("energy_anomaly", in: evaluate(state: makeState(at: now), points: warnPoints, energy: warn))?.severity == .warning)
        let (info, infoPoints) = energyHistory(lastDayKWh: 17)  // 1.7×
        #expect(finding("energy_anomaly", in: evaluate(state: makeState(at: now), points: infoPoints, energy: info))?.severity == .info)
        let (normal, normalPoints) = energyHistory(lastDayKWh: 11)
        #expect(finding("energy_anomaly", in: evaluate(state: makeState(at: now), points: normalPoints, energy: normal)) == nil)
    }

    @Test func energyAnomalyNeedsSevenDaysAndIgnoresZeros() {
        let (few, fewPoints) = energyHistory(lastDayKWh: 40, days: 7)  // only 6 baseline days
        #expect(finding("energy_anomaly", in: evaluate(state: makeState(at: now), points: fewPoints, energy: few)) == nil)
        var (zeros, zeroPoints) = energyHistory(lastDayKWh: 40)
        for i in 0..<5 { zeros[i].totalKWh = 0 }  // zero days are missing data → baseline too small
        #expect(finding("energy_anomaly", in: evaluate(state: makeState(at: now), points: zeroPoints, energy: zeros)) == nil)
    }

    @Test func airFilterThresholds() {
        func report(airDays: Double?) -> HealthReport {
            var records = [MaintenanceRecord(kind: .deodorizingFilter, timestamp: now.addingTimeInterval(-86_400))]
            if let airDays { records.append(MaintenanceRecord(kind: .airFilter, timestamp: now.addingTimeInterval(-airDays * 86_400))) }
            return evaluate(state: makeState(at: now), maintenance: records)
        }
        #expect(finding("air_filter_unknown", in: report(airDays: nil))?.severity == .info)
        #expect(finding("air_filter_due", in: report(airDays: 20))?.severity == .info)
        #expect(finding("air_filter_overdue", in: report(airDays: 31))?.severity == .warning)
        let fresh = report(airDays: 5)
        #expect(!codes(fresh).contains("air_filter_due") && !codes(fresh).contains("air_filter_overdue"))
    }

    @Test func deodorizingAndVBlockingFilters() {
        let old = [
            MaintenanceRecord(kind: .airFilter, timestamp: now.addingTimeInterval(-86_400)),
            MaintenanceRecord(kind: .deodorizingFilter, timestamp: now.addingTimeInterval(-91 * 86_400)),
            MaintenanceRecord(kind: .vBlockingFilter, timestamp: now.addingTimeInterval(-100 * 86_400)),
        ]
        let report = evaluate(state: makeState(at: now), maintenance: old)
        #expect(finding("deodorizing_filter_due", in: report)?.severity == .info)
        #expect(finding("deodorizing_filter_due", in: report)?.recommendation.contains("MAC-3010FT-E") == true)
        #expect(finding("v_blocking_filter_due", in: report)?.severity == .info)
        let none = evaluate(state: makeState(at: now), maintenance: [MaintenanceRecord(kind: .airFilter, timestamp: now)])
        #expect(finding("deodorizing_filter_unknown", in: none)?.severity == .info)
        #expect(finding("v_blocking_filter_due", in: none) == nil)  // optional accessory: only if ever recorded
    }

    @Test func firmware() {
        let pending = makeState(at: now, firmware: FirmwareInfo(deployment: "43.00", updateAborted: false))
        #expect(finding("firmware_pending", in: evaluate(state: pending))?.severity == .info)
        let aborted = makeState(at: now, firmware: FirmwareInfo(deployment: nil, updateAborted: true))
        #expect(finding("firmware_aborted", in: evaluate(state: aborted))?.severity == .info)
    }

    @Test func findingsSortedBySeverity() {
        let report = evaluate(
            state: makeState(at: now, hasError: true, wifi: -75),
            errors: [ErrorLogEntry(deviceId: 1, start: now.addingTimeInterval(-86_400), message: "x")],
            maintenance: [])
        let severities = report.findings.map(\.severity)
        #expect(severities == severities.sorted(by: >))
        #expect(report.overall == .critical)
    }
}
