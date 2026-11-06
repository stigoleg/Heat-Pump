import Foundation
import Synchronization
import Testing
@testable import HeatPumpKit

/// Records sends and serves a configurable budget.
/// One-shot gate a fake send can wait on.
final class Gate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func wait() async { for await _ in stream { return } }
    func open() {
        continuation.yield()
        continuation.finish()
    }
}

final class FakeWriter: Sendable {
    private let state = Mutex<(sent: [[DeviceChange]], budget: WriteBudget, outcome: ChangeResult, nextAllowed: Date?)>(
        ([], WriteBudget(remaining: 12), .ok, nil))

    var sent: [[DeviceChange]] { state.withLock { $0.sent } }
    func setBudget(_ budget: WriteBudget) { state.withLock { $0.budget = budget } }
    func reject(nextAllowed: Date?) { state.withLock { $0.outcome = .rejected; $0.nextAllowed = nextAllowed } }

    var send: @Sendable ([DeviceChange]) async throws -> [ChangeOutcome] {
        { changes in
            self.state.withLock { s in
                s.sent.append(changes)
                return changes.map {
                    ChangeOutcome(
                        result: s.outcome, message: s.outcome == .ok ? "Sendt" : "Not sent: Too many changes", field: $0.field,
                        nextAllowed: s.nextAllowed)
                }
            }
        }
    }
    var budget: @Sendable () async throws -> WriteBudget { { self.state.withLock { $0.budget } } }
}

