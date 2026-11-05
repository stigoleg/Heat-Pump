import Foundation
import Testing
@testable import HeatPumpKit

/// 0x09 (sub-mode, stage, auto sub-mode), runtime minutes in 0x03, defrost aggregation and the
/// frequent-defrost health rule.
@Suite("Local operating phase and defrost")
struct LocalPhaseTests {
    let date = Date(timeIntervalSince1970: 1_793_872_800)

    @Test func realFixtureDecodesSubModeStageAndRuntime() {
        let s = CN105Parser.sample(frames: LocalFixture.frames, at: date).sample
        #expect(s.subMode == 0)
        #expect(s.stage == 1)
        #expect(s.autoSubMode == 0)
        // 0x0015D49F minutes ≈ 23 845 hours (unit made 2022-04).
        #expect(s.runtimeMinutes == 1_430_687)
        #expect(s.runtimeHours == 23_844)
        // NORMAL with the compressor stopped while on: resting.
        #expect(s.phase == .resting)
    }

    func sample(subMode: UInt8, running: Bool, power: Bool = true, mode: UInt8 = 1) -> LocalSample {
        let frames = [
            CN105Parser.frame(group: 0x02, payload: [8: power ? 1 : 0, 9: mode, 16: 0xAA]),
            CN105Parser.frame(group: 0x06, payload: [8: running ? 40 : 0, 9: running ? 1 : 0, 11: 200]),
            CN105Parser.frame(group: 0x09, payload: [8: subMode, 9: running ? 3 : 1, 10: 0]),
        ]
        return CN105Parser.sample(frames: frames, at: date).sample
    }

    @Test func phases() {
        #expect(sample(subMode: 2, running: true).phase == .defrost)
        #expect(sample(subMode: 4, running: false).phase == .preheat)
        #expect(sample(subMode: 1, running: true).phase == .warmup)
        #expect(sample(subMode: 8, running: false).phase == .standby)
        #expect(sample(subMode: 0, running: true).phase == .heating)
        #expect(sample(subMode: 0, running: true, mode: 3).phase == .cooling)
        #expect(sample(subMode: 0, running: false).phase == .resting)
        #expect(sample(subMode: 0, running: false, power: false).phase == .off)
        #expect(sample(subMode: 0x10, running: false).phase == .off)
        #expect(LocalPhase.defrost.statusLine == "Avriser – det kan blåse lite eller kaldt i noen minutter")
        #expect(LocalPhase.standby.statusLine == "Hviler (ønsket temperatur nådd)")
        #expect(LocalSample(timestamp: date).phase == nil)
    }

