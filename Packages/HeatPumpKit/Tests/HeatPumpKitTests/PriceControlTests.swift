import Foundation
import GRDB
import Testing
@testable import HeatPumpKit

@Suite("Price control: planner, rules and runner")
struct PriceControlTests {
    let clock = TestClock()  // Thursday 2026-11-05 10:00 UTC

    func hours(_ levels: [PriceLevel?], prices: [Double]? = nil, from start: Date? = nil) -> [PriceControlHour] {
        let first = start ?? clock.now
        return levels.enumerated().map { i, level in
            PriceControlHour(start: first.addingTimeInterval(Double(i) * 3600), totalOre: prices?[i] ?? 100, level: level)
        }
    }

    // MARK: Planner

    @Test func lowersByLevelAndMergesEqualHours() {
        let steps = PriceControlPlanner.plan(
            hours: hours([.normal, .expensive, .veryExpensive, .veryExpensive, .cheap, .normal], prices: [90, 150, 240, 245, 60, 95]),
            base: { _ in 21 }, settings: .default, now: clock.now)
        #expect(steps.map(\.kind) == [.normal, .reduce, .reduce, .normal])
        #expect(steps.map(\.target) == [21, 20, 19, 21])
        #expect(steps[2].start == clock.now.addingTimeInterval(2 * 3600))
        #expect(steps[2].end == clock.now.addingTimeInterval(4 * 3600))
        #expect(steps[2].priceOre == 245)
        #expect(steps[2].reason == "Svært dyrt (" + Norwegian.format("%.2f", 2.45) + " kr/kWh)")
        #expect(steps[3].end == clock.now.addingTimeInterval(6 * 3600))
        #expect(steps[1].summary(now: clock.now, timeZone: .gmt).hasPrefix("11–12: senkes til 20 °C"))
    }

    @Test func neverBelowTheMinimum() {
        let settings = PriceControlSettings(reduceVeryExpensive: 3, minimumTemperature: 18)
        let lowered = PriceControlPlanner.plan(hours: hours([.veryExpensive]), base: { _ in 19.5 }, settings: settings, now: clock.now)
        #expect(lowered.first?.target == 18)
        // A base at or under the minimum is left alone (never raised to the minimum either).
        let atMinimum = PriceControlPlanner.plan(hours: hours([.veryExpensive]), base: { _ in 17 }, settings: settings, now: clock.now)
        #expect(atMinimum.first?.target == 17)
        #expect(atMinimum.first?.kind == .normal)
    }

    @Test func preheatsTheTwoCheapestHoursBeforeAnExpensiveBlock() {
        let levels: [PriceLevel?] = [.cheap, .normal, .cheap, .normal, .expensive, .expensive, .normal]
        let input = hours(levels, prices: [50, 80, 40, 90, 160, 170, 90])
        let off = PriceControlPlanner.plan(hours: input, base: { _ in 21 }, settings: .default, now: clock.now)
        #expect(!off.contains { $0.kind == .preheat })
        let steps = PriceControlPlanner.plan(hours: input, base: { _ in 21 }, settings: PriceControlSettings(preheat: true), now: clock.now)
        let preheated = steps.filter { $0.kind == .preheat }
        #expect(preheated.map(\.start) == [clock.now, clock.now.addingTimeInterval(2 * 3600)])
        #expect(preheated.allSatisfy { $0.target == 22 })  // never above base + 1
        #expect(steps.contains { $0.kind == .reduce && $0.target == 20 && $0.end == clock.now.addingTimeInterval(6 * 3600) })
    }

    @Test func followsTheWeeklyPlanAsBaseAndSkipsHoursWithoutOne() {
        let switchAt = clock.now.addingTimeInterval(2 * 3600)
        let steps = PriceControlPlanner.plan(
            hours: hours(Array(repeating: .veryExpensive, count: 5)),
            base: { $0 < switchAt ? 19 : $0 < switchAt.addingTimeInterval(2 * 3600) ? 22 : nil }, settings: .default, now: clock.now)
        #expect(steps.map(\.target) == [18, 20])
        #expect(steps.map(\.base) == [19, 22])
        #expect(steps.last?.end == switchAt.addingTimeInterval(2 * 3600))  // the fifth hour has no base
    }

