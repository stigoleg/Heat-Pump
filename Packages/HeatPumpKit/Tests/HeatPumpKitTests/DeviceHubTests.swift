import Foundation
import GRDB
import Synchronization
import Testing
@testable import DemoIntegration
@testable import HeatPumpKit
@testable import MELCloudIntegration

/// The demo integration under another service name, so texts show which integration they name.
struct RenamedDemoIntegration: Integration {
    var base = DemoIntegration()
    var id: String { base.id }
    var displayName: String { "SimCloud" }
    var vendorName: String { base.vendorName }
    var credentialFields: [CredentialField] { [] }
    var rateLimitPolicy: RateLimitPolicy { .standard }
    var errorCodes: any ErrorCodeExplaining { base.errorCodes }
    func makeConnection(_ context: IntegrationContext) throws -> any DeviceConnection {
        try base.makeConnection(context)
    }
}

/// A simulated account whose device list can change (another account signed in).
actor SwitchableAccount: DeviceConnection, ThermostatDriver {
    nonisolated let identifier = "mock"
    let inner: MockBackend
    private var listed: [DeviceKey]

    init(now: @escaping @Sendable () -> Date, listed: [DeviceKey]) {
        inner = MockBackend(timeZone: .gmt, now: now, units: [.unit(0), .unit(1)])
        self.listed = listed
    }

    func list(_ keys: [DeviceKey]) { listed = keys }
    func login() async throws {}
    func listDevices() async throws -> [DeviceSummary] { inner.listing.filter { listed.contains($0.key) } }
    func fetchState(device: DeviceKey) async throws -> DeviceState {
        guard listed.contains(device) else { throw HeatPumpError.deviceNotFound }
        return try await inner.fetchState(device: device)
    }
    func apply(_ changes: ChangeSet) async throws -> DeviceState? { try await inner.apply(changes) }
}

/// Counts how often a source is asked for.
final class Counter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

@Suite("Device hub")
struct DeviceHubTests {
    let clock = TestClock()
    let store: HistoryStore
    let living = DemoUnit.unit(0).key
    let bedroom = DemoUnit.unit(1).key

    init() throws {
        store = try HistoryStore(path: temporaryDatabasePath())
    }

    /// A demo hub with the living room and bedroom units on one connection.
    func demoHub(
        integration: any Integration = DemoIntegration(), backend: (any DeviceConnection & ThermostatDriver)? = nil,
        prices: Counter? = nil, weather: Counter? = nil
    ) throws -> DeviceHub {
        let connection = backend ?? MockBackend(timeZone: .gmt, now: clock.provider, units: [.unit(0), .unit(1)])
        try store.syncDevices(MockBackend.listing([.unit(0), .unit(1)]), integration: DemoIntegration.id)
        return try DeviceHub(
            store: store, catalog: [integration], fixedIntegrations: [DemoIntegration.id], defaultIntegrations: [DemoIntegration.id],
            isDemo: true, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper,
            priceProvider: { _ in
                prices?.increment()
                return MockPriceProvider()
            },
            weatherProvider: { _ in
                weather?.increment()
                return MockWeatherProvider(now: clock.provider)
            },
            makeRuntime: { IntegrationRuntime(integration: $0, connection: connection) })
    }

    // MARK: Two simulated devices

    @Test func demoDevicesComeFromTheEnvironment() {
        #expect(DemoUnit.units(environment: [:]).map(\.key) == [MockBackend.device])
        #expect(DemoUnit.units(environment: ["VARMEPUMPE_DEMO_DEVICES": "heatpump,heatpump"]).map(\.key) == [living, bedroom])
        #expect(DemoUnit.units(environment: ["VARMEPUMPE_DEMO_DEVICES": "meter"]).count == 1)
    }

