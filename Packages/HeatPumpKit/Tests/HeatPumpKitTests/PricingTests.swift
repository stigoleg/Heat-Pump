import Foundation
import Testing
@testable import HeatPumpKit
@testable import DemoIntegration

@Suite("Electricity prices and cost")
struct PricingTests {
    let oslo = TimeZone(identifier: "Europe/Oslo")!

    func date(_ s: String) -> Date { WireDate.parse(s, timeZone: oslo)! }

    @Test func hvaKosterStrommenAddsVatExceptNO4() throws {
        let data = try Fixture.data("hvakosterstrommen_NO1")
        let no1 = try HvaKosterStrommenProvider.parse(data, area: .no1, timeZone: oslo)
        #expect(no1.count == 24)
        #expect(no1[0].hour == date("2026-11-04T00:00:00"))
        #expect(abs(no1[0].spotOre - 182.509) < 0.001)
        #expect(abs(no1[0].totalOre - 182.509 * 1.25) < 0.001)
        let no4 = try HvaKosterStrommenProvider.parse(data, area: .no4, timeZone: oslo)
        #expect(no4[0].totalOre == no4[0].spotOre)
    }

    @Test func quarterHourPricesAreAveragedPerHour() throws {
        let json = """
            [{"NOK_per_kWh":1.0,"time_start":"2026-11-04T00:00:00+01:00"},{"NOK_per_kWh":2.0,"time_start":"2026-11-04T00:15:00+01:00"},
             {"NOK_per_kWh":3.0,"time_start":"2026-11-04T00:30:00+01:00"},{"NOK_per_kWh":2.0,"time_start":"2026-11-04T00:45:00+01:00"},
             {"NOK_per_kWh":1.0,"time_start":"2026-11-04T01:00:00+01:00"}]
            """
        let prices = try HvaKosterStrommenProvider.parse(Data(json.utf8), area: .no1, timeZone: oslo)
        #expect(prices.count == 2)
        #expect(prices[0].spotOre == 200)
        #expect(prices[1].spotOre == 100)
    }

