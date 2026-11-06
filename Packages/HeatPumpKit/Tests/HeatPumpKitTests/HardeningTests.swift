import Foundation
import GRDB
import Synchronization
import Testing
@testable import DemoIntegration
@testable import HeatPumpKit
@testable import MELCloudIntegration

/// A copy of `Fixtures/history_v11.sqlite` (see `DeviceKeyMigrationTests`) under a fresh directory.
func v11FixtureCopy() throws -> String {
    let url = try #require(Bundle.module.url(forResource: "history_v11", withExtension: "sqlite", subdirectory: "Fixtures"))
    let path = temporaryDatabasePath()
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: url.path, toPath: path)
    return path
}

@Suite("Concurrent first migration")
struct ConcurrentMigrationTests {
    /// App and helper open a v11 file at the same moment: the one that loses the race sees the
    /// other's migrations once it gets the write lock and runs again instead of failing.
    @Test func twoStoresOpeningOneV11FileBothSucceed() throws {
        for _ in 0..<4 {
            let path = try v11FixtureCopy()
            let failures = Mutex<[String]>([])
            DispatchQueue.concurrentPerform(iterations: 3) { _ in
                do {
                    let store = try HistoryStore(path: path, legacyIntegration: MELCloudIntegration.id)
                    _ = try store.devices()
                } catch {
                    failures.withLock { $0.append(String(describing: error)) }
                }
            }
            #expect(failures.withLock { $0 } == [])
            let store = try HistoryStore(path: path, legacyIntegration: MELCloudIntegration.id)
            #expect(try store.devices().map(\.key) == [.melcloud(12345)])
        }
    }

    /// A real failure is still reported (and quickly: nothing else is migrating the file).
    @Test func aFailureThatPersistsIsReported() throws {
        let path = try v11FixtureCopy()
        let start = Date()
        #expect(throws: HistoryStore.MissingLegacyIntegration.self) { _ = try HistoryStore(path: path) }
        #expect(Date().timeIntervalSince(start) < 0.5)
    }
}

@Suite("Demo database")
struct DemoDatabaseTests {
    @Test func demoWithoutAnExplicitPathNeverUsesTheRealDatabase() {
        let real = HistoryStore.defaultPath(environment: [:])
        #expect(real.hasSuffix("/Varmepumpe/varmepumpe.sqlite"))
        let demo = HistoryStore.defaultPath(environment: ["VARMEPUMPE_BACKEND": "mock"])
        #expect(demo != real)
        #expect(demo == URL(fileURLWithPath: real).deletingLastPathComponent().appending(path: "demo.sqlite").path)
        // An explicit path wins in both modes.
        #expect(HistoryStore.defaultPath(environment: ["VARMEPUMPE_BACKEND": "mock", "VARMEPUMPE_DB_PATH": "/tmp/x.sqlite"]) == "/tmp/x.sqlite")
        #expect(HistoryStore.defaultPath(environment: ["VARMEPUMPE_DB_PATH": "/tmp/y.sqlite"]) == "/tmp/y.sqlite")
    }
}

/// A helper from 1.x (before device keys) still running across the upgrade reads and writes the
/// plain `fetch_state` keys (`global`, `credentials`, `state`, `write`, `report.*`).
@Suite("Legacy fetch keys for a helper from before device keys")
struct LegacyFetchKeyTests {
    let t = Date(timeIntervalSince1970: 1_793_872_800)
    let melcloud = MELCloudIntegration.id
    let first = DeviceKey.melcloud(12345)
    let second = DeviceKey.melcloud(999)

    /// A MELCloud store that keeps the plain keys in step, with two devices (the first one is the
    /// device a 1.x helper serves).
    func makeStore(mirror: Bool = true) throws -> HistoryStore {
        let store = try HistoryStore(path: temporaryDatabasePath(), legacyKeyMirror: mirror ? melcloud : nil)
        try store.registerDevices([
            DeviceSummary(key: first, name: "Stue", kind: .airToAirHeatPump),
            DeviceSummary(key: second, name: "Soverom", kind: .airToAirHeatPump),
        ])
        return store
    }

