import Foundation
import Testing
@testable import HeatPumpKit

@Suite("Weekly timer: decoding, editing and saving")
struct WeeklyTimerTests {
    let clock = TestClock()
    let oslo = TimeZone(identifier: "Europe/Oslo")!

    func timer(_ name: String = "timer_get2") throws -> WeeklyTimer {
        MELCloudClassicParser.weeklyTimer(try Fixture.json(name))
    }

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        WireDate.calendar(oslo).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func newEvent(_ minute: Int, _ temperature: Double, weekday: Int = 1) -> TimerEvent {
        TimerEvent(
            weekday: weekday, minuteOfDay: minute, power: true, mode: .heat, setTemperature: temperature, fanSpeed: 0,
            vaneHorizontal: .position3, vaneVertical: .auto)
    }

    // MARK: Decoding

    @Test func twoSeasonsAndTheActiveOne() throws {
        let timer = try timer("timer_get2_seasons")
        #expect(timer.decoded)
        #expect(timer.seasons.count == 2)
        #expect(timer.eventCount == 4)
        #expect(timer.seasons[0].name == "Vinter")
        #expect(timer.seasons[0].startMonth == 10)
        #expect(timer.seasons[1].events.first?.weekday == 3)
        #expect(timer.seasons[0].displayName == "Vinter (fra 1. oktober)")
        #expect(timer.activeSeasonIndex(on: date(2026, 11, 5), timeZone: oslo) == 0)
        #expect(timer.activeSeasonIndex(on: date(2026, 5, 20), timeZone: oslo) == 1)
        #expect(timer.activeSeasonIndex(on: date(2026, 2, 1), timeZone: oslo) == 0)  // continues from last autumn
        // Next event comes from the active season only (Thursday 5 Nov → Friday 23:00, not Wednesday 12:00).
        let next = try #require(timer.nextEvent(after: clock.now, timeZone: oslo))
        #expect(next.event.weekday == 5)
        #expect(next.date == date(2026, 11, 6, 23))
    }

    @Test func eventDayZeroIsSunday() {
        let sunday = MELCloudClassicParser.timerEvent(.object(["EventDay": .number(0), "EventHour": .number(7), "EventMinute": .number(5)]))
        #expect(sunday?.weekday == 7)
        let saturday = MELCloudClassicParser.timerEvent(.object(["EventDay": .number(6), "EventTime": .string("07:05:00")]))
        #expect(saturday?.weekday == 6)
        #expect(saturday?.minuteOfDay == 425)
        #expect(MELCloudClassicParser.timerEvent(.object(["EventDay": .number(7), "EventHour": .number(7), "EventMinute": .number(0)])) == nil)
        #expect(MELCloudClassicParser.timerEvent(.object(["EventDay": .number(1)])) == nil)
        // Sunday goes out as 0 again.
        var event = newEvent(425, 21)
        event.weekday = 7
        #expect(MELCloudClassicParser.timerEventJSON(event)["EventDay"] == .number(0))
    }

    @Test func legacyCacheDecodesReadOnly() throws {
        let legacy = """
            {"enabled": true, "events": [{"weekday": 1, "minuteOfDay": 390, "power": true, "mode": 1, "setTemperature": 21}],
             "eventCount": 1, "decoded": true, "fetchedAt": 800000000}
            """
        let timer = try JSONDecoder().decode(WeeklyTimer.self, from: Data(legacy.utf8))
        #expect(timer.enabled == true)
        #expect(timer.events.count == 1)
        #expect(!timer.decoded)
        #expect(timer.fetchedAt == nil)
        #expect(timer.validationProblem(limits: nil) != nil)
        // The new shape round-trips through the cache.
        let current = try self.timer()
        let again = try JSONDecoder().decode(WeeklyTimer.self, from: JSONEncoder().encode(current))
        #expect(again == current)
    }

    // MARK: Writing

    @Test func unchangedPlanGoesBackExactly() throws {
        let json = try Fixture.json("timer_get2_seasons")
        let body = MELCloudClassicParser.timerSetBody(timer: MELCloudClassicParser.weeklyTimer(json), deviceId: 42)
        #expect(body["Seasons"] == json["Seasons"])
        #expect(body["Devices"] == .array([.number(42)]))
        #expect(body["TimerEnabled"] == .bool(true))
        #expect(body["SkipPage1"] == .bool(true))
        let single = try Fixture.json("timer_get2")
        #expect(MELCloudClassicParser.timerSetBody(timer: MELCloudClassicParser.weeklyTimer(single), deviceId: 42)["Seasons"] == single["Seasons"])
    }