    @Test func tibberTotalIncludesVatAndOverlapIsDeduplicated() throws {
        let prices = try TibberPriceProvider.parse(try Fixture.data("tibber_prices"), timeZone: oslo)
        #expect(prices.map(\.hour) == [
            date("2026-11-04T23:00:00"), date("2026-11-05T00:00:00"), date("2026-11-05T01:00:00"), date("2026-11-06T00:00:00"),
        ])
        #expect(prices[1].totalOre == 100)
        #expect(abs(prices[1].spotOre - 78) < 0.0001)
        #expect(prices.allSatisfy { $0.area == "tibber" && $0.source == "tibber" })
    }

    @Test func tibberErrorsAndQuery() throws {
        let unauthorized = #"{"errors":[{"message":"Context creation failed: invalid token"}]}"#
        #expect(throws: PriceError.unauthorized) { try TibberPriceProvider.parse(Data(unauthorized.utf8), timeZone: oslo) }
        let query = TibberPriceProvider.query(rangeHours: 48)
        #expect(query.contains("priceInfo(resolution: HOURLY)"))
        #expect(query.contains("priceInfoRange(resolution: HOURLY, last: 48)"))
        #expect(!TibberPriceProvider.query(rangeHours: 0).contains("priceInfoRange"))
        #expect(TibberPriceProvider.query(rangeHours: 5000).contains("last: 744"))
    }

    @Test func tibberRequestCarriesBearerToken() async throws {
        let transport = StubTransport()
        transport.enqueue("/v1-beta/gql", body: try Fixture.data("tibber_prices"))
        let provider = TibberPriceProvider(token: "test-token", transport: transport, now: { self.date("2026-11-05T12:00:00") })
        let prices = try await provider.fetchPrices(
            days: [date("2026-11-04T00:00:00"), date("2026-11-05T00:00:00")], timeZone: oslo)
        #expect(prices.count == 3)
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        let body = try JSONValue.parse(try #require(request.httpBody))
        #expect(body["query"]?.string?.contains("priceInfoRange") == true)
    }

    @Test func hvaKosterStrommenKeepsDaysFetchedBeforeAFailure() async throws {
        let transport = StubTransport()
        transport.enqueue("11-04_NO1.json", body: try Fixture.data("hvakosterstrommen_NO1"))
        transport.enqueue("11-03_NO1.json", status: 500, body: Data())
        let provider = HvaKosterStrommenProvider(area: .no1, transport: transport)
        let prices = try await provider.fetchPrices(
            days: [date("2026-11-04T00:00:00"), date("2026-11-03T00:00:00"), date("2026-11-02T00:00:00")], timeZone: oslo)
        #expect(prices.count == 24)
        #expect(transport.requests.count == 2)  // stops after the failure
        let failing = StubTransport()
        failing.enqueue("11-04_NO1.json", status: 500, body: Data())
        await #expect(throws: PriceError.http(status: 500)) {
            _ = try await HvaKosterStrommenProvider(area: .no1, transport: failing).fetchPrices(days: [date("2026-11-04T00:00:00")], timeZone: oslo)
        }
    }

    @Test func rawDeviceIsOnlyReplacedByNewer() throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let t = date("2026-11-05T12:00:00")
        try store.saveRawDevice(RawDevice(deviceId: 1, fetchedAt: t, json: .object(["SetTemperature": .number(23)])))
        try store.saveRawDevice(RawDevice(deviceId: 1, fetchedAt: t.addingTimeInterval(-5), json: .object(["SetTemperature": .number(21)])))
        #expect(try store.rawDevice(deviceId: 1)?.json["SetTemperature"] == .number(23))
        try store.saveRawDevice(RawDevice(deviceId: 1, fetchedAt: t.addingTimeInterval(5), json: .object(["SetTemperature": .number(22)])))
        #expect(try store.rawDevice(deviceId: 1)?.json["SetTemperature"] == .number(22))
    }

    @Test func stromstotteAboveThreshold() {
        // 177 øre excl. VAT: 90 % of 100 øre above 77, plus 25 % VAT.
        #expect(abs(Stromstotte.support(spotOreExVat: 177, vatFactor: 1.25) - 112.5) < 0.0001)
        #expect(Stromstotte.support(spotOreExVat: 60, vatFactor: 1.25) == 0)
        #expect(abs(Stromstotte.support(spotOreExVat: 177, vatFactor: 1) - 90) < 0.0001)
    }

    @Test func gridTariffDayNightWeekendHoliday() {
        #expect(PriceCalculator.isGridDayRate(date("2026-11-05T06:00:00"), timeZone: oslo))  // Thursday
        #expect(!PriceCalculator.isGridDayRate(date("2026-11-05T05:00:00"), timeZone: oslo))
        #expect(!PriceCalculator.isGridDayRate(date("2026-11-05T22:00:00"), timeZone: oslo))
        #expect(!PriceCalculator.isGridDayRate(date("2026-11-07T12:00:00"), timeZone: oslo))  // Saturday
        #expect(!PriceCalculator.isGridDayRate(date("2026-12-25T12:00:00"), timeZone: oslo))  // Christmas, Friday
        #expect(!PriceCalculator.isGridDayRate(date("2026-05-14T12:00:00"), timeZone: oslo))  // Ascension Day 2026
        #expect(!PriceCalculator.isGridDayRate(date("2026-04-02T12:00:00"), timeZone: oslo))  // Maundy Thursday
        #expect(PriceCalculator.isGridDayRate(date("2026-04-07T12:00:00"), timeZone: oslo))  // Tuesday after Easter
    }

    @Test func breakdownPerAgreement() throws {
        let hour = date("2026-11-05T08:00:00")
        let spot = HourPrice(hour: hour, area: "NO1", source: "hvakosterstrommen", spotOre: 177, totalOre: 221.25)
        let norges = try #require(PriceCalculator.breakdown(hour: hour, settings: PriceSettings(), spot: nil, timeZone: oslo))
        #expect(norges.energyOre == 50 && norges.gridOre == 46.4 && norges.supportOre == 0)
        let spotSettings = PriceSettings(agreement: .spot, markupOre: 5)
        let b = try #require(PriceCalculator.breakdown(hour: hour, settings: spotSettings, spot: spot, timeZone: oslo))
        #expect(b.energyOre == 226.25)
        #expect(abs(b.supportOre + 112.5) < 0.0001)
        #expect(abs(b.totalOre - (226.25 + 46.4 - 112.5)) < 0.0001)
        #expect(PriceCalculator.breakdown(hour: hour, settings: spotSettings, spot: nil, timeZone: oslo) == nil)
    }

    @Test func counterDeltasAreSpreadOverHours() {
        let t0 = date("2026-11-05T10:30:00")
        let samples = [(at: t0, kWh: 100.0), (at: t0.addingTimeInterval(3600), kWh: 101.0),
                       (at: t0.addingTimeInterval(5 * 3600), kWh: 105.0), (at: t0.addingTimeInterval(5.5 * 3600), kWh: 99.0)]
        let hourly = CounterSampler.hourly(samples, timeZone: oslo)
        #expect(hourly[date("2026-11-05T10:00:00")] == 0.5)
        #expect(hourly[date("2026-11-05T11:00:00")] == 0.5)
        // 4 h gap > 3 h: skipped; decrease (reset): skipped.
        #expect(hourly.count == 2)
        #expect(CounterSampler.averagePowerW(Array(samples.prefix(2)), now: t0.addingTimeInterval(3600)) == 1000)
    }

    @Test func dayCostMeasuredVersusEstimate() throws {
        let hours = (0..<24).map { date("2026-11-05T00:00:00").addingTimeInterval(Double($0) * 3600) }
        let prices = hours.map { PriceBreakdown(hour: $0, energyOre: $0 == hours[8] ? 300 : 100, gridOre: 0, supportOre: 0, isDayRate: false) }
        // All 2 kWh measured in the expensive hour.
        let measured = try #require(PriceCalculator.dayCost(dayKWh: 2, hourly: [HourCost(hour: hours[8], kWh: 2)], prices: prices))
        #expect(abs(measured.cost.totalNok - 6) < 0.0001)
        #expect(!measured.isEstimate)
        // Nothing measured: 2 kWh at the day's average price.
        let estimate = try #require(PriceCalculator.dayCost(dayKWh: 2, hourly: [], prices: prices))
        #expect(abs(estimate.cost.totalNok - 2 * (100 * 23 + 300) / 24 / 100) < 0.0001)
        #expect(estimate.isEstimate)
        #expect(PriceCalculator.dayCost(dayKWh: 2, hourly: [], prices: []) == nil)
    }
}

