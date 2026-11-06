import Foundation
import Testing
@testable import DemoIntegration
@testable import HeatPumpKit
@testable import MELCloudIntegration

/// `Fixtures/history_v11.sqlite` was written by the store as it was before device keys (schema
/// v11): device 12345 in building 678 ("Stue"), three snapshots (cool, fan, heat; the newest
/// stale), an expected state (dry), the device object, two error events, two temperature points,
/// two energy days, an air-filter record, three change-log rows (one batch of two sent, one
/// rejected), two local readings, last fetches for `state` and `report.energy`, an `away`
/// refusal, a price fetch and a login-throttle block until 12:00Z on 2026-11-05.
@Suite("Device keys: migration from v11")
struct DeviceKeyMigrationTests {
    let base = Date(timeIntervalSince1970: 1_793_872_800)  // 2026-11-05T10:00:00Z, when the fixture was written
    let device = DeviceKey.melcloud(12345)
    let other = DeviceKey(integration: MELCloudIntegration.id, nativeId: "999")
    let melcloud = MELCloudIntegration.id

    /// A copy of the fixture under a fresh directory.
    func fixtureCopy() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "history_v11", withExtension: "sqlite", subdirectory: "Fixtures"))
        let path = temporaryDatabasePath()
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: url.path, toPath: path)
        return path
    }

    @Test func keysEveryRowAndKeepsData() throws {
        let path = try fixtureCopy()
        let store = try HistoryStore(path: path, legacyIntegration: melcloud)
        let day: TimeInterval = 86_400

        // Device registry: the one device, enabled, with its name and building.
        let devices = try store.devices()
        #expect(devices.count == 1)
        let record = try #require(devices.first)
        #expect(record.key == device)
        #expect(record.kind == .airToAirHeatPump)
        #expect(record.enabled)
        #expect(record.name == "Stue")
        #expect(record.metadata == ["buildingId": "678"])
        #expect(record.firstSeen == base.addingTimeInterval(-7200))
        #expect(record.lastSeen == base.addingTimeInterval(-60))

        // Snapshots: modes stored as integers decode, and the newest keeps its stale flag.
        let snapshots = try store.snapshots(device: device, from: base.addingTimeInterval(-day), to: base)
        #expect(snapshots.map(\.mode) == [.cool, .fan, .heat])
        #expect(snapshots.allSatisfy { $0.key == device && $0.vaneVertical == .swing && $0.vaneHorizontal == .split })
        let latest = try #require(try store.latestSnapshot(device: device))
        #expect(latest.stale)
        #expect(latest.state.setTemperature == 21)
        #expect(try store.expectedState(device: device)?.state.mode == .dry)
        #expect(try store.rawDevice(device)?.listing?["DeviceName"]?.string == "Stue")

        // Logs and history.
        #expect(try store.errorEvents(device: device, since: base.addingTimeInterval(-2 * day)).map(\.message) == ["state error", "E6"])
        #expect(try store.temperaturePoints(device: device, from: base.addingTimeInterval(-day), to: base).count == 2)
        #expect(try store.latestEnergyDay(device: device) == "2026-11-04")
        #expect(try store.energyDays(device: device, fromDay: "2026-11-01", toDay: "2026-11-30").map(\.totalKWh) == [7.5, 8.25])

        // Rows without a device id got the device's key (another device's filter excludes them).
        #expect(try store.maintenanceRecords(device: device).map(\.note) == ["Vasket"])
        #expect(try store.maintenanceRecords(device: other).isEmpty)
        #expect(try store.changes(device: device).count == 3)
        #expect(try store.changes(device: other).isEmpty)
        let samples = try store.localSamples(device: device, from: base.addingTimeInterval(-day), to: base)
        #expect(samples.map(\.powerW) == [420, 450])
        #expect(samples.allSatisfy { $0.mode == .heat && $0.vaneVertical == .swing && $0.vaneHorizontal == .swing })
        #expect(try store.localSamples(device: other, from: base.addingTimeInterval(-day), to: base).isEmpty)

        // The sent batch still counts toward the integration's budget; the rejected row does not.
        let usage = try store.writeUsage(integration: melcloud, now: base)
        #expect(usage.used == [base.addingTimeInterval(-1800)])
        #expect(usage.lastWrite == base.addingTimeInterval(-1800))

        // Tables that are not device-scoped are untouched.
        #expect(try store.prices(source: "hvakosterstrommen", area: "NO1", from: base, to: base.addingTimeInterval(3600)).count == 1)
        #expect(try store.setting([String: String].self, key: "fixture") == ["area": "NO1"])
        #expect(try store.forecast(from: base, to: base.addingTimeInterval(3600)).count == 1)
        #expect(try store.houseHours(from: base.addingTimeInterval(-day), to: base).count == 1)
    }

    @Test func activeBlockAndLastFetchesSurvive() async throws {
        let path = try fixtureCopy()
        let store = try HistoryStore(path: path, legacyIntegration: melcloud)
        let now = base.addingTimeInterval(60)

        // The integration's rows were copied to its namespace (the plain ones stay for a 1.x
        // helper, `LegacyFetchKeyTests`); third-party keys were not.
        #expect(try store.fetchState(key: "global")?.blockedUntil == base.addingTimeInterval(7200))
        #expect(try store.blockStatus(now: now, integration: melcloud) == BlockStatus(until: base.addingTimeInterval(7200), reason: .loginThrottled))
        #expect(try store.fetchState(key: "\(melcloud)/state")?.lastSuccess == base.addingTimeInterval(-30))
        #expect(try store.fetchState(key: "\(melcloud)/report.energy")?.lastSuccess == base.addingTimeInterval(-600))
        #expect(try store.fetchState(key: "\(melcloud)/away")?.blockedUntil == base.addingTimeInterval(86_400))
        #expect(try store.fetchState(key: "\(melcloud)/write")?.lastAttempt == base.addingTimeInterval(-1800))
        #expect(try store.fetchState(key: "prices.hvakosterstrommen.NO1") != nil)

        // The block still stops every call to the service, from any process.
        #expect(
            try store.reserveFetch(key: "\(melcloud)/state", minInterval: 60, now: now, blockingIntegration: melcloud)
                == .blocked(until: base.addingTimeInterval(7200)))
        let clock = TestClock(now)
        let backend = CountingBackend(now: clock.provider)
        let service = HeatPumpService(backend: backend, store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        let result = try await service.currentState(force: true)
        #expect(result.blockReason == .loginThrottled)
        #expect(result.blockedUntil == base.addingTimeInterval(7200))
        #expect(result.state?.key == device)
        #expect(await backend.fetchStateCalls == 0)
        // The away refusal still pauses automatic reads.
        #expect(try await service.endpointRefusedUntil(HeatPumpService.awayFetchKey) == base.addingTimeInterval(86_400))
    }

    @Test func backupIsTheUnmigratedFileAndOpeningTwiceIsIdempotent() throws {
        let path = try fixtureCopy()
        let backup = HistoryStore.backupPath(for: path)
        #expect(backup.hasSuffix("/test-pre-v12.sqlite"))
        #expect(!FileManager.default.fileExists(atPath: backup))

        _ = try HistoryStore(path: path, legacyIntegration: melcloud)
        #expect(FileManager.default.fileExists(atPath: backup))
        let written = try FileManager.default.attributesOfItem(atPath: backup)[.modificationDate] as? Date

        // The copy is the v11 file: its rows still lack device keys, so it cannot be opened
        // without knowing their integration, and opening it with one migrates it the same way.
        let copy = temporaryDatabasePath()
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: copy).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: backup, toPath: copy)
        #expect(throws: HistoryStore.MissingLegacyIntegration.self) { _ = try HistoryStore(path: copy) }
        #expect(try HistoryStore(path: copy, legacyIntegration: melcloud).latestSnapshot(device: device)?.state.mode == .heat)

        // Opening again changes nothing and keeps the first backup.
        let again = try HistoryStore(path: path, legacyIntegration: melcloud)
        #expect(try again.devices().count == 1)
        #expect(try again.snapshots(device: device, from: base.addingTimeInterval(-86_400), to: base).count == 3)
        #expect(try again.changes(device: nil).count == 3)
        #expect(try FileManager.default.attributesOfItem(atPath: backup)[.modificationDate] as? Date == written)
    }

    @Test func newDatabaseNeedsNoBackup() throws {
        let path = temporaryDatabasePath()
        let store = try HistoryStore(path: path, legacyIntegration: melcloud)
        #expect(!FileManager.default.fileExists(atPath: HistoryStore.backupPath(for: path)))
        #expect(try store.devices().isEmpty)
        _ = try HistoryStore(path: path)
        #expect(!FileManager.default.fileExists(atPath: HistoryStore.backupPath(for: path)))
    }
}