    /// Writes a row as the 1.x helper's store does.
    func oldHelper(_ store: HistoryStore, _ sql: String, _ arguments: StatementArguments) throws {
        try store.pool.write { db in try db.execute(sql: sql, arguments: arguments) }
    }

    func plainRow(_ store: HistoryStore, _ key: String) throws -> Row? {
        try store.pool.read { db in try Row.fetchOne(db, sql: "SELECT * FROM fetch_state WHERE key = ?", arguments: [key]) }
    }

    func record(_ at: Date) -> ChangeRecord {
        ChangeRecord(timestamp: at, source: .app, field: "power", oldValue: "on", newValue: "off", reason: nil, result: .pending)
    }

    @Test func anOldHelpersBlockAndReservationsHoldBackTheNewApp() async throws {
        let store = try makeStore()
        // The old helper hit a login throttle and fetched the state and the energy report.
        try oldHelper(store, "INSERT INTO fetch_state (key, blockedUntil, reason) VALUES ('global', ?, 'loginThrottled')", [t.addingTimeInterval(600)])
        try oldHelper(store, "INSERT INTO fetch_state (key, lastAttempt) VALUES ('state', ?)", [t.addingTimeInterval(-10)])
        try oldHelper(store, "INSERT INTO fetch_state (key, lastAttempt) VALUES ('report.energy', ?)", [t.addingTimeInterval(-10)])
        try oldHelper(store, "INSERT INTO fetch_state (key, lastAttempt) VALUES ('write', ?)", [t.addingTimeInterval(-2)])

        #expect(try store.blockStatus(now: t, integration: melcloud) == BlockStatus(until: t.addingTimeInterval(600), reason: .loginThrottled))
        #expect(try store.blockedUntil(now: t, integration: melcloud) == t.addingTimeInterval(600))
        #expect(
            try store.reserveFetch(key: "\(melcloud)/state", minInterval: 60, now: t, blockingIntegration: melcloud)
                == .blocked(until: t.addingTimeInterval(600)))

