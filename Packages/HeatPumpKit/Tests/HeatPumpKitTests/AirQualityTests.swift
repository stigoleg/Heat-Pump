import Foundation
import GRDB
import MCP
import Testing
@testable import DemoIntegration
@testable import HeatPumpKit
@testable import varmepumpe_mcp

/// A sensor integration without a vendor: what the core does for any air quality sensor.
struct FakeAirIntegration: Integration {
    static let id = "fake-air"
    var id: String { Self.id }
    var displayName: String { "AirCo" }
    var vendorName: String { "AirCo" }
    var unitDescription: String { "AirCo air quality sensor" }
    var credentialFields: [CredentialField] { [] }
    var rateLimitPolicy: RateLimitPolicy {
        RateLimitPolicy(
            maxAge: 300, minRefreshInterval: 300, reportInterval: 3600, defaultLoginBlock: 1800, unauthorizedBlock: 3600, maxWriteWait: 0,
            writeBaseMaxAge: 0, changeBudget: ChangeBudgetPolicy(maxChangesPerHour: 0, window: 3600, minSpacing: 0))
    }
    var errorCodes: any ErrorCodeExplaining { NoErrorCodes() }
    func makeConnection(_ context: IntegrationContext) throws -> any DeviceConnection { throw HeatPumpError.notSupported }
}

/// Records every call and answers from what the test set.
actor FakeAirSensor: AirQualityDriver, AirQualityLogReporting, RequestBudgetReporting {
    nonisolated let identifier = "fake-air"
    let devices: [DeviceSummary]
    private(set) var latestCalls: [[DeviceKey]] = []
    private(set) var hourlyCalls: [DateInterval] = []
    private(set) var thresholdCalls = 0
    var failure: HeatPumpError?
    var budget: RequestBudget?
    var thresholds: AirQualityThresholds?
    var values: [AirQualityMetric: Double] = [.radonShortTerm: 80, .radonLongTerm: 60, .co2: 650, .humidity: 40, .temperature: 21.5, .battery: 90]

    init(devices: [DeviceSummary]) { self.devices = devices }

    func set(failure: HeatPumpError?) { self.failure = failure }
    func set(budget: RequestBudget?) { self.budget = budget }
    func set(thresholds: AirQualityThresholds?) { self.thresholds = thresholds }
    func set(values: [AirQualityMetric: Double]) { self.values = values }

    func login() async throws {}
    func listDevices() async throws -> [DeviceSummary] { devices }

    nonisolated var maxAirQualityLogDays: Int { 200 }

    func fetchLatest(devices: [DeviceKey]) async throws -> [AirQualityReading] {
        latestCalls.append(devices)
        if let failure { throw failure }
        return devices.map { AirQualityReading(device: $0, recorded: Date(timeIntervalSince1970: 1_793_872_500), values: values) }
    }

    func fetchHourly(device: DeviceKey, range: DateInterval) async throws -> [AirQualityHour] {
        hourlyCalls.append(range)
        if let failure { throw failure }
        return stride(from: range.start.timeIntervalSince1970, to: range.end.timeIntervalSince1970, by: 3600).map {
            AirQualityHour(hour: Date(timeIntervalSince1970: $0), values: [.radonShortTerm: 70, .co2: 600])
        }
    }

    func fetchThresholds(device: DeviceKey) async throws -> AirQualityThresholds? {
        thresholdCalls += 1
        if let failure { throw failure }
        return thresholds
    }

    func requestBudget() async -> RequestBudget? { budget }
}

@Suite("Air quality sensors: levels, storage, service, hub and MCP")
struct AirQualityTests {
    let clock = TestClock()
    let living = DemoUnit.unit(0).key
    let meter = MockMeter.device
    let cellar = DeviceKey(integration: FakeAirIntegration.id, nativeId: "2930000001")
    let bedroom = DeviceKey(integration: FakeAirIntegration.id, nativeId: "2930000002")

    var sensorListing: [DeviceSummary] {
        [
            DeviceSummary(key: cellar, name: "Kjeller", kind: .airQualitySensor),
            DeviceSummary(key: bedroom, name: "Soverom", kind: .airQualitySensor),
        ]
    }

    // MARK: Levels and findings