@Suite("Device keys")
struct DeviceKeyTests {
    @Test func parsesAndEncodes() throws {
        let key = try #require(DeviceKey("melcloud-classic:12345"))
        #expect(key.integration == "melcloud-classic")
        #expect(key.nativeId == "12345")
        #expect(DeviceKey("demo:a:b")?.nativeId == "a:b")
        #expect(DeviceKey("nocolon") == nil)
        #expect(DeviceKey(":1") == nil)
        let data = try JSONEncoder().encode(key)
        #expect(String(decoding: data, as: UTF8.self) == "\"melcloud-classic:12345\"")
        #expect(try JSONDecoder().decode(DeviceKey.self, from: data) == key)
    }

    @Test func enumsAreStoredByKeyAndReadLegacyIntegers() throws {
        let encoded = try JSONEncoder().encode([OperationMode.heat, .fan])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["heat","fan"]"#)
        #expect(try JSONDecoder().decode([OperationMode].self, from: Data("[1,2,3,7,8]".utf8)) == [.heat, .dry, .cool, .fan, .auto])
        #expect(try JSONDecoder().decode([OperationMode].self, from: Data(#"["auto"]"#.utf8)) == [.auto])
        #expect(try JSONDecoder().decode([VaneVertical].self, from: Data("[0,1,5,7]".utf8)) == [.auto, .position1, .position5, .swing])
        #expect(try JSONDecoder().decode([VaneHorizontal].self, from: Data("[3,8,12]".utf8)) == [.position3, .split, .swing])
        #expect(try JSONDecoder().decode([VaneHorizontal].self, from: Data(#"["5_right"]"#.utf8)) == [.position5])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(OperationMode.self, from: Data("4".utf8)) }
    }

