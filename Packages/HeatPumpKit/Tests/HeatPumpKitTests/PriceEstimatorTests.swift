import Foundation
import GRDB
import Testing
@testable import HeatPumpKit
@testable import DemoIntegration

@Suite("Price estimate and the multi-day outlook")
struct PriceEstimatorTests {
    let clock = TestClock()  // Thursday 2026-11-05 10:00 UTC
    let calendar = WireDate.calendar(.gmt)
    var today: Date { calendar.startOfDay(for: clock.now) }

    /// Weekday shape with mean 1: low at night, peak at 18.
    static func weekdayShape(_ hour: Int) -> Double { 1 + 0.4 * cos(2 * .pi * Double(hour - 18) / 24) }
    static func weekendShape(_ hour: Int) -> Double { 1 + 0.1 * cos(2 * .pi * Double(hour - 18) / 24) }

    /// `days` complete days before today; `level(dayOffset)` is the day's mean (offset −1 = yesterday).
    func history(days: Int, noise: Bool = false, level: (Int) -> Double) -> [HourPrice] {
        (1...days).flatMap { back -> [HourPrice] in
            let day = today.addingTimeInterval(-Double(back) * 86_400)
            let weekend = calendar.isDateInWeekend(day)
            return (0..<24).map { h in
                let shape = weekend ? Self.weekendShape(h) : Self.weekdayShape(h)
                let wobble = noise ? 6 * sin(Double(h * back)) : 0
                let spot = level(-back) * shape + wobble
                return HourPrice(
                    hour: day.addingTimeInterval(Double(h) * 3600), area: "NO1", source: "hvakosterstrommen", spotOre: spot,
                    totalOre: spot * 1.25)
            }
        }
    }

    func estimate(_ history: [HourPrice], temperatures: [Date: Double] = [:]) -> SpotEstimateResult? {
        let from = today.addingTimeInterval(86_400)  // tomorrow (Friday)
        return PriceEstimator.estimate(
            history: history, dayTemperatures: temperatures, from: from, to: from.addingTimeInterval(3 * 86_400), timeZone: .gmt)
    }

    @Test func usesTheHourProfileAndTheLastWeeksLevel() throws {
        // 21 days at 100 øre, then the last 7 days at 150 øre.
        let result = try #require(estimate(history(days: 28) { $0 >= -7 ? 150 : 100 }))
        #expect(result.basisDays == 28)
        #expect(result.temperatureSlope == nil)
        let friday = today.addingTimeInterval(86_400)
        let fridayPeak = try #require(result.hours.first { $0.hour == friday.addingTimeInterval(18 * 3600) })
        #expect(abs(fridayPeak.median - 150 * 1.4) < 1e-6)
        let fridayNight = try #require(result.hours.first { $0.hour == friday.addingTimeInterval(6 * 3600) })
        #expect(abs(fridayNight.median - 150 * Self.weekdayShape(6)) < 1e-6)
        // Saturday follows the flatter weekend shape.
        let saturdayPeak = try #require(result.hours.first { $0.hour == friday.addingTimeInterval((24 + 18) * 3600) })
        #expect(abs(saturdayPeak.median - 150 * 1.1) < 1e-6)
        #expect(result.hours.count == 72)
    }

    @Test func temperatureEffectIsUsedWhenPricesFollowTheTemperature() throws {
        // Daily level = 100 − 5 × mean temperature; temperatures swing between −5 and +5 °C.
        func temperature(_ offset: Int) -> Double { 5 * sin(Double(offset) * 0.7) }
        var temperatures: [Date: Double] = [:]
        for back in 1...30 { temperatures[today.addingTimeInterval(-Double(back) * 86_400)] = temperature(-back) }
        let friday = today.addingTimeInterval(86_400)
        temperatures[friday] = -10
        let result = try #require(estimate(history(days: 30) { 100 - 5 * temperature($0) }, temperatures: temperatures))
        #expect(abs((result.temperatureSlope ?? 0) + 5) < 1e-6)
        #expect(abs((result.correlation ?? 0) + 1) < 1e-6)
        // Mean of Friday's hours = 100 − 5 × (−10) = 150.
        let fridayHours = result.hours.filter { calendar.isDate($0.hour, inSameDayAs: friday) }
        let mean = fridayHours.reduce(0) { $0 + $1.median } / Double(fridayHours.count)
        #expect(abs(mean - 150) < 1e-6)
    }