/// Counts fetches; returns a flat price for every hour of the requested days.
final class StubPriceProvider: PriceProvider, @unchecked Sendable {
    let source = "hvakosterstrommen"
    let area = "NO1"
    let fetchesRangesInOneRequest = false
    private let lock = NSLock()
    private var _requests: [[Date]] = []
    var requests: [[Date]] { lock.withLock { _requests } }

    func fetchPrices(days: [Date], timeZone: TimeZone) async throws -> [HourPrice] {
        lock.withLock { _requests.append(days) }
        let calendar = WireDate.calendar(timeZone)
        return days.flatMap { day in
            (0..<24).compactMap { calendar.date(byAdding: .hour, value: $0, to: calendar.startOfDay(for: day)) }
                .map { HourPrice(hour: $0, area: area, source: source, spotOre: 100, totalOre: 125) }
        }
    }
}

@Suite("Price sync and cost in the service")
struct PriceServiceTests {

    private func makeService(clock: TestClock, provider: StubPriceProvider) throws -> HeatPumpService {
        let store = try HistoryStore(path: temporaryDatabasePath())
        // A real (non-mock) backend identifier so the provider's source/area are used.
        return HeatPumpService(
            backend: CountingBackend(now: clock.provider), store: store, timeZone: .gmt, now: clock.provider,
            priceProvider: { _ in provider })
    }

