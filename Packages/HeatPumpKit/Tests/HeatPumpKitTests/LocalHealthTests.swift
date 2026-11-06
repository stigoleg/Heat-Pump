import Foundation
import Testing
@testable import HeatPumpKit
@testable import MELCloudIntegration

@Suite("Health rules on local readings")
struct LocalHealthTests {
    let now = Date(timeIntervalSince1970: 1_793_872_800)  // 2026-11-05T10:00:00Z

    /// One reading per minute over `minutes` before `end`. `running(minute)` decides the compressor.
    func readings(
        minutes: Int, end: Date? = nil, mode: OperationMode = .heat, watts: Int = 800, room: Double = 21, outdoor: Double = 1,
        running: (Int) -> Bool
    ) -> [LocalSample] {
        let end = end ?? now
        let rawMode = [OperationMode.heat: 1, .cool: 3, .dry: 2, .fan: 7, .auto: 0][mode]
        return (0...minutes).map { i in
            var s = LocalSample(timestamp: end.addingTimeInterval(Double(i - minutes) * 60))
            let on = running(i)
            s.power = true
            s.setRaw(mode: rawMode, fan: 0, vaneVertical: 0, vaneHorizontal: 0)
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

    /// Stores the readings in a fresh database and builds the input the way the service does (SQL aggregates).
    func input(_ samples: [LocalSample]) throws -> LocalHealthInput {
        let store = try HistoryStore(path: temporaryDatabasePath())
        try store.insertLocalSamples(samples)
        return try LocalHealth.input(store: store, now: now, enabled: true, latest: try store.latestLocalSample())
    }

    func evaluate(_ input: LocalHealthInput, cloudErrorShown: Bool = false) -> [HealthFinding] {
        LocalHealth.evaluate(input, cloudErrorShown: cloudErrorShown, now: now, timeZone: .gmt)
    }

    func codes(_ samples: [LocalSample]) throws -> Set<String> {
        Set(evaluate(try input(samples)).map(\.code))
    }

    @Test func longCalmCyclesAreFine() throws {
        // 40 min on, 20 min off: 1 start per hour.
        #expect(try codes(readings(minutes: 180) { $0 % 60 >= 20 }).isEmpty)
    }

    @Test func fourStartsPerHourIsShortCycling() throws {
        // 10 min on, 5 min off: 4 starts per hour.
        let findings = evaluate(try input(readings(minutes: 180) { $0 % 15 >= 5 }))
        let finding = try #require(findings.first { $0.code == "short_cycling" })
        #expect(finding.severity == .warning)
        #expect(finding.detail.contains("4,0"))
        #expect(finding.recommendation.contains("air filter"))
    }

    @Test func sixStartsInTwoHoursIsStronger() throws {
        // 5 min on, 5 min off: 6 starts per hour.
        #expect(try codes(readings(minutes: 180) { $0 % 10 >= 5 }).contains("short_cycling_strong"))
        // Only the last hour busy: average below 4, one busy hour → nothing.
        #expect(try codes(readings(minutes: 180) { $0 < 120 ? $0 % 60 >= 20 : $0 % 10 >= 5 }).isEmpty)
    }

    @Test func shortCyclingNeedsHeatingAndEnoughReadings() throws {
        #expect(try codes(readings(minutes: 180, mode: .cool) { $0 % 15 >= 5 }).isEmpty)
        // Only 2 h of readings: not enough to judge 3 h.
        #expect(try codes(readings(minutes: 120) { $0 % 15 >= 5 }).isEmpty)
        // Every 10 minutes: gaps over 5 min, starts cannot be seen.
        let sparse = readings(minutes: 180) { $0 % 15 >= 5 }.enumerated().filter { $0.offset % 10 == 0 }.map(\.element)
        #expect(try codes(sparse).isEmpty)
    }

    /// `baselineDays` days with 8 hours of readings each, then the last 8 hours.
    func powerHistory(
        baselineDays: Int = 14, baseOutdoor: Double = 1, baseW: Int, baseRunning: @escaping (Int) -> Bool = { _ in true },
        recentOutdoor: Double = 1, recentW: Int, recentRunning: @escaping (Int) -> Bool = { _ in true }
    ) -> [LocalSample] {
        var samples: [LocalSample] = []
        for day in stride(from: baselineDays, through: 1, by: -1) {
            let end = now.addingTimeInterval(-Double(day) * 86_400 - 3600)
            samples += readings(minutes: 480, end: end, watts: baseW, room: 21, outdoor: baseOutdoor, running: baseRunning)
        }
        samples += readings(minutes: 480, watts: recentW, room: 21, outdoor: recentOutdoor, running: recentRunning)
        return samples
    }

    func powerFinding(_ samples: [LocalSample]) throws -> HealthFinding? {
        evaluate(try input(samples)).first { $0.code == "power_vs_outdoor" }
    }

    @Test func powerVersusOutdoorTemperature() throws {
        // ΔT 20 °C throughout; baseline 300 W on average.
        #expect(try powerFinding(powerHistory(baseW: 300, recentW: 400)) == nil)  // 1.33×
        let info = try #require(try powerFinding(powerHistory(baseW: 300, recentW: 500)))
        #expect(info.severity == .info)  // 1.67×
        #expect(info.detail.contains("25 W per degree"))
        let warning = try #require(try powerFinding(powerHistory(baseW: 300, recentW: 700)))
        #expect(warning.severity == .warning)  // 2.33×
        // Too few baseline days: no judgement.
        #expect(try powerFinding(powerHistory(baselineDays: 4, baseW: 300, recentW: 700)) == nil)
    }

    /// Regression (review): a cold spell with continuous running, then mild weather with short
    /// runs, must not look like high consumption. Running-only averages gave "2,1 ganger".
    @Test func mildWeatherAfterColdSpellIsNotHighConsumption() throws {
        let samples = powerHistory(
            baseOutdoor: -5, baseW: 800, recentOutdoor: 15, recentW: 380, recentRunning: { $0 % 40 < 20 })
        #expect(try powerFinding(samples) == nil)
        // Even against a baseline at the same mild difference, short runs at 380 W are normal.
        let mild = powerHistory(
            baseOutdoor: 15, baseW: 380, baseRunning: { $0 % 40 < 20 }, recentOutdoor: 15, recentW: 380,
            recentRunning: { $0 % 40 < 20 })
        #expect(try powerFinding(mild) == nil)
    }

    @Test func baselineMustHaveAComparableTemperatureDifference() throws {
        // Baseline only at ΔT 26 °C, recent at ΔT 20 °C with twice the power: not comparable.
        #expect(try powerFinding(powerHistory(baseOutdoor: -5, baseW: 300, recentOutdoor: 1, recentW: 700)) == nil)
        // Small differences (ΔT < 5 °C) are never judged.
        #expect(try powerFinding(powerHistory(baseOutdoor: 18, baseW: 100, recentOutdoor: 18, recentW: 400)) == nil)
    }

    @Test func wattsPerDegreeIncludesIdleTime() throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        // 20 min at 380 W, 20 min at 4 W, ΔT 6: about 192 W / 6 °C = 32 W per degree.
        try store.insertLocalSamples(readings(minutes: 120, room: 21, outdoor: 15) { $0 % 40 < 20 }.map {
            var s = $0
            s.powerW = s.isRunning ? 380 : 4
            return s
        })
        let hours = try store.localPowerBuckets(from: now.addingTimeInterval(-7200), to: now, bucketSeconds: 7200, origin: now.addingTimeInterval(-7200))
        let ratio = try #require(LocalHealth.wattsPerDegree(hours))
        #expect(abs(ratio - 32) < 2)
    }

    @Test func unreachableForMoreThanAnHour() {
        let failing = LocalHealthInput(
            enabled: true, lastAttempt: now.addingTimeInterval(-300), lastSuccess: now.addingTimeInterval(-7200),
            failingSince: now.addingTimeInterval(-3900))
        let finding = evaluate(failing).first { $0.code == "local_unreachable" }
        #expect(finding?.severity == .info)
        #expect(finding?.detail.contains("MELCloud work as before") == true)
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
        // Away from home: not the adapter's fault, no finding.
        var away = failing
        away.onHomeNetwork = false
        #expect(evaluate(away).isEmpty)
    }

    @Test func cloudConnectOffIsAWarning() {
        var latest = readings(minutes: 1) { _ in false }.last
        latest?.cloudConnected = false
        let finding = evaluate(LocalHealthInput(enabled: true, latest: latest)).first { $0.code == "local_cloud_connect_off" }
        #expect(finding?.severity == .warning)
        #expect(finding?.title == "The MELCloud connection is turned off in the adapter")
    }

    @Test func localErrorCodeFeedsActiveError() {
        var latest = readings(minutes: 1) { _ in false }.last
        latest?.errorCode = 0x6840
        let finding = evaluate(LocalHealthInput(enabled: true, latest: latest)).first { $0.code == "active_error_local" }
        #expect(finding?.severity == .critical)
        #expect(finding?.detail.contains("0x6840") == true)
        #expect(finding?.title.contains("local") == true)
        // Already reported by MELCloud: not twice.
        #expect(evaluate(LocalHealthInput(enabled: true, latest: latest), cloudErrorShown: true).isEmpty)
        // Old reading: not trusted.
        latest?.timestamp = now.addingTimeInterval(-3600)
        #expect(evaluate(LocalHealthInput(enabled: true, latest: latest)).allSatisfy { $0.code != "active_error_local" })
    }

    @Test func engineIncludesLocalFindings() throws {
        let report = HealthEngine.evaluate(
            HealthInput(
                latestState: makeState(at: now), maintenance: [
                    MaintenanceRecord(kind: .airFilter, timestamp: now), MaintenanceRecord(kind: .deodorizingFilter, timestamp: now),
                ], now: now, timeZone: .gmt,
                local: try input(readings(minutes: 180) { $0 % 15 >= 5 })))
        #expect(report.findings.contains { $0.code == "short_cycling" })
        #expect(report.overall == .warning)
        #expect(!report.findings.contains { $0.code == "all_ok" })
    }
}
