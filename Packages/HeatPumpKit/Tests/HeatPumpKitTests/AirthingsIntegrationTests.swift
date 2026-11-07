import Foundation
import Testing
@testable import AirthingsIntegration
@testable import DemoIntegration
@testable import HeatPumpKit
@testable import Integrations

/// The Airthings Consumer API through `StubTransport`, from redacted fixtures in the documented
/// shapes (`Fixtures/airthings_*.json`), and its request budget through the hub.
@Suite("Airthings integration")
struct AirthingsIntegrationTests {
    let clock = TestClock()
    let values = CredentialValues(["clientId": "CLIENT-ID", "clientSecret": "CLIENT-SECRET"])
    let account = "00000000-0000-4000-8000-000000000001"
    let cellar = DeviceKey(integration: AirthingsIntegration.id, nativeId: "2930000001")
    let living = DeviceKey(integration: AirthingsIntegration.id, nativeId: "2960000002")

    func connection(_ transport: StubTransport, values: CredentialValues? = nil) -> AirthingsConnection {
        let values = values ?? self.values
        return AirthingsConnection(credentials: { values }, transport: transport, now: clock.provider)
    }

    /// A transport that answers the token and the account once.
    func signedIn() throws -> StubTransport {
        let transport = StubTransport()
        transport.enqueue("token", body: try Fixture.data("airthings_token"))
        transport.enqueue("accounts", body: try Fixture.data("airthings_accounts"))
        return transport
    }

    func query(_ request: URLRequest?) -> [URLQueryItem] {
        request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    }

    // MARK: Integration

