import Foundation
import Synchronization
import Testing
@testable import HeatPumpKit
@testable import DemoIntegration
@testable import MELCloudIntegration

/// Counts reads per host; replies with the fixture frames (or fails) without any network.
final class FakeLocalNetwork: Sendable {
    struct State {
        var reads: [String] = []
        var failingHosts: Set<String> = []
        var frames = LocalFixture.frames
        var scans: [String] = []
        var scanResult: [String] = []
        /// The Mac's current /24 networks: 192.168.10.0 and 192.168.1.0 ("home").
        var subnets: [UInt32] = [0xC0A8_0A00, 0xC0A8_0100]
    }

    let state = Mutex(State())

    var reads: [String] { state.withLock { $0.reads } }
    var scans: [String] { state.withLock { $0.scans } }

    var access: LocalAccess {
        LocalAccess(
            makeClient: { host in Client(host: host, network: self) }, scanner: Scanner(network: self),
            currentSubnets: { self.state.withLock { $0.subnets } })
    }

    struct Client: CN105StatusReading {
        let host: String
        let network: FakeLocalNetwork
        func readStatus() async throws -> LocalStatusReply {
            let (fail, frames) = network.state.withLock { s in
                s.reads.append(host)
                return (s.failingHosts.contains(host), s.frames)
            }
            if fail { throw LocalAccessError.network("Tidsavbrudd") }
            return LocalStatusReply(frames: frames, adapterVersion: "34.00", rssi: -54, cloudConnect: "ON")
        }
    }

    struct Scanner: LocalNetworkScanning {
        let network: FakeLocalNetwork
        func hosts(matchingMAC mac: String) async throws -> [String] {
            network.state.withLock { s in
                s.scans.append(mac)
                return s.scanResult
            }
        }
    }
}

@Suite("Local access through the service")
struct LocalServiceTests {
    let clock = TestClock()
    let path = temporaryDatabasePath()
    let network = FakeLocalNetwork()

    func makeService(store: HistoryStore? = nil) throws -> HeatPumpService {
        HeatPumpService(
            backend: MockBackend(timeZone: .gmt, now: clock.provider), store: try store ?? HistoryStore(path: path),
            timeZone: .gmt, now: clock.provider, sleep: clock.sleeper, local: network.access)
    }

    @Test func offByDefaultAndNeverReads() async throws {
        let service = try makeService()
        #expect(try await service.localSettings() == LocalSettings(enabled: false, host: nil))
        let live = try await service.liveStatus()
        #expect(live.sample == nil)
        #expect(live.refreshed == false)
        #expect(network.reads.isEmpty)
        #expect(try await service.healthReport().findings.allSatisfy { !$0.code.hasPrefix("local") })
    }

    @Test func readsAtMostOncePer20SecondsAcrossProcesses() async throws {
        let service = try makeService()
        try await service.saveLocalSettings(LocalSettings(enabled: true, host: "192.168.10.83"))
        let first = try await service.liveStatus(maxAge: 0)
        #expect(first.refreshed)
        #expect(first.sample?.powerW == 4)
        #expect(first.sample?.energyKWh == 4146.4)
        #expect(first.sample?.adapterVersion == "34.00")
        // A second process on the same database within 20 s gets the stored reading, no request.
        let other = try makeService(store: try HistoryStore(path: path))
        clock.advance(10)
        let second = try await other.liveStatus(maxAge: 0)
        #expect(second.refreshed == false)
        #expect(second.sample == first.sample)
        #expect(network.reads.count == 1)
        // Fresh enough: no request even after the spacing.
        clock.advance(15)
        _ = try await service.liveStatus(maxAge: 60)
        #expect(network.reads.count == 1)
        _ = try await service.liveStatus(maxAge: 20)
        #expect(network.reads.count == 2)
    }