        // The service makes no call while the old helper's block lasts.
        let clock = TestClock(t)
        let backend = CountingBackend(now: clock.provider)
        let service = HeatPumpService(backend: backend, store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        let result = try await service.currentState(force: true)
        #expect(result.blockReason == .loginThrottled)
        #expect(await backend.fetchStateCalls == 0)

        // Without a block, the old helper's last state fetch and report still space the new ones.
        try oldHelper(store, "DELETE FROM fetch_state WHERE key = 'global'", [])
        #expect(
            try store.reserveFetch(key: "\(melcloud)/state", minInterval: 60, now: t, blockingIntegration: melcloud)
                == .throttled(nextAllowed: t.addingTimeInterval(50)))
        let report = HistoryStore.fetchKey("report.energy", device: first)
        #expect(
            try store.reserveFetch(key: report, minInterval: 3600, now: t, blockingIntegration: melcloud)
                == .throttled(nextAllowed: t.addingTimeInterval(3590)))
        // The old helper served the first device only; the second one's reports are its own.
        let secondReport = HistoryStore.fetchKey("report.energy", device: second)
        #expect(try store.reserveFetch(key: secondReport, minInterval: 3600, now: t, blockingIntegration: melcloud) == .allowed)
        // Its last write keeps the 5 s spacing.
        #expect(try store.reserveChange([record(t)], device: first) == .tooSoon(nextAllowed: t.addingTimeInterval(3)))
        #expect(try store.writeUsage(integration: melcloud, now: t).lastWrite == t.addingTimeInterval(-2))

        // Refused credentials recorded by the old helper stop the new app too.
        try oldHelper(store, "INSERT INTO fetch_state (key, lastAttempt, blockedUntil) VALUES ('credentials', ?, ?)", [t, HistoryStore.indefinite])
        #expect(try store.credentialsRejected(integration: melcloud))
        #expect(try store.reserveFetch(key: "\(melcloud)/state", minInterval: 60, now: t.addingTimeInterval(120), blockingIntegration: melcloud)
            == .credentialsRejected)
        try store.clearCredentialsRejected(integration: melcloud)
        #expect(try !store.credentialsRejected(integration: melcloud))
        #expect(try plainRow(store, "credentials") == nil)
    }

    @Test func theNewAppsBlockAndReservationsReachTheOldHelper() throws {
        let store = try makeStore()
        try store.recordBlock(until: t.addingTimeInterval(900), reason: .rateLimited, integration: melcloud)
        let global = try #require(try plainRow(store, "global"))
        #expect(global["blockedUntil"] as Date? == t.addingTimeInterval(900))
        #expect(global["reason"] as String? == "rateLimited")

        try store.recordCredentialsRejected(now: t, integration: melcloud)
        #expect(try plainRow(store, "credentials")?["blockedUntil"] as Date? == HistoryStore.indefinite)
        try store.clearCredentialsRejected(integration: melcloud)
        #expect(try plainRow(store, "credentials") == nil)

        let later = t.addingTimeInterval(1000)
        #expect(try store.reserveFetch(key: "\(melcloud)/state", minInterval: 60, now: later, blockingIntegration: melcloud) == .allowed)
        #expect(try plainRow(store, "state")?["lastAttempt"] as Date? == later)
        let report = HistoryStore.fetchKey("report.temperature", device: first)
        #expect(try store.reserveFetch(key: report, minInterval: 3600, now: later, blockingIntegration: melcloud) == .allowed)
        #expect(try plainRow(store, "report.temperature")?["lastAttempt"] as Date? == later)
        // The second device's reports never touch the old helper's row.
        let secondReport = HistoryStore.fetchKey("report.energy", device: second)
        #expect(try store.reserveFetch(key: secondReport, minInterval: 3600, now: later, blockingIntegration: melcloud) == .allowed)
        #expect(try plainRow(store, "report.energy") == nil)

        guard case .reserved = try store.reserveChange([record(later)], device: second) else {
            Issue.record("expected a reservation")
            return
        }
        #expect(try plainRow(store, "write")?["lastAttempt"] as Date? == later)
        // Device-scoped keys other than reports are not the old helper's business.
        #expect(try store.reserveFetch(key: HistoryStore.fetchKey("away", device: first), minInterval: 60, now: later, blockingIntegration: melcloud) == .allowed)
        #expect(try plainRow(store, "away") == nil)
    }

    @Test func onlyTheMirroredIntegrationReadsPlainKeys() throws {
        let store = try makeStore(mirror: false)
        try oldHelper(store, "INSERT INTO fetch_state (key, blockedUntil, reason) VALUES ('global', ?, 'rateLimited')", [t.addingTimeInterval(600)])
        #expect(try store.blockStatus(now: t, integration: melcloud) == nil)
        #expect(try store.reserveFetch(key: "\(melcloud)/state", minInterval: 60, now: t, blockingIntegration: melcloud) == .allowed)
        #expect(try plainRow(store, "state") == nil)

        let mirrored = try makeStore()
        try oldHelper(mirrored, "INSERT INTO fetch_state (key, blockedUntil, reason) VALUES ('global', ?, 'rateLimited')", [t.addingTimeInterval(600)])
        #expect(try mirrored.reserveFetch(key: "demo/state", minInterval: 60, now: t, blockingIntegration: "demo") == .allowed)
        #expect(try mirrored.blockStatus(now: t, integration: "demo") == nil)
    }

    @Test func migrationKeepsThePlainRows() throws {
        let path = try v11FixtureCopy()
        let base = t
        let store = try HistoryStore(path: path, legacyIntegration: melcloud, legacyKeyMirror: melcloud)
        // v12 copies the integration's rows; the plain ones stay for a 1.x helper.
        #expect(try plainRow(store, "global")?["blockedUntil"] as Date? == base.addingTimeInterval(7200))
        #expect(try plainRow(store, "global")?["reason"] as String? == "loginThrottled")
        #expect(try plainRow(store, "state")?["lastSuccess"] as Date? == base.addingTimeInterval(-30))
        #expect(try plainRow(store, "report.energy")?["lastSuccess"] as Date? == base.addingTimeInterval(-600))
        #expect(try plainRow(store, "write")?["lastAttempt"] as Date? == base.addingTimeInterval(-1800))
        #expect(try store.fetchState(key: "\(melcloud)/global")?.blockedUntil == base.addingTimeInterval(7200))
    }

    /// A file migrated by a build whose v12 moved the rows gets them back in v15.
    @Test func v15RestoresThePlainRowsOfAFileMigratedBefore() throws {
        let path = try v11FixtureCopy()
        let base = t
        do {
            let store = try HistoryStore(path: path, legacyIntegration: melcloud)
            try store.pool.write { db in
                try db.execute(sql: "DELETE FROM fetch_state WHERE key IN ('global', 'credentials', 'state', 'write', 'away') OR key LIKE 'report.%'")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [HistoryStore.legacyKeysMigration])
                // The device's own report row is newer than the integration's (the state after v13).
                try db.execute(
                    sql: "UPDATE fetch_state SET lastAttempt = ? WHERE key = ?",
                    arguments: [base.addingTimeInterval(-60), HistoryStore.fetchKey("report.energy", device: first)])
            }
            #expect(try plainRow(store, "global") == nil)
        }
        let store = try HistoryStore(path: path, legacyIntegration: melcloud, legacyKeyMirror: melcloud)
        #expect(try plainRow(store, "global")?["blockedUntil"] as Date? == base.addingTimeInterval(7200))
        #expect(try plainRow(store, "state")?["lastSuccess"] as Date? == base.addingTimeInterval(-30))
        #expect(try plainRow(store, "write")?["lastAttempt"] as Date? == base.addingTimeInterval(-1800))
        #expect(try plainRow(store, "report.energy")?["lastAttempt"] as Date? == base.addingTimeInterval(-60))
        #expect(try plainRow(store, "away")?["blockedUntil"] as Date? == base.addingTimeInterval(86_400))
        // Third-party keys were plain all along.
        #expect(try plainRow(store, "prices.hvakosterstrommen.NO1") != nil)
    }
}