    @Test func storedAndReadBack() throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        var s = sample(subMode: 2, running: true)
        s.runtimeMinutes = 1234
        try store.insertLocalSample(s)
        let back = try #require(try store.latestLocalSample())
        #expect(back.subMode == 2)
        #expect(back.stage == 3)
        #expect(back.autoSubMode == 0)
        #expect(back.runtimeMinutes == 1234)
        #expect(back.phase == .defrost)
    }

    /// One reading per minute for `minutes`, defrosting where `defrost(minute)` is true.
    func readings(from start: Date, minutes: Int, outdoor: Double = -2, defrost: (Int) -> Bool) -> [LocalSample] {
        (0..<minutes).map { m in
            var s = sample(subMode: defrost(m) ? 2 : 0, running: true)
            s.timestamp = start.addingTimeInterval(Double(m) * 60)
            s.outdoorTemperature = outdoor
            s.roomTemperature = 21
            return s
        }
    }

    @Test func bucketsCountDefrostsAndMinutes() throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let start = Date(timeIntervalSince1970: 1_793_872_800)  // whole hour
        // Two defrosts of 5 minutes in the hour: minutes 10–14 and 40–44.
        try store.insertLocalSamples(readings(from: start, minutes: 60) { (10..<15).contains($0) || (40..<45).contains($0) })
        let bucket = try #require(try store.localPowerBuckets(from: start, to: start.addingTimeInterval(3599), bucketSeconds: 3600).first)
        #expect(bucket.defrosts == 2)
        #expect(bucket.defrostSeconds == 600)
        #expect(bucket.phaseCount == 60)
        #expect(bucket.averageOutdoor == -2)
    }

    @Test func phaseSpansFollowChangesAndGaps() throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let start = date
        var samples = readings(from: start, minutes: 30) { (10..<15).contains($0) }
        // A 20-minute gap, then 5 more minutes of heating.
        samples += readings(from: start.addingTimeInterval(50 * 60), minutes: 5) { _ in false }
        try store.insertLocalSamples(samples)
        let spans = try store.localPhaseSpans(from: start, to: start.addingTimeInterval(3600))
        #expect(spans.map(\.kind) == [.running, .defrost, .running, .running])
        #expect(spans[1].start == start.addingTimeInterval(600))
        #expect(spans[1].end == start.addingTimeInterval(900))
        #expect(spans[2].end == start.addingTimeInterval(30 * 60))  // last reading + 1 min before the gap
        #expect(spans[3].start == start.addingTimeInterval(50 * 60))
    }

    func hours(_ count: Int, endingAt end: Date, defrosts: Int, defrostMinutes: Double, outdoor: Double = -2) -> [LocalPowerBucket] {
        (0..<count).map { i in
            LocalPowerBucket(
                start: end.addingTimeInterval(-Double(count - i) * 3600), averageW: 600, runningShare: 0.8, heatingShare: 1,
                averageDelta: 20, observedSeconds: 3600, runningSeconds: 2800, count: 60, defrosts: defrosts,
                defrostSeconds: defrostMinutes * 60, phaseCount: 60, averageOutdoor: outdoor)
        }
    }

    @Test func frequentDefrostRule() {
        let now = date
        // > 3 defrosts per hour for 3 hours in a row: warning.
        let busy = LocalHealth.frequentDefrost(hours(3, endingAt: now, defrosts: 4, defrostMinutes: 12), now: now)
        #expect(busy.map(\.code) == ["frequent_defrost"])
        #expect(busy.first?.severity == .warning)
        #expect(busy.first?.recommendation.contains("snø/is og løv") == true)
        // Only two such hours: nothing from that rule (and share is below 20 %).
        #expect(LocalHealth.frequentDefrost(hours(2, endingAt: now, defrosts: 4, defrostMinutes: 10), now: now).isEmpty)
        // Defrosting a quarter of the time over 6+ hours at mild temperatures: info.
        let share = LocalHealth.frequentDefrost(hours(8, endingAt: now, defrosts: 2, defrostMinutes: 15, outdoor: 1), now: now)
        #expect(share.map(\.code) == ["defrost_share"])
        #expect(share.first?.severity == .info)
        // The same share in hard frost (below −5 °C) is expected.
        #expect(LocalHealth.frequentDefrost(hours(8, endingAt: now, defrosts: 2, defrostMinutes: 15, outdoor: -12), now: now).isEmpty)
        // Thin data (few readings) says nothing.
        var thin = hours(4, endingAt: now, defrosts: 5, defrostMinutes: 20)
        for i in thin.indices { thin[i].phaseCount = 10 }
        #expect(LocalHealth.frequentDefrost(thin, now: now).isEmpty)
    }

    @Test func defrostHistoryMetricPerHour() async throws {
        let clock = TestClock()
        let store = try HistoryStore(path: temporaryDatabasePath())
        let start = clock.now.addingTimeInterval(-7200)
        try store.insertLocalSamples(readings(from: start, minutes: 120) { (10..<16).contains($0) || (70..<74).contains($0) })
        let service = HeatPumpService(backend: MockBackend(timeZone: .gmt, now: clock.provider), store: store, timeZone: .gmt, now: clock.provider)
        let points = try await service.history(metric: .defrost, from: start, to: clock.now)
        #expect(points.map(\.value) == [6, 4])
        #expect(points.map(\.text) == ["1 avriminger", "1 avriminger"])
        #expect(points.allSatisfy { $0.source == "local" })
        let summary = try await service.liveSummary(maxAge: 3600)
        #expect(summary.defrostsLast24Hours == 2)
        #expect(summary.defrostMinutesLast24Hours == 10)
    }

    @Test func simulationDefrostsInTheColdAndKeepsTheCounter() throws {
        // Find a cold, running minute in the simulation that defrosts.
        var t = date
        var found: LocalSample?
        for _ in 0..<(3 * 1440) {
            let s = MockLocalSimulation.sample(at: t)
            if s.phase == .defrost { found = s; break }
            t = t.addingTimeInterval(60)
        }
        let s = try #require(found)
        #expect((s.outdoorTemperature ?? 99) < 3)
        // Round trip through the frames the simulated adapter sends.
        let decoded = CN105Parser.sample(frames: MockLocalSimulation.frames(for: s), at: s.timestamp).sample
        #expect(decoded.subMode == 2)
        #expect(decoded.runtimeMinutes == s.runtimeMinutes)
        #expect(decoded.stage == s.stage)
    }
}