    @Test func failuresBackOff() async throws {
        let service = try makeService()
        try await service.saveLocalSettings(LocalSettings(enabled: true, host: "192.168.10.83"))
        network.state.withLock { $0.failingHosts = ["192.168.10.83"] }
        let failed = try await service.liveStatus(maxAge: 0)
        #expect(failed.message?.contains("Tidsavbrudd") == true)
        #expect(failed.reachability.consecutiveFailures == 1)
        clock.advance(60)
        _ = try await service.liveStatus(maxAge: 0)
        #expect(network.reads.count == 1)  // 2 min back-off after one failure
        clock.advance(61)
        _ = try await service.liveStatus(maxAge: 0)
        #expect(network.reads.count == 2)
        #expect(try await service.localReachability().consecutiveFailures == 2)
        clock.advance(200)
        _ = try await service.liveStatus(maxAge: 0)
        #expect(network.reads.count == 2)  // 4 min after two failures
        #expect(HeatPumpService.localBackoff(failures: 3) == 480)
        #expect(HeatPumpService.localBackoff(failures: 9) == 600)
        // Recovery resets the count.
        network.state.withLock { $0.failingHosts = [] }
        clock.advance(60)
        let ok = try await service.liveStatus(maxAge: 0)
        #expect(ok.refreshed)
        #expect(ok.reachability.consecutiveFailures == 0)
        #expect(ok.reachability.failingSince == nil)
    }