    @Test func melcloudMapsItsOwnNumbers() {
        #expect(OperationMode.allCases.map(\.melcloudValue) == [1, 2, 3, 7, 8])
        #expect(VaneVertical.allCases.map(\.melcloudValue) == [0, 1, 2, 3, 4, 5, 7])
        #expect(VaneHorizontal.allCases.map(\.melcloudValue) == [0, 1, 2, 3, 4, 5, 8, 12])
        #expect(CloudOperationMode(raw: 9) == CloudOperationMode(mode: .heat, iSee: true, raw: 9))
        #expect(DeviceKey.melcloud(7).rawValue == "melcloud-classic:7")
    }

    @Test func blocksAndBudgetsArePerIntegration() throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let t = Date(timeIntervalSince1970: 1_793_872_800)
        try store.recordBlock(until: t.addingTimeInterval(600), reason: .rateLimited, integration: "melcloud-classic")
        #expect(
            try store.reserveFetch(key: "melcloud-classic/state", minInterval: 60, now: t, blockingIntegration: "melcloud-classic")
                == .blocked(until: t.addingTimeInterval(600)))
        #expect(try store.reserveFetch(key: "demo/state", minInterval: 60, now: t, blockingIntegration: "demo") == .allowed)
        try store.recordCredentialsRejected(now: t, integration: "demo")
        #expect(try store.credentialsRejected(integration: "demo"))
        #expect(try !store.credentialsRejected(integration: "melcloud-classic"))

        func record(_ at: Date) -> ChangeRecord {
            ChangeRecord(timestamp: at, source: .app, field: "power", oldValue: "on", newValue: "off", reason: nil, result: .pending)
        }
        _ = try store.reserveChange([record(t)], device: .melcloud(1), limit: 1)
        if case .reserved = try store.reserveChange([record(t.addingTimeInterval(10))], device: .melcloud(1), limit: 1) {
            Issue.record("the integration's budget is used up")
        }
        // Another integration has its own budget and spacing.
        guard case .reserved = try store.reserveChange([record(t.addingTimeInterval(1))], device: MockBackend.device, limit: 1) else {
            Issue.record("expected a reservation for the other integration")
            return
        }
    }
}