@Suite("Price control on a device that goes away")
struct PriceControlDeviceTests {
    let clock = TestClock()  // 10:00Z; 10–12 are very expensive below
    let living = DemoUnit.unit(0).key
    let bedroom = DemoUnit.unit(1).key

    /// A hub over `account` (living room and bedroom listed), with Tibber-style prices stored and
    /// both states fetched (living room 21 °C, bedroom 19 °C).
    func makeHub(_ account: SwitchableAccount, store: HistoryStore) async throws -> DeviceHub {
        try store.registerDevices(account.inner.listing)
        let hub = try DeviceHub(
            store: store, catalog: [DemoIntegration()], defaultIntegrations: [DemoIntegration.id], isDemo: true, timeZone: .gmt,
            now: clock.provider, sleep: clock.sleeper, makeRuntime: { IntegrationRuntime(integration: $0, connection: account) })
        let a = try #require(try await hub.heatPumpService(for: living))
        let b = try #require(try await hub.heatPumpService(for: bedroom))
        try await a.savePriceSettings(PriceSettings(agreement: .tibber))
        let today = WireDate.calendar(.gmt).startOfDay(for: clock.now)
        try store.upsertPrices((0..<24).map { h in
            let expensive = h == 10 || h == 11
            return HourPrice(
                hour: today.addingTimeInterval(Double(h) * 3600), area: "NO1", source: "mock", spotOre: expensive ? 200 : 80,
                totalOre: expensive ? 250 : 100, level: expensive ? "VERY_EXPENSIVE" : "NORMAL")
        })
        _ = try await a.currentState()
        clock.advance(61)
        _ = try await b.currentState()
        return hub
    }

