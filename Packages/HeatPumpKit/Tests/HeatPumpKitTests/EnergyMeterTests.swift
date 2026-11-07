import Foundation
import GRDB
import MCP
import Testing
@testable import DemoIntegration
@testable import HeatPumpKit
@testable import TibberIntegration
@testable import varmepumpe_mcp

@Suite("Energy meter: storage, hub, service and MCP")
struct EnergyMeterTests {
    let clock = TestClock()
    let living = DemoUnit.unit(0).key
    let meter = MockMeter.device

    func hours(_ count: Int, from start: Date, kWh: Double = 1.5) -> [HouseHour] {
        (0..<count).map { HouseHour(hour: start.addingTimeInterval(Double($0) * 3600), kWh: kWh, costNok: 2, unitPriceOre: 130) }
    }

    // MARK: Storage

    @Test func houseConsumptionMovesToMeterHourlyAndKeepsABackup() throws {
        let path = temporaryDatabasePath()
        let base = clock.now.addingTimeInterval(-6 * 3600)
        do {
            // A file from the previous version (up to v13) with house hours.
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            let queue = try DatabaseQueue(path: path)
            try HistoryStore.migrator(legacyIntegration: nil).migrate(queue, upTo: HistoryStore.deviceScopeMigration)
            try queue.write { db in
                for h in 0..<5 {
                    try db.execute(
                        sql: "INSERT INTO house_consumption_hourly (hour, kWh, cost, unitPrice) VALUES (?, ?, ?, ?)",
                        arguments: [base.addingTimeInterval(Double(h) * 3600), 1.0 + Double(h), 2.5, 125])
                }
            }
            try queue.close()
        }
        let store = try HistoryStore(path: path)
        let backup = HistoryStore.backupPath(for: path, before: HistoryStore.meterMigration)
        #expect(FileManager.default.fileExists(atPath: backup))
        #expect(!FileManager.default.fileExists(atPath: HistoryStore.backupPath(for: path)))
        // Every row under the placeholder; the house reads the same numbers.
        let house = try store.houseHours(from: .distantPast, to: .distantFuture)
        #expect(house.map(\.kWh) == [1, 2, 3, 4, 5])
        #expect(house.first?.costNok == 2.5)
        #expect(house.first?.unitPriceOre == 125)
        #expect(try store.meterHours(device: HistoryStore.pendingMeterKey, from: .distantPast, to: .distantFuture).count == 5)
        // The first meter registered adopts them; the house still reads the same numbers.
        let home = DeviceKey(integration: "tibber", nativeId: "home-1")
        try store.registerDevices([DeviceSummary(key: home, name: "Hjemme", kind: .energyMeter)])
        #expect(try store.houseMeterKey() == home)
        #expect(try store.meterHours(device: home, from: .distantPast, to: .distantFuture).map(\.kWh) == [1, 2, 3, 4, 5])
        #expect(try store.meterHours(device: HistoryStore.pendingMeterKey, from: .distantPast, to: .distantFuture).isEmpty)
        #expect(try store.houseHours(from: .distantPast, to: .distantFuture) == house)
        // Opening again changes nothing.
        _ = try HistoryStore(path: path)
    }