    @Test func temperatureEffectIsSkippedWithoutACorrelation() throws {
        // Level alternates 90/110 regardless of the steadily rising temperature.
        var temperatures: [Date: Double] = [:]
        for back in 1...30 { temperatures[today.addingTimeInterval(-Double(back) * 86_400)] = Double(-back) }
        temperatures[today.addingTimeInterval(86_400)] = -20
        let result = try #require(estimate(history(days: 30) { $0.isMultiple(of: 2) ? 90 : 110 }, temperatures: temperatures))
        #expect(abs(result.correlation ?? 1) < 0.4)
        #expect(result.temperatureSlope == nil)
        let friday = today.addingTimeInterval(86_400)
        let fridayHours = result.hours.filter { calendar.isDate($0.hour, inSameDayAs: friday) }
        let mean = fridayHours.reduce(0) { $0 + $1.median } / Double(fridayHours.count)
        #expect(abs(mean - 100) < 3)  // the last 7 days' level, not moved by the cold forecast
    }

    @Test func bandIsOrderedAndHasWidthWithNoisyPrices() throws {
        let result = try #require(estimate(history(days: 28, noise: true) { 80 + 20 * sin(Double($0)) }))
        #expect(result.hours.allSatisfy { $0.low <= $0.median && $0.median <= $0.high })
        #expect(result.hours.contains { $0.high - $0.low > 1 })
    }

    @Test func noEstimateWithFewerThanFourteenDays() {
        #expect(estimate(history(days: 13) { _ in 100 }) == nil)
        // Incomplete days do not count.
        let gappy = history(days: 20) { _ in 100 }.filter { calendar.component(.hour, from: $0.hour) < 12 }
        #expect(estimate(gappy) == nil)
    }

    @Test func quantilesInterpolate() {
        #expect(PriceEstimator.quantile([4, 1, 3, 2], 0.5) == 2.5)
        #expect(PriceEstimator.quantile([1, 2, 3, 4, 5], 0.25) == 2)
        #expect(PriceEstimator.quantile([7], 0.75) == 7)
    }

    // MARK: Service

    func makeService(store: HistoryStore) -> HeatPumpService {
        HeatPumpService(backend: CountingBackend(now: clock.provider), store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
    }

    @Test func outlookAddsTheEstimateAfterTheLastPublishedHourInFullPrice() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let service = makeService(store: store)
        try await service.savePriceSettings(PriceSettings(agreement: .spot, area: .no1))
        // 20 past days plus today's prices.
        var prices = history(days: 20) { _ in 100 }
        prices += (0..<24).map { h in
            HourPrice(
                hour: today.addingTimeInterval(Double(h) * 3600), area: "NO1", source: "hvakosterstrommen",
                spotOre: 100 * Self.weekdayShape(h), totalOre: 125 * Self.weekdayShape(h))
        }
        try store.upsertPrices(prices)
        let outlook = try await service.priceOutlook()
        #expect(outlook.known.first?.hour == clock.now)
        #expect(outlook.known.last?.hour == today.addingTimeInterval(23 * 3600))
        let first = try #require(outlook.estimate.first)
        #expect(first.hour == today.addingTimeInterval(86_400))
        #expect(outlook.estimate.last?.hour == today.addingTimeInterval(8 * 86_400 - 3600))
        #expect(outlook.basisDays == 21)  // today counts: it is complete
        // Friday 00:00: spot 100 × weekday shape (1 at midnight), × 1.25 VAT, plus the night grid
        // rate, minus strømstøtte (90 % above 77 øre excl. VAT).
        let expected = 100 * 1.25 + GridTariff.elvia2026.nightOre - 0.9 * (100 - 77) * 1.25
        #expect(abs(first.totalOre - expected) < 1e-6)
        #expect(outlook.estimate.allSatisfy { $0.lowOre <= $0.totalOre && $0.totalOre <= $0.highOre })
    }

