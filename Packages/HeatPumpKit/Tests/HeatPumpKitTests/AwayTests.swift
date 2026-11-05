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
        let rejecting = RecordingApprover(.rejected)
        let change = AwayChange.holidayMode(HolidayMode(enabled: true, start: clock.now, end: clock.now.addingTimeInterval(86_400)))
        let refused = try await service.applyAway(change, source: .claude, reason: "Hytta", approver: rejecting)
        #expect(refused.result == .rejected)
        #expect(rejecting.received.count == 1)
        #expect(rejecting.received.first?.summaries.first?.hasPrefix("Slå på feriemodus") == true)
        #expect(await backend.awayWrites == 0)
        let approving = RecordingApprover(.approved)
        let sent = try await service.applyAway(change, source: .claude, reason: "Hytta", approver: approving)
        #expect(sent.result == .ok)
        #expect(await backend.awayWrites == 1)
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
