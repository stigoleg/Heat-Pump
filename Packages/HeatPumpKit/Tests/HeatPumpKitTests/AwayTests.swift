import Foundation
import Testing
@testable import HeatPumpKit

@Suite("Frost protection, holiday mode and the weekly timer")
struct AwayTests {
    let clock = TestClock()
    let oslo = TimeZone(identifier: "Europe/Oslo")!

    // MARK: Validation and payloads

    @Test func frostProtectionLimitsFollowTheLibrary() {
        #expect(FrostProtection(enabled: true, minimum: 8, maximum: 12).validationProblem() == nil)
        #expect(FrostProtection(enabled: true, minimum: 4, maximum: 6).validationProblem() == nil)
        #expect(FrostProtection(enabled: true, minimum: 3, maximum: 10).validationProblem() != nil)
        #expect(FrostProtection(enabled: true, minimum: 14, maximum: 17).validationProblem() != nil)
        #expect(FrostProtection(enabled: true, minimum: 10, maximum: 11).validationProblem() != nil)  // gap < 2
        #expect(FrostProtection(enabled: false, minimum: 10, maximum: 11).validationProblem() != nil)
        #expect(FrostProtection(enabled: true, minimum: 8.5, maximum: 12).validationProblem() != nil)  // whole degrees
        #expect(FrostProtection(enabled: true, minimum: 8, maximum: 12).summary == "på, 8–12 °C")
        #expect(FrostProtection(enabled: false, minimum: 8, maximum: 12).summary == "av")
    }