    @Test func twoDevicesHaveTheirOwnStateAndHistory() async throws {
        let hub = try demoHub()
        let devices = try await hub.devices()
        #expect(devices.map(\.key) == [living, bedroom])
        #expect(devices.map(\.name) == ["Living room (simulated)", "Bedroom (simulated)"])
        #expect(try await hub.primaryDevice?.key == living)
        let a = try #require(try await hub.heatPumpService(for: living))
        let b = try #require(try await hub.heatPumpService(for: bedroom))
        #expect(hub.primaryAtLaunch === a)
        #expect(try await hub.primaryService() === a)

        let first = try await a.currentState()
        #expect(first.refreshed && first.state?.key == living && first.state?.setTemperature == 21)
        // The state spacing is the integration's (one fetch per minute across its devices).
        let throttled = try await b.currentState()
        #expect(!throttled.refreshed && throttled.state == nil && throttled.nextRefreshAllowed != nil)
        clock.advance(61)
        let second = try await b.currentState()
        #expect(second.refreshed && second.state?.key == bedroom && second.state?.setTemperature == 19)
        #expect(try await a.cachedState()?.key == living)

        // Reports are spaced per device, so both get their history; the bedroom uses less.
        _ = try await a.syncHistory()
        let reports = try await b.syncHistory()
        #expect(reports.allSatisfy { $0.status == .fetched })
        let livingEnergy = try await a.energy(period: .month, from: clock.now.addingTimeInterval(-20 * 86_400), to: clock.now)
        let bedroomEnergy = try await b.energy(period: .month, from: clock.now.addingTimeInterval(-20 * 86_400), to: clock.now)
        let livingKWh = livingEnergy.reduce(0) { $0 + $1.totalKWh }
        let bedroomKWh = bedroomEnergy.reduce(0) { $0 + $1.totalKWh }
        #expect(livingKWh > 0 && bedroomKWh > 0 && bedroomKWh < livingKWh)
        #expect(try await a.errorLog(days: 90).allSatisfy { $0.device == living })
        #expect(try await b.errorLog(days: 90).isEmpty)
    }

    @Test func budgetAndBlockAreTheIntegrations() async throws {
        let hub = try demoHub()
        let a = try #require(try await hub.heatPumpService(for: living))
        let b = try #require(try await hub.heatPumpService(for: bedroom))
        _ = try await a.currentState()
        clock.advance(61)
        _ = try await b.currentState()
        let before = try await b.writeBudget().remaining
        let outcome = try await a.apply(.temperature(22), source: .app, reason: "test")
        #expect(outcome.result == .ok)
        // One change budget per integration: the bedroom sees the living room's write.
        #expect(try await b.writeBudget().remaining == before - 1)
        #expect(try await a.cachedState()?.setTemperature == 22)
        #expect(try await b.cachedState()?.setTemperature == 19)

        // A block on the integration stops both devices.
        try store.recordBlock(until: clock.now.addingTimeInterval(3600), reason: .rateLimited, integration: DemoIntegration.id)
        clock.advance(120)
        for service in [a, b] {
            let result = try await service.currentState(force: true)
            #expect(!result.refreshed && result.blockedUntil != nil)
        }
    }

    @Test func pricesAndWeatherAreFetchedOnceForTwoDevices() async throws {
        let prices = Counter()
        let weather = Counter()
        let hub = try demoHub(prices: prices, weather: weather)
        let a = try #require(try await hub.heatPumpService(for: living))
        let b = try #require(try await hub.heatPumpService(for: bedroom))
        #expect(a.energy === b.energy && a.energy === hub.energy)
        try await a.savePriceSettings(PriceSettings(agreement: .spot, area: .no1))
        #expect(try await a.syncPrices().status == .fetched)
        #expect(try await b.syncPrices().status != .fetched)
        #expect(try await a.syncWeather().status == .fetched)
        #expect(try await b.syncWeather().status != .fetched)
        #expect(prices.count == 1)
        #expect(weather.count == 1)
        #expect(try await a.priceSettings() == b.priceSettings())
        #expect(try await b.weatherLocation()?.source == .demo)
    }

