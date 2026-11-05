import Foundation
import Testing
@testable import HeatPumpKit

@Suite("Health rules on local readings")
struct LocalHealthTests {
    let now = Date(timeIntervalSince1970: 1_793_872_800)  // 2026-11-05T10:00:00Z

    /// One reading per minute over `minutes` before now. `running(minute)` decides the compressor.
    func readings(
        minutes: Int, end: Date? = nil, mode: OperationMode = .heat, watts: Int = 800, room: Double = 21, outdoor: Double = 1,
        running: (Int) -> Bool
    ) -> [LocalSample] {
        let end = end ?? now
        return (0...minutes).map { i in
            var s = LocalSample(timestamp: end.addingTimeInterval(Double(i - minutes) * 60))
            let on = running(i)
            s.power = true
            s.mode = mode
            s.operating = on
            s.compressorHz = on ? 40 : 0
            s.powerW = on ? watts : 4
            s.roomTemperature = room
            s.outdoorTemperature = outdoor
            s.errorCode = CN105Parser.noError
            s.cloudConnected = true
            return s
        }
    }

    func evaluate(_ input: LocalHealthInput, cloudErrorShown: Bool = false) -> [HealthFinding] {
        LocalHealth.evaluate(input, cloudErrorShown: cloudErrorShown, now: now, timeZone: .gmt)
    }

    func codes(_ samples: [LocalSample]) -> Set<String> {
        Set(evaluate(LocalHealthInput(enabled: true, samples: samples)).map(\.code))
    }

    @Test func longCalmCyclesAreFine() {
        // 40 min on, 20 min off: 1 start per hour.
        #expect(codes(readings(minutes: 180) { $0 % 60 >= 20 }).isEmpty)
    }

    @Test func fourStartsPerHourIsShortCycling() throws {
        // 10 min on, 5 min off: 4 starts per hour.
        let findings = evaluate(LocalHealthInput(enabled: true, samples: readings(minutes: 180) { $0 % 15 >= 5 }))
        let finding = try #require(findings.first { $0.code == "short_cycling" })
        #expect(finding.severity == .warning)
        #expect(finding.detail.contains("4,0"))
        #expect(finding.recommendation.contains("luftfilteret"))
    }

    @Test func sixStartsInTwoHoursIsStronger() {
        // 5 min on, 5 min off: 6 starts per hour.
        #expect(codes(readings(minutes: 180) { $0 % 10 >= 5 }).contains("short_cycling_strong"))
        // Only the last hour busy: average below 4, one busy hour → nothing.
        #expect(codes(readings(minutes: 180) { $0 < 120 ? $0 % 60 >= 20 : $0 % 10 >= 5 }).isEmpty)
    }

    @Test func shortCyclingNeedsHeatingAndEnoughReadings() {
        #expect(codes(readings(minutes: 180, mode: .cool) { $0 % 15 >= 5 }).isEmpty)
        // Only 2 h of readings: not enough to judge 3 h.
        #expect(codes(readings(minutes: 120) { $0 % 15 >= 5 }).isEmpty)
        // Every 10 minutes: gaps over 5 min, starts cannot be seen.
        let sparse = readings(minutes: 180) { $0 % 15 >= 5 }.enumerated().filter { $0.offset % 10 == 0 }.map(\.element)
        #expect(codes(sparse).isEmpty)
    }

    /// 15 days: 14 baseline days at `baseW` W, then the last 24 h at `recentW` W, ΔT 20 °C.
    func powerHistory(baseW: Int, recentW: Int, baselineDays: Int = 14) -> [LocalSample] {
        var samples: [LocalSample] = []
        for day in 1...baselineDays {
            let end = now.addingTimeInterval(-Double(day) * 86_400 - 3600)
            samples += readings(minutes: 120, end: end, watts: baseW, room: 21, outdoor: 1) { _ in true }
        }
        samples += readings(minutes: 120, watts: recentW, room: 21, outdoor: 1) { _ in true }
        return samples
    }

