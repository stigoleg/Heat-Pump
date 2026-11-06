import Foundation
import Testing
@testable import HeatPumpKit
@testable import MELCloudIntegration

/// MELCloud Classic modes 9/10/11 are heat/dry/cool with i-See (homebridge constants).
@Suite("i-See operation modes 9/10/11")
struct ISeeModeTests {
    func raw(mode: Int) throws -> JSONValue {
        var object = try Fixture.json("device_get_full").object ?? [:]
        object["OperationMode"] = .number(Double(mode))
        return .object(object)
    }

    @Test func cloudModesMapToBaseModeWithISee() {
        #expect(CloudOperationMode(raw: 9) == CloudOperationMode(mode: .heat, iSee: true, raw: 9))
        #expect(CloudOperationMode(raw: 10)?.mode == .dry)
        #expect(CloudOperationMode(raw: 11)?.mode == .cool)
        #expect(CloudOperationMode(raw: 1) == CloudOperationMode(mode: .heat, iSee: false, raw: 1))
        #expect(CloudOperationMode(raw: 8)?.mode == .auto)
        #expect(CloudOperationMode(raw: 0) == nil)
        #expect(CloudOperationMode(raw: 4) == nil)
        #expect(CloudOperationMode(raw: 12) == nil)
    }

    @Test func stateReadsISeeModes() throws {
        for (raw, mode) in [(9, OperationMode.heat), (10, .dry), (11, .cool)] {
            let state = try MELCloudClassicParser.state(listing: nil, get: try self.raw(mode: raw), fetchedAt: Date())
            #expect(state.mode == mode)
            #expect(state.iSee == true)
        }
        let plain = try MELCloudClassicParser.state(listing: nil, get: try raw(mode: 1), fetchedAt: Date())
        #expect(plain.mode == .heat)
        #expect(plain.iSee == false)
    }

    @Test func rawISeeModeIsKeptWhenModeIsNotChanged() throws {
        let body = try MELCloudClassicParser.setAtaPayload(
            ChangeSet(device: .melcloud(1), setTemperature: 22), raw: try raw(mode: 9))
        #expect(body["OperationMode"] == .number(9))
        #expect(body["EffectiveFlags"] == .number(0x04))
        let power = try MELCloudClassicParser.setAtaPayload(ChangeSet(device: .melcloud(1), power: false), raw: try raw(mode: 11))
        #expect(power["OperationMode"] == .number(11))
    }

    @Test func choosingAModeSendsThePlainValue() throws {
        let body = try MELCloudClassicParser.setAtaPayload(ChangeSet(device: .melcloud(1), mode: .cool), raw: try raw(mode: 9))
        #expect(body["OperationMode"] == .number(3))
        #expect(body["EffectiveFlags"] == .number(0x02))
    }

    @Test func responseWithISeeModeIsMerged() throws {
        let merged = MELCloudClassicParser.merged(raw: try raw(mode: 1), response: .object(["OperationMode": .number(10)]))
        #expect(merged["OperationMode"] == .number(10))
        let unknown = MELCloudClassicParser.merged(raw: try raw(mode: 9), response: .object(["OperationMode": .number(0)]))
        #expect(unknown["OperationMode"] == .number(9))
    }

    @Test func serviceWritesWithISeeBase() async throws {
        let clock = TestClock()
        let transport = StubTransport()
        transport.enqueue("ListDevices", body: try Fixture.data("list_devices"))
        var get = try raw(mode: 9).object ?? [:]
        get["DeviceID"] = .number(100_001)
        let getData = try JSONEncoder().encode(JSONValue.object(get))
        transport.enqueue("Device/Get", body: getData)
        transport.enqueue("Device/SetAta", body: getData)
        let credentials = InMemoryCredentialStore(
            credentials: MELCloudCredentials(email: "user@example.com", password: "secret"), contextKey: "KEY")
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MELCloudClassicBackend(credentials: credentials, transport: transport, timeZone: .gmt, rawCache: store, now: clock.provider)
        let service = HeatPumpService(backend: backend, store: store, credentials: credentials, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        let state = try await service.currentState(force: true)
        #expect(state.state?.mode == .heat)
        let outcome = try await service.apply(.temperature(22), source: .app, reason: "test")
        #expect(outcome.result == .ok)
        let sent = transport.requests.last { $0.url?.path.hasSuffix("SetAta") == true }
        let body = try JSONValue.parse(sent?.httpBody ?? Data())
        #expect(body["OperationMode"] == .number(9))
    }
}
