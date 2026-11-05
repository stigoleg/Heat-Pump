import Foundation
import Testing
@testable import HeatPumpKit

@Suite("Price levels and energy per mode")
struct PriceLevelAndModeTests {
    @Test func relativeBandsFollowTibbersDefinition() {
        // Tibber: ≤ 60 % very cheap, ≤ 90 % cheap, < 115 % normal, < 140 % expensive, else very expensive.
        let average = 100.0
        #expect(PriceLevel.relative(price: 60, average: average) == .veryCheap)
        #expect(PriceLevel.relative(price: 61, average: average) == .cheap)
        #expect(PriceLevel.relative(price: 90, average: average) == .cheap)
        #expect(PriceLevel.relative(price: 91, average: average) == .normal)
        #expect(PriceLevel.relative(price: 114.9, average: average) == .normal)
        #expect(PriceLevel.relative(price: 115, average: average) == .expensive)
        #expect(PriceLevel.relative(price: 140, average: average) == .veryExpensive)
        #expect(PriceLevel.relative(price: 50, average: 0) == nil)
        #expect(PriceLevel(tibber: "VERY_EXPENSIVE") == .veryExpensive)
        #expect(PriceLevel(tibber: "something") == nil)
        #expect(PriceLevel.cheap.displayName == "Billig")
    }

    @Test func tibberLevelIsParsedAndStored() throws {
        let prices = try TibberPriceProvider.parse(try Fixture.data("tibber_prices"), timeZone: TimeZone(identifier: "Europe/Oslo")!)
        let midnight = try #require(prices.first { $0.hour == Date(timeIntervalSince1970: 1_793_833_200) })  // 2026-11-05 00:00 +01
        #expect(midnight.level == "CHEAP")
        #expect(prices.first { $0.level == "VERY_EXPENSIVE" } != nil)
        let store = try HistoryStore(path: temporaryDatabasePath())
        try store.upsertPrices(prices)
        let back = try store.prices(source: "tibber", area: "tibber", from: .distantPast, to: .distantFuture)
        #expect(back.first { $0.hour == midnight.hour }?.level == "CHEAP")
    }

    func service(clock: TestClock, store: HistoryStore) -> HeatPumpService {
        HeatPumpService(
            backend: MockBackend(timeZone: .gmt, now: clock.provider), store: store, timeZone: .gmt, now: clock.provider,
            sleep: clock.sleeper, priceProvider: { _ in MockPriceProvider() })
    }

    @Test func otherSourcesGetLevelsAgainstTheTrailing72Hours() async throws {
        let clock = TestClock()
        let store = try HistoryStore(path: temporaryDatabasePath())
        let now = clock.now
        // 72 hours at 100 øre, then one hour at 50 and one at 150 (hvakosterstrommen NO1).
        var prices = (1...72).map { h in
            HourPrice(hour: now.addingTimeInterval(-Double(h) * 3600), area: "NO1", source: "hvakosterstrommen", spotOre: 80, totalOre: 100)
        }
        prices.append(HourPrice(hour: now, area: "NO1", source: "hvakosterstrommen", spotOre: 40, totalOre: 50))
        prices.append(HourPrice(hour: now.addingTimeInterval(3600), area: "NO1", source: "hvakosterstrommen", spotOre: 120, totalOre: 150))
        try store.upsertPrices(prices)
        // Not the demo backend, so prices come from the hvakosterstrommen rows above.
        let real = HeatPumpService(
            backend: CountingBackend(now: clock.provider), store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        try await real.savePriceSettings(PriceSettings(agreement: .spot, area: .no1))
        let hours = try await real.priceBreakdowns(from: now, to: now.addingTimeInterval(7200))
        #expect(hours.map(\.level) == [.veryCheap, .veryExpensive])
        #expect(hours.allSatisfy { $0.levelFromTibber == false })
        // Without 48 hours of history before it, no level is guessed.
        let early = try await real.priceBreakdowns(from: now.addingTimeInterval(-70 * 3600), to: now.addingTimeInterval(-69 * 3600))
        #expect(early.first?.level == nil)
    }

    @Test func norgesprisHasNoLevel() async throws {
        let clock = TestClock()
        let service = service(clock: clock, store: try HistoryStore(path: temporaryDatabasePath()))
        let hours = try await service.priceBreakdowns(from: clock.now, to: clock.now.addingTimeInterval(3600))
        #expect(hours.count == 1)
        #expect(hours.first?.level == nil)
    }

    @Test func energyReportKeepsEveryMode() throws {
        let start = Date(timeIntervalSince1970: 1_793_664_000)  // 2026-11-03
        let end = start.addingTimeInterval(2 * 86_400)
        let days = MELCloudClassicParser.energy(try Fixture.json("energy_report"), range: DateInterval(start: start, end: end), timeZone: .gmt)
        let first = try #require(days.first)
        #expect(first.heatingKWh == 8.5)
        #expect(first.autoKWh == 0.2)
        #expect(first.fanKWh == 0.1)
        #expect(first.dryKWh == 0)
        #expect(first.otherKWh == 0)
        let store = try HistoryStore(path: temporaryDatabasePath())
        try store.upsertEnergyDays(days, deviceId: 1, now: end)
        let back = try store.energyDays(deviceId: 1, fromDay: "2026-11-01", toDay: "2026-11-30")
        #expect(back.first?.autoKWh == 0.2)
        #expect(back.first?.fanKWh == 0.1)
    }

    @Test func bucketsCarryTheModeSplit() async throws {
        let clock = TestClock()
        let store = try HistoryStore(path: temporaryDatabasePath())
        try store.insertSnapshot(makeState(at: clock.now))
        try store.upsertEnergyDays(
            [
                EnergyDay(day: "2026-11-03", totalKWh: 10, heatingKWh: 9, coolingKWh: 0, autoKWh: 0.5, dryKWh: 0, fanKWh: 0.5, otherKWh: 0),
                EnergyDay(day: "2026-11-04", totalKWh: 5, heatingKWh: 5, coolingKWh: 0),
            ], deviceId: 1, now: clock.now)
        let service = HeatPumpService(
            backend: CountingBackend(now: clock.provider), store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        let buckets = try await service.energy(
            period: .week, from: Date(timeIntervalSince1970: 1_793_664_000), to: clock.now)
        let modes = try #require(buckets.first?.modes)
        #expect(modes.heatingKWh == 14)
        #expect(modes.autoKWh == 0.5)
        #expect(modes.fanKWh == 0.5)
        #expect(modes.shares.first?.mode == .heat)
    }
}
