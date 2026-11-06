import Foundation
import Synchronization
import Testing
@testable import HeatPumpKit
@testable import DemoIntegration
@testable import TibberIntegration

/// Records the `last:` argument of each request and answers with fixed hours.
final class FakeHouseProvider: HouseConsumptionProviding {
    let requests = Mutex<[Int]>([])
    let hours: [HouseHour]
    init(hours: [HouseHour]) { self.hours = hours }
    func fetchConsumption(lastHours: Int) async throws -> [HouseHour] {
        requests.withLock { $0.append(lastHours) }
        return hours
    }
}

@Suite("House consumption from Tibber and the heat pump's share")
struct HouseConsumptionTests {
    let clock = TestClock()

    @Test func parsesTibberConsumptionAndSkipsUnfinishedHours() throws {
        let hours = try TibberConsumptionProvider.parse(try Fixture.data("tibber_consumption"))
        #expect(hours.count == 2)
        #expect(hours[0].hour == Date(timeIntervalSince1970: 1_793_862_000))  // 2026-11-05T07:00Z
        #expect(hours[0].kWh == 2.0)
        #expect(hours[0].costNok == 2.4)
        #expect(hours[0].unitPriceOre == 120)
    }

    @Test func queryAndHeaders() async throws {
        #expect(TibberConsumptionProvider.query(lastHours: 5000).contains("consumption(resolution: HOURLY, last: 744)"))
        let transport = StubTransport()
        transport.enqueue("gql", body: try Fixture.data("tibber_consumption"))
        let provider = TibberConsumptionProvider(token: "TOKEN", transport: transport)
        _ = try await provider.fetchConsumption(lastHours: 10)
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Varmepumpe") == true)
        let body = try JSONValue.parse(try #require(request.httpBody))
        #expect(body["query"]?.string?.contains("last: 10") == true)
    }

    func makeService(store: HistoryStore, provider: (any HouseConsumptionProviding)?) -> HeatPumpService {
        HeatPumpService(
            backend: CountingBackend(now: clock.provider), store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper,
            houseProvider: { provider })
    }

    @Test func backfillsOnceThenFetchesOnlyNewHoursAtMostHourly() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let latest = clock.now.addingTimeInterval(-2 * 3600)
        let fake = FakeHouseProvider(hours: [HouseHour(hour: latest, kWh: 1.2, costNok: 1.5, unitPriceOre: 125)])
        let service = makeService(store: store, provider: fake)
        #expect(try await service.syncHouseConsumption().status == .fetched)
        #expect(fake.requests.withLock { $0 } == [744])
        #expect(try await service.syncHouseConsumption().status == .skipped)
        clock.advance(3600)
        _ = try await service.syncHouseConsumption()
        // Latest stored hour began 3 h ago → ask for the last 3 + 2 hours.
        #expect(fake.requests.withLock { $0 } == [744, 5])
        #expect(try await service.houseHours(from: .distantPast, to: .distantFuture).count == 1)
    }

    @Test func withoutATokenNothingIsFetched() async throws {
        let service = makeService(store: try HistoryStore(path: temporaryDatabasePath()), provider: nil)
        #expect(try await service.syncHouseConsumption().status == .notConfigured)
    }

    @Test func shareOfTheHouse() throws {
        let day = Date(timeIntervalSince1970: 1_793_836_800)  // 2026-11-05T00:00Z
        var house: [Date: HouseHour] = [:]
        var pump: [Date: HourCost] = [:]
        for h in 0..<24 {
            let hour = day.addingTimeInterval(Double(h) * 3600)
            house[hour] = HouseHour(hour: hour, kWh: 2, costNok: 2, unitPriceOre: 100)
            if h < 22 { pump[hour] = HourCost(hour: hour, kWh: 0.5, cost: nil, measuredLocally: true) }
        }
        let summary = HouseShare.summarize(house: house, heatPump: pump, timeZone: .gmt)
        #expect(summary.hours.count == 24)
        #expect(summary.hours.first?.share == 0.25)
        let d = try #require(summary.days.first)
        #expect(d.houseKWh == 48)
        #expect(d.heatPumpKWh == 11)
        #expect(d.hoursWithBoth == 22)
        #expect(d.share.map { abs($0 - 11.0 / 44.0) < 1e-9 } == true)  // only hours with both
        #expect(d.heatPumpMeasured == true)
        #expect(d.houseCostNok == 48)
        // Too few hours with both: no share for the day.
        let sparse = HouseShare.summarize(house: house, heatPump: pump.filter { $0.key < day.addingTimeInterval(10 * 3600) }, timeZone: .gmt)
        #expect(sparse.days.first?.share == nil)
    }

    @Test func serviceShareUsesTheHeatPumpsHourlyUse() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        try store.insertSnapshot(makeState(at: clock.now))
        let yesterday = WireDate.calendar(.gmt).startOfDay(for: clock.now).addingTimeInterval(-86_400)
        try store.upsertHouseHours(
            (0..<24).map { HouseHour(hour: yesterday.addingTimeInterval(Double($0) * 3600), kWh: 2, costNok: 2.5, unitPriceOre: 125) })
        // Local counter readings every 5 minutes, 0.1 kWh per 12 minutes = 0.5 kWh per hour.
        var samples: [LocalSample] = []
        for m in stride(from: -5, to: 24 * 60 + 5, by: 5) {
            var s = LocalSample(timestamp: yesterday.addingTimeInterval(Double(m) * 60))
            s.energyKWh = ((100 + Double(m) / 120) * 10).rounded(.down) / 10  // 0.1 kWh steps like the real counter
            samples.append(s)
        }
        try store.insertLocalSamples(samples)
        let service = makeService(store: store, provider: nil)
        let summary = try await service.houseShare(from: yesterday, to: yesterday.addingTimeInterval(86_400))
        let day = try #require(summary.days.first)
        #expect(day.hoursWithBoth == 24)
        #expect(abs((day.share ?? 0) - 0.25) < 0.02)
        #expect(day.heatPumpMeasured)
        #expect(summary.yesterday?.day == day.day)
    }
}