    @Test func norgesprisNeedsNoFetch() async throws {
        let clock = TestClock()
        let provider = StubPriceProvider()
        let service = try makeService(clock: clock, provider: provider)
        #expect(try await service.syncPrices().status == .notNeeded)
        #expect(provider.requests.isEmpty)
        let today = try await service.prices(day: clock.now)
        #expect(today.count == 24)
        #expect(today.allSatisfy { $0.energyOre == 50 })
    }

    @Test func spotSyncIsHourlyAndTomorrowOnlyAfter1330() async throws {
        let clock = TestClock()  // 10:00 UTC
        let provider = StubPriceProvider()
        let service = try makeService(clock: clock, provider: provider)
        try await service.savePriceSettings(PriceSettings(agreement: .spot, area: .no1))
        let first = try await service.syncPrices()
        #expect(first.status == .fetched)
        let requested = try #require(provider.requests.first)
        #expect(requested.count == 10)  // capped per run, newest first
        #expect(requested.first == WireDate.calendar(.gmt).startOfDay(for: clock.now))
        // Within the hour: skipped, no request.
        clock.advance(600)
        #expect(try await service.syncPrices().status == .skipped)
        #expect(provider.requests.count == 1)
        // After 13:30: tomorrow is included.
        clock.advance(3.6 * 3600)
        _ = try await service.syncPrices()
        let tomorrow = WireDate.calendar(.gmt).date(byAdding: .day, value: 1, to: WireDate.calendar(.gmt).startOfDay(for: clock.now))
        #expect(provider.requests.last?.first == tomorrow)
    }

    @Test func counterSamplesUseTheirReadingTime() async throws {
        let clock = TestClock()
        let store = try HistoryStore(path: temporaryDatabasePath())
        let service = HeatPumpService(backend: CountingBackend(now: clock.provider), store: store, timeZone: .gmt, now: clock.provider)
        let listedAt = clock.now
        // Three snapshots 10 min apart that all carry the same cached listing reading,
        // then a new listing 30 min later with +0.5 kWh.
        for i in 0..<3 {
            var s = makeState(at: clock.now.addingTimeInterval(Double(i) * 600))
            s.energy = EnergyCounters(currentConsumedKWh: 100, counterAt: listedAt)
            try store.insertSnapshot(s)
        }
        var later = makeState(at: clock.now.addingTimeInterval(1800))
        later.energy = EnergyCounters(currentConsumedKWh: 100.5, counterAt: clock.now.addingTimeInterval(1800))
        try store.insertSnapshot(later)
        let samples = try await service.counterSamples(from: clock.now.addingTimeInterval(-60), to: clock.now.addingTimeInterval(3600))
        #expect(samples.map(\.at) == [listedAt, listedAt.addingTimeInterval(1800)])
        // 0.5 kWh over 30 min = 1 kW, not 0.5 kWh squeezed into the last 10 min.
        let watts = CounterSampler.averagePowerW(samples, now: listedAt.addingTimeInterval(1800))
        #expect(watts == 1000)
    }

    @Test func energyBucketsCarryCost() async throws {
        let clock = TestClock()
        let provider = StubPriceProvider()
        let service = try makeService(clock: clock, provider: provider)
        _ = try await service.currentState()
        let day = WireDate.day(clock.now.addingTimeInterval(-86_400), timeZone: .gmt)
        try service.store.upsertEnergyDays([EnergyDay(day: day, totalKWh: 10, heatingKWh: 10, coolingKWh: 0)], deviceId: MockBackend.deviceId, now: clock.now)
        let buckets = try await service.energy(period: .day, from: clock.now.addingTimeInterval(-2 * 86_400), to: clock.now)
        let bucket = try #require(buckets.first { $0.period == day })
        // Norgespris 50 øre + grid (mix of 46,40 day / 31,40 night) for 10 kWh, priced at the day's average.
        let cost = try #require(bucket.cost)
        #expect(cost.energyNok == 5)
        #expect(cost.gridNok > 3.1 && cost.gridNok < 4.7)
        #expect(bucket.isEstimate)
        #expect(bucket.costNok == ((cost.totalNok) * 100).rounded() / 100)
    }
}