    @Test func norgesprisHasEveryHourKnownAndNoEstimate() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let service = makeService(store: store)
        let outlook = try await service.priceOutlook()
        #expect(outlook.agreement == .norgespris)
        #expect(outlook.estimate.isEmpty)
        #expect(outlook.known.count == 14 + 7 * 24)  // 10:00 today to the end of day 7
        #expect(outlook.known.allSatisfy { $0.energyOre == 50 })
    }

    @Test func spotWithoutEnoughHistorySaysWhy() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let service = makeService(store: store)
        try await service.savePriceSettings(PriceSettings(agreement: .spot, area: .no1))
        try store.upsertPrices(history(days: 5) { _ in 100 })
        let outlook = try await service.priceOutlook()
        #expect(outlook.estimate.isEmpty)
        #expect(outlook.estimateMissing?.contains("14 days") == true)
    }

    @Test func dailyOutlookUsesTheDegreeDayModelForEachForecastDay() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        try store.insertSnapshot(makeState(at: clock.now))
        var days: [EnergyDay] = []
        for i in 1...14 {
            let day = today.addingTimeInterval(-Double(i) * 86_400)
            let mean = -2 + Double(i % 14)
            try store.upsertTemperaturePoints(
                (0..<24).map { TemperaturePoint(timestamp: day.addingTimeInterval(Double($0) * 3600), room: 21, set: 21, outdoor: mean) },
                device: testDevice)
            days.append(EnergyDay(day: WireDate.day(day, timeZone: .gmt), totalKWh: 0.42 * (17 - mean), heatingKWh: 0.42 * (17 - mean)))
        }
        try store.upsertEnergyDays(days, device: testDevice, now: clock.now)
        // Three hourly days at −3 °C, then one day with MET's 6-hourly entries at 7 °C.
        let tomorrow = today.addingTimeInterval(86_400)
        var forecast = (0..<72).map { ForecastHour(time: tomorrow.addingTimeInterval(Double($0) * 3600), temperature: -3) }
        forecast += [0, 6, 12, 18].map { ForecastHour(time: tomorrow.addingTimeInterval(Double(72 + $0) * 3600), temperature: 7) }
        try store.replaceForecast(forecast, fetchedAt: clock.now)
        let service = makeService(store: store)
        let outlook = try await service.dailyOutlook()
        #expect(outlook.count == 4)
        #expect(outlook.first?.day == WireDate.day(tomorrow, timeZone: .gmt))
        #expect(outlook.first?.kWh == 8.4)
        #expect(outlook.last?.kWh == 4.2)  // 0.42 × (17 − 7)
        #expect(outlook.last?.meanOutdoor == 7)
        // Norgespris: every hour has a known price, nothing estimated.
        #expect(outlook.allSatisfy { $0.costNok != nil && $0.knownPriceHours == 24 && !$0.usesEstimatedPrices })
        // The first day matches the single-day estimate.
        let single = try #require(try await service.tomorrowEstimate())
        #expect(outlook.first?.costNok == single.costNok)
    }

    @Test func forecastKeepsSixHourPrecipitation() throws {
        let hours = try METForecastProvider.parse(try Fixture.data("met_compact"))
        #expect(hours.first?.precipitation6h == 0)
        // Beyond the hourly part the symbol and amount come from next_6_hours.
        #expect(hours.contains { $0.precipitation == nil && $0.symbol != nil && $0.precipitation6h != nil })
        let store = try HistoryStore(path: temporaryDatabasePath())
        try store.replaceForecast(
            [ForecastHour(time: clock.now, temperature: 1, precipitation6h: 2.5)], fetchedAt: clock.now)
        #expect(try store.forecast(from: clock.now, to: clock.now.addingTimeInterval(3600)).first?.precipitation6h == 2.5)
    }
}
