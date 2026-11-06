import Foundation
import Testing
@testable import HeatPumpKit

/// Regression tests for the round-3 SetAta bug: MELCloud Classic resets every field that is
/// missing from the body (power off, mode 0), so writes must carry the full, fresh device object.
@Suite("Service writes through MELCloud Classic")
struct SetAtaServiceTests {
    private func makeService(_ transport: StubTransport, clock: TestClock) throws -> (HeatPumpService, HistoryStore) {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let credentials = InMemoryCredentialStore(
            credentials: MELCloudCredentials(email: "user@example.com", password: "secret"), contextKey: "KEY")
        let backend = MELCloudClassicBackend(
            credentials: credentials, transport: transport, timeZone: .gmt, rawCache: store, now: clock.provider)
        let service = HeatPumpService(
            backend: backend, store: store, credentials: credentials, timeZone: .gmt, now: clock.provider,
            sleep: clock.sleeper)
        return (service, store)
    }

    private func paths(_ transport: StubTransport) -> [String] {
        transport.requests.compactMap { $0.url?.lastPathComponent }
    }

    @Test func staleDeviceObjectIsRefetchedAndResponseBecomesSnapshot() async throws {
        let clock = TestClock()
        let transport = StubTransport()
        transport.enqueue("/User/ListDevices", body: try Fixture.data("list_devices"))
        transport.enqueue("/Device/Get", body: try Fixture.data("device_get_full"))
        let (service, store) = try makeService(transport, clock: clock)
        _ = try await service.currentState()

        clock.advance(120)
        transport.enqueue("/Device/Get", body: try Fixture.data("device_get_full"))
        transport.enqueue("/Device/SetAta", body: try Fixture.data("setata_response_partial"))
        let outcome = try await service.apply(.temperature(23), source: .app, reason: "test")
        #expect(outcome.result == .ok)
        #expect(paths(transport).suffix(2) == ["Get", "SetAta"])

        let body = try JSONValue.parse(try #require(transport.requests.last?.httpBody))
        #expect(body["Power"]?.bool == true)
        #expect(body["OperationMode"]?.int == 1)
        #expect(body["SetTemperature"]?.double == 23)
        #expect(body["EffectiveFlags"]?.int == 4)

        let latest = try #require(try store.latestSnapshot()?.state)
        #expect(latest.mode == .heat)
        #expect(latest.power)
        #expect(latest.setTemperature == 23)
        #expect(latest.hasPendingCommand)
    }

    @Test func freshResponseIsBaseForTheNextWrite() async throws {
        let clock = TestClock()
        let transport = StubTransport()
        transport.enqueue("/User/ListDevices", body: try Fixture.data("list_devices"))
        transport.enqueue("/Device/Get", body: try Fixture.data("device_get_full"))
        let (service, _) = try makeService(transport, clock: clock)
        _ = try await service.currentState()
        transport.enqueue("/Device/SetAta", body: try Fixture.data("setata_response_partial"))
        #expect(try await service.apply(.temperature(23), source: .app, reason: "a").result == .ok)

        clock.advance(30)
        transport.enqueue("/Device/SetAta", body: try Fixture.data("setata_response_partial"))
        #expect(try await service.apply(.power(false), source: .app, reason: "b").result == .ok)
        // No extra Device/Get: the SetAta response refreshed the device object.
        #expect(paths(transport) == ["ListDevices", "Get", "SetAta", "SetAta"])
        let body = try JSONValue.parse(try #require(transport.requests.last?.httpBody))
        #expect(body["Power"]?.bool == false)
        #expect(body["SetTemperature"]?.double == 23)
        #expect(body["OperationMode"]?.int == 1)
        #expect(body["EffectiveFlags"]?.int == 1)
    }

    @Test func throttledRefreshRejectsInsteadOfSendingPartialBody() async throws {
        let clock = TestClock()
        let transport = StubTransport()
        transport.enqueue("/User/ListDevices", body: try Fixture.data("list_devices"))
        transport.enqueue("/Device/Get", body: try Fixture.data("device_get_full"))
        let (service, store) = try makeService(transport, clock: clock)
        _ = try await service.currentState()

        // A failed refresh uses the 60 s slot without renewing the device object.
        clock.advance(61)
        transport.enqueue("/Device/Get", status: 500, body: Data())
        _ = try await service.currentState(force: true)
        clock.advance(10)

        let outcome = try await service.apply(.temperature(23), source: .app, reason: "test")
        #expect(outcome.result == .rejected)
        #expect(outcome.message.contains("fresh status"))
        #expect(!paths(transport).contains("SetAta"))
        #expect(try store.changes(limit: 1).first?.result == .rejected)
    }

    @Test func temperatureHistoryFallsBackToSnapshots() async throws {
        let clock = TestClock()
        let store = try HistoryStore(path: temporaryDatabasePath())
        let service = HeatPumpService(backend: MockBackend(timeZone: .gmt, now: clock.provider), store: store, timeZone: .gmt, now: clock.provider)
        for i in 0..<3 {
            try store.insertSnapshot(makeState(at: clock.now.addingTimeInterval(Double(i) * 600), room: 20 + Double(i)))
        }
        let empty = try await service.temperatureHistory(from: clock.now.addingTimeInterval(-3600), to: clock.now.addingTimeInterval(3600))
        #expect(!empty.fromMELCloud)
        #expect(empty.points.map(\.room) == [20, 21, 22])

        try store.upsertTemperaturePoints([TemperaturePoint(timestamp: clock.now.addingTimeInterval(300), room: 19)], deviceId: 1)
        let mixed = try await service.temperatureHistory(from: clock.now.addingTimeInterval(-3600), to: clock.now.addingTimeInterval(3600))
        #expect(mixed.fromMELCloud)
        #expect(mixed.points.map(\.room) == [19, 21, 22])
    }

    /// Counts approval requests.
    final class CountingApprover: ChangeApprover, @unchecked Sendable {
        private let lock = NSLock()
        private var _asked = 0
        var asked: Int { lock.withLock { _asked } }
        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            lock.withLock { _asked += 1 }
            return .approved
        }
    }

    private func invalidModeDevice() throws -> Data {
        var get = try Fixture.json("device_get_full").object ?? [:]
        get["OperationMode"] = .number(0)
        get["Power"] = .bool(false)
        return try JSONEncoder().encode(JSONValue.object(get))
    }

    @Test func locallyRefusedWritesUseNoBudgetAndNoApproval() async throws {
        let clock = TestClock()
        let transport = StubTransport()
        transport.enqueue("/User/ListDevices", body: try Fixture.data("list_devices"))
        transport.enqueue("/Device/Get", body: try invalidModeDevice())
        let (service, store) = try makeService(transport, clock: clock)
        _ = try await service.currentState()
        #expect(try store.latestSnapshot()?.state.mode == nil)

        let outcome = try await service.apply(.temperature(23), source: .app, reason: "x")
        #expect(outcome.result == .rejected)
        #expect(outcome.message.contains("no valid mode"))
        let approver = CountingApprover()
        let viaClaude = try await service.applyWithApproval([.power(true)], source: .claude, reason: "y", approver: approver)
        #expect(viaClaude.allSatisfy { $0.result == .rejected })
        #expect(approver.asked == 0)
        #expect(!paths(transport).contains("SetAta"))
        #expect(try await service.writeBudget().remaining == 12)

        // Choosing a mode together with the change is allowed.
        transport.enqueue("/Device/SetAta", body: try Fixture.data("setata_response"))
        let fixed = try await service.apply([.power(true), .mode(.heat)], source: .app, reason: "z")
        #expect(fixed.allSatisfy { $0.result == .ok })
        let body = try JSONValue.parse(try #require(transport.requests.last?.httpBody))
        #expect(body["OperationMode"]?.int == 1)
        #expect(body["Power"]?.bool == true)
    }

    @Test func missingObjectAfterRefreshIsRejectedNotCounted() async throws {
        let clock = TestClock()
        let transport = StubTransport()
        transport.enqueue("/User/ListDevices", body: try Fixture.data("list_devices"))
        transport.enqueue("/Device/Get", body: try Fixture.data("device_get_full"))
        let (service, store) = try makeService(transport, clock: clock)
        _ = try await service.currentState()
        clock.advance(120)
        // The refresh answers with something that is not a device object.
        transport.enqueue("/Device/Get", body: Data("[]".utf8))
        let outcome = try await service.apply(.temperature(23), source: .app, reason: "x")
        #expect(outcome.result == .rejected)
        #expect(!paths(transport).contains("SetAta"))
        #expect(try store.changes(limit: 1).first?.result == .rejected)
        #expect(try await service.writeBudget().remaining == 12)
    }
}