    @Test func pastHoursAreLeftOut() {
        let steps = PriceControlPlanner.plan(
            hours: hours([.expensive, .expensive], from: clock.now.addingTimeInterval(-3600)), base: { _ in 21 }, settings: .default,
            now: clock.now.addingTimeInterval(1))
        #expect(steps.first?.start == clock.now)
    }

    @Test func weeklyPlanEventInForce() throws {
        // Thursday 06:00 → 20 °C, Thursday 12:00 → 22 °C, Friday 08:00 off.
        let timer = WeeklyTimer(
            enabled: true,
            seasons: [
                TimerSeason(events: [
                    TimerEvent(weekday: 4, minuteOfDay: 360, power: true, mode: .heat, setTemperature: 20),
                    TimerEvent(weekday: 4, minuteOfDay: 720, power: true, mode: .heat, setTemperature: 22),
                    TimerEvent(weekday: 5, minuteOfDay: 480, power: false),
                ])
            ], decoded: true)
        let at10 = try #require(timer.event(inForceAt: clock.now, timeZone: .gmt))
        #expect(at10.event.setTemperature == 20)
        #expect(at10.date == clock.now.addingTimeInterval(-4 * 3600))
        #expect(timer.event(inForceAt: clock.now.addingTimeInterval(2 * 3600), timeZone: .gmt)?.event.setTemperature == 22)
        // Wednesday: last week's Friday "off" is the latest event.
        #expect(timer.event(inForceAt: clock.now.addingTimeInterval(-86_400), timeZone: .gmt)?.event.power == false)
    }

    // MARK: Rules

    func step(_ kind: PlannedStep.Kind = .reduce, target: Double = 19, base: Double = 21, from: Date? = nil, hours: Double = 2) -> PlannedStep {
        let start = from ?? clock.now
        return PlannedStep(
            start: start, end: start.addingTimeInterval(hours * 3600), target: target, base: base, kind: kind, level: .veryExpensive,
            priceOre: 245, reason: "Svært dyrt (2,45 kr/kWh)")
    }

    func context(
        set: Double = 21, steps: [PlannedStep]? = nil, at: Date? = nil, power: Bool = true, mode: OperationMode = .heat,
        pending: Bool = false, comfort: Double? = 21
    ) -> PriceControlContext {
        let now = at ?? clock.now.addingTimeInterval(30)
        var state = makeState(at: now, power: power, mode: mode, set: set)
        state.hasPendingCommand = pending
        return PriceControlContext(
            settings: PriceControlSettings(enabled: true, comfortTemperature: comfort), state: state, steps: steps ?? [step()], now: now)
    }

    @Test func sendsTheStepTargetOnceAndThenHolds() {
        var memory = PriceControlMemory()
        let first = PriceControlEngine.evaluate(context(), memory: &memory)
        #expect(first.target == 19)
        #expect(first.reason == "Prisstyring: Svært dyrt (2,45 kr/kWh)")
        #expect(first.kind == .lowered)
        // What the runner records after a successful send.
        memory.lastSent = 19
        memory.lastSentAt = clock.now.addingTimeInterval(30)
        memory.appliedStepStart = clock.now
        let later = PriceControlEngine.evaluate(context(set: 19, at: clock.now.addingTimeInterval(600)), memory: &memory)
        #expect(later.target == nil)
        #expect(later.kind == .lowered)
        #expect(later.comfortTemperature == nil)
    }

