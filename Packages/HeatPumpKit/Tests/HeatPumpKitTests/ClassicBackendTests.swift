import Foundation
import Testing
@testable import HeatPumpKit
@testable import MELCloudIntegration

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

    @Test func setAtaPayloadSingleFieldKeepsFullObject() throws {
        let raw = try Fixture.json("device_get_full")
        let body = try MELCloudClassicParser.setAtaPayload(
            ChangeSet(deviceId: 100001, buildingId: 1, setTemperature: 21.5), raw: raw)
        #expect(body["EffectiveFlags"] == .number(0x04))
        #expect(body["SetTemperature"] == .number(21.5))
        #expect(body["DeviceID"] == .number(100001))
        #expect(body["HasPendingCommand"] == .bool(true))
        // Unchanged fields go out with their current values, never as defaults.
        #expect(body["Power"] == .bool(true))
        #expect(body["OperationMode"] == .number(1))
        #expect(body["SetFanSpeed"] == .number(0))
        #expect(body["VaneHorizontal"] == .number(3))
        #expect(body["VaneVertical"] == .number(0))
        #expect(body["DefaultHeatingSetTemperature"] == .number(23))
    }

    @Test func setAtaPayloadEachFieldAndCombined() throws {
        let raw = try Fixture.json("device_get_full")
        let cases: [(ChangeSet, Int, String, JSONValue)] = [
            (ChangeSet(deviceId: 1, buildingId: 1, power: false), 0x01, "Power", .bool(false)),
            (ChangeSet(deviceId: 1, buildingId: 1, mode: .cool), 0x02, "OperationMode", .number(3)),
            (ChangeSet(deviceId: 1, buildingId: 1, fanSpeed: 0), 0x08, "SetFanSpeed", .number(0)),
            (ChangeSet(deviceId: 1, buildingId: 1, vaneVertical: .swing), 0x10, "VaneVertical", .number(7)),
            (ChangeSet(deviceId: 1, buildingId: 1, vaneHorizontal: .split), 0x100, "VaneHorizontal", .number(8)),
        ]
        for (changes, flags, key, value) in cases {
            let body = try MELCloudClassicParser.setAtaPayload(changes, raw: raw)
            #expect(body["EffectiveFlags"] == .number(Double(flags)), "\(key)")
            #expect(body[key] == value, "\(key)")
        }
        let combined = try MELCloudClassicParser.setAtaPayload(
            ChangeSet(deviceId: 1, buildingId: 1, power: true, mode: .heat, setTemperature: 22), raw: raw)
        #expect(combined["EffectiveFlags"] == .number(0x07))
    }

    @Test func powerOnlyChangeKeepsSetpointAndMode() throws {
        let raw = try Fixture.json("device_get_full")
        let body = try MELCloudClassicParser.setAtaPayload(ChangeSet(deviceId: 100001, buildingId: 1, power: false), raw: raw)
        #expect(body["EffectiveFlags"] == .number(0x01))
        #expect(body["Power"] == .bool(false))
        #expect(body["SetTemperature"] == .number(22.5))
        #expect(body["OperationMode"] == .number(1))
    }

    @Test func setAtaPayloadRefusesIncompleteBase() throws {
        // A base without the fields MELCloud would otherwise reset is never sent.
        let partial: JSONValue = .object(["DeviceID": .number(1), "SetTemperature": .number(21)])
        #expect(throws: HeatPumpError.self) {
            try MELCloudClassicParser.setAtaPayload(ChangeSet(deviceId: 1, buildingId: 1, setTemperature: 22), raw: partial)
        }
        var invalidMode = try Fixture.json("device_get_full").object ?? [:]
        invalidMode["OperationMode"] = .number(0)
        #expect(throws: HeatPumpError.self) {
            try MELCloudClassicParser.setAtaPayload(
                ChangeSet(deviceId: 1, buildingId: 1, power: true), raw: .object(invalidMode))
        }
        // Choosing a mode in the same change makes it valid.
        let fixed = try MELCloudClassicParser.setAtaPayload(
            ChangeSet(deviceId: 1, buildingId: 1, power: true, mode: .heat), raw: .object(invalidMode))
        #expect(fixed["OperationMode"] == .number(1))
    }

    @Test func partialResponseDoesNotNullMode() throws {
        let raw = try Fixture.json("device_get_full")
        let merged = MELCloudClassicParser.merged(raw: raw, response: try Fixture.json("setata_response_partial"))
        #expect(merged["OperationMode"] == .number(1))
        #expect(merged["Power"] == .bool(true))
        #expect(merged["SetTemperature"] == .number(23))
        let zeroMode = MELCloudClassicParser.merged(raw: raw, response: .object(["OperationMode": .number(0)]))
        #expect(zeroMode["OperationMode"] == .number(1))
        let state = try MELCloudClassicParser.state(listing: nil, get: merged, fetchedAt: Date())
        #expect(state.mode == .heat)
        #expect(state.power)
    }

    @Test func stateModeSkipsInvalidValues() throws {
        var get = try Fixture.json("device_get_full").object ?? [:]
        get["OperationMode"] = .string("3")
        #expect(try MELCloudClassicParser.state(listing: nil, get: .object(get), fetchedAt: Date()).mode == .cool)
        let listing: JSONValue = .object(["DeviceID": .number(100001), "Device": .object(["OperationMode": .number(1)])])
        // Device/Get says 0: the unit has no valid mode, even if the older listing says Varme.
        get["OperationMode"] = .number(0)
        #expect(try MELCloudClassicParser.state(listing: listing, get: .object(get), fetchedAt: Date()).mode == nil)
        // Device/Get without the field: the listing is used.
        get["OperationMode"] = nil
        #expect(try MELCloudClassicParser.state(listing: listing, get: .object(get), fetchedAt: Date()).mode == .heat)
    }

    @Test func payloadEncodesIntegersWithoutFraction() throws {
        let body = try MELCloudClassicParser.setAtaPayload(
            ChangeSet(deviceId: 100001, buildingId: 1, setTemperature: 21), raw: try Fixture.json("device_get_full"))
        let text = String(decoding: try JSONEncoder().encode(JSONValue.object(body)), as: UTF8.self)
        #expect(text.contains("\"DeviceID\":100001"))
        #expect(text.contains("\"EffectiveFlags\":4"))
    }

    private func makeBackend(
        _ transport: StubTransport, contextKey: String? = nil, cache: (any RawDeviceCache)? = nil
    ) -> MELCloudClassicBackend {
        MELCloudClassicBackend(
            credentials: InMemoryCredentialStore(
                credentials: AccountCredentials(email: "user@example.com", password: "secret"), contextKey: contextKey),
            transport: transport, timeZone: .gmt, rawCache: cache, now: { Date(timeIntervalSince1970: 1_793_872_800) })
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

    @Test func applySendsFullObjectAndUsesResponse() async throws {
        let transport = StubTransport()
        transport.enqueue("/User/ListDevices", body: try Fixture.data("list_devices"))
        transport.enqueue("/Device/Get", body: try Fixture.data("device_get_full"))
        transport.enqueue("/Device/SetAta", body: try Fixture.data("setata_response_partial"))
        let backend = makeBackend(transport, contextKey: "KEY")
        _ = try await backend.fetchState(deviceId: 100001)
        let state = try await backend.apply(ChangeSet(deviceId: 100001, buildingId: 200001, setTemperature: 23))
        let request = try #require(transport.requests.last)
        #expect(request.url?.path.hasSuffix("/Device/SetAta") == true)
        let body = try JSONValue.parse(request.httpBody ?? Data())
        #expect(body["EffectiveFlags"]?.int == 4)
        #expect(body["SetTemperature"]?.double == 23)
        #expect(body["Power"]?.bool == true)
        #expect(body["OperationMode"]?.int == 1)
        #expect(body["SetFanSpeed"]?.int == 0)
        #expect(body["VaneHorizontal"]?.int == 3)
        #expect(body["VaneVertical"]?.int == 0)
        #expect(body["HasPendingCommand"]?.bool == true)
        // The partial response (mode/power null) keeps the previous values.
        #expect(state?.mode == .heat)
        #expect(state?.power == true)
        #expect(state?.setTemperature == 23)
        #expect(state?.name == "Stue")
    }

    @Test func applyWithoutDeviceObjectSendsNothing() async throws {
        let transport = StubTransport()
        let backend = makeBackend(transport, contextKey: "KEY")
        await #expect(throws: HeatPumpError.self) {
            _ = try await backend.apply(ChangeSet(deviceId: 100001, buildingId: 200001, setTemperature: 21.5))
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func deviceObjectIsSharedThroughTheCache() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let first = StubTransport()
        first.enqueue("/User/ListDevices", body: try Fixture.data("list_devices"))
        first.enqueue("/Device/Get", body: try Fixture.data("device_get_full"))
        _ = try await makeBackend(first, contextKey: "KEY", cache: store).fetchState(deviceId: 100001)
        // A second process (e.g. the MCP helper) writes without its own Device/Get.
        let second = StubTransport()
        second.enqueue("/Device/SetAta", body: try Fixture.data("setata_response"))
        let other = makeBackend(second, contextKey: "KEY", cache: store)
        #expect(await other.writeBaseFetchedAt(deviceId: 100001) != nil)
        _ = try await other.apply(ChangeSet(deviceId: 100001, buildingId: 200001, power: false))
        let body = try JSONValue.parse(try #require(second.requests.first?.httpBody))
        #expect(body["Power"]?.bool == false)
        #expect(body["OperationMode"]?.int == 1)
        #expect(body["SetTemperature"]?.double == 22.5)
    }

    @Test func missingCredentials() async {
        let backend = MELCloudClassicBackend(credentials: InMemoryCredentialStore(), transport: StubTransport())
        await #expect(throws: HeatPumpError.missingCredentials) { try await backend.login() }
    }

    @Test func environmentCredentialsTakePrecedence() throws {
        let store = KeychainCredentialStore(
            service: "com.stigole.varmepumpe.tests-unused",
            environment: ["MELCLOUD_EMAIL": "dev@example.com", "MELCLOUD_PASSWORD": "pw"], serviceName: "MELCloud")
        #expect(try store.loadCredentials() == AccountCredentials(email: "dev@example.com", password: "pw"))
    }
}
