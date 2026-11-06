import Foundation
import Testing
@testable import HeatPumpKit
@testable import DemoIntegration

@Suite("App support")
struct AppSupportTests {
    let now = Date(timeIntervalSince1970: 1_793_872_800)

    @Test func signInClearsCredentialStopAndFetches() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let creds = InMemoryCredentialStore()
        let svc = HeatPumpService(
            backend: backend, store: try HistoryStore(path: temporaryDatabasePath()), credentials: creds,
            timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        #expect(await !svc.hasCredentials())
        #expect(try await svc.currentState().needsLogin)
        let result = try await svc.signIn(MELCloudCredentials(email: "a@b.no", password: "pw"))
        #expect(result.refreshed && !result.needsLogin)
        #expect(await svc.hasCredentials())
        try await svc.signOut()
        #expect(await !svc.hasCredentials())
    }

    @Test func maintenanceNextDue() async throws {
        let clock = TestClock()
        let svc = HeatPumpService(
            backend: CountingBackend(now: clock.provider), store: try HistoryStore(path: temporaryDatabasePath()),
            timeZone: .gmt, now: clock.provider)
        let done = clock.now.addingTimeInterval(-3 * 86_400)
        try await svc.recordMaintenance(kind: .airFilter, date: done)
        let status = try await svc.maintenanceStatus()
        #expect(status.first { $0.kind == .airFilter }?.nextDue == done.addingTimeInterval(14 * 86_400))
        #expect(status.first { $0.kind == .deodorizingFilter }?.nextDue == nil)
    }

    @Test func changeRecordDisplay() {
        let record = ChangeRecord(
            timestamp: now, source: .claude, field: "setTemperature", oldValue: "21.0", newValue: "21.5",
            reason: "x", result: .ok)
        #expect(record.displaySummary == "Change target temperature to 21,5 °C")
        #expect(record.oldDisplayValue == "21,0 °C")
        let mode = ChangeRecord(timestamp: now, source: .app, field: "mode", oldValue: "heat", newValue: "cool", reason: nil, result: .rejected)
        #expect(mode.newDisplayValue == "Cool")
        #expect(mode.oldDisplayValue == "Heat")
        let unknown = ChangeRecord(timestamp: now, source: .app, field: "weird", oldValue: nil, newValue: "1", reason: nil, result: .ok)
        #expect(unknown.displaySummary == "weird: 1")
        for change: DeviceChange in [.power(false), .fanSpeed(0), .vaneVertical(.swing), .vaneHorizontal(.split), .mode(.dry)] {
            #expect(DeviceChange(field: change.field, value: change.valueDescription) == change)
        }
    }

    @Test func notificationPlanner() {
        let old = ErrorLogEntry(deviceId: 1, start: now.addingTimeInterval(-10 * 86_400), message: "Gammel")
        // First run: baseline only.
        var (planned, memory) = NotificationPlanner.plan(
            state: makeState(at: now), errorEvents: [old], maintenance: [], memory: NotificationMemory(), now: now)
        #expect(planned.isEmpty)
        #expect(memory.lastErrorEventStart == old.start)

        let fresh = ErrorLogEntry(deviceId: 1, start: now.addingTimeInterval(-60), message: "Ny feil")
        (planned, memory) = NotificationPlanner.plan(
            state: makeState(at: now), errorEvents: [old, fresh], maintenance: [], memory: memory, now: now)
        #expect(planned.map(\.title) == ["New error in the error log"])
        (planned, memory) = NotificationPlanner.plan(
            state: makeState(at: now), errorEvents: [old, fresh], maintenance: [], memory: memory, now: now)
        #expect(planned.isEmpty)

        // Active error once, again after it clears and returns.
        let failing = makeState(at: now, hasError: true, errorCode: 5101)
        (planned, memory) = NotificationPlanner.plan(state: failing, errorEvents: [], maintenance: [], memory: memory, now: now)
        #expect(planned.first?.body.contains("5101") == true)
        (planned, memory) = NotificationPlanner.plan(state: failing, errorEvents: [], maintenance: [], memory: memory, now: now)
        #expect(planned.isEmpty)
        (planned, memory) = NotificationPlanner.plan(state: makeState(at: now), errorEvents: [], maintenance: [], memory: memory, now: now)
        (planned, memory) = NotificationPlanner.plan(state: failing, errorEvents: [], maintenance: [], memory: memory, now: now)
        #expect(planned.count == 1)

        // Overdue filter at most once per day.
        let overdue = [MaintenanceStatus(kind: .airFilter, displayName: "Luftfilter", status: "overdue")]
        (planned, memory) = NotificationPlanner.plan(state: nil, errorEvents: [], maintenance: overdue, memory: memory, now: now)
        #expect(planned.map(\.id) == ["filter-overdue"])
        (planned, memory) = NotificationPlanner.plan(
            state: nil, errorEvents: [], maintenance: overdue, memory: memory, now: now.addingTimeInterval(3600))
        #expect(planned.isEmpty)
        (planned, _) = NotificationPlanner.plan(
            state: nil, errorEvents: [], maintenance: overdue, memory: memory, now: now.addingTimeInterval(86_401))
        #expect(planned.count == 1)
    }
}

@Suite("Control settings")
struct ControlSettingsTests {
    @Test func diffAndClamp() {
        let state = makeState(at: Date(), mode: .heat, set: 12)
        let base = ControlSettings(state)
        var edited = base
        #expect(edited.changes(from: base).isEmpty)
        edited.mode = .cool
        edited.clampSetpoint(to: state.limits)
        #expect(edited.setTemperature == 16)
        edited.vaneHorizontal = .swing
        #expect(edited.changes(from: base) == [.mode(.cool), .temperature(16), .vaneHorizontal(.swing)])
    }
}
