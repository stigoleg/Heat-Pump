import Foundation
import Testing
@testable import HeatPumpKit

@Suite("MELCloud Classic SetAta and HTTP behaviour")
struct ClassicBackendTests {
    @Test func effectiveFlagBits() {
        #expect(ClassicEffectiveFlags.power.rawValue == 0x01)
        #expect(ClassicEffectiveFlags.operationMode.rawValue == 0x02)
        #expect(ClassicEffectiveFlags.setTemperature.rawValue == 0x04)
        #expect(ClassicEffectiveFlags.setFanSpeed.rawValue == 0x08)
        #expect(ClassicEffectiveFlags.vaneVertical.rawValue == 0x10)
        #expect(ClassicEffectiveFlags.vaneHorizontal.rawValue == 0x100)
    }

    @Test func setAtaPayloadSingleField() {
        let body = MELCloudClassicParser.setAtaPayload(ChangeSet(deviceId: 100001, buildingId: 1, setTemperature: 21.5))
        #expect(body["EffectiveFlags"] == .number(0x04))
        #expect(body["SetTemperature"] == .number(21.5))
        #expect(body["DeviceID"] == .number(100001))
        #expect(body["HasPendingCommand"] == .bool(true))
        #expect(body["Power"] == nil)
        #expect(body["OperationMode"] == nil)
    }

    @Test func setAtaPayloadEachFieldAndCombined() {
        let cases: [(ChangeSet, Int, String, JSONValue)] = [
            (ChangeSet(deviceId: 1, buildingId: 1, power: false), 0x01, "Power", .bool(false)),
            (ChangeSet(deviceId: 1, buildingId: 1, mode: .cool), 0x02, "OperationMode", .number(3)),
            (ChangeSet(deviceId: 1, buildingId: 1, fanSpeed: 0), 0x08, "SetFanSpeed", .number(0)),
            (ChangeSet(deviceId: 1, buildingId: 1, vaneVertical: .swing), 0x10, "VaneVertical", .number(7)),
            (ChangeSet(deviceId: 1, buildingId: 1, vaneHorizontal: .split), 0x100, "VaneHorizontal", .number(8)),
        ]
        for (changes, flags, key, value) in cases {
            let body = MELCloudClassicParser.setAtaPayload(changes)
            #expect(body["EffectiveFlags"] == .number(Double(flags)), "\(key)")
            #expect(body[key] == value, "\(key)")
        }
        let combined = MELCloudClassicParser.setAtaPayload(
            ChangeSet(deviceId: 1, buildingId: 1, power: true, mode: .heat, setTemperature: 22))
        #expect(combined["EffectiveFlags"] == .number(0x07))
    }

    @Test func payloadEncodesIntegersWithoutFraction() throws {
        let body = MELCloudClassicParser.setAtaPayload(ChangeSet(deviceId: 100001, buildingId: 1, setTemperature: 21))
        let text = String(decoding: try JSONEncoder().encode(JSONValue.object(body)), as: UTF8.self)
        #expect(text.contains("\"DeviceID\":100001"))
        #expect(text.contains("\"EffectiveFlags\":4"))
    }

    private func makeBackend(_ transport: StubTransport, contextKey: String? = nil) -> MELCloudClassicBackend {
        MELCloudClassicBackend(
            credentials: InMemoryCredentialStore(
                credentials: MELCloudCredentials(email: "user@example.com", password: "secret"), contextKey: contextKey),
            transport: transport, timeZone: .gmt, now: { Date(timeIntervalSince1970: 1_793_872_800) })
    }

    @Test func loginThenFetchState() async throws {
        let transport = StubTransport()
        transport.enqueue("/Login/ClientLogin", body: try Fixture.data("login_success"))
        transport.enqueue("/User/ListDevices", body: try Fixture.data("list_devices"))
        transport.enqueue("/Device/Get", body: try Fixture.data("device_get"))
        let backend = makeBackend(transport)
        let state = try await backend.fetchState(deviceId: 100001)
        #expect(state.setTemperature == 21.5)
        let requests = transport.requests
        #expect(requests.count == 3)
        #expect(requests[1].value(forHTTPHeaderField: "X-MitsContextKey") == "FAKE-CONTEXT-KEY-0001")
        #expect(requests[2].url?.query?.contains("id=100001") == true)
        #expect(requests[2].url?.query?.contains("buildingID=200001") == true)
        let loginBody = try JSONValue.parse(requests[0].httpBody ?? Data())
        #expect(loginBody["Email"]?.string == "user@example.com")
        #expect(loginBody["AppVersion"]?.string == "1.19.1.1")
        #expect(loginBody["Persist"]?.bool == true)
    }