    @Test func manualChangePausesUntilTheNextStepAndBecomesComfort() {
        let steps = [step(), step(.normal, target: 21, from: clock.now.addingTimeInterval(2 * 3600))]
        var memory = PriceControlMemory(lastSent: 19, lastSentAt: clock.now.addingTimeInterval(30), appliedStepStart: clock.now)
        // Not yet confirmed by the unit: no conclusion.
        let pending = PriceControlEngine.evaluate(
            context(set: 22, steps: steps, at: clock.now.addingTimeInterval(600), pending: true), memory: &memory)
        #expect(pending.kind == .lowered)
        #expect(memory.lastSent == 19)
        // Confirmed: the user set 22 °C.
        let paused = PriceControlEngine.evaluate(context(set: 22, steps: steps, at: clock.now.addingTimeInterval(900)), memory: &memory)
        #expect(paused.kind == .paused)
        #expect(paused.target == nil)
        #expect(paused.comfortTemperature == 22)
        #expect(memory.pausedUntil == clock.now.addingTimeInterval(2 * 3600))
        #expect(memory.lastSent == nil)
        // Next step boundary: control resumes (base 22 now matches, nothing to send).
        let next = [step(.normal, target: 22, base: 22, from: clock.now.addingTimeInterval(2 * 3600))]
        let resumed = PriceControlEngine.evaluate(
            context(set: 22, steps: next, at: clock.now.addingTimeInterval(2 * 3600 + 30), comfort: 22), memory: &memory)
        #expect(resumed.kind == .normal)
        #expect(resumed.target == nil)
        #expect(memory.pausedUntil == nil)
    }

    @Test func weeklyPlanChangeIsNotAManualOverride() {
        var memory = PriceControlMemory(lastSent: 19, lastSentAt: clock.now.addingTimeInterval(30), appliedStepStart: clock.now)
        var c = context(set: 23, at: clock.now.addingTimeInterval(3700))
        c.timerFiredAt = clock.now.addingTimeInterval(1200)
        let decision = PriceControlEngine.evaluate(c, memory: &memory)
        #expect(decision.kind != .paused)
        #expect(decision.target == 19)  // the step is applied again (in the next clock hour)
    }

    @Test func skipsWhenItMustNotAct() {
        func kindAndText(_ c: PriceControlContext) -> (PriceControlStatus.Kind, String, Double?) {
            var memory = PriceControlMemory()
            let d = PriceControlEngine.evaluate(c, memory: &memory)
            return (d.kind, d.text, d.target)
        }
        var holiday = context()
        holiday.holidayActive = true
        #expect(kindAndText(holiday).2 == nil)
        #expect(kindAndText(holiday).1.contains("Feriemodus"))
        #expect(kindAndText(context(power: false)).1.contains("av"))
        var frost = context(power: false)
        frost.frostProtection = true
        #expect(kindAndText(frost).1.contains("frostsikringen"))
        #expect(kindAndText(context(mode: .cool)).1.contains("varmemodus"))
        var blocked = context()
        blocked.blockedReason = "MELCloud er sperret"
        #expect(kindAndText(blocked).1 == "MELCloud er sperret")
        var timer = context()
        timer.timerEventNear = clock.now.addingTimeInterval(300)
        #expect(kindAndText(timer).0 == .waiting)
        #expect(kindAndText(timer).2 == nil)
        var off = context()
        off.settings.enabled = false
        #expect(kindAndText(off).0 == .off)
        #expect(kindAndText(context(steps: [])).2 == nil)
    }

    @Test func atMostOneChangePerHour() {
        var memory = PriceControlMemory(lastSent: 19, lastSentAt: clock.now.addingTimeInterval(30), appliedStepStart: clock.now)
        // A one-hour step boundary inside the same clock hour as the last send is impossible, so
        // simulate a new step starting in the same hour.
        let next = step(.normal, target: 21, from: clock.now.addingTimeInterval(1200), hours: 1)
        let d = PriceControlEngine.evaluate(context(set: 19, steps: [next], at: clock.now.addingTimeInterval(1500)), memory: &memory)
        #expect(d.kind == .waiting)
        #expect(d.target == nil)
    }