    @Test func invalidHostIsRefused() async throws {
        let service = try makeService()
        await #expect(throws: HeatPumpError.self) {
            try await service.saveLocalSettings(LocalSettings(enabled: true, host: "8.8.8.8"))
        }
        let test = try await service.testLocal(host: "evil.example.com")
        #expect(test.ok == false)
        #expect(network.reads.isEmpty)
    }

    @Test func testReadDoesNotSaveTheAddress() async throws {
        let service = try makeService()
        let result = try await service.testLocal(host: "192.168.1.77")
        #expect(result.ok)
        #expect(result.message.contains("34.00") && result.message.contains("4 W"))
        #expect(try await service.localSettings().host == nil)
        let again = try await service.testLocal(host: "192.168.1.77")
        #expect(again.ok == false)  // within 20 s
        #expect(network.reads == ["192.168.1.77"])
    }

    @Test func awayFromHomeReadsNothingAndDoesNotBlameTheAdapter() async throws {
        let service = try makeService()
        _ = try await service.currentState()
        try await service.saveLocalSettings(LocalSettings(enabled: true, host: "192.168.10.83"))
        network.state.withLock { $0.subnets = [0x0A00_0000] }  // on 10.0.0.0/24, e.g. at a café
        for _ in 0..<10 {
            let live = try await service.liveStatus(maxAge: 0)
            #expect(live.refreshed == false)
            #expect(live.message?.contains("Not on the home network") == true)
            #expect(live.reachability.onHomeNetwork == false)
            clock.advance(3700)
        }
        #expect(network.reads.isEmpty)
        #expect(network.scans.isEmpty)
        #expect(try await service.localReachability().consecutiveFailures == 0)
        #expect(try await service.healthReport().findings.allSatisfy { $0.code != "local_unreachable" })
        // Manual actions stay possible.
        _ = try await service.testLocal(host: "192.168.10.83")
        #expect(network.reads == ["192.168.10.83"])
        // Back home: reads resume.
        network.state.withLock { $0.subnets = [0xC0A8_0A00] }
        clock.advance(30)
        #expect(try await service.liveStatus(maxAge: 0).refreshed)
    }

    @Test func testingAnotherAddressLeavesHistoryAndFailuresAlone() async throws {
        let service = try makeService()
        try await service.saveLocalSettings(LocalSettings(enabled: true, host: "192.168.10.83"))
        network.state.withLock { $0.failingHosts = ["192.168.10.83"] }
        _ = try await service.liveStatus(maxAge: 0)
        #expect(try await service.localReachability().consecutiveFailures == 1)
        clock.advance(30)
        let other = try await service.testLocal(host: "192.168.1.77")
        #expect(other.ok)
        #expect(try service.store.latestLocalSample() == nil)  // not stored
        let reach = try await service.localReachability()
        #expect(reach.consecutiveFailures == 1)
        #expect(reach.lastSuccess == nil)
        // A failing test of another address does not count either.
        network.state.withLock { $0.failingHosts = ["192.168.10.83", "192.168.1.78"] }
        clock.advance(30)
        #expect(try await service.testLocal(host: "192.168.1.78").ok == false)
        #expect(try await service.localReachability().consecutiveFailures == 1)
        // Testing the saved address is a real read: stored, failures reset.
        network.state.withLock { $0.failingHosts = [] }
        clock.advance(30)
        #expect(try await service.testLocal(host: "192.168.10.83").ok)
        #expect(try service.store.latestLocalSample() != nil)
        #expect(try await service.localReachability().consecutiveFailures == 0)
    }

    @Test func discoveryFindsTheUnitByMACWithoutShowingIt() async throws {
        let service = try makeService()
        _ = try await service.currentState()  // snapshot with the mock's MAC
        try await service.saveLocalSettings(LocalSettings(enabled: true, host: "192.168.1.10"))
        network.state.withLock {
            $0.failingHosts = ["192.168.1.10"]
            $0.scanResult = ["192.168.1.42"]
        }
        let result = try await service.discoverLocal()
        #expect(result.host == "192.168.1.42")
        #expect(network.scans == ["00:00:5e:00:53:01"])
        #expect(!result.message.lowercased().contains("00:00:5e"))
        #expect(try await service.localSettings().host == "192.168.1.42")
        // The saved address was tried first; the new one is read after the 20 s spacing.
        #expect(network.reads == ["192.168.1.10"])
        let again = try await service.discoverLocal()
        #expect(again.host == nil)  // at most once per minute
        clock.advance(25)
        #expect(try await service.liveStatus(maxAge: 0).refreshed)
        #expect(network.reads.last == "192.168.1.42")
    }

    @Test func automaticRediscoveryAtMostHourly() async throws {
        let service = try makeService()
        _ = try await service.currentState()
        try await service.saveLocalSettings(LocalSettings(enabled: true, host: "192.168.1.10"))
        network.state.withLock { $0.failingHosts = ["192.168.1.10"] }
        for _ in 0..<3 {
            _ = try await service.liveStatus(maxAge: 0)
            clock.advance(601)
        }
        #expect(network.scans.count == 1)  // after the third failure
        for _ in 0..<3 {
            _ = try await service.liveStatus(maxAge: 0)
            clock.advance(601)
        }
        #expect(network.scans.count == 1)  // < 1 h later: not again
        clock.advance(3600)
        _ = try await service.liveStatus(maxAge: 0)
        #expect(network.scans.count == 2)
    }

    @Test func localCounterMakesDaysExact() async throws {
        let service = try makeService()
        _ = try await service.currentState()
        try await service.savePriceSettings(PriceSettings(agreement: .norgespris))
        let calendar = WireDate.calendar(.gmt)
        let day = calendar.startOfDay(for: clock.now.addingTimeInterval(-86_400))
        // Cloud says 9 kWh; the local counter says 12.0 kWh over the full day (0.5 kWh per hour).
        try service.store.upsertEnergyDays(
            [EnergyDay(day: WireDate.day(day, timeZone: .gmt), totalKWh: 9, heatingKWh: 9)], deviceId: MockBackend.deviceId,
            now: clock.now)
        var samples: [LocalSample] = []
        for minute in stride(from: -5, through: 24 * 60 + 5, by: 5) {
            var s = LocalSample(timestamp: day.addingTimeInterval(Double(minute) * 60))
            s.energyKWh = 4000 + (Double(minute) / 60 * 0.5 * 10).rounded() / 10
            samples.append(s)
        }
        try service.store.insertLocalSamples(samples)
        let buckets = try await service.energy(period: .day, from: day, to: day.addingTimeInterval(86_399))
        let bucket = try #require(buckets.first)
        #expect(abs(bucket.totalKWh - 12) < 0.11)
        #expect(bucket.isEstimate == false)
        #expect(bucket.costNok != nil)
        let hours = try await service.hourlyConsumption(from: day, to: day.addingTimeInterval(86_400))
        #expect(hours.count == 24)
        #expect(hours.allSatisfy { $0.measuredLocally })
        // Without local data the same day is priced from the cloud total and marked an estimate.
        let other = HeatPumpService(
            backend: MockBackend(timeZone: .gmt, now: clock.provider), store: try HistoryStore(path: temporaryDatabasePath()),
            timeZone: .gmt, now: clock.provider)
        _ = try await other.currentState()
        try await other.savePriceSettings(PriceSettings(agreement: .norgespris))
        try other.store.upsertEnergyDays(
            [EnergyDay(day: WireDate.day(day, timeZone: .gmt), totalKWh: 9)], deviceId: MockBackend.deviceId, now: clock.now)
        #expect(try await other.energy(period: .day, from: day, to: day.addingTimeInterval(86_399)).first?.isEstimate == true)
    }

    @Test func partialLocalCoverageKeepsCloudTotal() async throws {
        let service = try makeService()
        _ = try await service.currentState()
        let day = WireDate.calendar(.gmt).startOfDay(for: clock.now.addingTimeInterval(-86_400))
        try service.store.upsertEnergyDays(
            [EnergyDay(day: WireDate.day(day, timeZone: .gmt), totalKWh: 9)], deviceId: MockBackend.deviceId, now: clock.now)
        // Only 06–09 covered.
        try service.store.insertLocalSamples((0...36).map { i in
            var s = LocalSample(timestamp: day.addingTimeInterval(6 * 3600 + Double(i) * 300))
            s.energyKWh = 4000 + Double(i) / 10
            return s
        })
        let bucket = try #require(try await service.energy(period: .day, from: day, to: day.addingTimeInterval(86_399)).first)
        #expect(bucket.totalKWh == 9)
        let hours = try await service.hourlyConsumption(from: day, to: day.addingTimeInterval(86_400))
        #expect(hours.filter(\.measuredLocally).count == 3)
    }

    @Test func historyMetricsFromLocalReadings() async throws {
        let service = try makeService()
        let t0 = clock.now.addingTimeInterval(-600)
        try service.store.insertLocalSamples((0..<10).map { i in
            var s = LocalSample(timestamp: t0.addingTimeInterval(Double(i) * 60))
            s.powerW = 500 + i
            s.compressorHz = 30 + i
            return s
        })
        let power = try await service.history(metric: .powerW, from: t0, to: clock.now)
        #expect(power.map(\.value) == (0..<10).map { Double(500 + $0) })
        #expect(power.allSatisfy { $0.source == "local" })
        let hz = try await service.history(metric: .compressorHz, from: t0, to: clock.now)
        #expect(hz.last?.value == 39)
    }

    @Test func liveSummaryCountsStartsAndPower() async throws {
        let service = try makeService()
        let now = clock.now
        // Readings every minute for 3 h: 10 min on (800 W), 5 min off (4 W) → 4 starts per hour.
        try service.store.insertLocalSamples((0...180).map { i in
            var s = LocalSample(timestamp: now.addingTimeInterval(Double(i - 180) * 60))
            let running = i % 15 >= 5
            s.operating = running
            s.compressorHz = running ? 40 : 0
            s.powerW = running ? 800 : 4
            return s
        })
        let summary = try await service.liveSummary()
        #expect(summary.startsLastHour == 4)
        #expect(summary.startsLast3Hours == 12)
        #expect(summary.startsLast24Hours == 12)
        #expect(summary.powerLast60Minutes?.maxW == 800)
        #expect(summary.powerLast60Minutes?.minW == 4)
        #expect(summary.observedHoursLast24 == 3)
        #expect(summary.live.refreshed == false)  // local access is off: nothing read
    }

    @Test func simulatedAdapterGoesThroughCryptoAndParser() async throws {
        let at = clock.now
        let service = HeatPumpService(
            backend: MockBackend(timeZone: .gmt, now: clock.provider), store: try HistoryStore(path: path), timeZone: .gmt,
            now: clock.provider, local: .simulated(now: { at }))
        try await service.saveLocalSettings(LocalSettings(enabled: true, host: MockLocalSimulation.host))
        let live = try await service.liveStatus(maxAge: 0)
        let sample = try #require(live.sample)
        let expected = MockLocalSimulation.sample(at: at)
        #expect(sample.powerW == expected.powerW)
        #expect(sample.compressorHz == expected.compressorHz)
        #expect(sample.energyKWh == expected.energyKWh)
        #expect(sample.outdoorTemperature == expected.outdoorTemperature)
        #expect(sample.roomTemperature == expected.roomTemperature)
        #expect(sample.mode == .heat && sample.setTemperature == 21)
        #expect(sample.cloudConnected == true)
        // The simulated adapter refuses anything but the status request.
        var request = try LocalSmartClient.statusRequest(host: MockLocalSimulation.host, iv: Array(repeating: 1, count: 16))
        let other = try LocalSmartClient.encrypt(Array("<CSV><CONNECT>OFF</CONNECT></CSV>".utf8), iv: Array(repeating: 1, count: 16))
        request.httpBody = Data(("<ESV>" + Data(Array(repeating: 1, count: 16) + other).base64EncodedString() + "</ESV>").utf8)
        let (_, response) = try await MockLocalTransport(now: { at }).send(request)
        #expect(response.statusCode == 400)
    }

    @Test func simulationIsConsistentWithTheCounter() {
        let start = Date(timeIntervalSince1970: 1_793_872_800)
        let samples = MockLocalSimulation.samples(from: start, to: start.addingTimeInterval(24 * 3600))
        let averageW = Double(samples.compactMap(\.powerW).reduce(0, +)) / Double(samples.count)
        let counterKWh = (samples.last?.energyKWh ?? 0) - (samples.first?.energyKWh ?? 0)
        #expect(abs(averageW * 24 / 1000 - counterKWh) / counterKWh < 0.1)
        let running = samples.filter(\.isRunning).compactMap(\.powerW)
        #expect(running.allSatisfy { (260...1240).contains($0) })
        #expect(samples.filter { !$0.isRunning }.allSatisfy { $0.powerW == 4 })
        #expect(CompressorCycles.starts(in: samples).starts > 20)
    }

    @Test func pruningThinsOldReadings() throws {
        let store = try HistoryStore(path: path)
        let now = clock.now
        let old = now.addingTimeInterval(-100 * 86_400)
        try store.insertLocalSamples((0..<60).map { LocalSample(timestamp: old.addingTimeInterval(Double($0) * 60)) })
        try store.insertLocalSamples((0..<60).map { LocalSample(timestamp: now.addingTimeInterval(Double(-$0) * 60)) })
        let removed = try store.pruneLocalSamples(now: now)
        #expect(removed > 40)
        let remainingOld = try store.localSamples(from: old, to: old.addingTimeInterval(3600))
        #expect((6...7).contains(remainingOld.count))  // one per 10 minutes
        #expect(try store.localSamples(from: now.addingTimeInterval(-3600), to: now).count == 60)
    }

    @Test func arpParserReadsSyntheticMessages() {
        let header = MemoryLayout<rt_msghdr>.size
        var message = [UInt8](repeating: 0, count: header)
        // sockaddr_in (16 bytes): len, family, port, address 192.168.1.42
        message += [16, UInt8(AF_INET), 0, 0, 192, 168, 1, 42] + [UInt8](repeating: 0, count: 8)
        // sockaddr_dl: len 20, family AF_LINK, index, type, nlen 0, alen 6, slen 0, then the address
        message += [20, UInt8(AF_LINK), 0, 0, 6, 0, 6, 0, 0x00, 0x00, 0x5E, 0x00, 0x53, 0x01, 0, 0, 0, 0, 0, 0]
        let length = UInt16(message.count)
        message[0] = UInt8(length & 0xFF)
        message[1] = UInt8(length >> 8)
        let entries = ARPScanner.parseRouteMessages(message + message)
        #expect(entries == Array(repeating: ARPScanner.Entry(ip: "192.168.1.42", mac: "00005e005301"), count: 2))
        #expect(normalizedMAC("00:00:5E:00:53:01") == "00005e005301")
    }
}