    @Test func levelsUseTheSensorsThresholdsElseTheStandardOnes() {
        let standard = AirQualityThresholds.standard
        #expect(standard.level(.co2, 650) == .good)
        #expect(standard.level(.co2, 900) == .fair)
        #expect(standard.level(.co2, 1000) == .poor)
        #expect(standard.level(.humidity, 20) == .poor)
        #expect(standard.level(.humidity, 27) == .fair)
        #expect(standard.level(.humidity, 45) == .good)
        #expect(standard.level(.humidity, 75) == .poor)
        #expect(standard.level(.radonLongTerm, 120) == .fair)
        #expect(standard.level(.pressure, 1010) == nil)
        #expect(standard.level(.battery, 5) == nil)

        // Only radon of its own (as a vendor answers): the long-term average follows it, the rest
        // stays standard.
        let own = AirQualityThresholds(ranges: [.radonShortTerm: AirQualityThresholds.rising(50, 200)], maxAge: 3600)
        #expect(own.level(.radonShortTerm, 120) == .fair)
        #expect(own.level(.radonLongTerm, 40) == .good)
        #expect(own.level(.radonLongTerm, 210) == .poor)
        #expect(own.level(.co2, 1200) == .poor)
        #expect(AirQualityRange(from: 10, to: 20, level: .fair).contains(10))
        #expect(!AirQualityRange(from: 10, to: 20, level: .fair).contains(20))
    }

    func values(_ values: [AirQualityMetric: Double]) -> [AirQualityValue] {
        AirQualityMetric.allCases.compactMap { metric in
            values[metric].map { AirQualityValue(metric: metric, value: $0, level: AirQualityThresholds.standard.level(metric, $0)) }
        }
    }

    func codes(_ values: [AirQualityMetric: Double], recorded: Date? = nil) -> [String] {
        AirQualityHealth.findings(values: self.values(values), recorded: recorded ?? clock.now, now: clock.now, serviceName: "AirCo").map(\.code)
    }

    @Test func radonIsJudgedByTheLongTermAverage() {
        #expect(codes([.radonShortTerm: 300, .radonLongTerm: 80]) == ["air_radon_short"])
        #expect(codes([.radonShortTerm: 300, .radonLongTerm: 100]) == ["air_radon_action"])
        #expect(codes([.radonShortTerm: 50, .radonLongTerm: 210]) == ["air_radon_limit"])
        #expect(codes([.radonShortTerm: 140, .radonLongTerm: 60]).isEmpty)
        let action = AirQualityHealth.findings(
            values: values([.radonLongTerm: 120]), recorded: clock.now, now: clock.now, serviceName: "AirCo")
        #expect(action.first?.severity == .warning)
        #expect(action.first?.detail.contains("120 Bq/m³") == true)
    }

    @Test func poorValuesBatteryAndSilenceBecomeFindings() {
        #expect(codes([.co2: 1200]) == ["air_co2_high"])
        #expect(codes([.co2: 900]).isEmpty)
        #expect(codes([.humidity: 22]) == ["air_humidity_low"])
        #expect(codes([.humidity: 75]) == ["air_humidity_high"])
        #expect(codes([.voc: 2500, .pm25: 30]) == ["air_voc_high", "air_pm25_high"])
        #expect(codes([.battery: 8]) == ["air_battery_low"])
        #expect(codes([.temperature: 27]).isEmpty)
        #expect(codes([.co2: 600], recorded: clock.now.addingTimeInterval(-7 * 3600)) == ["air_stale"])
        let stale = AirQualityHealth.findings(
            values: [], recorded: clock.now.addingTimeInterval(-7 * 3600), now: clock.now, serviceName: "AirCo")
        #expect(stale.first?.recommendation.contains("AirCo") == true)
    }

    // MARK: Storage

