import Foundation
import Testing
@testable import HeatPumpKit

@Suite("MET forecast and expected use tomorrow")
struct WeatherTests {
    let clock = TestClock()

    @Test func parsesTheCapturedCompactForecast() throws {
        let hours = try METForecastProvider.parse(try Fixture.data("met_compact"))
        #expect(hours.count == 84)
        let first = try #require(hours.first)
        #expect(first.time == Date(timeIntervalSince1970: 1_793_887_200))  // 2026-11-05T14:00:00Z
        #expect(first.temperature == 5.8)
        #expect(first.windSpeed == 0.5)
        #expect(first.humidity == 79.6)
        #expect(first.cloudFraction == 8.8)
        #expect(first.symbol == "clearsky_day")
        #expect(first.precipitation == 0)
        // The 6-hourly tail has no next_1_hours block.
        #expect(hours.last?.precipitation == nil)
    }

    @Test func requestUsesRoundedCoordinatesAndAnIdentifyingUserAgent() async throws {
        let transport = StubTransport()
        transport.enqueue(
            "compact", body: try Fixture.data("met_compact"),
            headers: ["Last-Modified": "Thu, 05 Nov 2026 14:38:45 GMT", "Expires": "Thu, 05 Nov 2026 15:08:59 GMT"])
        let agent = METForecastProvider.userAgent(version: "1.0", contact: "ola@example.com")
        #expect(agent == "Varmepumpe-macOS/1.0 (personlig bruk; kontakt: ola@example.com)")
        #expect(METForecastProvider.userAgent(version: "1.0", contact: "  ") == "Varmepumpe-macOS/1.0 (personlig bruk)")
        let provider = METForecastProvider(userAgent: agent, transport: transport)
        let response = try await provider.fetch(latitude: 59.912_34, longitude: 10.756_78, ifModifiedSince: "Thu, 05 Nov 2026 13:00:00 GMT")
        let request = try #require(transport.requests.first)
        #expect(request.url?.query == "lat=59.91&lon=10.76")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == agent)
        #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == "Thu, 05 Nov 2026 13:00:00 GMT")
        #expect(response.hours.count == 84)
        #expect(response.lastModified == "Thu, 05 Nov 2026 14:38:45 GMT")
        #expect(response.expires == Date(timeIntervalSince1970: 1_793_891_339))
    }

    @Test func statusCodes() async throws {
        let transport = StubTransport()
        transport.enqueue("compact", status: 304, body: Data())
        transport.enqueue("compact", status: 203, body: try Fixture.data("met_compact"))
        transport.enqueue("compact", status: 429, body: Data())
        transport.enqueue("compact", status: 403, body: Data())
        let provider = METForecastProvider(userAgent: "x", transport: transport)
        let notModified = try await provider.fetch(latitude: 60, longitude: 10, ifModifiedSince: "a")
        #expect(notModified.status == 304)
        #expect(notModified.hours.isEmpty)
        #expect(try await provider.fetch(latitude: 60, longitude: 10, ifModifiedSince: nil).hours.count == 84)
        await #expect(throws: WeatherError.throttled(until: nil)) { _ = try await provider.fetch(latitude: 60, longitude: 10, ifModifiedSince: nil) }
        await #expect(throws: WeatherError.forbidden) { _ = try await provider.fetch(latitude: 60, longitude: 10, ifModifiedSince: nil) }
    }

    func makeService(store: HistoryStore, transport: StubTransport) -> HeatPumpService {
        HeatPumpService(
            backend: CountingBackend(now: clock.provider), store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper,
            weatherProvider: { METForecastProvider(userAgent: METForecastProvider.userAgent(version: "1.0", contact: $0.contactEmail), transport: transport) })
    }

    @Test func syncRespectsExpiresTheHourlyLimitAndIfModifiedSince() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let transport = StubTransport()
        let service = makeService(store: store, transport: transport)
        #expect(try await service.syncWeather().status == .noLocation)
        #expect(transport.requests.isEmpty)