    @Test func liveMinutesAreKeptFor48Hours() throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let old = LiveMinute(minute: clock.now.addingTimeInterval(-50 * 3600), powerW: 900, maxPowerW: 1000, consumptionTodayKWh: 1, lastReading: clock.now.addingTimeInterval(-50 * 3600))
        try store.saveLiveMinute(old, device: meter)
        let new = LiveMinute(minute: clock.now, powerW: 1200, maxPowerW: 1400, consumptionTodayKWh: 9, lastReading: clock.now.addingTimeInterval(30))
        try store.saveLiveMinute(new, device: meter)
        #expect(try store.liveMinutes(device: meter, from: .distantPast, to: .distantFuture) == [new])
        #expect(try store.latestLiveMinute(device: meter) == new)
    }

    // MARK: Hub with a heat pump and a meter

    func demoHub(store: HistoryStore) throws -> DeviceHub {
        let backend = MockBackend(timeZone: .gmt, now: clock.provider, units: [.unit(0)])
        let mock = MockMeter(now: clock.provider)
        try store.syncDevices(backend.listing, integration: DemoIntegration.id)
        try store.syncDevices(MockMeter.listing, integration: DemoMeterIntegration.id)
        let clock = clock
        return try DeviceHub(
            store: store, catalog: [DemoIntegration(), DemoMeterIntegration()],
            fixedIntegrations: [DemoIntegration.id, DemoMeterIntegration.id], defaultIntegrations: [DemoIntegration.id], isDemo: true,
            timeZone: .gmt, now: clock.provider, sleep: clock.sleeper, houseProvider: { MockHouseConsumptionProvider(now: clock.provider) },
            makeRuntime: { integration in
                IntegrationRuntime(integration: integration, connection: integration.id == DemoMeterIntegration.id ? mock : backend)
            })
    }

    @Test func hubServesAHeatPumpAndAMeter() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let hub = try demoHub(store: store)
        let devices = try await hub.devices()
        #expect(devices.map(\.key) == [living, meter])
        #expect(devices.map(\.kind) == [.airToAirHeatPump, .energyMeter])
        #expect(devices[1].capabilities == [.energyLog, .livePower])
        #expect(try await hub.service(for: living)?.heatPump != nil)
        #expect(try await hub.service(for: meter)?.energyMeter != nil)
        #expect(try await hub.heatPumpService(for: meter) == nil)
        #expect(try await hub.primaryDevice?.key == living)
        #expect(try await hub.priceControlDevice() == living)
        #expect(hub.integration(for: meter)?.displayName == "Tibber")
    }

    @Test func houseConsumptionComesFromTheMeterWithTheSameNumbers() async throws {
        // Token only.
        let tokenStore = try HistoryStore(path: temporaryDatabasePath())
        let tokenService = HeatPumpService(
            backend: MockBackend(timeZone: .gmt, now: clock.provider), store: tokenStore, timeZone: .gmt, now: clock.provider,
            sleep: clock.sleeper, houseProvider: { [clock] in MockHouseConsumptionProvider(now: clock.provider) })
        #expect(try await tokenService.syncHouseConsumption().status == .fetched)
        let fromToken = try tokenStore.houseHours(from: .distantPast, to: .distantFuture)

        // An enabled meter: its own hours, spaced per meter, shared with the meter's service.
        let store = try HistoryStore(path: temporaryDatabasePath())
        let hub = try demoHub(store: store)
        let sync = try await hub.energy.syncHouseConsumption()
        #expect(sync.status == .fetched)
        #expect(sync.count == 744)
        #expect(try store.fetchState(key: "demo-meter/meter.hours@home")?.lastSuccess == clock.now)
        #expect(try store.fetchState(key: HeatPumpService.houseFetchKey) == nil)
        let fromMeter = try store.houseHours(from: .distantPast, to: .distantFuture)
        #expect(fromMeter == fromToken)
        #expect(try store.meterHours(device: meter, from: .distantPast, to: .distantFuture) == fromToken)
        let service = try #require(try await hub.meterService(for: meter))
        #expect(try await service.syncHours().status == .skipped)  // the same hourly slot
    }

    @Test func todayUsesHoursThenTheLiveCounter() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let hub = try demoHub(store: store)
        let service = try #require(try await hub.meterService(for: meter))
        let midnight = WireDate.calendar(.gmt).startOfDay(for: clock.now)  // clock: 10:00Z
        try store.upsertMeterHours(hours(8, from: midnight), device: meter)  // 00–07 reported
        func minute(_ hour: Double, _ kWh: Double) -> LiveMinute {
            let at = midnight.addingTimeInterval(hour * 3600)
            return LiveMinute(minute: at, powerW: 1000, maxPowerW: 1100, consumptionTodayKWh: kWh, lastReading: at.addingTimeInterval(30))
        }
        for m in [minute(7.9, 12.0), minute(8.5, 12.6), minute(8.95, 13.0), minute(9.5, 13.5)] { try store.saveLiveMinute(m, device: meter) }
        let today = try await service.today()
        #expect(today.hoursCovered == 10)
        #expect(today.includesLive)
        #expect(abs(today.kWh - (8 * 1.5 + 1.0 + 0.5)) < 1e-9)  // 08: 13.0 − 12.0, 09: 13.5 − 13.0
        let status = try #require(try await service.status())
        #expect(status.hasLivePower)
        #expect(status.live?.powerW == 1000)
    }

    @Test func liveReadingsAreStoredAndAMeterWithoutLiveStops() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let hub = try demoHub(store: store)
        let service = try #require(try await hub.meterService(for: meter))
        for await event in await service.live() {
            if case .reading = event { break }
        }
        #expect(try store.latestLiveMinute(device: meter) != nil)

        let other = DeviceKey(integration: DemoMeterIntegration.id, nativeId: "no-live")
        try store.registerDevices([DeviceSummary(key: other, name: "No live", kind: .energyMeter)])
        let plain = EnergyMeterService(
            connection: TibberConnection(token: { nil }, transport: StubTransport(), sockets: FakeSockets(), userAgent: "test"),
            store: store, integration: TibberIntegration(), energy: hub.energy, device: other)
        var events: [LivePowerEvent] = []
        for await event in await plain.live() { events.append(event) }
        #expect(events == [.state(.stopped(.notAvailable))])
    }

    @Test func theLiveStreamFollowsTheStoreAndRecordsWhatItLearns() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let hub = try demoHub(store: store)
        let home = DeviceKey(integration: TibberIntegration.id, nativeId: "96a14971-525a-4420-aae9-e5aedaa129ff")
        try store.registerDevices([
            DeviceSummary(key: home, name: "Hjemme", kind: .energyMeter, metadata: [TibberIntegration.realTimeKey: "true"])
        ])
        let clock = clock
        func service(_ transport: StubTransport, _ sockets: FakeSockets = FakeSockets()) -> EnergyMeterService {
            let connection = TibberConnection(token: { "TOKEN" }, transport: transport, sockets: sockets, userAgent: "test", now: clock.provider)
            return EnergyMeterService(
                connection: connection, store: store, integration: TibberIntegration(), energy: hub.energy, device: home, now: clock.provider)
        }
        /// The events until the stream stops or waits.
        func events(_ service: EnergyMeterService) async -> [LivePowerEvent] {
            var events: [LivePowerEvent] = []
            for await event in await service.live() {
                events.append(event)
                if case .state(.stopped) = event { break }
                if case .state(.waiting) = event { break }
            }
            return events
        }

        // A token the homes request refuses stops every request of the integration.
        let refused = StubTransport()
        refused.enqueue("gql", body: try Fixture.data("tibber_unauthenticated"))
        #expect(await events(service(refused)).last == .state(.stopped(.unauthorized)))
        #expect(try store.credentialsRejected(integration: TibberIntegration.id))
        // While it stands, a new stream sends nothing.
        let quiet = StubTransport()
        let sockets = FakeSockets()
        #expect(await events(service(quiet, sockets)) == [.state(.stopped(.unauthorized))])
        #expect(quiet.requests.isEmpty)
        #expect(sockets.connects == 0)
        try store.clearCredentialsRejected(integration: TibberIntegration.id)

        // 429 blocks the integration (the hourly sync waits too), and a new stream waits it out.
        let until = clock.now.addingTimeInterval(TibberAPI.rateLimitPause)
        let limited = StubTransport()
        limited.enqueue("gql", status: 429, body: Data())
        #expect(await events(service(limited)).last == .state(.waiting(until: until)))
        #expect(try store.blockedUntil(now: clock.now, integration: TibberIntegration.id) == until)
        let blocked = StubTransport()
        #expect(await events(service(blocked)) == [.state(.waiting(until: until))])
        #expect(blocked.requests.isEmpty)
    }

    // MARK: Tibber through the hub

    func tibberHub(store: HistoryStore, credentials: InMemoryCredentialStore, transport: StubTransport) throws -> DeviceHub {
        let backend = MockBackend(timeZone: .gmt, now: clock.provider, units: [.unit(0)])
        try store.syncDevices(backend.listing, integration: DemoIntegration.id)
        let clock = clock
        return try DeviceHub(
            store: store, catalog: [DemoIntegration(), TibberIntegration()], defaultIntegrations: [DemoIntegration.id],
            timeZone: .gmt, now: clock.provider, sleep: clock.sleeper,
            makeRuntime: { integration in
                guard integration.id == TibberIntegration.id else { return IntegrationRuntime(integration: integration, connection: backend) }
                let connection = TibberConnection(
                    token: { (try? credentials.loadValues(for: integration.credentialMapping))?["token"] }, transport: transport,
                    sockets: FakeSockets(), userAgent: "test", now: clock.provider)
                return IntegrationRuntime(integration: integration, connection: connection, credentials: credentials)
            })
    }

    @Test func addingTibberListsItsHomesAndKeepsThePriceToken() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        try store.upsertHouseHours(hours(3, from: clock.now.addingTimeInterval(-5 * 3600)))  // fetched with the token before
        let credentials = InMemoryCredentialStore()
        try credentials.saveTibberToken("PRICE-TOKEN")
        let transport = StubTransport()
        transport.enqueue("gql", body: try Fixture.data("tibber_homes"))
        let hub = try tibberHub(store: store, credentials: credentials, transport: transport)
        // Nothing changes until the user adds it.
        #expect(try await hub.devices().map(\.key) == [living])

        let result = try #require(try await hub.addIntegration(id: TibberIntegration.id, credentials: CredentialValues(["token": "PRICE-TOKEN"])))
        #expect(result.refreshed)
        #expect(result.error == nil)
        let devices = try await hub.devices()
        let first = DeviceKey(integration: "tibber", nativeId: "96a14971-525a-4420-aae9-e5aedaa129ff")
        #expect(devices.map(\.key).contains(first))
        #expect(devices.first { $0.key == first }?.capabilities == [.energyLog, .livePower])
        #expect(devices.filter { $0.kind == .energyMeter }.count == 2)
        #expect(try await hub.meterService(for: first) != nil)
        // The first home took over the house's hours.
        #expect(try store.meterHours(device: first, from: .distantPast, to: .distantFuture).count == 3)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer PRICE-TOKEN")

        try await hub.removeIntegration(id: TibberIntegration.id)
        #expect(credentials.loadTibberToken() == "PRICE-TOKEN")  // prices keep it
        #expect(try await hub.devices().map(\.key) == [living])
    }

    @Test func aRefusedTokenStopsTheMetersRequests() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let transport = StubTransport()
        transport.enqueue("gql", body: try Fixture.data("tibber_unauthenticated"))
        let hub = try tibberHub(store: store, credentials: InMemoryCredentialStore(), transport: transport)
        let result = try #require(try await hub.addIntegration(id: TibberIntegration.id, credentials: CredentialValues(["token": "BAD"])))
        #expect(result.needsLogin)
        #expect(result.error?.contains("Tibber") == true)
        #expect(try store.credentialsRejected(integration: TibberIntegration.id))
        // Saving the token again (Electricity price) lifts the stop.
        try await hub.sharedCredentialsChanged()
        #expect(try !store.credentialsRejected(integration: TibberIntegration.id))
    }

    // MARK: Discovery and price control

    @Test func newDevicesAreFoundOnceADay() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let account = SwitchableAccount(now: clock.provider, listed: [living])
        try store.syncDevices(MockBackend.listing([.unit(0)]), integration: DemoIntegration.id)
        let hub = try DeviceHub(
            store: store, catalog: [DemoIntegration()], defaultIntegrations: [DemoIntegration.id], timeZone: .gmt, now: clock.provider,
            sleep: clock.sleeper, makeRuntime: { IntegrationRuntime(integration: $0, connection: account) })
        let bedroom = DemoUnit.unit(1).key
        await account.list([living, bedroom])
        #expect(try await hub.discoverDevices())
        #expect(try await hub.devices().map(\.key) == [living, bedroom])
        // Not again the same day.
        await account.list([bedroom])
        clock.advance(3600)
        #expect(try await !hub.discoverDevices())
        // A day later the unit the account dropped is turned off, not deleted.
        clock.advance(DeviceHub.discoveryInterval)
        #expect(try await hub.discoverDevices())
        #expect(try await hub.devices().map(\.key) == [bedroom])
        #expect(try await hub.allDevices().map(\.key).contains(living))
    }

    @Test func turningOffPriceControlsDeviceTurnsPriceControlOff() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider, units: [.unit(0), .unit(1)])
        try store.syncDevices(backend.listing, integration: DemoIntegration.id)
        let hub = try DeviceHub(
            store: store, catalog: [DemoIntegration()], fixedIntegrations: [DemoIntegration.id], defaultIntegrations: [DemoIntegration.id],
            isDemo: true, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper,
            makeRuntime: { IntegrationRuntime(integration: $0, connection: backend) })
        let service = try #require(try await hub.heatPumpService(for: living))
        _ = try await service.currentState(force: true)
        try await service.enablePriceControl()
        #expect(try await service.priceControlSettings().enabled)
        // Another device: price control stays on.
        try await hub.setEnabled(false, for: DemoUnit.unit(1).key)
        #expect(try await service.priceControlSettings().enabled)
        try await hub.setEnabled(true, for: DemoUnit.unit(1).key)
        // Its own device: off first, with the temperature restored.
        try await hub.setEnabled(false, for: living)
        #expect(try await !service.priceControlSettings().enabled)
        #expect(try await service.priceControlStatus()?.kind == .off)
    }

    // MARK: MCP

    @Test func meterToolsAppearOnlyWithAMeter() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let router = ToolRouter(hub: try demoHub(store: store), approver: FixedApprover(.approved))
        let tools = await router.tools()
        let names = tools.map(\.name)
        #expect(names.first == "list_devices")
        #expect(names.contains("get_meter_status"))
        // Descriptions name the heat pump's service only.
        #expect(tools.first { $0.name == "get_error_log" }?.description?.contains("Tibber") == false)

        // Heat pump tools need no device: the meter cannot answer them.
        let status = await router.handle(CallTool.Parameters(name: "get_status", arguments: [:]))
        #expect(status.isError != true)
        let energy = await router.handle(CallTool.Parameters(name: "get_energy", arguments: ["period": "day"]))
        #expect(energy.isError != true)

        let meter = await router.handle(CallTool.Parameters(name: "get_meter_status", arguments: [:]))
        #expect(meter.isError != true)
        let text = meter.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
        #expect(text.contains(#""key":"demo-meter:home""#))
        #expect(text.contains(#""hasLivePower":true"#))
        let wrong = await router.handle(CallTool.Parameters(name: "get_meter_status", arguments: ["device": .string(living.rawValue)]))
        #expect(wrong.isError == true)

        // One heat pump without a meter: no meter tools.
        let catalog = ToolCatalog.tools(
            for: [DeviceDescriptor(key: living, name: "Living", kind: .airToAirHeatPump, capabilities: MockBackend(units: [.unit(0)]).capabilities)],
            service: "MELCloud")
        #expect(!catalog.map(\.name).contains("get_meter_status"))
        #expect(catalog.map(\.name) == ToolCatalog.all(service: "MELCloud").map(\.name))
    }
}