    @Test func migrationAddsTheTablesAndKeepsABackup() throws {
        let path = temporaryDatabasePath()
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            let queue = try DatabaseQueue(path: path)
            try HistoryStore.migrator(legacyIntegration: nil).migrate(queue, upTo: HistoryStore.legacyKeysMigration)
            try queue.close()
        }
        let store = try HistoryStore(path: path)
        #expect(FileManager.default.fileExists(atPath: HistoryStore.backupPath(for: path, before: HistoryStore.airQualityMigration)))
        #expect(!FileManager.default.fileExists(atPath: HistoryStore.backupPath(for: path, before: HistoryStore.meterMigration)))
        #expect(try store.latestAirQuality(device: cellar) == nil)
        // A new file needs no copy.
        let fresh = temporaryDatabasePath()
        _ = try HistoryStore(path: fresh)
        #expect(!FileManager.default.fileExists(atPath: HistoryStore.backupPath(for: fresh, before: HistoryStore.airQualityMigration)))
    }

    @Test func storageKeepsTheNewestValuesAndTwoYearsOfHours() throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        try store.saveAirQualityReading(
            AirQualityReading(device: cellar, recorded: clock.now, values: [.radonShortTerm: 80, .co2: 700]), fetchedAt: clock.now)
        try store.saveAirQualityReading(AirQualityReading(device: cellar, recorded: clock.now, values: [.co2: 720]), fetchedAt: clock.now)
        let latest = try #require(try store.latestAirQuality(device: cellar))
        #expect(latest.reading.values == [.co2: 720])
        #expect(latest.fetchedAt == clock.now)

        let old = AirQualityHour(hour: clock.now.addingTimeInterval(-HistoryStore.airQualityRetention - 3600), values: [.co2: 500])
        let new = AirQualityHour(hour: clock.now.addingTimeInterval(-3600), values: [.co2: 600, .humidity: 41])
        try store.upsertAirQualityHours([old, new], device: cellar, now: clock.now)
        #expect(try store.airQualityHours(device: cellar, from: .distantPast, to: .distantFuture) == [new])
        #expect(try store.latestAirQualityHour(device: cellar) == new.hour)
        #expect(try store.airQualityHours(device: bedroom, from: .distantPast, to: .distantFuture).isEmpty)
    }

    // MARK: Hub and service

    func hub(store: HistoryStore, sensor: FakeAirSensor) throws -> DeviceHub {
        let backend = MockBackend(timeZone: .gmt, now: clock.provider, units: [.unit(0)])
        let mock = MockMeter(now: clock.provider)
        try store.syncDevices(backend.listing, integration: DemoIntegration.id)
        try store.syncDevices(MockMeter.listing, integration: DemoMeterIntegration.id)
        try store.syncDevices(sensorListing, integration: FakeAirIntegration.id)
        let ids = [DemoIntegration.id, DemoMeterIntegration.id, FakeAirIntegration.id]
        return try DeviceHub(
            store: store, catalog: [DemoIntegration(), DemoMeterIntegration(), FakeAirIntegration()], fixedIntegrations: ids,
            defaultIntegrations: ids, isDemo: true, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper,
            makeRuntime: { integration in
                switch integration.id {
                case DemoMeterIntegration.id: IntegrationRuntime(integration: integration, connection: mock)
                case FakeAirIntegration.id: IntegrationRuntime(integration: integration, connection: sensor)
                default: IntegrationRuntime(integration: integration, connection: backend)
                }
            })
    }

    @Test func hubServesAHeatPumpAMeterAndSensors() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let hub = try hub(store: store, sensor: FakeAirSensor(devices: sensorListing))
        let devices = try await hub.devices()
        #expect(devices.map(\.kind) == [.airToAirHeatPump, .energyMeter, .airQualitySensor, .airQualitySensor])
        #expect(devices[2].capabilities == [.airQuality, .airQualityLog])
        #expect(try await hub.service(for: cellar)?.airQuality != nil)
        #expect(try await hub.heatPumpService(for: cellar) == nil)
        #expect(try await hub.meterService(for: cellar) == nil)
        #expect(try await hub.primaryDevice?.key == living)
        #expect(try await hub.priceControlDevice() == living)
        #expect(DeviceNavigation.screens(for: devices[2]) == [.overview, .history])
        #expect(DeviceNavigation.screens(kind: .airQualitySensor, capabilities: [.airQuality]) == [.overview])
        #expect(DeviceNavigation.normalized(.device(cellar, .control), devices: devices) == .device(cellar, .overview))
    }

    @Test func newestValuesAreOneRequestForEverySensorAtMostEveryFiveMinutes() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let sensor = FakeAirSensor(devices: sensorListing)
        let hub = try hub(store: store, sensor: sensor)
        let first = try #require(try await hub.airQualityService(for: cellar))
        let second = try #require(try await hub.airQualityService(for: bedroom))

        let sync = try await first.syncLatest()
        #expect(sync.status == .fetched)
        #expect(sync.count == 2)
        #expect(await sensor.latestCalls == [[cellar, bedroom]])
        // The other sensor finds its values fetched.
        #expect(try await second.syncLatest().status == .skipped)
        #expect(try await second.status()?.value(.co2)?.value == 650)
        clock.advance(299)
        #expect(try await first.syncLatest().status == .skipped)
        clock.advance(2)
        #expect(try await second.syncLatest().status == .fetched)
        #expect(await sensor.latestCalls.count == 2)

        let status = try #require(try await first.status())
        #expect(status.value(.radonShortTerm)?.level == .good)
        #expect(status.batteryPercent == 90)
        #expect(status.worstLevel == .good)
        #expect(!status.thresholdsFromDevice)
        #expect(try await first.lastSync() == clock.now)
    }

    @Test func historyBackfillsAYearInPiecesThenOnlyTheNewHours() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let sensor = FakeAirSensor(devices: sensorListing)
        let service = try #require(try await hub(store: store, sensor: sensor).airQualityService(for: cellar))
        let yearAgo = clock.now.addingTimeInterval(-365 * 86_400)

        #expect(try await service.syncHistory().status == .fetched)
        var calls = await sensor.hourlyCalls
        #expect(calls.count == 1)
        #expect(calls[0].start == yearAgo)  // the test clock is on a whole hour
        #expect(calls[0].end == yearAgo.addingTimeInterval(200 * 86_400))
        #expect(try await service.syncHistory().status == .skipped)  // hourly

        clock.advance(3600)
        _ = try await service.syncHistory()
        calls = await sensor.hourlyCalls
        #expect(calls[1].start == calls[0].end.addingTimeInterval(-2 * 3600))
        #expect(calls[1].end == clock.now)

        clock.advance(3600)
        _ = try await service.syncHistory()
        calls = await sensor.hourlyCalls
        #expect(calls[2].start == clock.now.addingTimeInterval(-3 * 3600))  // the last fetch less two hours
        #expect(try await service.hours(from: clock.now.addingTimeInterval(-3600), to: clock.now).first?.values[.co2] == 600)
    }

    @Test func thresholdsAreFetchedDailyOrAsLongAsTheyMayBeCached() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let sensor = FakeAirSensor(devices: sensorListing)
        await sensor.set(thresholds: AirQualityThresholds(ranges: [.co2: AirQualityThresholds.rising(500, 600)], maxAge: 2 * 86_400))
        let service = try #require(try await hub(store: store, sensor: sensor).airQualityService(for: cellar))
        #expect(try await service.syncThresholds().status == .fetched)
        _ = try await service.syncLatest()
        let status = try #require(try await service.status())
        #expect(status.thresholdsFromDevice)
        #expect(status.value(.co2)?.level == .poor)
        #expect(status.findings.map(\.code) == ["air_co2_high"])
        clock.advance(86_400 + 60)
        #expect(try await service.syncThresholds().status == .skipped)  // the vendor allows two days
        clock.advance(86_400)
        #expect(try await service.syncThresholds().status == .fetched)
        #expect(await sensor.thresholdCalls == 2)
    }

    @Test func aNearlyUsedUpBudgetStopsRequestsUntilTheWindowResets() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let sensor = FakeAirSensor(devices: sensorListing)
        let reset = clock.now.addingTimeInterval(1800)
        await sensor.set(budget: RequestBudget(limit: 120, remaining: 12, resetsAt: reset))
        let service = try #require(try await hub(store: store, sensor: sensor).airQualityService(for: cellar))
        #expect(try await service.syncLatest().status == .fetched)
        #expect(try store.blockStatus(now: clock.now, integration: FakeAirIntegration.id)?.until == reset)
        #expect(try await service.syncHistory().status == .skipped)
        #expect(await sensor.hourlyCalls.isEmpty)
        // Plenty left: no block.
        let other = try HistoryStore(path: temporaryDatabasePath())
        let relaxed = FakeAirSensor(devices: sensorListing)
        await relaxed.set(budget: RequestBudget(limit: 120, remaining: 13, resetsAt: reset))
        _ = try await hub(store: other, sensor: relaxed).airQualityService(for: cellar)?.syncLatest()
        #expect(try other.blockStatus(now: clock.now, integration: FakeAirIntegration.id) == nil)
    }

    @Test func refusalsStopEveryRequest() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let sensor = FakeAirSensor(devices: sensorListing)
        let service = try #require(try await hub(store: store, sensor: sensor).airQualityService(for: cellar))
        await sensor.set(failure: .rateLimited(until: clock.now.addingTimeInterval(600)))
        let limited = try await service.syncLatest()
        #expect(limited.status == .failed)
        #expect(limited.message?.contains("AirCo") == true)
        #expect(try await service.syncHistory().status == .skipped)

        let other = try HistoryStore(path: temporaryDatabasePath())
        let refused = FakeAirSensor(devices: sensorListing)
        await refused.set(failure: .invalidCredentials(nil))
        let second = try #require(try await hub(store: other, sensor: refused).airQualityService(for: cellar))
        #expect(try await second.syncLatest().status == .failed)
        #expect(try await second.credentialsRejected())
        clock.advance(3600)
        #expect(try await second.syncLatest().status == .skipped)
        #expect(await refused.latestCalls.count == 1)
    }

    @Test func radonNotificationIsOptInAndWeekly() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let sensor = FakeAirSensor(devices: sensorListing)
        await sensor.set(values: [.radonShortTerm: 140, .radonLongTerm: 130])
        let service = try #require(try await hub(store: store, sensor: sensor).airQualityService(for: cellar))
        _ = try await service.syncLatest()
        let status = try await service.status()
        #expect(try await service.radonAlertsEnabled() == false)
        let device = (key: cellar, name: "Kjeller")
        var plan = NotificationPlanner.planAirQuality(status: status, enabled: false, memory: NotificationMemory(), now: clock.now, device: device)
        #expect(plan.notifications.isEmpty)
        try await service.setRadonAlerts(true)
        #expect(try await service.radonAlertsEnabled())
        plan = NotificationPlanner.planAirQuality(status: status, enabled: true, memory: NotificationMemory(), now: clock.now, device: device)
        #expect(plan.notifications.map(\.id) == ["radon-high@fake-air:2930000001"])
        #expect(plan.notifications.first?.title.hasPrefix("Kjeller: ") == true)
        let again = NotificationPlanner.planAirQuality(
            status: status, enabled: true, memory: plan.memory, now: clock.now.addingTimeInterval(6 * 86_400), device: device)
        #expect(again.notifications.isEmpty)
        let week = NotificationPlanner.planAirQuality(
            status: status, enabled: true, memory: plan.memory, now: clock.now.addingTimeInterval(7 * 86_400), device: device)
        #expect(week.notifications.count == 1)
        // Memory from before this field decodes.
        let old = try JSONDecoder().decode(NotificationMemory.self, from: Data(#"{"activeErrorNotified":false}"#.utf8))
        #expect(old.lastRadonAlert == nil)
    }

    // MARK: MCP

    func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
    }

    @Test func airQualityToolsAppearOnlyWithASensorAndPickIt() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let sensor = FakeAirSensor(devices: sensorListing)
        let router = ToolRouter(hub: try hub(store: store, sensor: sensor), approver: FixedApprover(.approved))
        let names = await router.tools().map(\.name)
        #expect(names.contains("get_air_quality") && names.contains("get_air_quality_history") && names.contains("get_meter_status"))

        // Heat pump tools still need no device: neither the meter nor a sensor can answer them.
        let status = await router.handle(CallTool.Parameters(name: "get_status", arguments: [:]))
        #expect(status.isError != true)

        // Every sensor at once without device.
        let all = await router.handle(CallTool.Parameters(name: "get_air_quality", arguments: [:]))
        #expect(all.isError != true)
        #expect(text(all).contains(#""key":"fake-air:2930000001""#) && text(all).contains(#""key":"fake-air:2930000002""#))
        #expect(text(all).contains(#""level":"good""#))
        #expect(await sensor.latestCalls.count == 1)

        let one = await router.handle(CallTool.Parameters(name: "get_air_quality", arguments: ["device": "soverom"]))
        #expect(text(one).contains("2930000002") && !text(one).contains("2930000001"))

        // History needs the choice between the two sensors.
        let ambiguous = await router.handle(CallTool.Parameters(name: "get_air_quality_history", arguments: ["metric": "co2"]))
        #expect(ambiguous.isError == true)
        let history = await router.handle(
            CallTool.Parameters(name: "get_air_quality_history", arguments: ["metric": "co2", "device": "Kjeller"]))
        #expect(history.isError != true)
        #expect(text(history).contains(#""period":"hour""#))
        let wrong = await router.handle(CallTool.Parameters(name: "get_air_quality", arguments: ["device": .string(living.rawValue)]))
        #expect(wrong.isError == true)
        let badMetric = await router.handle(
            CallTool.Parameters(name: "get_air_quality_history", arguments: ["metric": "noise", "device": "Kjeller"]))
        #expect(badMetric.isError == true)

        // The instructions mention the sensors only when one is enabled.
        let devices = try await router.hub.devices()
        #expect(instructions(for: DemoIntegration(), devices: devices).contains("get_air_quality"))
        #expect(!instructions(for: DemoIntegration(), devices: Array(devices.prefix(2))).contains("get_air_quality"))

        // One heat pump only: the catalog is unchanged.
        let heatPump = DeviceDescriptor(key: living, name: "Living", kind: .airToAirHeatPump, capabilities: MockBackend(units: [.unit(0)]).capabilities)
        #expect(ToolCatalog.tools(for: [heatPump], service: "MELCloud").map(\.name) == ToolCatalog.all(service: "MELCloud").map(\.name))
        #expect(ToolCatalog.kind(of: "get_air_quality") == .airQualitySensor)
        #expect(ToolCatalog.kind(of: "get_status") == .airToAirHeatPump)
    }
}