    @Test func powerVersusOutdoorTemperature() throws {
        #expect(!codes(powerHistory(baseW: 600, recentW: 800)).contains("power_vs_outdoor"))  // 1.33×
        let info = try #require(
            evaluate(LocalHealthInput(enabled: true, samples: powerHistory(baseW: 600, recentW: 1000))).first {
                $0.code == "power_vs_outdoor"
            })
        #expect(info.severity == .info)  // 1.67×
        #expect(info.detail.contains("50 W per grad"))
        let warning = try #require(
            evaluate(LocalHealthInput(enabled: true, samples: powerHistory(baseW: 500, recentW: 1100))).first {
                $0.code == "power_vs_outdoor"
            })
        #expect(warning.severity == .warning)  // 2.2×
        // Not enough baseline days: no judgement.
        #expect(!codes(powerHistory(baseW: 500, recentW: 1100, baselineDays: 5)).contains("power_vs_outdoor"))
    }

    @Test func powerRatioIgnoresSmallTemperatureDifferences() {
        let mild = readings(minutes: 120, room: 21, outdoor: 18) { _ in true }
        #expect(LocalHealth.powerRatio(mild) == nil)
        #expect(LocalHealth.powerRatio(readings(minutes: 120, watts: 600, room: 21, outdoor: 1) { _ in true }) == 30)
    }

    @Test func unreachableForMoreThanAnHour() {
        let failing = LocalHealthInput(
            enabled: true, samples: [], lastAttempt: now.addingTimeInterval(-300), lastSuccess: now.addingTimeInterval(-7200),
            failingSince: now.addingTimeInterval(-3900))
        let finding = evaluate(failing).first { $0.code == "local_unreachable" }
        #expect(finding?.severity == .info)
        #expect(finding?.detail.contains("MELCloud virker som før") == true)
        // Failing for 30 min: not yet.
        var short = failing
        short.failingSince = now.addingTimeInterval(-1800)
        #expect(evaluate(short).isEmpty)
        // Nobody has tried for hours (app closed): no claim about reachability.
        var idle = failing
        idle.lastAttempt = now.addingTimeInterval(-4 * 3600)
        #expect(evaluate(idle).isEmpty)
        var off = failing
        off.enabled = false
        #expect(evaluate(off).isEmpty)
    }

    @Test func cloudConnectOffIsAWarning() {
        var s = readings(minutes: 1) { _ in false }
        s[s.count - 1].cloudConnected = false
        let finding = evaluate(LocalHealthInput(enabled: true, samples: s)).first { $0.code == "local_cloud_connect_off" }
        #expect(finding?.severity == .warning)
        #expect(finding?.title == "MELCloud-tilkoblingen er slått av i modulen")
    }

    @Test func localErrorCodeFeedsActiveError() {
        var s = readings(minutes: 1) { _ in false }
        s[s.count - 1].errorCode = 0x6840
        let findings = evaluate(LocalHealthInput(enabled: true, samples: s))
        let finding = findings.first { $0.code == "active_error_local" }
        #expect(finding?.severity == .critical)
        #expect(finding?.detail.contains("0x6840") == true)
        #expect(finding?.title.contains("lokal") == true)
        // Already reported by MELCloud: not twice.
        #expect(evaluate(LocalHealthInput(enabled: true, samples: s), cloudErrorShown: true).isEmpty)
        // Old reading: not trusted.
        s[s.count - 1].timestamp = now.addingTimeInterval(-3600)
        #expect(evaluate(LocalHealthInput(enabled: true, samples: s)).allSatisfy { $0.code != "active_error_local" })
    }

    @Test func engineIncludesLocalFindings() {
        let report = HealthEngine.evaluate(
            HealthInput(
                latestState: makeState(at: now), maintenance: [
                    MaintenanceRecord(kind: .airFilter, timestamp: now), MaintenanceRecord(kind: .deodorizingFilter, timestamp: now),
                ], now: now, timeZone: .gmt,
                local: LocalHealthInput(enabled: true, samples: readings(minutes: 180) { $0 % 15 >= 5 })))
        #expect(report.findings.contains { $0.code == "short_cycling" })
        #expect(report.overall == .warning)
        #expect(!report.findings.contains { $0.code == "all_ok" })
    }
}