        try await service.saveWeatherSettings(WeatherSettings(latitude: 59.9139, longitude: 10.7522, placeName: "Hjemme"))
        let expires = clock.now.addingTimeInterval(900)
        func httpDate(_ d: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .gmt
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            return f.string(from: d)
        }
        transport.enqueue("compact", body: try Fixture.data("met_compact"), headers: ["Last-Modified": "LM1", "Expires": httpDate(expires)])
        // At most nine days are kept.
        let kept = try METForecastProvider.parse(try Fixture.data("met_compact")).filter { $0.time < clock.now.addingTimeInterval(9 * 86_400) }.count
        #expect(kept < 84)
        let first = try await service.syncWeather()
        #expect(first.status == .fetched)
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].value(forHTTPHeaderField: "If-Modified-Since") == nil)

        clock.advance(600)  // not expired yet
        #expect(try await service.syncWeather().status == .upToDate)
        clock.advance(600)  // expired, but less than an hour since the last request
        #expect(try await service.syncWeather().status == .skipped)
        #expect(transport.requests.count == 1)

        clock.advance(3600)
        transport.enqueue("compact", status: 304, body: Data(), headers: ["Expires": httpDate(clock.now.addingTimeInterval(1800))])
        #expect(try await service.syncWeather().status == .notModified)
        #expect(transport.requests[1].value(forHTTPHeaderField: "If-Modified-Since") == "LM1")
        // The stored forecast survives a 304.
        let stored = try await service.weatherForecast(from: .distantPast, to: .distantFuture)
        #expect(stored.hours.count == kept)
        #expect(stored.location?.displayName == "Hjemme")
        #expect(stored.location?.latitude == 59.91)
    }

    @Test func newPlaceDropsTheOldForecastAndFetchesSooner() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let transport = StubTransport()
        let service = makeService(store: store, transport: transport)
        try await service.saveWeatherSettings(WeatherSettings(latitude: 59.91, longitude: 10.75))
        transport.enqueue("compact", body: try Fixture.data("met_compact"))
        #expect(try await service.syncWeather().status == .fetched)
        #expect(try await !service.weatherForecast(from: clock.now, to: .distantFuture).hours.isEmpty)

        // Same place again (only the name): the forecast stays.
        try await service.saveWeatherSettings(WeatherSettings(latitude: 59.91, longitude: 10.75, placeName: "Hjemme"))
        #expect(try await !service.weatherForecast(from: clock.now, to: .distantFuture).hours.isEmpty)

        try await service.saveWeatherSettings(WeatherSettings(latitude: 63.43, longitude: 10.39))
        #expect(try await service.weatherForecast(from: clock.now, to: .distantFuture).hours.isEmpty)
        // Within MET's 10-minute spacing: wait; after it, fetch at once instead of after an hour.
        clock.advance(300)
        #expect(try await service.syncWeather().status == .skipped)
        clock.advance(400)
        transport.enqueue("compact", body: try Fixture.data("met_compact"))
        #expect(try await service.syncWeather().status == .fetched)
        #expect(transport.requests.count == 2)
    }

    @Test func throttledAnswerIsRemembered() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let transport = StubTransport()
        let service = makeService(store: store, transport: transport)
        try await service.saveWeatherSettings(WeatherSettings(latitude: 60, longitude: 10))
        transport.enqueue("compact", status: 429, body: Data())
        let result = try await service.syncWeather()
        #expect(result.status == .failed)
        #expect(result.message?.contains("429") == true)
        clock.advance(120)
        #expect(try await service.syncWeather().status == .skipped)
    }

    @Test func melcloudBuildingLocationIsUsedWhenNothingIsTyped() async throws {
        let wrappers = MELCloudClassicParser.listedDevices(try Fixture.json("list_devices"))
        let location = try #require(MELCloudClassicParser.buildingLocation(wrappers.first))
        #expect(location.latitude == 59.9139)
        let store = try HistoryStore(path: temporaryDatabasePath())
        try store.insertSnapshot(makeState(at: clock.now))
        try store.saveRawDevice(RawDevice(deviceId: 1, fetchedAt: clock.now, json: .object([:]), listing: wrappers.first))
        let service = makeService(store: store, transport: StubTransport())
        let resolved = try #require(try await service.weatherLocation())
        #expect(resolved.source == .melcloud)
        #expect(resolved.latitude == 59.91)
        #expect(resolved.longitude == 10.75)
        // Typed coordinates win.
        try await service.saveWeatherSettings(WeatherSettings(latitude: 63.43, longitude: 10.39, placeName: "Trondheim"))
        #expect(try await service.weatherLocation()?.source == .manual)
        await #expect(throws: HeatPumpError.self) { try await service.saveWeatherSettings(WeatherSettings(latitude: 95, longitude: 10)) }
        await #expect(throws: HeatPumpError.self) { try await service.saveWeatherSettings(WeatherSettings(latitude: 60, longitude: nil)) }
        await #expect(throws: HeatPumpError.self) { try await service.saveWeatherSettings(WeatherSettings(contactEmail: "ikke-epost")) }
    }

    @Test func degreeDayRegression() throws {
        let points = (0..<12).map { i in (degreeDays: Double(i) * 2, kWh: 1 + 0.42 * Double(i) * 2) }
        let model = try #require(DegreeDayModel.fit(points))
        #expect(abs(model.slope - 0.42) < 1e-9)
        #expect(abs(model.intercept - 1) < 1e-9)
        #expect(model.residualStd < 1e-9)
        #expect(abs(model.predict(degreeDays: 20) - 9.4) < 1e-9)
        #expect(DegreeDayModel.fit(Array(points.prefix(9))) == nil)
        #expect(DegreeDayModel.fit((0..<12).map { _ in (degreeDays: 5.0, kWh: 3.0) }) == nil)
        let noisy = points.enumerated().map { (degreeDays: $1.degreeDays, kWh: $1.kWh + ($0.isMultiple(of: 2) ? 0.5 : -0.5)) }
        #expect((try #require(DegreeDayModel.fit(noisy))).residualStd > 0.4)
        #expect(DegreeDayModel.degreeDays(mean: 20) == 0)
        #expect(DegreeDayModel.degreeDays(mean: -3) == 20)
    }

    @Test func costIsSpreadByColdness() {
        // Two hours: one at 17 °C (floor weight 0.5) and one at 7 °C (weight 10).
        let cost = EnergyForecast.cost(kWh: 10.5, hours: [(17, 100), (7, 200)])
        #expect(cost.map { abs($0 - (0.5 * 1 + 10 * 2)) < 1e-9 } == true)
    }

    @Test func tomorrowEstimateFromHistoryForecastAndPrices() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        try store.insertSnapshot(makeState(at: clock.now))
        let calendar = WireDate.calendar(.gmt)
        let today = calendar.startOfDay(for: clock.now)
        // 14 days: mean outdoor −2…+11 °C (hourly log points), kWh = 0.42 per degree-day.
        var days: [EnergyDay] = []
        for i in 1...14 {
            let day = today.addingTimeInterval(-Double(i) * 86_400)
            let mean = -2 + Double(i % 14)
            try store.upsertTemperaturePoints(
                (0..<24).map { TemperaturePoint(timestamp: day.addingTimeInterval(Double($0) * 3600), room: 21, set: 21, outdoor: mean) },
                deviceId: 1)
            days.append(EnergyDay(day: WireDate.day(day, timeZone: .gmt), totalKWh: 0.42 * (17 - mean), heatingKWh: 0.42 * (17 - mean)))
        }
        try store.upsertEnergyDays(days, deviceId: 1, now: clock.now)
        // Tomorrow: −3 °C all day → 20 degree-days → 8.4 kWh.
        let tomorrow = today.addingTimeInterval(86_400)
        try store.replaceForecast(
            (0..<24).map { ForecastHour(time: tomorrow.addingTimeInterval(Double($0) * 3600), temperature: -3) }, fetchedAt: clock.now)
        let service = makeService(store: store, transport: StubTransport())
        let estimate = try #require(try await service.tomorrowEstimate())
        #expect(estimate.day == WireDate.day(tomorrow, timeZone: .gmt))
        #expect(estimate.kWh == 8.4)
        #expect(estimate.basisDays == 14)
        #expect(estimate.kWhLow == estimate.kWhHigh)  // a perfect fit has no spread
        // Norgespris 50 øre + Elvia grid; Friday 2026-11-06 → day rate 06–22.
        let expected = 8.4 * (50 + (16 * 46.4 + 8 * 31.4) / 24) / 100
        #expect(abs((estimate.costNok ?? 0) - expected) < 0.06)
        #expect(estimate.pricesFromToday == false)
        #expect(estimate.shortText == "Estimate tomorrow: ~8 kWh · ~" + Display.format("%.0f NOK", expected))
    }

    @Test func noEstimateWithoutEnoughDays() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        try store.insertSnapshot(makeState(at: clock.now))
        let service = makeService(store: store, transport: StubTransport())
        #expect(try await service.tomorrowEstimate() == nil)
    }
}