    @Test func devicesCanBeDisabledAndRenamed() async throws {
        let hub = try demoHub()
        let b = try #require(try await hub.heatPumpService(for: bedroom))
        try await hub.rename(bedroom, to: "  Soverom ")
        #expect(try await hub.devices().map(\.name) == ["Living room (simulated)", "Soverom"])
        // A status keeps the user's name (the integration's name is kept apart).
        clock.advance(61)
        _ = try await b.currentState()
        #expect(try await hub.devices().last?.name == "Soverom")
        try await hub.setEnabled(false, for: bedroom)
        #expect(try await hub.devices().map(\.key) == [living])
        #expect(try await hub.allDevices().map(\.isEnabled) == [true, false])
        #expect(try await hub.heatPumpService(for: bedroom) == nil)
        try await hub.rename(bedroom, to: nil)
        #expect(try await hub.allDevices().last?.name == "Bedroom (simulated)")
    }

    @Test func priceControlSteersTheFirstHeatPumpUnlessChosen() async throws {
        let hub = try demoHub()
        #expect(try await hub.priceControlDevice() == living)
        try await hub.setPriceControlDevice(bedroom)
        #expect(try await hub.priceControlDevice() == bedroom)
        #expect(try await hub.priceControlService() === hub.heatPumpService(for: bedroom))
        try await hub.setEnabled(false, for: bedroom)
        #expect(try await hub.priceControlDevice() == living)
    }

    @Test func changeLogNamesTheDevice() async throws {
        let hub = try demoHub()
        let a = try #require(try await hub.heatPumpService(for: living))
        let b = try #require(try await hub.heatPumpService(for: bedroom))
        _ = try await a.currentState()
        clock.advance(61)
        _ = try await b.currentState()
        _ = try await b.apply(.power(false), source: .app, reason: "night")
        let log = try await hub.changeLog(limit: 10)
        #expect(log.first?.device?.key == bedroom)
        #expect(log.first?.record.field == "power")
        #expect(try await a.changeLog(limit: 10, source: nil).isEmpty)
    }

    // MARK: Two integrations

    @Test func twoIntegrationsHaveIndependentBlocksAndNameTheirService() async throws {
        let transport = StubTransport()
        transport.enqueue("/Login/ClientLogin", body: try Fixture.data("login_success"))
        transport.enqueue("/User/ListDevices", body: try Fixture.data("list_devices"))
        transport.enqueue("/Device/Get", body: try Fixture.data("device_get"))
        let credentials = InMemoryCredentialStore(credentials: MELCloudCredentials(email: "a@b.no", password: "pw"))
        let melcloud = MELCloudClassicBackend(credentials: credentials, transport: transport, timeZone: .gmt, rawCache: store, now: clock.provider)
        let demo = MockBackend(timeZone: .gmt, now: clock.provider)
        try store.syncDevices(MockBackend.listing([.unit(0)]), integration: DemoIntegration.id)
        try store.registerDevices([DeviceSummary(key: .melcloud(100001), name: "Stue", metadata: ["buildingId": "200001"])])
        try store.saveSetting([MELCloudIntegration.id, DemoIntegration.id], key: DeviceHub.integrationsKey)
        let hub = try DeviceHub(
            store: store, catalog: [MELCloudIntegration(), RenamedDemoIntegration()], defaultIntegrations: [MELCloudIntegration.id],
            timeZone: .gmt, now: clock.provider, sleep: clock.sleeper,
            makeRuntime: { integration in
                integration.id == MELCloudIntegration.id
                    ? IntegrationRuntime(integration: integration, connection: melcloud, credentials: credentials)
                    : IntegrationRuntime(integration: integration, connection: demo)
            })
        #expect(await hub.activeIntegrations.map(\.id) == [MELCloudIntegration.id, DemoIntegration.id])
        #expect(try await hub.devices().map(\.key) == [MockBackend.device, .melcloud(100001)])
        let pump = try #require(try await hub.heatPumpService(for: .melcloud(100001)))
        let simulated = try #require(try await hub.heatPumpService(for: MockBackend.device))

        // The demo integration is blocked; MELCloud still fetches.
        try store.recordBlock(until: clock.now.addingTimeInterval(3600), reason: .loginThrottled, integration: DemoIntegration.id)
        let blocked = try await simulated.currentState()
        #expect(!blocked.refreshed && blocked.blockedUntil != nil)
        #expect(blocked.blockMessage?.contains("SimCloud") == true)
        let fetched = try await pump.currentState()
        #expect(fetched.refreshed && fetched.state?.key == .melcloud(100001))
        #expect(transport.requests.count == 3)

        // Texts a service builds name its own integration, whatever the process-wide name is.
        try store.recordCredentialsRejected(now: clock.now, integration: MELCloudIntegration.id)
        clock.advance(700)
        let rejected = try await pump.currentState()
        #expect(rejected.error?.hasPrefix("MELCloud did not accept") == true)
        #expect(simulated.describe(HeatPumpError.credentialsRejected).hasPrefix("SimCloud did not accept"))
        #expect(pump.describe(HeatPumpError.http(status: 500)) == "MELCloud answered with HTTP error 500.")
    }