    @Test func editedEventKeepsUnknownFieldsAndOtherSeasons() throws {
        let json = try Fixture.json("timer_get2_seasons")
        var timer = MELCloudClassicParser.weeklyTimer(json)
        let original = timer.seasons[0].events[0]  // Monday and Tuesday 06:30 → 21 °C
        #expect(timer.days(of: original, season: 0) == [1, 2])
        var edited = original
        edited.minuteOfDay = 7 * 60 + 15
        edited.setTemperature = 21.5
        timer.put(edited, on: [1, 2, 3], replacing: original, season: 0)
        let body = MELCloudClassicParser.timerSetBody(timer: timer, deviceId: 42)
        let events = try #require(body["Seasons"]?.array?[0]["Events"]?.array)
        #expect(events.count == 4)
        let monday = try #require(events.first { $0["EventDay"] == .number(1) && $0["EventHour"] == .number(7) })
        #expect(monday["ID"] == .number(201))  // MELCloud sees an edit of the same event
        #expect(monday["EventMinute"] == .number(15))
        #expect(monday["EventTime"] == .string("07:15:00"))
        #expect(monday["SetTemperature"] == .number(21.5))
        #expect(monday["Settings"] == .string("<settings></settings>"))
        let wednesday = try #require(events.first { $0["EventDay"] == .number(3) })
        #expect(wednesday["ID"] == nil)
        #expect(wednesday["Name"] == .string("-"))
        #expect(wednesday["FanSpeed"] == .number(0))
        // The untouched Friday event and the other season are byte-for-byte as read.
        #expect(events.contains(json["Seasons"]!.array![0]["Events"]!.array![2]))
        #expect(body["Seasons"]?.array?[1] == json["Seasons"]?.array?[1])
        #expect(body["Seasons"]?.array?[0]["Name"] == .string("Vinter"))
    }