    @Test func isInTheCatalogWithClientCredentials() throws {
        #expect(IntegrationCatalog.all.filter { $0.id == AirthingsIntegration.id }.count == 1)
        let integration = AirthingsIntegration()
        #expect(integration.credentialFields.map(\.kind) == [.clientId, .clientSecret])
        #expect(integration.credentialFields.map(\.isSecret) == [false, true])
        #expect(integration.credentialFields[1].helpURL?.absoluteString == "https://consumer-api-doc.airthings.com/dashboard")
        #expect(integration.credentialFields[1].help?.contains("client ID") == true)
        #expect(integration.credentialMapping.items.map(\.account) == ["airthings/clientId", "airthings/clientSecret"])
        #expect(integration.rateLimitPolicy.changeBudget.maxChangesPerHour == 0)
        #expect(integration.knowledge.names == ["air-quality"])
        let store = try HistoryStore(path: temporaryDatabasePath())
        #expect(throws: HeatPumpError.missingCredentials) {
            try integration.makeConnection(IntegrationContext(environment: [:], store: store))
        }
        #expect(connection(StubTransport()).capabilities == [.airQuality, .airQualityLog])
    }

    // MARK: Token

    @Test func theTokenIsRequestedWithAJSONBodyAndKeptUntilItExpires() async throws {
        let transport = try signedIn()
        transport.enqueue("devices", body: try Fixture.data("airthings_devices"))
        transport.enqueue("devices", body: try Fixture.data("airthings_devices"))
        let client = connection(transport)
        _ = try await client.listDevices()
        _ = try await client.listDevices()
        let token = try #require(transport.requests.first)
        #expect(token.url?.absoluteString == "https://accounts-api.airthings.com/v1/token")
        #expect(token.httpMethod == "POST")
        #expect(token.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONValue.parse(try #require(token.httpBody))
        #expect(body["grant_type"]?.string == "client_credentials")
        #expect(body["client_id"]?.string == "CLIENT-ID")
        #expect(body["client_secret"]?.string == "CLIENT-SECRET")
        #expect(body["scope"]?.array?.compactMap(\.string) == ["read:device:current_values"])
        // One token, one account lookup, two listings; the secret is in no URL.
        #expect(transport.requests.map { $0.url?.lastPathComponent ?? "" } == ["token", "accounts", "devices", "devices"])
        #expect(transport.requests.allSatisfy { !($0.url?.absoluteString.contains("SECRET") ?? true) })
        #expect(transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer REDACTED-ACCESS-TOKEN")

        // Expired (10800 s less a minute): a new token.
        clock.advance(10_800)
        transport.enqueue("token", body: try Fixture.data("airthings_token"))
        transport.enqueue("devices", body: try Fixture.data("airthings_devices"))
        _ = try await client.listDevices()
        #expect(transport.requests.suffix(2).map { $0.url?.lastPathComponent ?? "" } == ["token", "devices"])
    }

    @Test func refusedClientValuesAreInvalidCredentialsAndNothingIsSentWithout() async throws {
        let transport = StubTransport()
        transport.enqueue("token", status: 400, body: try Fixture.data("airthings_invalid_client"))
        await #expect(throws: HeatPumpError.invalidCredentials("invalid_grant")) { try await connection(transport).login() }
        #expect(transport.requests.count == 1)

        let none = StubTransport()
        await #expect(throws: HeatPumpError.missingCredentials) {
            try await connection(none, values: CredentialValues(["clientId": "CLIENT-ID"])).listDevices()
        }
        #expect(none.requests.isEmpty)
    }

    @Test func anExpiredTokenIsRenewedOnceThenUnauthorized() async throws {
        let transport = try signedIn()
        transport.enqueue("devices", status: 401, body: Data(#"{"message":"Unauthorized"}"#.utf8))
        transport.enqueue("token", body: try Fixture.data("airthings_token"))
        transport.enqueue("devices", body: try Fixture.data("airthings_devices"))
        let client = connection(transport)
        #expect(try await client.listDevices().count == 3)
        #expect(transport.requests.map { $0.url?.lastPathComponent ?? "" } == ["token", "accounts", "devices", "token", "devices"])

        transport.enqueue("devices", status: 401, body: Data())
        transport.enqueue("token", body: try Fixture.data("airthings_token"))
        transport.enqueue("devices", status: 401, body: Data())
        await #expect(throws: HeatPumpError.unauthorized) { try await client.listDevices() }
        #expect(transport.requests.count == 8)
    }

    // MARK: Reads

    @Test func listingSkipsHubsAndThePurifier() async throws {
        let transport = try signedIn()
        transport.enqueue("devices", body: try Fixture.data("airthings_devices"))
        let client = connection(transport)
        let devices = try await client.listDevices()
        #expect(devices.map(\.key.rawValue) == ["airthings:2930000001", "airthings:2960000002", "airthings:2920000003"])
        #expect(devices.map(\.name) == ["Kjeller", "Stue", "2920000003"])
        #expect(devices.allSatisfy { $0.kind == .airQualitySensor })
        #expect(devices[0].metadata == ["type": "WAVE_PLUS", "home": "Hjemme"])
        #expect(devices[1].metadata == ["type": "VIEW_PLUS"])
        let recent = await client.recentListing()
        #expect(recent?.count == 3, "\(String(describing: recent))")
        clock.advance(3601)
        #expect(await client.recentListing() == nil)
        #expect(transport.requests[2].url?.path == "/v1/accounts/\(account)/devices")
    }

    @Test func newestValuesForSeveralSensorsInOneRequest() async throws {
        let transport = try signedIn()
        transport.enqueue("sensors", body: try Fixture.data("airthings_sensors"))
        let readings = try await connection(transport).fetchLatest(devices: [cellar, living])
        let request = try #require(transport.requests.last)
        #expect(request.url?.path == "/v1/accounts/\(account)/sensors")
        #expect(query(request).filter { $0.name == "sn" }.map(\.value) == ["2930000001", "2960000002"])
        #expect(query(request).first { $0.name == "unit" }?.value == "metric")

        // The sensor without any value is left out; nulls and unknown types are skipped.
        #expect(readings.map(\.device) == [cellar, living])
        let first = readings[0]
        #expect(first.values == [.radonShortTerm: 84, .temperature: 19.6, .humidity: 41, .pressure: 1003.4, .co2: 1150, .voc: 112, .battery: 78])
        #expect(first.recorded == Date(timeIntervalSince1970: 1_793_872_500))  // 09:55 UTC
        #expect(readings[1].values == [.pm25: 4, .pm1: 3])
        #expect(readings[1].recorded == nil)
    }

    @Test func historyIsOneHourlyPageInColumns() async throws {
        let transport = try signedIn()
        transport.enqueue("samples", body: try Fixture.data("airthings_samples"))
        let range = DateInterval(start: clock.now.addingTimeInterval(-3 * 3600), end: clock.now)
        let hours = try await connection(transport).fetchHourly(device: cellar, range: range)
        let request = try #require(transport.requests.last)
        #expect(request.url?.path == "/v1/accounts/\(account)/devices/2930000001/samples")
        let items = Dictionary(uniqueKeysWithValues: query(request).map { ($0.name, $0.value ?? "") })
        #expect(items["resolution"] == "HOUR")
        #expect(items["pageSize"] == "5000")
        #expect(items["start"] == "2026-11-05T07:00:00Z")
        #expect(items["end"] == "2026-11-05T10:00:00Z")
        #expect(hours.count == 3)
        #expect(hours[0].hour == range.start)
        #expect(hours[0].values[.temperature] == 19.4)
        #expect(hours[2].values[.temperature] == nil)  // null inside a column
        #expect(hours[2].values[.co2] == 1150)
        #expect(hours.allSatisfy { $0.values[.pm25] == nil })  // null column
        #expect(AirthingsAPI.hours(from: try JSONValue.parse(Data(#"{"data":{"time":[]},"cursor":null}"#.utf8))).isEmpty)
    }

    @Test func thresholdsKeepKnownRatingsAndTheCacheAge() async throws {
        let transport = try signedIn()
        transport.enqueue("thresholds", body: try Fixture.data("airthings_thresholds"), headers: ["Cache-Control": "private, max-age=86400"])
        let thresholds = try #require(try await connection(transport).fetchThresholds(device: cellar))
        #expect(transport.requests.last?.url?.path == "/v1/accounts/\(account)/devices/2930000001/thresholds")
        #expect(thresholds.maxAge == 86_400)
        #expect(thresholds.ranges[.radonShortTerm]?.count == 3)
        #expect(thresholds.ranges[.co2]?.count == 3)  // SEVERE is unknown and left out
        #expect(thresholds.level(.co2, 1150) == .fair)
        #expect(thresholds.level(.radonLongTerm, 150) == .fair)  // follows the short-term ranges
        #expect(AirthingsAPI.maxAge("no-cache") == nil)
    }

    // MARK: Errors and limits

    @Test func tooManyRequestsBlockForAsLongAsTheAnswerSays() async throws {
        let transport = try signedIn()
        let client = connection(transport)
        transport.enqueue("sensors", status: 429, body: try Fixture.data("airthings_error"), headers: ["X-RateLimit-Retry-After": "900"])
        await #expect(throws: HeatPumpError.rateLimited(until: clock.now.addingTimeInterval(900))) {
            try await client.fetchLatest(devices: [cellar])
        }
        transport.enqueue("sensors", status: 429, body: Data())
        await #expect(throws: HeatPumpError.rateLimited(until: clock.now.addingTimeInterval(AirthingsAPI.rateLimitPause))) {
            try await client.fetchLatest(devices: [cellar])
        }
        transport.enqueue("sensors", status: 403, body: try Fixture.data("airthings_error"))
        await #expect(throws: HeatPumpError.deviceNotFound) { try await client.fetchLatest(devices: [cellar]) }
        transport.enqueue("sensors", status: 400, body: Data(#"{"message":"Invalid unit"}"#.utf8))
        await #expect(throws: HeatPumpError.server("Invalid unit")) { try await client.fetchLatest(devices: [cellar]) }
        transport.enqueue("sensors", status: 500, body: Data())
        await #expect(throws: HeatPumpError.http(status: 500)) { try await client.fetchLatest(devices: [cellar]) }
        transport.enqueue("sensors", body: Data("not json".utf8))
        await #expect(throws: HeatPumpError.decoding("invalid JSON")) { try await client.fetchLatest(devices: [cellar]) }
        // One token and one account lookup for all of them.
        #expect(transport.requests.filter { $0.url?.lastPathComponent == "token" }.count == 1)
    }

    @Test func theBudgetComesFromTheHeaders() async throws {
        let transport = try signedIn()
        let reset = clock.now.addingTimeInterval(1800)
        transport.enqueue(
            "sensors", body: try Fixture.data("airthings_sensors"),
            headers: ["X-RateLimit-Limit": "120", "X-RateLimit-Remaining": "9", "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970))])
        let client = connection(transport)
        #expect(await client.requestBudget() == nil)
        _ = try await client.fetchLatest(devices: [cellar])
        #expect(await client.requestBudget() == RequestBudget(limit: 120, remaining: 9, resetsAt: reset))
    }

    // MARK: Through the hub

    /// Five sensors on one account in a hub, polled as the app polls (every minute).
    func hub(store: HistoryStore, transport: StubTransport) throws -> DeviceHub {
        let sensors = (1...5).map {
            DeviceSummary(key: DeviceKey(integration: AirthingsIntegration.id, nativeId: "293000000\($0)"), name: "Sensor \($0)", kind: .airQualitySensor)
        }
        try store.syncDevices(sensors, integration: AirthingsIntegration.id)
        let client = connection(transport)
        return try DeviceHub(
            store: store, catalog: [AirthingsIntegration()], defaultIntegrations: [AirthingsIntegration.id], timeZone: .gmt,
            now: clock.provider, sleep: clock.sleeper,
            makeRuntime: { IntegrationRuntime(integration: $0, connection: client) })
    }

    @Test func fiveSensorsStayWellBelowTheHourlyBudget() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let transport = try signedIn()
        for _ in 0..<40 {
            transport.enqueue("sensors", body: try Fixture.data("airthings_sensors"))
            transport.enqueue("samples", body: try Fixture.data("airthings_samples"))
            transport.enqueue("thresholds", body: try Fixture.data("airthings_thresholds"))
        }
        let hub = try hub(store: store, transport: transport)
        var services: [AirQualityService] = []
        for device in try await hub.devices() { services.append(try #require(try await hub.airQualityService(for: device.key))) }
        #expect(services.count == 5)

        var perHour: [Int] = []
        for _ in 0..<2 {
            let before = transport.requests.count
            for _ in 0..<60 {
                for service in services {
                    _ = try await service.syncLatest()
                    _ = try await service.syncThresholds()
                    _ = try await service.syncHistory()
                }
                clock.advance(60)
            }
            perHour.append(transport.requests.count - before)
        }
        // First hour: token, account, 12 × newest values, 5 × thresholds, 5 × history.
        #expect(perHour[0] == 24)
        // Then: 12 × newest values (all five in each) and 5 × history.
        #expect(perHour[1] == 17)
        #expect(perHour.allSatisfy { $0 < AirthingsAPI.assumedHourlyLimit / 4 })
        let latest = transport.requests.filter { $0.url?.lastPathComponent == "sensors" }
        #expect(latest.allSatisfy { query($0).filter { $0.name == "sn" }.count == 5 })
        #expect(try store.latestAirQuality(device: cellar)?.reading.values[.co2] == 1150)
    }

    @Test func aRefusedClientStopsEveryRequestUntilNewValuesAreSaved() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let transport = StubTransport()
        transport.enqueue("token", status: 400, body: try Fixture.data("airthings_invalid_client"))
        let hub = try hub(store: store, transport: transport)
        let service = try #require(try await hub.airQualityService(for: cellar))
        let sync = try await service.syncLatest()
        #expect(sync.status == .failed)
        #expect(sync.message?.contains("Airthings") == true)
        #expect(try await service.credentialsRejected())
        clock.advance(3600)
        #expect(try await service.syncLatest().status == .skipped)
        #expect(try await service.syncHistory().status == .skipped)
        #expect(transport.requests.count == 1)
    }

    @Test func a429BlocksTheIntegrationAcrossSensors() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let transport = try signedIn()
        transport.enqueue("sensors", status: 429, body: Data(), headers: ["X-RateLimit-Retry-After": "1200"])
        let hub = try hub(store: store, transport: transport)
        let service = try #require(try await hub.airQualityService(for: cellar))
        #expect(try await service.syncLatest().status == .failed)
        #expect(try store.blockStatus(now: clock.now, integration: AirthingsIntegration.id)?.until == clock.now.addingTimeInterval(1200))
        let other = try #require(try await hub.airQualityService(for: DeviceKey(integration: AirthingsIntegration.id, nativeId: "2930000002")))
        #expect(try await other.syncHistory().status == .skipped)
        #expect(transport.requests.count == 3)
    }

    // MARK: Demo

    @Test func theDemoSensorComesOnlyWhenAskedFor() async throws {
        let path = temporaryDatabasePath()
        let plain = try IntegrationCatalog.makeHub(environment: ["VARMEPUMPE_BACKEND": "mock", "VARMEPUMPE_DB_PATH": path])
        #expect(try await plain.devices().map(\.kind) == [.airToAirHeatPump])
        let hub = try IntegrationCatalog.makeHub(
            environment: ["VARMEPUMPE_BACKEND": "mock", "VARMEPUMPE_DB_PATH": path, "VARMEPUMPE_DEMO_DEVICES": "heatpump,airthings"])
        let devices = try await hub.devices()
        #expect(devices.map(\.kind) == [.airToAirHeatPump, .airQualitySensor])
        #expect(devices[1].key == MockAirQualitySensor.device)
        #expect(hub.integration(for: MockAirQualitySensor.device)?.displayName == "Airthings")
        try await hub.seedDemoHistoryIfNeeded()
        let service = try #require(try await hub.airQualityService(for: MockAirQualitySensor.device))
        #expect(try await service.syncLatest().status == .fetched)
        let status = try #require(try await service.status())
        let radon = try #require(status.value(.radonShortTerm)?.value)
        #expect((20...160).contains(radon))
        #expect(status.findings.contains { $0.code == "air_radon_action" })
        #expect(try await service.hours(from: Date().addingTimeInterval(-365 * 86_400), to: Date()).count > 8000)
        // Turned off again when no longer asked for.
        let again = try IntegrationCatalog.makeHub(environment: ["VARMEPUMPE_BACKEND": "mock", "VARMEPUMPE_DB_PATH": path])
        #expect(try await again.devices().count == 1)
    }
}