    // MARK: Accounts

    @Test func signingInToAnotherAccountDisablesTheOldDevice() async throws {
        let account = SwitchableAccount(now: clock.provider, listed: [living])
        try store.registerDevices([DeviceSummary(key: living, name: "Living room (simulated)")])
        let hub = try DeviceHub(
            store: store, catalog: [DemoIntegration()], defaultIntegrations: [DemoIntegration.id], timeZone: .gmt,
            now: clock.provider, sleep: clock.sleeper,
            makeRuntime: { IntegrationRuntime(integration: $0, connection: account) })
        let held = try #require(hub.primaryAtLaunch)
        #expect(try await held.currentState().state?.key == living)

        await account.list([bedroom])
        clock.advance(61)
        let result = try await hub.signIn(integration: DemoIntegration.id, values: CredentialValues())
        #expect(result.refreshed && result.state?.key == bedroom)
        #expect(try await hub.devices().map(\.key) == [bedroom])
        #expect(try store.devices().first { $0.key == living }?.enabled == false)
        // The service the app holds now serves the new account's device.
        #expect(try await held.currentDevice() == bedroom)
        #expect(try await hub.primaryService() === held)
    }

    @Test func firstSignInAdoptsTheServiceThatFoundTheDevice() async throws {
        let account = SwitchableAccount(now: clock.provider, listed: [living, bedroom])
        let hub = try DeviceHub(
            store: store, catalog: [DemoIntegration()], defaultIntegrations: [DemoIntegration.id], timeZone: .gmt,
            now: clock.provider, sleep: clock.sleeper,
            makeRuntime: { IntegrationRuntime(integration: $0, connection: account) })
        #expect(try await hub.devices().isEmpty)
        let held = try #require(hub.primaryAtLaunch)
        let result = try await hub.signIn(integration: DemoIntegration.id, values: CredentialValues())
        #expect(result.state?.key == living)
        #expect(try await hub.devices().map(\.key) == [living, bedroom])
        #expect(try await hub.heatPumpService(for: living) === held)
        #expect(try await hub.heatPumpService(for: bedroom) !== held)
    }

    @Test func notificationsNameTheDeviceOnlyWhenAsked() {
        let state = makeState(at: clock.now, hasError: true, errorCode: 1234)
        let plain = NotificationPlanner.plan(
            state: state, errorEvents: [], maintenance: [], memory: NotificationMemory(), now: clock.now, serviceName: "MELCloud",
            noErrorCodes: [8000])
        let named = NotificationPlanner.plan(
            state: state, errorEvents: [], maintenance: [], memory: NotificationMemory(), now: clock.now, serviceName: "MELCloud",
            noErrorCodes: [8000], device: (bedroom, "Bedroom"))
        #expect(plain.notifications.map(\.id) == ["active-error"])
        #expect(named.notifications.map(\.id) == ["active-error@demo:100002"])
        #expect(named.notifications.first?.title == "Bedroom: " + (plain.notifications.first?.title ?? ""))
        #expect(named.memory == plain.memory)
    }

    @Test func approvalNamesTheDevice() async {
        final class Recorder: ChangeApprover {
            let seen = Mutex<ApprovalRequest?>(nil)
            func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
                seen.withLock { $0 = request }
                return .approved
            }
        }
        let recorder = Recorder()
        let request = ApprovalRequest(summaries: ["Temperature 22 °C"], reason: "cold")
        _ = await DeviceNamingApprover(base: recorder, device: "Bedroom").requestApproval(request)
        let seen = recorder.seen.withLock { $0 }
        #expect(seen?.device == "Bedroom")
        #expect(seen?.message.hasPrefix("Device: Bedroom\n\n") == true)
        #expect(request.message.hasPrefix("•"))
    }
}