    @Test func frostProtectionBody() {
        let body = MELCloudClassicParser.frostProtectionBody(FrostProtection(enabled: true, minimum: 8, maximum: 12), deviceId: 100_001)
        #expect(body == .object([
            "Enabled": .bool(true), "MinimumTemperature": .number(8), "MaximumTemperature": .number(12),
            "DeviceIds": .array([.number(100_001)]),
        ]))
    }

    @Test func holidayDatesGoOutAsUTCWallClock() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = oslo
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 20, hour: 10, minute: 0)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 27, hour: 18, minute: 30)))
        let body = MELCloudClassicParser.holidayModeBody(HolidayMode(enabled: true, start: start, end: end), deviceId: 7)
        #expect(body["Enabled"] == .bool(true))
        #expect(body["StartDate"] == .object([
            "Year": .number(2026), "Month": .number(12), "Day": .number(20), "Hour": .number(9), "Minute": .number(0), "Second": .number(0),
        ]))
        #expect(body["EndDate"]?["Hour"] == .number(17))
        #expect(body["EndDate"]?["Minute"] == .number(30))
        #expect(body["HMTimeZones"] == .array([.object(["Devices": .array([.number(7)])])]))
        // Read back: HMStartDate is UTC wall clock.
        let parsed = try MELCloudClassicParser.holidayMode(.object([
            "HMEnabled": .bool(true), "HMDefined": .bool(true), "HMStartDate": .string("2026-12-20T09:00:00"),
            "HMEndDate": .string("2026-12-27T17:30:00"),
        ]))
        #expect(parsed.start == start)
        #expect(parsed.end == end)
        // Components when the strings are missing.
        let fromComponents = try MELCloudClassicParser.holidayMode(.object([
            "HMEnabled": .bool(false), "StartDate": body["StartDate"]!, "EndDate": body["EndDate"]!,
        ]))
        #expect(fromComponents.start == start)
        #expect(fromComponents.enabled == false)
        // Switching off without dates sends nulls.
        let off = MELCloudClassicParser.holidayModeBody(HolidayMode(enabled: false), deviceId: 7)
        #expect(off["StartDate"] == .null)
    }

    @Test func holidayValidation() {
        let now = clock.now
        #expect(HolidayMode(enabled: true, start: now, end: now.addingTimeInterval(86_400)).validationProblem(now: now) == nil)
        #expect(HolidayMode(enabled: true, start: nil, end: now.addingTimeInterval(86_400)).validationProblem(now: now) != nil)
        #expect(HolidayMode(enabled: true, start: now.addingTimeInterval(7200), end: now.addingTimeInterval(3600)).validationProblem(now: now) != nil)
        #expect(HolidayMode(enabled: true, start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600)).validationProblem(now: now) != nil)
        #expect(HolidayMode(enabled: true, start: now, end: now.addingTimeInterval(400 * 86_400)).validationProblem(now: now) != nil)
        #expect(HolidayMode(enabled: false).validationProblem(now: now) == nil)
    }

    @Test func tolerantParsingAndErrors() throws {
        let fp = try MELCloudClassicParser.frostProtection(.object([
            "FPDefined": .bool(true), "FPEnabled": .bool(true), "FPMinTemperature": .number(8), "FPMaxTemperature": .number(12),
        ]))
        #expect(fp == FrostProtection(enabled: true, minimum: 8, maximum: 12, defined: true))
        #expect(throws: HeatPumpError.self) {
            try MELCloudClassicParser.frostProtection(.object(["AttributeErrors": .object(["Id": .array([.string("bad")])])]))
        }
        #expect(throws: HeatPumpError.self) { try MELCloudClassicParser.frostProtection(.object(["Foo": .number(1)])) }
        #expect(throws: HeatPumpError.self) {
            try MELCloudClassicParser.checkMutation(.object(["Success": .bool(false), "AttributeErrors": .object(["MinimumTemperature": .array([.string("x")])])]))
        }
        try MELCloudClassicParser.checkMutation(.object(["Success": .bool(true), "AttributeErrors": .null]))
        try MELCloudClassicParser.checkMutation(.null)
        // Shapes for stderr carry key names and types only.
        let shape = MELCloudClassicParser.redactedShape(.object(["FPMinTemperature": .number(8), "Devices": .array([.number(100_001)])]))
        #expect(shape.contains("FPMinTemperature:number"))
        #expect(!shape.contains("100001") && !shape.contains("8"))
    }

    // MARK: Timer

    @Test func timerDecodesKnownShapes() throws {
        let timer = MELCloudClassicParser.weeklyTimer(try Fixture.json("timer_get2"))
        #expect(timer.enabled == true)
        #expect(timer.eventCount == 4)
        #expect(timer.decoded)
        #expect(timer.events.count == 4)
        #expect(timer.events[0] == TimerEvent(weekday: 1, minuteOfDay: 390, power: true, mode: .heat, setTemperature: 21))
        #expect(timer.events[2].weekday == 6)
        #expect(timer.events[2].minuteOfDay == 480)
        #expect(timer.events[2].power == true)
        #expect(timer.events[3].weekday == 7)  // .NET DayOfWeek 0 = Sunday
        #expect(timer.events[3].minuteOfDay == 1350)
        #expect(timer.events[3].power == false)
        #expect(timer.events[0].summary == "Varme 21 °C")
    }

    @Test func timerWithUnknownShapeOnlyCounts() throws {
        let timer = MELCloudClassicParser.weeklyTimer(try Fixture.json("timer_unknown"))
        #expect(timer.enabled == false)
        #expect(timer.eventCount == 2)
        #expect(!timer.decoded)
        #expect(timer.events.isEmpty)
        #expect(MELCloudClassicParser.weeklyTimer(.null).eventCount == 0)
    }

    @Test func nextTimerEvent() throws {
        let timer = MELCloudClassicParser.weeklyTimer(try Fixture.json("timer_get2"))
        // Thursday 2026-11-05 10:00 UTC (= 11:00 Oslo): next is Saturday 08:00.
        let next = try #require(timer.nextEvent(after: clock.now, timeZone: oslo))
        #expect(next.event.weekday == 6)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = oslo
        #expect(next.date == calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 8)))
    }

    // MARK: Service

    func makeService(store: HistoryStore, backend: MockBackend) -> HeatPumpService {
        HeatPumpService(backend: backend, store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
    }

    @Test func readsAreCachedAndLimitedToHourly() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let service = makeService(store: store, backend: backend)
        _ = try await service.currentState()
        let first = try await service.awaySettings()
        #expect(first.frost?.enabled == false)
        #expect(await backend.awayReads == 1)
        clock.advance(1800)
        _ = try await service.awaySettings()
        #expect(await backend.awayReads == 1)
        clock.advance(1900)
        _ = try await service.awaySettings()
        #expect(await backend.awayReads == 2)
    }

    @Test func appWriteIsBudgetedLoggedAndCached() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let service = makeService(store: store, backend: backend)
        _ = try await service.currentState()
        _ = try await service.awaySettings()
        let outcome = try await service.applyAway(
            .frostProtection(FrostProtection(enabled: true, minimum: 8, maximum: 12)), source: .app, reason: "Reiser bort")
        #expect(outcome.result == .ok)
        #expect(await backend.frost.enabled == true)
        let row = try #require(try store.changes(limit: 1).first)
        #expect(row.field == "frostProtection")
        #expect(row.oldValue == "av")
        #expect(row.newValue == "på, 8–12 °C")
        #expect(row.result == .ok)
        #expect(try await service.writeBudget().remaining == ChangeBudget.maxChangesPerHour - 1)
        #expect(try await service.storedAwaySettings()?.frost?.enabled == true)
        // A second write right away waits for the 5 s spacing (the test clock advances).
        let holiday = try await service.applyAway(
            .holidayMode(HolidayMode(enabled: true, start: clock.now, end: clock.now.addingTimeInterval(3 * 86_400))), source: .app, reason: "Ferie")
        #expect(holiday.result == .ok)
        #expect(try store.changes(limit: 1).first?.field == "holidayMode")
    }

    @Test func invalidWritesUseNoBudgetAndAskNobody() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let service = makeService(store: store, backend: backend)
        _ = try await service.currentState()
        let approver = RecordingApprover(.approved)
        let outcome = try await service.applyAway(
            .frostProtection(FrostProtection(enabled: true, minimum: 2, maximum: 12)), source: .claude, reason: "x", approver: approver)
        #expect(outcome.result == .rejected)
        #expect(approver.received.isEmpty)
        #expect(await backend.awayWrites == 0)
        #expect(try await service.writeBudget().remaining == ChangeBudget.maxChangesPerHour)
    }

    @Test func claudeNeedsApproval() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let service = makeService(store: store, backend: backend)
        _ = try await service.currentState()
        _ = try await service.applyAway(.frostProtection(FrostProtection(enabled: true, minimum: 8, maximum: 12)), source: .app, reason: "x")
        let rejecting = RecordingApprover(.rejected)
        let change = AwayChange.holidayMode(HolidayMode(enabled: true, start: clock.now, end: clock.now.addingTimeInterval(86_400)))
        let refused = try await service.applyAway(change, source: .claude, reason: "Hytta", approver: rejecting)
        #expect(refused.result == .rejected)
        #expect(rejecting.received.count == 1)
        let summary = rejecting.received.first?.summaries.first ?? ""
        #expect(summary.hasPrefix("Slå på feriemodus"))
        #expect(summary.contains("frostsikringens område 8–12 °C"))
        #expect(await backend.awayWrites == 1)  // only the frost protection
        let approving = RecordingApprover(.approved)
        let sent = try await service.applyAway(change, source: .claude, reason: "Hytta", approver: approving)
        #expect(sent.result == .ok)
        #expect(await backend.awayWrites == 2)
        #expect(try store.changes(limit: 1).first?.source == .claude)
    }

    @Test func budgetExhaustedRejectsAwayWrites() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let service = makeService(store: store, backend: backend)
        _ = try await service.currentState()
        for i in 0..<ChangeBudget.maxChangesPerHour {
            _ = try store.reserveChange([
                ChangeRecord(timestamp: clock.now.addingTimeInterval(Double(i) * 6 - 600), source: .app, field: "x", oldValue: nil, newValue: "y", reason: nil, result: .pending)
            ])
        }
        let outcome = try await service.applyAway(.frostProtection(FrostProtection(enabled: false, minimum: 8, maximum: 12)), source: .app, reason: "x")
        #expect(outcome.result == .rejected)
        #expect(outcome.nextAllowed != nil)
        #expect(await backend.awayWrites == 0)
    }

    /// MockBackend whose away/timer endpoints answer 401 (as an unsupported endpoint might).
    actor RefusingBackend: HeatPumpBackend {
        nonisolated let identifier = "refusing"
        let inner: MockBackend
        init(now: @escaping @Sendable () -> Date) { inner = MockBackend(timeZone: .gmt, now: now) }
        func login() async throws {}
        func listDevices() async throws -> [DeviceSummary] { try await inner.listDevices() }
        func fetchState(deviceId: Int) async throws -> DeviceState { try await inner.fetchState(deviceId: deviceId) }
        func apply(_ changes: ChangeSet) async throws -> DeviceState? { try await inner.apply(changes) }
        func fetchErrorLog(deviceId: Int, range: DateInterval) async throws -> [ErrorLogEntry] { [] }
        func fetchTemperatureLog(deviceId: Int, range: DateInterval) async throws -> [TemperaturePoint] { [] }
        func fetchEnergy(deviceId: Int, range: DateInterval) async throws -> [EnergyDay] { [] }
        func fetchSignalStrength(deviceId: Int) async throws -> Int? { nil }
        func fetchAwaySettings(deviceId: Int) async throws -> AwaySettings { throw HeatPumpError.unauthorized }
        func applyAway(_ change: AwayChange, deviceId: Int) async throws { throw HeatPumpError.unauthorized }
        func fetchWeeklyTimer(deviceId: Int) async throws -> WeeklyTimer { throw HeatPumpError.unauthorized }
    }

    @Test func refusalsFromTheseEndpointsDoNotBlockMELCloud() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let service = HeatPumpService(backend: RefusingBackend(now: clock.provider), store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        _ = try await service.currentState()
        let away = try await service.awaySettings()
        #expect(away.message?.contains("Kunne ikke lese") == true)
        _ = try await service.weeklyTimer()
        let outcome = try await service.applyAway(.frostProtection(FrostProtection(enabled: true, minimum: 8, maximum: 12)), source: .app, reason: "x")
        #expect(outcome.result == .failed)
        #expect(try store.blockStatus(now: clock.now) == nil)
    }

    // MARK: Round 5 review

    @Test func holidayNeedsFrostProtectionOn() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let service = makeService(store: store, backend: backend)
        _ = try await service.currentState()
        let approver = RecordingApprover(.approved)
        let holiday = AwayChange.holidayMode(HolidayMode(enabled: true, start: clock.now, end: clock.now.addingTimeInterval(86_400)))
        // Mock starts with frost protection off.
        let refused = try await service.applyAway(holiday, source: .claude, reason: "Ferie", approver: approver)
        #expect(refused.result == .rejected)
        #expect(refused.message.contains("frostsikring er av"))
        #expect(approver.received.isEmpty)
        #expect(await backend.awayWrites == 0)
        // Low but allowed range: sent, and the summary warns.
        clock.advance(10)
        _ = try await service.applyAway(.frostProtection(FrostProtection(enabled: true, minimum: 6, maximum: 10)), source: .app, reason: "x")
        clock.advance(10)
        let sent = try await service.applyAway(holiday, source: .claude, reason: "Ferie", approver: approver)
        #expect(sent.result == .ok)
        #expect(approver.received.first?.summaries.first?.contains("8 °C eller mer anbefales") == true)
        // Frost protection cannot be switched off during the holiday.
        clock.advance(10)
        let off = try await service.applyAway(.frostProtection(FrostProtection(enabled: false, minimum: 6, maximum: 10)), source: .app, reason: "x")
        #expect(off.result == .rejected)
        #expect(off.message.contains("feriemodus er på"))
        #expect(await backend.frost.enabled == true)
    }

    @Test func holidayRefusedWhenFrostIsUnknown() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let service = HeatPumpService(backend: RefusingBackend(now: clock.provider), store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        _ = try await service.currentState()
        let outcome = try await service.applyAway(
            .holidayMode(HolidayMode(enabled: true, start: clock.now, end: clock.now.addingTimeInterval(86_400))), source: .app, reason: "x")
        #expect(outcome.result == .rejected)
        #expect(outcome.message.contains("ikke vet om frostsikring er på"))
        #expect(try await service.writeBudget().remaining == ChangeBudget.maxChangesPerHour)
    }

    @Test func frostRangeIsNeverGuessed() {
        let current = FrostProtection(enabled: true, minimum: 10, maximum: 14)
        #expect(FrostProtection.resolving(enabled: false, minimum: nil, maximum: nil, current: current)
            == FrostProtection(enabled: false, minimum: 10, maximum: 14))
        #expect(FrostProtection.resolving(enabled: false, minimum: nil, maximum: nil, current: nil) == nil)
        #expect(FrostProtection.resolving(enabled: true, minimum: 8, maximum: nil, current: nil) == nil)
        #expect(FrostProtection.resolving(enabled: true, minimum: 8, maximum: 12, current: nil) == FrostProtection(enabled: true, minimum: 8, maximum: 12))
        #expect(AwayChange.frostProtection(FrostProtection(enabled: false, minimum: 10, maximum: 14)).displaySummary
            == "Slå av frostsikring (området 10–14 °C lagres uendret)")
    }

    @Test func writeIsReadBackForComparison() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let service = makeService(store: store, backend: backend)
        _ = try await service.currentState()
        _ = try await service.applyAway(.frostProtection(FrostProtection(enabled: true, minimum: 8, maximum: 12)), source: .app, reason: "x")
        let stored = try #require(try await service.storedAwaySettings())
        #expect(stored.pendingSince == nil)  // read back right away
        #expect(stored.sentFrost == FrostProtection(enabled: true, minimum: 8, maximum: 12))
        #expect(stored.frost?.enabled == true)
        #expect(stored.sentAt != nil)
    }

    @Test func refusingEndpointsCauseNoLoginsFor24Hours() async throws {
        let transport = StubTransport()
        transport.enqueue("/User/ListDevices", body: try Fixture.data("list_devices"))
        transport.enqueue("/Device/Get", body: try Fixture.data("device_get_full"))
        for _ in 0..<30 {
            transport.enqueue("/FrostProtection/GetSettings", status: 401, body: Data())
            transport.enqueue("/Timer/Get2", status: 401, body: Data())
            transport.enqueue("/Login/ClientLogin", body: try Fixture.data("login_success"))
        }
        let store = try HistoryStore(path: temporaryDatabasePath())
        let credentials = InMemoryCredentialStore(
            credentials: MELCloudCredentials(email: "user@example.com", password: "secret"), contextKey: "KEY")
        let backend = MELCloudClassicBackend(credentials: credentials, transport: transport, timeZone: .gmt, rawCache: store, now: clock.provider)
        let service = HeatPumpService(backend: backend, store: store, credentials: credentials, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        _ = try await service.currentState()
        var last: AwaySettings?
        for _ in 0..<24 {
            last = try await service.awaySettings()
            _ = try await service.weeklyTimer()
            clock.advance(3600)
        }
        let paths = transport.requests.compactMap { $0.url?.path }
        #expect(paths.filter { $0.hasSuffix("ClientLogin") }.isEmpty)
        #expect(paths.filter { $0.hasSuffix("FrostProtection/GetSettings") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("Timer/Get2") }.count == 1)
        #expect(last?.message?.contains("tillot ikke å lese frostsikring og feriemodus") == true)
        #expect(last?.refusedUntil != nil)
        #expect(try store.blockStatus(now: clock.now) == nil)
        // "Prøv igjen" lifts the pause.
        _ = try await service.awaySettings(manual: true)
        #expect(transport.requests.compactMap { $0.url?.path }.filter { $0.hasSuffix("FrostProtection/GetSettings") }.count == 2)
    }

    @Test func holidayWireTimeIsOneFunction() throws {
        let date = try #require(WireDate.calendar(.gmt).date(from: DateComponents(year: 2026, month: 12, day: 20, hour: 6, minute: 40)))
        let json = HolidayWireTime.components(date)
        #expect(json["Hour"] == .number(6))
        #expect(HolidayWireTime.date(components: json) == date)
        #expect(HolidayWireTime.date(string: "2026-12-20T06:40:00") == date)
    }

    @Test func timerIsReadAtMostEverySixHoursAndNotedOnWrites() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let service = makeService(store: store, backend: backend)
        _ = try await service.currentState()
        let timer = try #require(try await service.weeklyTimer())
        #expect(timer.enabled == true)
        #expect(await backend.timerReads == 1)
        clock.advance(3 * 3600)
        _ = try await service.weeklyTimer()
        #expect(await backend.timerReads == 1)
        clock.advance(3 * 3600 + 1)
        _ = try await service.weeklyTimer()
        #expect(await backend.timerReads == 2)
        let outcome = try await service.apply(.temperature(22), source: .app, reason: "x")
        #expect(outcome.message.contains("ukeplanen"))
    }
}