@Suite("Local aggregates in SQL")
struct LocalAggregateTests {
    let now = Date(timeIntervalSince1970: 1_793_872_800)

    @Test func bucketsMatchTheReadings() throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        // Two hours, one reading per minute: 10 min on (600 W, 40 Hz), 5 min off (4 W): 4 starts per hour.
        let samples: [LocalSample] = (0..<120).map { i in
            var s = LocalSample(timestamp: now.addingTimeInterval(Double(i) * 60))
            let on = i % 15 >= 5
            s.operating = on
            s.compressorHz = on ? 40 : 0
            s.powerW = on ? 600 : 4
            s.power = true
            s.setRaw(mode: 1, fan: 0, vaneVertical: 0, vaneHorizontal: 0)
            s.roomTemperature = 21
            s.outdoorTemperature = 1
            return s
        }
        try store.insertLocalSamples(samples)
        let hours = try store.localPowerBuckets(from: now, to: now.addingTimeInterval(7200), bucketSeconds: 3600)
        #expect(hours.map(\.starts) == CompressorCycles.startsPerHour(samples, timeZone: .gmt).map(\.starts))
        #expect(hours.map(\.count) == [60, 60])
        let first = try #require(hours.first)
        #expect(first.start == now)
        #expect(abs((first.averageW ?? 0) - (40 * 600 + 20 * 4) / 60.0) < 0.01)
        #expect(first.averageRunningHz == 40)
        #expect(abs(first.runningShare - 40.0 / 60) < 0.001)
        #expect(first.heatingShare == 1)
        #expect(first.averageDelta == 20)
        #expect(first.observedSeconds == 59 * 60)
        #expect(hours[1].observedSeconds == 60 * 60)  // the pair across the boundary counts in the later hour
        let total = try #require(LocalPowerBucket.merged(hours))
        #expect(total.starts == 8)
        #expect(total.runningSeconds == CompressorCycles.runningSeconds(in: samples))
        #expect(total.maxW == 600 && total.minW == 4)
        // One bucket over a custom origin; a reading exactly at `to` lands in the last bucket.
        let one = try store.localPowerBuckets(from: now, to: now.addingTimeInterval(119 * 60), bucketSeconds: 119 * 60, origin: now)
        #expect(one.count == 1 && one.first?.count == 120)
    }

    @Test func counterReadingsAreThinnedButKeepTheNewest() throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        try store.insertLocalSamples((0..<30).map { i in
            var s = LocalSample(timestamp: now.addingTimeInterval(Double(i) * 60))
            s.energyKWh = 100 + Double(i) / 10
            return s
        })
        let readings = try store.localCounterReadings(from: now, to: now.addingTimeInterval(3600))
        #expect(readings.count == 7)  // one per 5 minutes plus the newest
        #expect(readings.first?.kWh == 100)
        #expect(readings.last.map { abs($0.kWh - 102.9) < 1e-9 } == true)
    }
}
