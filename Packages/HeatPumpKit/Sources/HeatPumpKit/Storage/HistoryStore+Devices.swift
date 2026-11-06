import Foundation
import GRDB

/// A device in the registry (`devices`): every device the store holds data for.
public struct DeviceRecord: Sendable, Equatable {
    public var key: DeviceKey
    public var kind: DeviceKind
    /// The name the integration reports (updated with every status).
    public var name: String
    /// The user's own name for the device (`rename`), or nil.
    public var customName: String?
    /// Disabled devices keep their data but are not served.
    public var enabled: Bool
    public var sortOrder: Int
    /// Integration-defined attributes (`DeviceSummary.metadata`).
    public var metadata: [String: String]
    public var firstSeen: Date?
    public var lastSeen: Date?

    public var summary: DeviceSummary { DeviceSummary(key: key, name: name, kind: kind, metadata: metadata) }

    /// The user's name when set, else the integration's.
    public var displayName: String {
        guard let customName, !customName.isEmpty else { return name }
        return customName
    }
}

extension HistoryStore {
    // MARK: Device registry

    /// All devices, enabled first in their sort order.
    public func devices() throws -> [DeviceRecord] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM devices ORDER BY enabled DESC, sortOrder, key").compactMap { row in
                guard let key = DeviceKey(row["key"] as String) else { return nil }
                let metadata = (row["metadata"] as String?).flatMap {
                    try? JSONDecoder().decode([String: String].self, from: Data($0.utf8))
                }
                return DeviceRecord(
                    key: key, kind: DeviceKind(rawValue: row["kind"]) ?? .airToAirHeatPump, name: row["name"],
                    customName: row["customName"], enabled: row["enabled"], sortOrder: row["sortOrder"], metadata: metadata ?? [:],
                    firstSeen: row["firstSeen"], lastSeen: row["lastSeen"])
            }
        }
    }

    /// Adds listed devices that are new (enabled, after the existing ones) and refreshes the
    /// name, kind and metadata of known ones. Never enables or disables a known device.
    public func registerDevices(_ devices: [DeviceSummary]) throws {
        try pool.write { db in
            for device in devices { try Self.upsertDevice(device, seen: nil, full: true, db: db) }
        }
    }

    /// Inserts the device (enabled, last in order) when it is not in the registry; otherwise
    /// updates its name and when it was last seen, and with `full` also its kind and metadata. An
    /// energy meter adopts the house's hours kept under `pendingMeterKey`.
    static func upsertDevice(_ device: DeviceSummary, seen: Date?, full: Bool, db: Database) throws {
        let json = full ? String(decoding: try JSONEncoder().encode(device.metadata), as: UTF8.self) : nil
        try db.execute(
            sql: """
                INSERT INTO devices (key, integration, kind, name, nativeId, enabled, sortOrder, metadata, firstSeen, lastSeen)
                VALUES (?, ?, ?, ?, ?, 1, (SELECT COALESCE(MAX(sortOrder) + 1, 0) FROM devices), ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    name = excluded.name,
                    kind = CASE WHEN ? THEN excluded.kind ELSE kind END,
                    metadata = COALESCE(excluded.metadata, metadata),
                    firstSeen = COALESCE(firstSeen, excluded.firstSeen),
                    lastSeen = CASE WHEN lastSeen IS NULL OR excluded.lastSeen > lastSeen THEN excluded.lastSeen ELSE lastSeen END
                """,
            arguments: [
                device.key.rawValue, device.key.integration, device.kind.rawValue, device.name, device.key.nativeId, json,
                seen, seen, full,
            ])
        // The first meter takes over the house's hours fetched before any meter was known.
        if full, device.kind == .energyMeter { try adoptPendingMeterHours(to: device.key, db: db) }
    }

    // MARK: Backup before device keys

    /// Identifier of the migration that introduced device keys.
    static let deviceKeyMigration = "v12"

    /// Where the copy taken before the device-key migration is kept: `<name>-pre-v12.sqlite`
    /// next to the database.
    public static func backupPath(for path: String) -> String { backupPath(for: path, before: deviceKeyMigration) }

    /// Where the copy taken before `migration` is kept: `<name>-pre-<migration>.sqlite`.
    public static func backupPath(for path: String, before migration: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appending(path: "\(name)-pre-\(migration).sqlite").path
    }

    /// Copies an existing database (one that has migrations but not the device-key one) with
    /// SQLite's backup API, which includes what is still in the WAL. Done once: an existing copy
    /// is never overwritten. New databases need no copy. The copy is written under a temporary
    /// name and moved into place, so a crash never leaves a partial file that looks complete.
    func backUpBeforeDeviceKeysIfNeeded(_ migrator: DatabaseMigrator) throws {
        let applied = try pool.read { db in try migrator.appliedIdentifiers(db) }
        guard !applied.isEmpty, !applied.contains(Self.deviceKeyMigration) else { return }
        try backUp(to: Self.backupPath(for: path))
    }

    /// Copies the database to `backup` once (see `backUpBeforeDeviceKeysIfNeeded`).
    func backUp(to backup: String) throws {
        guard !FileManager.default.fileExists(atPath: backup) else { return }
        let partial = backup + ".partial-\(UUID().uuidString)"
        do {
            let queue = try DatabaseQueue(path: partial)
            try pool.backup(to: queue)
            try queue.close()
            try FileManager.default.moveItem(atPath: partial, toPath: backup)
        } catch {
            try? FileManager.default.removeItem(atPath: partial)
            // Another process may have finished the same copy first.
            if FileManager.default.fileExists(atPath: backup) { return }
            throw error
        }
    }

    // MARK: Migration to device keys (v12)

    /// The error when a file with pre-v12 rows is opened without knowing whose rows they are.
    struct MissingLegacyIntegration: Error, CustomStringConvertible {
        var description: String { "The database holds data from before device keys; open it with the integration that wrote it." }
    }

    /// `fetch_state` keys that belong to the device integration (everything but third-party
    /// sources such as prices, weather and house consumption). They get the integration's prefix.
    static let legacyIntegrationFetchKeys = [
        "global", "credentials", "write", "state", "away", "timer", "away.verify", "timer.verify", "timer.presave",
        "firmware", "local", "local.discovery", "local.autodiscovery", "local.prune",
    ]

    /// Gives every device-scoped row a `deviceKey` built from its legacy integer id and
    /// `legacyIntegration`, registers the devices, stores the snapshot mode as its key and
    /// namespaces the integration's `fetch_state` keys. Rows without a device id (change log,
    /// maintenance, local readings) get the current device: the one with the newest snapshot (or,
    /// without snapshots, the newest stored device object); only that device stays enabled.
    static func migrateToDeviceKeys(_ db: Database, legacyIntegration: String?) throws {
        try db.execute(
            sql: """
                CREATE TABLE devices (
                    key TEXT PRIMARY KEY,
                    integration TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    name TEXT NOT NULL,
                    nativeId TEXT NOT NULL,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    sortOrder INTEGER NOT NULL DEFAULT 0,
                    metadata TEXT,
                    firstSeen DATETIME,
                    lastSeen DATETIME
                );
                """)
        let idTables = ["snapshots", "device_raw", "expected_state", "error_events", "temperature_log", "energy_daily"]
        let legacyIds = try Int.fetchAll(
            db, sql: idTables.map { "SELECT deviceId FROM \($0)" }.joined(separator: " UNION ") + " ORDER BY 1")
        let placeholders = legacyIntegrationFetchKeys.map { _ in "?" }.joined(separator: ", ")
        let fetchFilter = "key IN (\(placeholders)) OR key LIKE 'report.%'"
        let legacyFetchRows = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM fetch_state WHERE \(fetchFilter)",
            arguments: StatementArguments(legacyIntegrationFetchKeys)) ?? 0
        guard (legacyIds.isEmpty && legacyFetchRows == 0) || legacyIntegration != nil else { throw MissingLegacyIntegration() }
        let integration = legacyIntegration ?? ""
        func key(_ id: Int) -> String { DeviceKey(integration: integration, nativeId: String(id)).rawValue }

        // The current device and the registry.
        let current =
            try Int.fetchOne(db, sql: "SELECT deviceId FROM snapshots ORDER BY ts DESC, id DESC LIMIT 1")
            ?? Int.fetchOne(db, sql: "SELECT deviceId FROM device_raw ORDER BY ts DESC LIMIT 1")
            ?? legacyIds.first
        let ordered = (current.map { [$0] } ?? []) + legacyIds.filter { $0 != current }
        for (index, id) in ordered.enumerated() {
            let latest = try String.fetchOne(
                db, sql: "SELECT stateJSON FROM snapshots WHERE deviceId = ? ORDER BY ts DESC, id DESC LIMIT 1", arguments: [id])
                ?? String.fetchOne(db, sql: "SELECT stateJSON FROM expected_state WHERE deviceId = ?", arguments: [id])
            let name = try latest.flatMap {
                try String.fetchOne(db, sql: "SELECT json_extract(?, '$.name')", arguments: [$0])
            }
            // The legacy state carried the integration's second id (the building); kept as metadata.
            let building = try latest.flatMap {
                try String.fetchOne(db, sql: "SELECT CAST(json_extract(?, '$.buildingId') AS TEXT)", arguments: [$0])
            }
            let metadata = building.map { String(decoding: (try? JSONEncoder().encode(["buildingId": $0])) ?? Data(), as: UTF8.self) }
            let seen = try Row.fetchOne(
                db,
                sql: """
                    SELECT MIN(ts) AS first, MAX(ts) AS last FROM
                        (SELECT ts FROM snapshots WHERE deviceId = ? UNION ALL SELECT ts FROM device_raw WHERE deviceId = ?)
                    """,
                arguments: [id, id])
            try db.execute(
                sql: """
                    INSERT INTO devices (key, integration, kind, name, nativeId, enabled, sortOrder, metadata, firstSeen, lastSeen)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    key(id), integration, DeviceKind.airToAirHeatPump.rawValue, name ?? "", String(id), index == 0, index,
                    metadata, seen?["first"] as Date?, seen?["last"] as Date?,
                ])
        }

        // Tables with a device id: rebuilt with the key (it is part of their primary keys).
        let rebuild = """
                CREATE TABLE snapshots_v12 (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts DATETIME NOT NULL,
                    deviceKey TEXT NOT NULL,
                    power BOOLEAN,
                    mode TEXT,
                    setTemperature DOUBLE,
                    roomTemperature DOUBLE,
                    outdoorTemperature DOUBLE,
                    hasError BOOLEAN,
                    errorCode INTEGER,
                    offline BOOLEAN,
                    wifiSignal INTEGER,
                    stale BOOLEAN NOT NULL DEFAULT 0,
                    stateJSON TEXT NOT NULL
                );
                INSERT INTO snapshots_v12 (id, ts, deviceKey, power, mode, setTemperature, roomTemperature,
                    outdoorTemperature, hasError, errorCode, offline, wifiSignal, stale, stateJSON)
                SELECT id, ts, :integration || ':' || deviceId, power,
                    CASE mode WHEN 1 THEN 'heat' WHEN 2 THEN 'dry' WHEN 3 THEN 'cool' WHEN 7 THEN 'fan' WHEN 8 THEN 'auto' END,
                    setTemperature, roomTemperature, outdoorTemperature, hasError, errorCode, offline, wifiSignal, stale,
                    json_set(stateJSON, '$.key', :integration || ':' || deviceId)
                FROM snapshots;
                DROP TABLE snapshots;
                ALTER TABLE snapshots_v12 RENAME TO snapshots;
                CREATE INDEX snapshots_device_ts ON snapshots(deviceKey, ts);

                CREATE TABLE error_events_v12 (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    deviceKey TEXT NOT NULL,
                    start DATETIME NOT NULL,
                    "end" DATETIME,
                    message TEXT NOT NULL,
                    code TEXT,
                    source TEXT NOT NULL,
                    UNIQUE(deviceKey, start, message)
                );
                INSERT INTO error_events_v12 (id, deviceKey, start, "end", message, code, source)
                SELECT id, :integration || ':' || deviceId, start, "end", message, code, source FROM error_events;
                DROP TABLE error_events;
                ALTER TABLE error_events_v12 RENAME TO error_events;

                CREATE TABLE temperature_log_v12 (
                    deviceKey TEXT NOT NULL,
                    ts DATETIME NOT NULL,
                    room DOUBLE,
                    "set" DOUBLE,
                    outdoor DOUBLE,
                    PRIMARY KEY(deviceKey, ts)
                );
                INSERT INTO temperature_log_v12 (deviceKey, ts, room, "set", outdoor)
                SELECT :integration || ':' || deviceId, ts, room, "set", outdoor FROM temperature_log;
                DROP TABLE temperature_log;
                ALTER TABLE temperature_log_v12 RENAME TO temperature_log;

                CREATE TABLE energy_daily_v12 (
                    deviceKey TEXT NOT NULL,
                    day TEXT NOT NULL,
                    totalKWh DOUBLE NOT NULL,
                    heatingKWh DOUBLE,
                    coolingKWh DOUBLE,
                    updatedAt DATETIME NOT NULL,
                    autoKWh DOUBLE,
                    dryKWh DOUBLE,
                    fanKWh DOUBLE,
                    otherKWh DOUBLE,
                    PRIMARY KEY(deviceKey, day)
                );
                INSERT INTO energy_daily_v12 (deviceKey, day, totalKWh, heatingKWh, coolingKWh, updatedAt, autoKWh, dryKWh,
                    fanKWh, otherKWh)
                SELECT :integration || ':' || deviceId, day, totalKWh, heatingKWh, coolingKWh, updatedAt, autoKWh, dryKWh,
                    fanKWh, otherKWh FROM energy_daily;
                DROP TABLE energy_daily;
                ALTER TABLE energy_daily_v12 RENAME TO energy_daily;

                CREATE TABLE expected_state_v12 (
                    deviceKey TEXT PRIMARY KEY,
                    ts DATETIME NOT NULL,
                    stateJSON TEXT NOT NULL
                );
                INSERT INTO expected_state_v12 (deviceKey, ts, stateJSON)
                SELECT :integration || ':' || deviceId, ts, json_set(stateJSON, '$.key', :integration || ':' || deviceId)
                FROM expected_state;
                DROP TABLE expected_state;
                ALTER TABLE expected_state_v12 RENAME TO expected_state;

                CREATE TABLE device_raw_v12 (
                    deviceKey TEXT PRIMARY KEY,
                    ts DATETIME NOT NULL,
                    json TEXT NOT NULL,
                    listingJSON TEXT
                );
                INSERT INTO device_raw_v12 (deviceKey, ts, json, listingJSON)
                SELECT :integration || ':' || deviceId, ts, json, listingJSON FROM device_raw;
                DROP TABLE device_raw;
                ALTER TABLE device_raw_v12 RENAME TO device_raw
                """
        for statement in rebuild.components(separatedBy: ";\n") {
            let sql = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sql.isEmpty else { continue }
            try db.execute(sql: sql, arguments: sql.contains(":integration") ? ["integration": integration] : [])
        }

        // Tables without a device id: the current device (nil, tied to no device, when there is none).
        // local_samples keeps the adapter's raw protocol values (mode, fan, vanes); the store maps
        // them when it reads, so they need no conversion.
        let currentKey = current.map(key)
        for table in ["change_log", "maintenance_log", "local_samples"] {
            try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN deviceKey TEXT")
            if let currentKey { try db.execute(sql: "UPDATE \(table) SET deviceKey = ?", arguments: [currentKey]) }
        }

        // The integration's fetch_state rows (last fetches, active blocks) are copied to its
        // namespace, so a block that was active before the upgrade still blocks after it. The
        // plain rows stay for a 1.x helper still running across the upgrade (`legacyKeyMirror`).
        if legacyFetchRows > 0 {
            try db.execute(
                sql: """
                    INSERT INTO fetch_state (key, lastAttempt, lastSuccess, blockedUntil, reason)
                    SELECT ? || '/' || key, lastAttempt, lastSuccess, blockedUntil, reason FROM fetch_state
                    WHERE \(fetchFilter)
                    """,
                arguments: StatementArguments([integration] + legacyIntegrationFetchKeys))
        }
    }
}