@Suite("Per-device caches")
struct DeviceScopeTests {
    let device = MockBackend.device

    @Test func migrationMovesGlobalCachesToTheCurrentDevice() throws {
        let path = temporaryDatabasePath()
        let t = Date(timeIntervalSince1970: 1_793_872_800)
        // A file as the previous version left it (v12).
        do {
            try FileManager.default.createDirectory(
                atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true)
            let queue = try DatabaseQueue(path: path)
            try HistoryStore.migrator(legacyIntegration: nil).migrate(queue, upTo: HistoryStore.deviceKeyMigration)
            try queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO devices (key, integration, kind, name, nativeId, enabled, sortOrder)
                        VALUES ('demo:100002', 'demo', 'airToAirHeatPump', 'Old', '100002', 0, 0),
                               ('demo:100001', 'demo', 'airToAirHeatPump', 'Stue', '100001', 1, 1)
                        """)
                for name in ["localConnection", "awaySettings", "weeklyTimer", "firmwareStatus", "localStatus"] {
                    try db.execute(sql: "INSERT INTO app_settings (key, json) VALUES (?, '{}')", arguments: [name])
                }
                try db.execute(sql: "INSERT INTO app_settings (key, json) VALUES ('priceSettings', '{}')")
                try db.execute(
                    sql: "INSERT INTO fetch_state (key, lastAttempt, lastSuccess, blockedUntil) VALUES (?, ?, ?, ?)",
                    arguments: ["demo/away", t, t, t.addingTimeInterval(86_400)])
                try db.execute(
                    sql: "INSERT INTO fetch_state (key, lastAttempt, lastSuccess) VALUES (?, ?, ?)",
                    arguments: ["demo/report.energy", t, t])
                try db.execute(
                    sql: "INSERT INTO fetch_state (key, lastAttempt, lastSuccess) VALUES (?, ?, ?)", arguments: ["demo/state", t, t])
            }
            try queue.close()
        }
        let store = try HistoryStore(path: path)
        for name in HistoryStore.deviceSettingNames {
            #expect(try store.setting(JSONValue.self, key: name) == nil)
            #expect(try store.setting(JSONValue.self, key: "\(name)@demo:100001") != nil)
        }
        #expect(try store.setting(JSONValue.self, key: "priceSettings") != nil)
        let away = try #require(try store.fetchState(key: "demo/away@100001"))
        #expect(away.lastAttempt == t && away.lastSuccess == t && away.blockedUntil == nil)
        #expect(try store.fetchState(key: "demo/away")?.blockedUntil == t.addingTimeInterval(86_400))
        #expect(try store.fetchState(key: "demo/report.energy@100001")?.lastSuccess == t)
        // The state spacing stays the integration's.
        #expect(try store.fetchState(key: "demo/state@100001") == nil)
        #expect(try store.devices().map(\.customName) == [nil, nil])
    }

    @Test func aCacheSavedBeforeAnyDeviceIsAdoptedByTheFirstDevice() async throws {
        let clock = TestClock()
        let store = try HistoryStore(path: temporaryDatabasePath())
        let service = HeatPumpService(backend: MockBackend(timeZone: .gmt, now: clock.provider), store: store, now: clock.provider)
        try await service.saveLocalSettings(LocalSettings(enabled: false, host: "192.168.1.9"))
        #expect(try store.setting(LocalSettings.self, key: "localConnection")?.host == "192.168.1.9")
        _ = try await service.currentState()
        #expect(try await service.localSettings().host == "192.168.1.9")
        #expect(try store.setting(LocalSettings.self, key: "localConnection") == nil)
        #expect(try store.deviceSetting(LocalSettings.self, name: "localConnection", device: device)?.host == "192.168.1.9")
        // Another device starts with its own (default) settings.
        #expect(try store.deviceSetting(LocalSettings.self, name: "localConnection", device: DemoUnit.unit(1).key) == nil)
    }
}