    @Test func unauthorizedTriggersSingleRelogin() async throws {
        let transport = StubTransport()
        transport.enqueue("/User/ListDevices", status: 401, body: Data())
        transport.enqueue("/Login/ClientLogin", body: try Fixture.data("login_success"))
        transport.enqueue("/User/ListDevices", body: try Fixture.data("list_devices"))
        let backend = makeBackend(transport, contextKey: "EXPIRED")
        let devices = try await backend.listDevices()
        #expect(devices.count == 1)
        #expect(transport.requests.map { $0.url!.lastPathComponent } == ["ListDevices", "ClientLogin", "ListDevices"])
    }

    @Test func repeatedUnauthorizedIsNotRetriedForever() async throws {
        let transport = StubTransport()
        transport.enqueue("/User/ListDevices", status: 401, body: Data())
        transport.enqueue("/Login/ClientLogin", body: try Fixture.data("login_success"))
        transport.enqueue("/User/ListDevices", status: 401, body: Data())
        let backend = makeBackend(transport, contextKey: "EXPIRED")
        await #expect(throws: HeatPumpError.unauthorized) { try await backend.listDevices() }
    }

    @Test func tooManyRequestsMapsToRateLimited() async throws {
        let transport = StubTransport()
        transport.enqueue("/User/ListDevices", status: 429, body: Data(), headers: ["Retry-After": "600"])
        let backend = makeBackend(transport, contextKey: "KEY")
        let expected = Date(timeIntervalSince1970: 1_793_872_800 + 600)
        await #expect(throws: HeatPumpError.rateLimited(until: expected)) { try await backend.listDevices() }
    }

    @Test func tooManyRequestsWithoutHeaderBlocksTwoHours() async throws {
        let transport = StubTransport()
        transport.enqueue("/User/ListDevices", status: 429, body: Data())
        let backend = makeBackend(transport, contextKey: "KEY")
        let expected = Date(timeIntervalSince1970: 1_793_872_800 + 7200)
        await #expect(throws: HeatPumpError.rateLimited(until: expected)) { try await backend.listDevices() }
    }

    @Test func loginRefusalAndThrottle() async throws {
        let refused = StubTransport()
        refused.enqueue("/Login/ClientLogin", body: try Fixture.data("login_refused"))
        await #expect(throws: HeatPumpError.invalidCredentials("Feil e-post eller passord")) {
            try await makeBackend(refused).login()
        }
        let throttled = StubTransport()
        throttled.enqueue("/Login/ClientLogin", body: try Fixture.data("login_throttled"))
        let until = Date(timeIntervalSince1970: 1_793_872_800 + 17 * 60)
        await #expect(throws: HeatPumpError.loginThrottled(until: until)) { try await makeBackend(throttled).login() }
    }

    @Test func applySendsSetAta() async throws {
        let transport = StubTransport()
        transport.enqueue("/Device/SetAta", body: try Fixture.data("setata_response"))
        let backend = makeBackend(transport, contextKey: "KEY")
        try await backend.apply(ChangeSet(deviceId: 100001, buildingId: 200001, setTemperature: 21.5))
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        let body = try JSONValue.parse(request.httpBody ?? Data())
        #expect(body["EffectiveFlags"]?.int == 4)
        #expect(body["SetTemperature"]?.double == 21.5)
    }

    @Test func missingCredentials() async {
        let backend = MELCloudClassicBackend(credentials: InMemoryCredentialStore(), transport: StubTransport())
        await #expect(throws: HeatPumpError.missingCredentials) { try await backend.login() }
    }

    @Test func environmentCredentialsTakePrecedence() throws {
        let store = KeychainCredentialStore(
            service: "com.stigole.varmepumpe.tests-unused",
            environment: ["MELCLOUD_EMAIL": "dev@example.com", "MELCLOUD_PASSWORD": "pw"])
        #expect(try store.loadCredentials() == MELCloudCredentials(email: "dev@example.com", password: "pw"))
    }
}