    @Test func iSeeModeIsKeptWhenTheModeIsUnchanged() throws {
        var timer = try timer()
        let saturday = timer.seasons[0].events[2]
        var warmer = saturday
        warmer.setTemperature = 22
        timer.put(warmer, on: [6], replacing: saturday)
        let event = try #require(
            MELCloudClassicParser.timerSetBody(timer: timer, deviceId: 1)["Seasons"]?.array?[0]["Events"]?.array?.first { $0["ID"] == .number(103) })
        #expect(event["OperationMode"] == .number(9))
        #expect(event["SetTemperature"] == .number(22))
        var cooling = warmer
        cooling.mode = .cool
        timer.put(cooling, on: [6], replacing: warmer)
        let cooled = try #require(
            MELCloudClassicParser.timerSetBody(timer: timer, deviceId: 1)["Seasons"]?.array?[0]["Events"]?.array?.first { $0["ID"] == .number(103) })
        #expect(cooled["OperationMode"] == .number(3))
    }

    @Test func newPlanGetsTheDefaultSeasonAndNoEventsSwitchesItOff() {
        var timer = MELCloudClassicParser.weeklyTimer(.object(["Enabled": .bool(false), "Seasons": .array([])]))
        #expect(timer.decoded)
        timer.put(newEvent(390, 21), on: TimerEvent.weekdays)
        let body = MELCloudClassicParser.timerSetBody(timer: timer, deviceId: 1)
        let season = body["Seasons"]?.array?.first
        #expect(season?["ID"] == .number(-1))
        #expect(season?["Name"] == .string("Default"))
        #expect(season?["StartDay"] == .number(1))
        #expect(season?["StartMonth"] == .number(1))
        #expect(season?["Events"]?.array?.count == 5)
        var empty = timer
        empty.enabled = true
        empty.seasons[0].events = []
        #expect(MELCloudClassicParser.timerSetBody(timer: empty, deviceId: 1)["TimerEnabled"] == .bool(false))
    }

    @Test func saveErrorCodes() {
        func answer(_ code: Int?, max: Int? = nil) -> JSONValue {
            var data: [String: JSONValue] = [:]
            if let code { data["ErrorCode"] = .number(Double(code)) }
            if let max { data["MaxEvents"] = .number(Double(max)) }
            return .object(["Data": .object(data)])
        }
        #expect(MELCloudClassicParser.timerSaveError(answer(-1)) == nil)
        #expect(MELCloudClassicParser.timerSaveError(.object([:])) == nil)
        #expect(MELCloudClassicParser.timerSaveError(.object(["Data": .null])) == nil)
        #expect(MELCloudClassicParser.timerSaveError(.null) == nil)
        #expect(MELCloudClassicParser.timerSaveError(answer(0)) == "En ukjent feil oppstod da ukeplanen skulle lagres.")
        #expect(MELCloudClassicParser.timerSaveError(answer(1)) == "Sesongene er ikke gyldige. Sjekk startdatoene.")
        #expect(MELCloudClassicParser.timerSaveError(answer(2, max: 50))
            == "Du kan ikke ha mer enn 50 hendelser i ukeplanen (til sammen for alle sesonger).")
        #expect(MELCloudClassicParser.timerSaveError(answer(7)) == MELCloudClassicParser.timerErrorMessages[0])
        #expect(MELCloudClassicParser.timerSaveError(answer(-3)) == MELCloudClassicParser.timerErrorMessages[0])
    }

    // MARK: Editing

    @Test func editingFollowsTheWebClient() throws {
        var timer = try timer("timer_get2_seasons")
        let monday = timer.seasons[0].events[0]
        // Removing a shared event removes it on every day.
        var copy = timer
        copy.remove(monday, season: 0)
        #expect(copy.seasons[0].events.count == 1)
        #expect(copy.eventCount == 2)
        // An event at the same day and time is replaced.
        timer.put(newEvent(23 * 60, 18), on: [5], season: 0)
        #expect(timer.seasons[0].events(on: 5).map(\.setTemperature) == [18])
        #expect(timer.seasons[0].events(on: 5).first?.raw?["ID"] == .number(203))
        // Copy Monday to the weekend.
        timer.copyDay(1, to: [6, 7], season: 0)
        #expect(timer.seasons[0].events(on: 7).map(\.minuteOfDay) == [390])
        #expect(timer.seasons[0].events(on: 7).first?.raw == nil)
        #expect(timer.eventCount == 6)
    }

    @Test func templates() throws {
        var timer = try timer()
        let base = newEvent(0, 20)
        timer.apply(.nightSetback, base: base, replace: true)
        #expect(timer.eventCount == 14)
        #expect(timer.seasons[0].events(on: 6).map(\.timeText) == ["08:00", "22:30"])
        #expect(timer.seasons[0].events(on: 1).map(\.setTemperature) == [21, 19])
        #expect(timer.seasons[0].events.allSatisfy { $0.mode == .heat && $0.power == true && $0.vaneHorizontal == .position3 })
        // Adding keeps other events and replaces the same day and time.
        timer.apply(.awayDaytime, base: base, replace: false)
        #expect(timer.eventCount == 24)
        #expect(timer.seasons[0].events(on: 3).map(\.timeText) == ["06:30", "08:00", "15:30", "22:30"])
    }

    @Test func differencesAreGroupedByDays() throws {
        let old = try timer("timer_get2_seasons")
        var timer = old
        timer.seasons[0].events[0].setTemperature = 20  // Monday only
        timer.put(newEvent(8 * 60, 18), on: TimerEvent.weekdays, season: 0)
        timer.remove(timer.seasons[0].events.first { $0.weekday == 5 }!, season: 0)
        timer.enabled = false
        let lines = timer.differences(from: old)
        #expect(lines == [
            "Ukeplanen slås av",
            "Vinter: Ny: hverdager kl. 08:00 – Varme 18 °C",
            "Vinter: Fjernet: fre kl. 23:00 – Varme 19 °C",
            "Vinter: Endret: man kl. 06:30 – Varme 21 °C → Varme 20 °C",
        ])
        #expect(old.differences(from: old).isEmpty)
        // A fan-only change shows the details.
        var fan = old
        fan.seasons[1].events[0].power = true
        fan.seasons[0].events[2].fanSpeed = 3
        #expect(fan.differences(from: old).contains("Vinter: Endret: fre kl. 23:00 – Varme 19 °C, vifte auto, spjeld Auto/3 (midten) → Varme 19 °C, vifte 3, spjeld Auto/3 (midten)"))
        #expect(TimerEvent.daysText([1, 2, 3, 5]) == "man–ons, fre")
        #expect(TimerEvent.daysText([6, 7]) == "helg")
        #expect(TimerEvent.daysText([1, 7]) == "man, søn")
        #expect(timer.summary == "Av, 8 hendelser")
    }

    @Test func validation() throws {
        let limits = TemperatureLimits(minHeat: 10, maxHeat: 31, minCoolDry: 16, maxCoolDry: 31)
        var timer = try timer()
        #expect(timer.validationProblem(limits: limits) == nil)
        var cold = timer
        cold.put(newEvent(600, 9), on: [2])
        #expect(cold.validationProblem(limits: limits)?.contains("10 °C–31 °C") == true)
        var step = timer
        step.put(newEvent(600, 20.3), on: [2])
        #expect(step.validationProblem(limits: limits) != nil)
        var cool = timer
        var cooling = newEvent(600, 12)
        cooling.mode = .cool
        cool.put(cooling, on: [2])
        #expect(cool.validationProblem(limits: limits)?.contains("kjøling") == true)
        var off = timer
        var offEvent = newEvent(600, 5)
        offEvent.power = false
        off.put(offEvent, on: [2])
        #expect(off.validationProblem(limits: limits) == nil)  // temperature of an off event is not used
        var late = timer
        late.seasons[0].events.append(newEvent(1440, 21))
        #expect(late.validationProblem(limits: limits) != nil)
        var duplicate = timer
        duplicate.seasons[0].events.append(newEvent(390, 22))
        #expect(duplicate.validationProblem(limits: limits)?.contains("To hendelser mandag kl. 06:30") == true)
        var many = timer
        many.maxEvents = 3
        #expect(many.validationProblem(limits: limits)?.contains("høyst 3") == true)
        timer.seasons[0].events = []
        timer.put(newEvent(390, 21), on: [1])
        timer.remove(timer.seasons[0].events[0])
        timer.enabled = true
        #expect(timer.validationProblem(limits: limits)?.contains("uten hendelser") == true)
        timer.enabled = false
        #expect(timer.validationProblem(limits: limits) == nil)
    }

    // MARK: Service

    func makeService(store: HistoryStore, backend: MockBackend) -> HeatPumpService {
        HeatPumpService(backend: backend, store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
    }

    @Test func saveRoundTripsThroughTheMock() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let service = makeService(store: store, backend: backend)
        _ = try await service.currentState()
        let base = try #require(try await service.weeklyTimer())
        var timer = base
        #expect(timer.decoded)
        #expect(timer.summary == "På, 14 hendelser")
        timer.put(newEvent(12 * 60, 20), on: [3])
        let budget = try await service.writeBudget().remaining
        let outcome = try await service.saveWeeklyTimer(timer, base: base, source: .app, reason: "Endret i appen (Ukeplan)")
        #expect(outcome.result == .ok)
        #expect(outcome.message.contains("MELCloud viser den samme planen"))
        #expect(await backend.timerWrites == 1)
        #expect(await backend.timerReads == 3)  // fresh read before sending, read back once
        let stored = try #require(try await service.storedWeeklyTimer())
        #expect(stored.eventCount == 15)
        #expect(stored.seasons[0].events(on: 3).map(\.timeText) == ["06:30", "12:00", "22:30"])
        #expect(stored.differences(from: timer).isEmpty)
        #expect(try await service.writeBudget().remaining == budget - 1)
        let record = try #require(try await service.changeLog(limit: 1, source: nil).first)
        #expect(record.field == "weeklyTimer")
        #expect(record.oldValue == "På, 14 hendelser")
        #expect(record.newValue == "På, 15 hendelser")
        #expect(record.result == .ok)
        #expect(record.displaySummary == "Ukeplan: På, 15 hendelser")
        // Within 15 s the fresh read is not repeated, so nothing is sent.
        clock.advance(6)
        timer.enabled = false
        let tooSoon = try await service.saveWeeklyTimer(timer, base: stored, source: .app, reason: "x")
        #expect(tooSoon.result == .rejected)
        #expect(tooSoon.message.contains("nettopp hentet"))
        // A second save later cannot read back (30 s) and says so.
        clock.advance(10)
        let second = try await service.saveWeeklyTimer(timer, base: stored, source: .app, reason: "x")
        #expect(second.result == .ok)
        #expect(second.message.contains("bekrefter ved neste henting"))
        #expect(await backend.timerReads == 4)
        #expect(try await service.storedWeeklyTimer()?.enabled == false)
    }

    @Test func refusalsAreLoggedAndSendNothing() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let service = makeService(store: store, backend: backend)
        // No status yet.
        let none = try await service.saveWeeklyTimer(try timer(), base: try timer(), source: .app, reason: "x")
        #expect(none.result == .rejected)
        _ = try await service.currentState()
        // Based on a plan that could not be decoded.
        let unreadable = WeeklyTimer(enabled: true, seasons: [], eventCount: 3, decoded: false)
        let unread = try await service.saveWeeklyTimer(try timer(), base: unreadable, source: .app, reason: "x")
        #expect(unread.result == .rejected)
        #expect(unread.message.contains("kunne ikke leses"))
        let base = try #require(try await service.weeklyTimer())
        var timer = base
        var tooCold = timer
        tooCold.put(newEvent(600, 8), on: [2])
        let cold = try await service.saveWeeklyTimer(tooCold, base: base, source: .app, reason: "x")
        #expect(cold.result == .rejected)
        #expect(cold.message.contains("Temperaturen tirsdag kl. 10:00"))
        timer.seasons[0].events = []
        timer.enabled = true
        let empty = try await service.saveWeeklyTimer(timer, base: base, source: .app, reason: "x")
        #expect(empty.result == .rejected)
        #expect(empty.message.contains("uten hendelser"))
        #expect(await backend.timerWrites == 0)
        #expect(await backend.timerReads == 1)  // validation refusals do not even read
        #expect(try await service.writeBudget().remaining == ChangeBudget.maxChangesPerHour)
        let log = try await service.changeLog(limit: 10, source: nil)
        #expect(log.count == 4)
        #expect(log.allSatisfy { $0.field == "weeklyTimer" && $0.result == .rejected })
    }

    @Test func mockRefusesTooManyEvents() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let service = makeService(store: store, backend: backend)
        _ = try await service.currentState()
        let base = try #require(try await service.weeklyTimer())
        var timer = base
        for minute in stride(from: 0, to: 6 * 60, by: 30) { timer.put(newEvent(minute, 20), on: TimerEvent.allDays) }
        let outcome = try await service.saveWeeklyTimer(timer, base: base, source: .app, reason: "x")
        #expect(outcome.result == .failed)
        #expect(outcome.message.contains("mer enn 50 hendelser"))
        #expect(await backend.timerWrites == 0)
    }

    @Test func planChangedInMELCloudIsNotOverwritten() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let service = makeService(store: store, backend: backend)
        _ = try await service.currentState()
        let base = try #require(try await service.weeklyTimer())
        var draft = base
        draft.put(newEvent(12 * 60, 20), on: [3])
        // Someone changes Monday 06:30 to 22 °C in the MELCloud app meanwhile.
        var elsewhere = base
        elsewhere.seasons[0].events[0].setTemperature = 22
        await backend.replaceTimer(.object([
            "Enabled": .bool(true), "Seasons": MELCloudClassicParser.timerSetBody(timer: elsewhere, deviceId: 1)["Seasons"]!,
        ]))
        let refused = try await service.saveWeeklyTimer(draft, base: base, source: .app, reason: "x")
        #expect(refused.result == .rejected)
        #expect(refused.message == "Ikke sendt: " + HeatPumpService.timerChangedMessage)
        #expect(await backend.timerWrites == 0)
        #expect(try await service.writeBudget().remaining == ChangeBudget.maxChangesPerHour)
        let record = try #require(try await service.changeLog(limit: 1, source: nil).first)
        #expect(record.result == .rejected)
        #expect(record.error == HeatPumpService.timerChangedMessage)
        // The fresh plan is cached, so "Hent planen på nytt" starts from it, and that save goes through.
        let fresh = try #require(try await service.storedWeeklyTimer())
        #expect(fresh.seasons[0].events[0].setTemperature == 22)
        var redo = fresh
        redo.put(newEvent(12 * 60, 20), on: [3])
        clock.advance(16)
        let saved = try await service.saveWeeklyTimer(redo, base: fresh, source: .app, reason: "x")
        #expect(saved.result == .ok)
        #expect(await backend.timerWrites == 1)
        // Only on/off and the plan count, not when it was read.
        var later = fresh
        later.fetchedAt = clock.now
        #expect(later.hasSameContent(as: fresh))
        later.enabled = false
        #expect(!later.hasSameContent(as: fresh))
    }

    @Test func failedFreshReadSendsNothing() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let service = makeService(store: store, backend: backend)
        _ = try await service.currentState()
        let base = try #require(try await service.weeklyTimer())
        var draft = base
        draft.put(newEvent(12 * 60, 20), on: [3])
        await backend.failNextTimerRead(with: .http(status: 500))
        let failed = try await service.saveWeeklyTimer(draft, base: base, source: .app, reason: "x")
        #expect(failed.result == .rejected)
        #expect(failed.message.contains("Kunne ikke lese ukeplanen fra MELCloud før lagring"))
        #expect(await backend.timerWrites == 0)
        // A refusal pauses timer reads, and saves are refused without reading during the pause.
        clock.advance(16)
        await backend.failNextTimerRead(with: .http(status: 403))
        _ = try await service.saveWeeklyTimer(draft, base: base, source: .app, reason: "x")
        #expect(try await service.endpointRefusedUntil(HeatPumpService.timerFetchKey) != nil)
        clock.advance(16)
        let reads = await backend.timerReads
        let paused = try await service.saveWeeklyTimer(draft, base: base, source: .app, reason: "x")
        #expect(paused.result == .rejected)
        #expect(paused.message.contains("tillot ikke å lese ukeplanen"))
        #expect(await backend.timerReads == reads)
        #expect(await backend.timerWrites == 0)
        #expect(try await service.writeBudget().remaining == ChangeBudget.maxChangesPerHour)
        #expect(try await service.changeLog(limit: 10, source: nil).allSatisfy { $0.result == .rejected })
    }

    @Test func pageOpenReadsAPlanOlderThanTenMinutes() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let service = makeService(store: store, backend: backend)
        _ = try await service.currentState()
        _ = try await service.weeklyTimer()
        clock.advance(5 * 60)
        _ = try await service.weeklyTimer(maxAge: HeatPumpService.timerManualInterval)
        #expect(await backend.timerReads == 1)
        clock.advance(6 * 60)
        _ = try await service.weeklyTimer(maxAge: HeatPumpService.timerManualInterval)
        #expect(await backend.timerReads == 2)
    }

    // MARK: HTTP

    @Test func setAta2RequestAndErrors() async throws {
        let transport = StubTransport()
        transport.enqueue("/Timer/SetAta2", body: Data(#"{"Success": true, "Data": {"ErrorCode": -1, "MaxEvents": 50}}"#.utf8))
        transport.enqueue("/Timer/SetAta2", body: Data(#"{"Data": {"ErrorCode": 2, "MaxEvents": 50}}"#.utf8))
        transport.enqueue("/Timer/SetAta2", status: 403, body: Data())
        let credentials = InMemoryCredentialStore(
            credentials: MELCloudCredentials(email: "user@example.com", password: "secret"), contextKey: "KEY")
        let backend = MELCloudClassicBackend(credentials: credentials, transport: transport, timeZone: .gmt, now: clock.provider)
        let timer = try timer()
        try await backend.saveWeeklyTimer(timer, deviceId: 42)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path.hasSuffix("/Timer/SetAta2") == true)
        #expect(request.value(forHTTPHeaderField: "X-MitsContextKey") == "KEY")
        let body = try JSONValue.parse(try #require(request.httpBody))
        #expect(body == MELCloudClassicParser.timerSetBody(timer: timer, deviceId: 42))
        await #expect(throws: HeatPumpError.server(MELCloudClassicParser.timerSaveError(.object(["Data": .object(["ErrorCode": .number(2), "MaxEvents": .number(50)])]))!)) {
            try await backend.saveWeeklyTimer(timer, deviceId: 42)
        }
        await #expect(throws: HeatPumpError.endpointRefused(status: 403)) { try await backend.saveWeeklyTimer(timer, deviceId: 42) }
        #expect(!transport.requests.contains { $0.url?.path.hasSuffix("ClientLogin") == true })
    }
}