@MainActor
@Suite("Auto-send debouncer")
struct ChangeDebouncerTests {
    let clock = TestClock()
    /// Never fires on its own; tests call `flush()`.
    let manual: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }

    func make(_ writer: FakeWriter, sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil, delay: TimeInterval = 2) -> ChangeDebouncer {
        let debouncer = ChangeDebouncer(
            delay: delay, send: writer.send, budget: writer.budget, sleep: sleep ?? manual, now: clock.provider)
        debouncer.updateLive(makeState(at: clock.now, set: 21))
        return debouncer
    }

    @Test func editsAreCoalescedIntoOneSend() async {
        let writer = FakeWriter()
        let d = make(writer)
        d.edit(.temperature(22))
        d.edit(.temperature(22.5))
        d.edit(.fanSpeed(3))
        #expect(d.status == .edited)
        await d.flush()
        #expect(writer.sent == [[.temperature(22.5), .fanSpeed(3)]])
        #expect(d.status == .sent)
        #expect(!d.hasDraft)
    }

    @Test func revertingDropsTheField() async {
        let writer = FakeWriter()
        let d = make(writer)
        d.edit(.temperature(22))
        d.edit(.fanSpeed(2))
        d.edit(.temperature(21))  // back to the live value
        await d.flush()
        #expect(writer.sent == [[.fanSpeed(2)]])

        let other = make(FakeWriter())
        other.edit(.temperature(22))
        other.edit(.temperature(21))
        #expect(!other.hasDraft)
        #expect(other.status == .idle)
    }

    @Test func timerSendsAfterTheLastEdit() async throws {
        let writer = FakeWriter()
        let d = make(writer, sleep: { try await Task.sleep(for: .seconds($0)) }, delay: 0.05)
        d.edit(.temperature(22), commit: false)  // dragging: no timer
        try await Task.sleep(for: .milliseconds(150))
        #expect(writer.sent.isEmpty)
        d.commit()
        d.edit(.temperature(22.5))
        for _ in 0..<40 where writer.sent.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(writer.sent == [[.temperature(22.5)]])
    }

    @Test func exhaustedBudgetKeepsTheDraftWaiting() async {
        let writer = FakeWriter()
        writer.setBudget(WriteBudget(remaining: 0, nextAllowed: clock.now.addingTimeInterval(600)))
        let d = make(writer)
        d.edit(.temperature(23))
        await d.flush()
        #expect(writer.sent.isEmpty)
        #expect(d.hasDraft)
        guard case .waiting(let reason, let retry) = d.status else { Issue.record("expected waiting"); return }
        #expect(reason.contains("max 12"))
        #expect(retry == clock.now.addingTimeInterval(600))
        #expect(d.remainingThisHour == 0)
        // Once allowed again the draft goes out.
        writer.setBudget(WriteBudget(remaining: 1))
        await d.flush()
        #expect(writer.sent == [[.temperature(23)]])
    }

    @Test func spacingWaitsInsteadOfSending() async {
        let writer = FakeWriter()
        writer.setBudget(WriteBudget(remaining: 8, nextAllowed: clock.now.addingTimeInterval(3)))
        let d = make(writer)
        d.edit(.power(false))
        await d.flush()
        #expect(writer.sent.isEmpty)
        guard case .waiting = d.status else { Issue.record("expected waiting"); return }
        clock.advance(4)
        writer.setBudget(WriteBudget(remaining: 8))
        await d.flush()
        #expect(writer.sent == [[.power(false)]])
    }

    @Test func rejectionWithRetryRestoresDraft() async {
        let writer = FakeWriter()
        writer.reject(nextAllowed: clock.now.addingTimeInterval(60))
        let d = make(writer)
        d.edit(.fanSpeed(4))
        await d.flush()
        #expect(d.hasDraft)
        guard case .waiting = d.status else { Issue.record("expected waiting"); return }
    }

    @Test func confirmationAfterTheUnitReports() async {
        let writer = FakeWriter()
        let d = make(writer)
        d.edit(.temperature(22))
        await d.flush()
        var pending = makeState(at: clock.now, set: 22)
        pending.hasPendingCommand = true
        d.updateLive(pending)
        #expect(d.status == .sent)
        clock.advance(30)
        d.updateLive(makeState(at: clock.now, set: 22))
        #expect(d.status == .confirmed)
    }

    @Test func powerOnWithUnknownModeAddsHeat() async {
        let writer = FakeWriter()
        let d = make(writer)
        var off = makeState(at: clock.now, power: false)
        off.mode = nil
        d.updateLive(off)
        d.edit(.power(true))
        await d.flush()
        #expect(writer.sent == [[.power(true), .mode(.heat)]])
    }

    @Test func editsDuringASendAreBasedOnWhatWasSent() async {
        let writer = FakeWriter()
        let gate = Gate()
        let gatedSend = writer.send
        let d = ChangeDebouncer(
            delay: 2, send: { changes in
                await gate.wait()
                return try await gatedSend(changes)
            }, budget: writer.budget, sleep: manual, now: clock.provider)
        d.updateLive(makeState(at: clock.now, set: 21))
        d.edit(.temperature(22))
        let sending = Task { await d.flush() }
        while d.status != .sending { await Task.yield() }
        // The controls keep showing what is being sent.
        #expect(d.displayed?.setTemperature == 22)
        // Back to 21 differs from what is being sent, so it is a real edit.
        d.edit(.temperature(21))
        #expect(d.hasDraft)
        d.edit(.temperature(21.5))
        #expect(d.displayed?.setTemperature == 21.5)
        gate.open()
        await sending.value
        #expect(d.hasDraft)
        #expect(d.status == .edited)
        await d.flush()
        #expect(writer.sent == [[.temperature(22)], [.temperature(21.5)]])
    }

    @Test func editEqualToInFlightValueIsDropped() async {
        let writer = FakeWriter()
        let gate = Gate()
        let gatedSend = writer.send
        let d = ChangeDebouncer(
            delay: 2, send: { changes in
                await gate.wait()
                return try await gatedSend(changes)
            }, budget: writer.budget, sleep: manual, now: clock.provider)
        d.updateLive(makeState(at: clock.now, set: 21))
        d.edit(.temperature(22))
        let sending = Task { await d.flush() }
        while d.status != .sending { await Task.yield() }
        d.edit(.temperature(22))
        #expect(!d.hasDraft)
        gate.open()
        await sending.value
        #expect(writer.sent == [[.temperature(22)]])
    }

    @Test func impliedModeGoesWhenPowerIsTurnedBack() async {
        let writer = FakeWriter()
        let d = make(writer)
        var off = makeState(at: clock.now, power: false)
        off.mode = nil
        d.updateLive(off)
        #expect(d.displayedMode == nil)
        d.edit(.power(true))
        #expect(d.displayedMode == .heat)
        d.edit(.power(false))
        #expect(!d.hasDraft)
        #expect(d.displayedMode == nil)
        await d.flush()
        #expect(writer.sent.isEmpty)
    }

    @Test func dragHasALongFallbackTimer() async {
        let delays = Mutex<[TimeInterval]>([])
        let writer = FakeWriter()
        let d = make(writer, sleep: { seconds in
            delays.withLock { $0.append(seconds) }
            try await Task.sleep(for: .seconds(3600))
        })
        d.edit(.temperature(22), commit: false)
        d.edit(.temperature(22.5))
        for _ in 0..<50 where delays.withLock({ $0.count }) < 2 { await Task.yield() }
        #expect(delays.withLock { $0 } == [ChangeDebouncer.dragFallback, 2])
    }

    @Test func modeSwitchClampsSetpoint() async {
        let writer = FakeWriter()
        let d = make(writer)
        d.updateLive(makeState(at: clock.now, set: 12))
        d.edit(.mode(.cool))
        await d.flush()
        #expect(writer.sent == [[.mode(.cool), .temperature(16)]])
    }
}

@Suite("Write budget")
struct WriteBudgetTests {
    @Test func budgetReflectsSpacingAndHourlyLimit() async throws {
        let clock = TestClock()
        let store = try HistoryStore(path: temporaryDatabasePath())
        let service = HeatPumpService(
            backend: CountingBackend(now: clock.provider), store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        _ = try await service.currentState()
        #expect(try await service.writeBudget() == WriteBudget(remaining: 12))
        #expect(try await service.apply(.fanSpeed(2), source: .app, reason: "x").result == .ok)
        let afterOne = try await service.writeBudget()
        #expect(afterOne.remaining == 11)
        #expect(afterOne.nextAllowed == clock.now.addingTimeInterval(5))
        for i in 0..<11 {
            clock.advance(6)
            #expect(try await service.apply(.fanSpeed(i % 2 == 0 ? 3 : 2), source: .app, reason: "x").result == .ok)
        }
        clock.advance(6)
        let exhausted = try await service.writeBudget()
        #expect(exhausted.remaining == 0)
        #expect(exhausted.nextAllowed != nil)
    }
}