    @Test func restoreOnlyWhileTheControllersSetpointIsInForce() {
        let state = makeState(at: clock.now, set: 19)
        #expect(PriceControlEngine.restoreTarget(memory: PriceControlMemory(lastSent: 19), state: state, base: 21) == 21)
        #expect(PriceControlEngine.restoreTarget(memory: PriceControlMemory(lastSent: 19), state: makeState(at: clock.now, set: 22), base: 21) == nil)
        #expect(PriceControlEngine.restoreTarget(memory: PriceControlMemory(), state: state, base: 21) == nil)
        #expect(PriceControlEngine.restoreTarget(memory: PriceControlMemory(lastSent: 21), state: makeState(at: clock.now, set: 21), base: 21) == nil)
    }

    @Test func settingsDecodeWithDefaultsAndValidate() throws {
        let old = try JSONDecoder().decode(PriceControlSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(old.enabled)
        #expect(old.reduceExpensive == 1 && old.reduceVeryExpensive == 2 && old.minimumTemperature == 18 && !old.preheat)
        #expect(PriceControlSettings.default.validationProblem() == nil)
        #expect(PriceControlSettings(reduceExpensive: 0.3).validationProblem() != nil)
        #expect(PriceControlSettings(minimumTemperature: 12).validationProblem() != nil)
        #expect(PriceControlSettings(reduceVeryExpensive: 5).validationProblem() != nil)
    }

    // MARK: Runner through the service (mock backend)

    func makeService() async throws -> (HeatPumpService, MockBackend, HistoryStore) {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let service = HeatPumpService(backend: backend, store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        try await service.savePriceSettings(PriceSettings(agreement: .tibber))
        let today = WireDate.calendar(.gmt).startOfDay(for: clock.now)
        // The mock backend is the demo, so prices are stored as "mock"/NO1. Tibber-style levels:
        // 10–12 very expensive, the rest normal.
        try store.upsertPrices((0..<24).map { h in
            let expensive = h == 10 || h == 11
            return HourPrice(
                hour: today.addingTimeInterval(Double(h) * 3600), area: "NO1", source: "mock", spotOre: expensive ? 200 : 80,
                totalOre: expensive ? 250 : 100, level: expensive ? "VERY_EXPENSIVE" : "NORMAL")
        })
        _ = try await service.currentState()
        return (service, backend, store)
    }

    @Test func runnerLowersLogsAsPrisstyringAndRestoresWhenTurnedOff() async throws {
        let (service, backend, store) = try await makeService()
        let status = try await service.enablePriceControl()
        #expect(try await service.priceControlSettings().comfortTemperature == 21)
        #expect(status.kind == .lowered)
        #expect(status.currentStep?.target == 19)
        let first = try #require(try store.changes(limit: 1).first)
        #expect(first.source == .automation)
        #expect(first.source.displayName == "Prisstyring")
        #expect(first.result == .ok)
        #expect(first.reason?.hasPrefix("Prisstyring: Svært dyrt") == true)
        #expect(try store.changes(limit: 10, source: .automation).count == 1)

        // Next tick in the same step: nothing new is sent.
        clock.advance(300)
        _ = try await service.currentState(force: true)
        #expect(try await service.runPriceControl().kind == .lowered)
        #expect(await backend.appliedChanges.count == 1)

        // Turning it off sets the comfort temperature back.
        let restored = try #require(try await service.disablePriceControl())
        #expect(restored.result == .ok)
        let changes = await backend.appliedChanges
        #expect(changes.map(\.setTemperature) == [19, 21])
        // Only the setpoint is ever sent: never power or mode.
        #expect(changes.allSatisfy { $0.power == nil && $0.mode == nil && $0.fanSpeed == nil })
        #expect(try store.changes(limit: 1).first?.reason == "Prisstyring: slått av – tilbake til vanlig temperatur")
        #expect(try await service.priceControlSettings().enabled == false)
        #expect(try await service.priceControlStatus()?.kind == .off)
    }

    @Test func manualChangeInTheAppPausesTheRunner() async throws {
        let (service, backend, _) = try await makeService()
        try await service.enablePriceControl()
        clock.advance(300)
        _ = try await service.apply(.temperature(22.5), source: .app, reason: "Endret i appen")
        try await service.notePriceControlManualSetpoint(22.5)
        #expect(try await service.priceControlSettings().comfortTemperature == 22.5)
        clock.advance(300)
        _ = try await service.currentState(force: true)
        let status = try await service.runPriceControl()
        #expect(status.kind == .paused)
        #expect(await backend.appliedChanges.map(\.setTemperature) == [19, 22.5])
        // Nothing to restore: the user's own setpoint is in force.
        #expect(try await service.restorePriceControl(reason: "test") == nil)
    }

    @Test func restartReconcilesWithThePlan() async throws {
        let (service, backend, _) = try await makeService()
        try await service.enablePriceControl()  // sends 19 for 10–12
        // The app quits without restoring (crash); it starts again at 12:05, a normal hour.
        clock.advance(2 * 3600 + 300)
        _ = try await service.currentState(force: true)
        let status = try await service.runPriceControl()
        #expect(status.kind == .normal)
        #expect(await backend.appliedChanges.map(\.setTemperature) == [19, 21])
    }

    @Test func failedRestoreKeepsTheLoweredSetpointFromBecomingComfort() async throws {
        let (service, backend, store) = try await makeService()
        try await service.enablePriceControl()  // 19 sent
        try store.recordBlock(until: clock.now.addingTimeInterval(3600), reason: .rateLimited)
        let outcome = try #require(try await service.restorePriceControl(reason: "test"))
        #expect(outcome.result != .ok)
        #expect(await backend.appliedChanges.map(\.setTemperature) == [19])
        // The next tick still knows 19 was the controller's, so the comfort stays 21.
        clock.advance(300)
        try await service.runPriceControl()
        #expect(try await service.priceControlSettings().comfortTemperature == 21)
        // Turning it off and on again does not take 19 as the comfort temperature either.
        try await service.disablePriceControl()
        try await service.enablePriceControl()
        #expect(try await service.priceControlSettings().comfortTemperature == 21)
    }

    @Test func overviewForClaudeIsReadOnlyAndShowsThePlan() async throws {
        let (service, _, _) = try await makeService()
        var overview = try await service.priceControlOverview()
        #expect(overview.settings.enabled == false)
        #expect(overview.appRunning == false)
        #expect(overview.plan.baseSource == .unknown)
        try await service.enablePriceControl()
        overview = try await service.priceControlOverview()
        #expect(overview.appRunning)
        #expect(overview.plan.baseSource == .comfort)
        #expect(overview.plan.changes.first?.target == 19)
        clock.advance(600)
        #expect(try await service.priceControlOverview().appRunning == false)
    }

    // MARK: Change source

    @Test func changeSourceDecodesOldAndNewRows() throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        for source in ["app", "claude", "automation"] {
            try store.pool.write { db in
                try db.execute(
                    sql: "INSERT INTO change_log (ts, source, field, old, new, reason, result) VALUES (?, ?, 'setTemperature', '21', '19', NULL, 'ok')",
                    arguments: [clock.now, source])
            }
        }
        let rows = try store.changes(limit: 10)
        #expect(Set(rows.map(\.source)) == [.app, .claude, .automation])
        #expect(try store.changes(limit: 10, source: .automation).count == 1)
        let json = #"{"timestamp":0,"source":"claude","field":"power","result":"ok"}"#
        #expect(try JSONDecoder().decode(ChangeRecord.self, from: Data(json.utf8)).source == .claude)
        #expect(ChangeSource(rawValue: "automation") == .automation)
    }
}