    @Test func memoryAndComfortTemperatureBelongToTheirDevice() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let account = SwitchableAccount(now: clock.provider, listed: [living, bedroom])
        let hub = try await makeHub(account, store: store)
        let a = try #require(try await hub.heatPumpService(for: living))
        let b = try #require(try await hub.heatPumpService(for: bedroom))

        let status = try await a.enablePriceControl()
        #expect(status.kind == .lowered && status.currentStep?.target == 19)
        #expect(try await a.priceControlSettings().comfortTemperature == 21)
        #expect(try await a.priceControlRuntime().memory.lastSent == 19)
        let sent = await account.inner.appliedChanges.count

        // The bedroom (also at 19) never sees the living room's memory or comfort temperature.
        #expect(try await b.priceControlSettings().comfortTemperature == nil)
        #expect(try await b.priceControlRuntime().memory.lastSent == nil)
        #expect(try await b.restorePriceControl(reason: "test", always: true) == nil)
        #expect(await account.inner.appliedChanges.count == sent)

        // Steering the bedroom instead starts from its own setpoint.
        try await a.disablePriceControl()
        try await hub.setPriceControlDevice(bedroom)
        clock.advance(61)
        _ = try await b.currentState(force: true)
        try await b.enablePriceControl()
        #expect(try await b.priceControlSettings().comfortTemperature == 19)
        #expect(try await a.priceControlSettings().comfortTemperature == 21)
    }

    @Test func aDeviceTheAccountNoLongerListsIsRestoredAndPriceControlTurnedOff() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let account = SwitchableAccount(now: clock.provider, listed: [living, bedroom])
        let hub = try await makeHub(account, store: store)
        let a = try #require(try await hub.priceControlService())
        #expect(try await a.currentDevice() == living)
        try await a.enablePriceControl()
        #expect(await account.inner.appliedChanges.last == ChangeSet(device: living, setTemperature: 19))

        await account.list([bedroom])
        clock.advance(61)
        _ = try await hub.refreshDeviceList()
        #expect(try await hub.devices().map(\.key) == [bedroom])
        #expect(await account.inner.appliedChanges.last == ChangeSet(device: living, setTemperature: 21))
        #expect(try await !a.priceControlSettings().enabled)
        // Price control now points at the bedroom, which it has not touched.
        let b = try #require(try await hub.priceControlService())
        #expect(try await b.currentDevice() == bedroom)
        #expect(try await !b.priceControlSettings().enabled)
        #expect(try await b.priceControlRuntime().memory.lastSent == nil)
    }

    @Test func v15GivesTheMemoryAndComfortTemperatureToTheControlledDevice() throws {
        let path = temporaryDatabasePath()
        do {
            let store = try HistoryStore(path: path)
            try store.registerDevices(MockBackend.listing([.unit(0), .unit(1)]))
            try store.saveSetting(bedroom, key: DeviceHub.priceControlDeviceKey)
            try store.saveSetting(PriceControlSettings(enabled: true, comfortTemperature: 20.5), key: HeatPumpService.priceControlKey)
            try store.saveSetting(PriceControlRuntime(memory: PriceControlMemory(lastSent: 18.5)), key: HeatPumpService.priceControlRuntimeKey)
            try store.pool.write { db in
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [HistoryStore.legacyKeysMigration])
            }
        }
        let store = try HistoryStore(path: path)
        #expect(try store.setting(JSONValue.self, key: HeatPumpService.priceControlRuntimeKey) == nil)
        let moved = try #require(
            try store.setting(PriceControlRuntime.self, key: HistoryStore.deviceSettingKey(HeatPumpService.priceControlRuntimeKey, device: bedroom)))
        #expect(moved.memory.lastSent == 18.5)
        #expect(moved.comfortTemperature == 20.5)
    }
}
