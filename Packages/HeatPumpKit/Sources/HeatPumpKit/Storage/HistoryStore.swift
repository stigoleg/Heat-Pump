import Foundation
import GRDB

/// Decision for a network fetch, taken atomically across processes.
public enum FetchDecision: Sendable, Equatable {
    case allowed
    case throttled(nextAllowed: Date)
    case blocked(until: Date)
    /// MELCloud refused the stored e-mail/password; no network until new credentials are saved.
    case credentialsRejected
}

/// Outcome of reserving a slot in the rolling change budget.
public enum ChangeReservation: Sendable, Equatable {
    /// Row ids in the order the records were given; all share one batch.
    case reserved(ids: [Int64])
    case exceeded(nextAllowed: Date)
    /// Another write (from any process) went out less than `ChangeBudget.minSpacing` ago.
    case tooSoon(nextAllowed: Date)
}

/// Why requests to the heat pump service are stopped. Drives the user-facing message.
public enum BlockReason: String, Codable, Sendable {
    /// HTTP 429, too much traffic.
    case rateLimited
    /// Too many login attempts (ErrorId 6).
    case loginThrottled
    /// HTTP 401 even after a fresh login.
    case unauthorized

    /// Explanation including when it ends, naming the service.
    public func message(until: Date, serviceName: String) -> String {
        let time = Display.time(until)
        switch self {
        case .rateLimited:
            return L10n.format(
                "%@ has temporarily stopped updates because there has been too much traffic. Try again at %@.", serviceName, time)
        case .loginThrottled:
            return L10n.format("Too many login attempts to %@. Try again at %@.", serviceName, time)
        case .unauthorized:
            return L10n.format("%@ refuses access even after a new login. The app tries again at %@.", serviceName, time)
        }
    }
}

public struct BlockStatus: Sendable, Equatable {
    public var until: Date
    public var reason: BlockReason
}

/// The standard change budget (`RateLimitPolicy.standard`), for texts and defaults that have no
/// service at hand.
public enum ChangeBudget {
    /// Maximum write requests per rolling window, across processes.
    public static var maxChangesPerHour: Int { ChangeBudgetPolicy.standard.maxChangesPerHour }
    public static var window: TimeInterval { ChangeBudgetPolicy.standard.window }
    /// Minimum time between two write requests, across processes.
    public static var minSpacing: TimeInterval { ChangeBudgetPolicy.standard.minSpacing }
}

/// The driver's full device object as last seen (MELCloud: `Device/Get` or a `SetAta` response).
/// Opaque to the core; only the driver that wrote it interprets it.
public struct RawDevice: Sendable, Equatable {
    public var device: DeviceKey
    public var fetchedAt: Date
    public var json: JSONValue
    /// The driver's listing entry for the device (MELCloud: the `User/ListDevices` wrapper), when known.
    public var listing: JSONValue?

    public init(device: DeviceKey, fetchedAt: Date, json: JSONValue, listing: JSONValue? = nil) {
        self.device = device
        self.fetchedAt = fetchedAt
        self.json = json
        self.listing = listing
    }
}

/// Persists the raw device object so every process can build a full `SetAta` body.
public protocol RawDeviceCache: Sendable {
    func saveRawDevice(_ raw: RawDevice) throws
    func rawDevice(_ device: DeviceKey) throws -> RawDevice?
}

extension HistoryStore: RawDeviceCache {}

public struct FetchStateRow: Sendable, Equatable {
    public var key: String
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var blockedUntil: Date?
}

/// Shared SQLite history (GRDB, WAL). Safe to open from several processes at once;
/// all cross-process coordination goes through `fetch_state` and `change_log` inside
/// `BEGIN IMMEDIATE` transactions.
public final class HistoryStore: Sendable {
    // `fetch_state` keys are namespaced per integration (`fetchKey(_:integration:)`), so each
    // integration's blocks and spacing are its own; third-party sources (prices, weather, house)
    // keep plain keys.

    /// `fetch_state` name of an integration's global block (HTTP 429 / login throttle).
    public static let globalKey = "global"
    /// `fetch_state` name set while the integration's service refuses the stored credentials.
    public static let credentialsKey = "credentials"
    /// `fetch_state` name whose `lastAttempt` is the integration's last write request.
    public static let writeKey = "write"
    /// Stored as `blockedUntil` for blocks that only end on user action.
    static let indefinite = Date(timeIntervalSince1970: 253_402_300_799)  // 9999-12-31

    /// The `fetch_state` key of `name` for `integration`, e.g. `melcloud-classic/state`.
    public static func fetchKey(_ name: String, integration: String) -> String { "\(integration)/\(name)" }

    public let path: String
    let pool: DatabasePool

    /// `legacyIntegration` is the integration that opened the store (`Integration.id`). Rows from
    /// before device keys (v12) carry only the integration's own numeric device id; the
    /// migration builds their keys and namespaces their `fetch_state` keys with it. Opening a file
    /// that has such rows without it fails rather than guess. Before that migration runs on an
    /// existing file, a copy is kept next to it (`backupPath(for:)`).
    public init(path: String, legacyIntegration: String? = nil) throws {
        self.path = path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.busyMode = .timeout(10)
        config.label = "HeatPumpKit.HistoryStore"
        pool = try DatabasePool(path: path, configuration: config)
        let migrator = Self.migrator(legacyIntegration: legacyIntegration)
        try backUpBeforeDeviceKeysIfNeeded(migrator)
        try migrator.migrate(pool)
    }

    /// `VARMEPUMPE_DB_PATH`, or `~/Library/Application Support/Varmepumpe/varmepumpe.sqlite`.
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["VARMEPUMPE_DB_PATH"], !override.isEmpty { return override }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: "Varmepumpe/varmepumpe.sqlite").path
    }

    // MARK: Migrations

    static func migrator(legacyIntegration: String?) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(
                sql: """
                    CREATE TABLE snapshots (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        ts DATETIME NOT NULL,
                        deviceId INTEGER NOT NULL,
                        power BOOLEAN,
                        mode INTEGER,
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
                    CREATE INDEX snapshots_device_ts ON snapshots(deviceId, ts);

                    CREATE TABLE error_events (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        deviceId INTEGER NOT NULL,
                        start DATETIME NOT NULL,
                        "end" DATETIME,
                        message TEXT NOT NULL,
                        code TEXT,
                        source TEXT NOT NULL,
                        UNIQUE(deviceId, start, message)
                    );

                    CREATE TABLE temperature_log (
                        deviceId INTEGER NOT NULL,
                        ts DATETIME NOT NULL,
                        room DOUBLE,
                        "set" DOUBLE,
                        outdoor DOUBLE,
                        PRIMARY KEY(deviceId, ts)
                    );

                    CREATE TABLE energy_daily (
                        deviceId INTEGER NOT NULL,
                        day TEXT NOT NULL,
                        totalKWh DOUBLE NOT NULL,
                        heatingKWh DOUBLE,
                        coolingKWh DOUBLE,
                        updatedAt DATETIME NOT NULL,
                        PRIMARY KEY(deviceId, day)
                    );

                    CREATE TABLE maintenance_log (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        kind TEXT NOT NULL,
                        ts DATETIME NOT NULL,
                        note TEXT
                    );
                    CREATE INDEX maintenance_kind_ts ON maintenance_log(kind, ts);

                    CREATE TABLE change_log (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        ts DATETIME NOT NULL,
                        source TEXT NOT NULL,
                        field TEXT NOT NULL,
                        old TEXT,
                        new TEXT,
                        reason TEXT,
                        result TEXT NOT NULL,
                        error TEXT
                    );
                    CREATE INDEX change_log_ts ON change_log(ts);

                    CREATE TABLE fetch_state (
                        key TEXT PRIMARY KEY,
                        lastAttempt DATETIME,
                        lastSuccess DATETIME,
                        blockedUntil DATETIME
                    );
                    """)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(
                sql: """
                    ALTER TABLE change_log ADD COLUMN batchId INTEGER;
                    CREATE TABLE expected_state (
                        deviceId INTEGER PRIMARY KEY,
                        ts DATETIME NOT NULL,
                        stateJSON TEXT NOT NULL
                    );
                    """)
        }
        migrator.registerMigration("v3") { db in
            try db.execute(sql: "ALTER TABLE fetch_state ADD COLUMN reason TEXT")
        }
        migrator.registerMigration("v4") { db in
            // Full MELCloud device object (Device/Get + listing wrapper) used as the base of
            // every SetAta body, shared so a fresh process (the MCP helper) can write too.
            try db.execute(
                sql: """
                    CREATE TABLE device_raw (
                        deviceId INTEGER PRIMARY KEY,
                        ts DATETIME NOT NULL,
                        json TEXT NOT NULL,
                        listingJSON TEXT
                    );
                    """)
        }
        migrator.registerMigration("v5") { db in
            try db.execute(
                sql: """
                    CREATE TABLE price_hourly (
                        hour DATETIME NOT NULL,
                        area TEXT NOT NULL,
                        source TEXT NOT NULL,
                        spotOre DOUBLE NOT NULL,
                        totalOre DOUBLE NOT NULL,
                        PRIMARY KEY(hour, source, area)
                    );
                    CREATE TABLE app_settings (
                        key TEXT PRIMARY KEY,
                        json TEXT NOT NULL
                    );
                    """)
        }
        migrator.registerMigration("v6") { db in
            // Readings from the Wi-Fi adapter on the home network (read-only local access).
            try db.execute(
                sql: """
                    CREATE TABLE local_samples (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        ts DATETIME NOT NULL,
                        power BOOLEAN,
                        mode INTEGER,
                        iSee BOOLEAN,
                        setTemperature DOUBLE,
                        fan INTEGER,
                        vaneVertical INTEGER,
                        vaneHorizontal INTEGER,
                        roomTemperature DOUBLE,
                        roomTemperature2 DOUBLE,
                        outdoorTemperature DOUBLE,
                        compressorHz INTEGER,
                        operating BOOLEAN,
                        powerW INTEGER,
                        energyKWh DOUBLE,
                        errorCode INTEGER,
                        rssi INTEGER,
                        adapterVersion TEXT,
                        cloudConnected BOOLEAN
                    );
                    CREATE INDEX local_samples_ts ON local_samples(ts);
                    """)
        }
        migrator.registerMigration("v7") { db in
            // 0x09 operating sub-mode/stage/auto sub-mode and the 0x03 runtime minutes.
            try db.execute(
                sql: """
                    ALTER TABLE local_samples ADD COLUMN subMode INTEGER;
                    ALTER TABLE local_samples ADD COLUMN stage INTEGER;
                    ALTER TABLE local_samples ADD COLUMN autoSubMode INTEGER;
                    ALTER TABLE local_samples ADD COLUMN runtimeMinutes INTEGER;
                    """)
        }
        migrator.registerMigration("v8") { db in
            // Tibber's price level per hour, and MELCloud's energy split for the remaining modes.
            try db.execute(
                sql: """
                    ALTER TABLE price_hourly ADD COLUMN level TEXT;
                    ALTER TABLE energy_daily ADD COLUMN autoKWh DOUBLE;
                    ALTER TABLE energy_daily ADD COLUMN dryKWh DOUBLE;
                    ALTER TABLE energy_daily ADD COLUMN fanKWh DOUBLE;
                    ALTER TABLE energy_daily ADD COLUMN otherKWh DOUBLE;
                    """)
        }
        migrator.registerMigration("v9") { db in
            // MET Norway hourly forecast for the house (up to 9 days ahead).
            try db.execute(
                sql: """
                    CREATE TABLE weather_forecast (
                        hour DATETIME PRIMARY KEY,
                        temp DOUBLE NOT NULL,
                        wind DOUBLE,
                        humidity DOUBLE,
                        cloud DOUBLE,
                        precipitation DOUBLE,
                        symbol TEXT,
                        fetchedAt DATETIME NOT NULL
                    );
                    """)
        }
        migrator.registerMigration("v10") { db in
            // The whole house's hourly use from Tibber (only with a Tibber token).
            try db.execute(
                sql: """
                    CREATE TABLE house_consumption_hourly (
                        hour DATETIME PRIMARY KEY,
                        kWh DOUBLE NOT NULL,
                        cost DOUBLE,
                        unitPrice DOUBLE
                    );
                    """)
        }
        migrator.registerMigration("v11") { db in
            // MET's precipitation for the next 6 hours (the only amount beyond the hourly part).
            try db.execute(sql: "ALTER TABLE weather_forecast ADD COLUMN precipitation6h DOUBLE")
        }
        migrator.registerMigration(Self.deviceKeyMigration) { db in
            // Device keys, the device registry, string modes and per-integration fetch keys.
            try Self.migrateToDeviceKeys(db, legacyIntegration: legacyIntegration)
        }
        migrator.registerMigration(Self.deviceScopeMigration) { db in
            // Per-device caches and fetch spacing, and the user's own device names.
            try Self.migrateToDeviceScope(db)
        }
        return migrator
    }

    /// Runs `body` in a `BEGIN IMMEDIATE` transaction so concurrent processes serialize on the write lock.
    private func immediate<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) throws -> T {
        try pool.writeWithoutTransaction { db in
            var result: T?
            try db.inTransaction(.immediate) {
                result = try body(db)
                return .commit
            }
            guard let result else { throw DatabaseError(resultCode: .SQLITE_ERROR, message: "transaction produced no result") }
            return result
        }
    }

    // MARK: Snapshots

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static func decodeState(_ json: String) -> DeviceState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(DeviceState.self, from: Data(json.utf8))
    }

    /// Stores the state and keeps the device registry in step (adds the device when it is new,
    /// updates its name and when it was last seen).
    public func insertSnapshot(_ state: DeviceState) throws {
        let json = String(decoding: try Self.encoder.encode(state), as: UTF8.self)
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO snapshots (ts, deviceKey, power, mode, setTemperature, roomTemperature,
                        outdoorTemperature, hasError, errorCode, offline, wifiSignal, stateJSON)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    state.fetchedAt, state.key.rawValue, state.power, state.mode?.rawValue, state.setTemperature,
                    state.roomTemperature, state.outdoorTemperature, state.hasError, state.errorCode,
                    state.offline, state.wifiSignal, json,
                ])
            try Self.upsertDevice(DeviceSummary(key: state.key, name: state.name), seen: state.fetchedAt, full: false, db: db)
        }
    }

    public struct Snapshot: Sendable, Equatable {
        public var state: DeviceState
        public var stale: Bool
    }

    public func latestSnapshot(device: DeviceKey) throws -> Snapshot? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT stateJSON, stale FROM snapshots WHERE deviceKey = ? ORDER BY ts DESC, id DESC LIMIT 1",
                arguments: [device.rawValue]),
                let state = Self.decodeState(row["stateJSON"])
            else { return nil }
            return Snapshot(state: state, stale: row["stale"])
        }
    }

    public func snapshots(device: DeviceKey, from: Date, to: Date) throws -> [DeviceState] {
        try pool.read { db in
            try String.fetchAll(
                db, sql: "SELECT stateJSON FROM snapshots WHERE deviceKey = ? AND ts >= ? AND ts <= ? ORDER BY ts",
                arguments: [device.rawValue, from, to]
            ).compactMap(Self.decodeState)
        }
    }

    public func markLatestSnapshotStale(device: DeviceKey) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    UPDATE snapshots SET stale = 1 WHERE id =
                        (SELECT id FROM snapshots WHERE deviceKey = ? ORDER BY ts DESC, id DESC LIMIT 1)
                    """,
                arguments: [device.rawValue])
        }
    }

    // MARK: Expected state

    /// State as it should be after changes accepted by MELCloud, written at `at`.
    /// Used for validation until a snapshot newer than `at` arrives.
    public func saveExpectedState(_ state: DeviceState, at: Date) throws {
        let json = String(decoding: try Self.encoder.encode(state), as: UTF8.self)
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO expected_state (deviceKey, ts, stateJSON) VALUES (?, ?, ?)
                    ON CONFLICT(deviceKey) DO UPDATE SET ts = excluded.ts, stateJSON = excluded.stateJSON
                    """,
                arguments: [state.key.rawValue, at, json])
        }
    }

    public func expectedState(device: DeviceKey) throws -> (state: DeviceState, at: Date)? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT ts, stateJSON FROM expected_state WHERE deviceKey = ?", arguments: [device.rawValue]),
                let state = Self.decodeState(row["stateJSON"])
            else { return nil }
            return (state, row["ts"])
        }
    }

    // MARK: Raw device object

    /// Stores the object unless a newer one is already stored (another process may have
    /// saved a SetAta answer while this one was waiting for a slower Device/Get).
    public func saveRawDevice(_ raw: RawDevice) throws {
        let json = String(decoding: try JSONEncoder().encode(raw.json), as: UTF8.self)
        let listing = try raw.listing.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO device_raw (deviceKey, ts, json, listingJSON) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceKey) DO UPDATE SET ts = excluded.ts, json = excluded.json,
                        listingJSON = COALESCE(excluded.listingJSON, listingJSON)
                    WHERE excluded.ts >= device_raw.ts
                    """,
                arguments: [raw.device.rawValue, raw.fetchedAt, json, listing])
        }
    }

    public func rawDevice(_ device: DeviceKey) throws -> RawDevice? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT ts, json, listingJSON FROM device_raw WHERE deviceKey = ?", arguments: [device.rawValue]),
                let json = try? JSONValue.parse(Data((row["json"] as String).utf8))
            else { return nil }
            let listing = (row["listingJSON"] as String?).flatMap { try? JSONValue.parse(Data($0.utf8)) }
            return RawDevice(device: device, fetchedAt: row["ts"], json: json, listing: listing)
        }
    }

    // MARK: Prices

    public func upsertPrices(_ prices: [HourPrice]) throws {
        try pool.write { db in
            for p in prices {
                try db.execute(
                    sql: """
                        INSERT INTO price_hourly (hour, area, source, spotOre, totalOre, level) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(hour, source, area) DO UPDATE SET spotOre = excluded.spotOre, totalOre = excluded.totalOre,
                            level = COALESCE(excluded.level, level)
                        """,
                    arguments: [p.hour, p.area, p.source, p.spotOre, p.totalOre, p.level])
            }
        }
    }

    /// Prices with `from <= hour < to` for one source and area.
    public func prices(source: String, area: String, from: Date, to: Date) throws -> [HourPrice] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT hour, area, source, spotOre, totalOre, level FROM price_hourly
                    WHERE source = ? AND area = ? AND hour >= ? AND hour < ? ORDER BY hour
                    """,
                arguments: [source, area, from, to]
            ).map {
                HourPrice(
                    hour: $0["hour"], area: $0["area"], source: $0["source"], spotOre: $0["spotOre"], totalOre: $0["totalOre"],
                    level: $0["level"])
            }
        }
    }

    // MARK: Settings

    public func setting<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        try pool.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT json FROM app_settings WHERE key = ?", arguments: [key])
            else { return nil }
            return try? JSONDecoder().decode(T.self, from: Data(json.utf8))
        }
    }

    public func saveSetting<T: Encodable>(_ value: T, key: String) throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO app_settings (key, json) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET json = excluded.json",
                arguments: [key, json])
        }
    }

    // MARK: Error events

    /// Inserts new entries; existing ones (same device, start, message) get their end time updated.
    @discardableResult
    public func upsertErrorEvents(_ entries: [ErrorLogEntry]) throws -> Int {
        try pool.write { db in
            let countSQL = "SELECT COUNT(*) FROM error_events"
            let before = try Int.fetchOne(db, sql: countSQL) ?? 0
            for entry in entries {
                try db.execute(
                    sql: """
                        INSERT INTO error_events (deviceKey, start, "end", message, code, source) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(deviceKey, start, message) DO UPDATE SET "end" = excluded."end",
                            code = COALESCE(excluded.code, code)
                        """,
                    arguments: [entry.device.rawValue, entry.start, entry.end, entry.message, entry.code, entry.source])
            }
            return (try Int.fetchOne(db, sql: countSQL) ?? 0) - before
        }
    }

    public func errorEvents(device: DeviceKey, since: Date) throws -> [ErrorLogEntry] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: #"""
                    SELECT start, "end", message, code, source FROM error_events
                    WHERE deviceKey = ? AND start >= ? ORDER BY start DESC
                    """#,
                arguments: [device.rawValue, since]
            ).map { row in
                ErrorLogEntry(
                    device: device, start: row["start"], end: row["end"], message: row["message"],
                    code: row["code"], source: row["source"])
            }
        }
    }

    // MARK: Temperature log

    public func upsertTemperaturePoints(_ points: [TemperaturePoint], device: DeviceKey) throws {
        try pool.write { db in
            for p in points {
                try db.execute(
                    sql: """
                        INSERT INTO temperature_log (deviceKey, ts, room, "set", outdoor) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(deviceKey, ts) DO UPDATE SET room = excluded.room, "set" = excluded."set",
                            outdoor = excluded.outdoor
                        """,
                    arguments: [device.rawValue, p.timestamp, p.room, p.set, p.outdoor])
            }
        }
    }

    public func temperaturePoints(device: DeviceKey, from: Date, to: Date) throws -> [TemperaturePoint] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: #"SELECT ts, room, "set", outdoor FROM temperature_log WHERE deviceKey = ? AND ts >= ? AND ts <= ? ORDER BY ts"#,
                arguments: [device.rawValue, from, to]
            ).map { TemperaturePoint(timestamp: $0["ts"], room: $0["room"], set: $0["set"], outdoor: $0["outdoor"]) }
        }
    }

    public func latestTemperaturePointDate(device: DeviceKey) throws -> Date? {
        try pool.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(ts) FROM temperature_log WHERE deviceKey = ?", arguments: [device.rawValue])
        }
    }

    // MARK: Energy

    public func upsertEnergyDays(_ days: [EnergyDay], device: DeviceKey, now: Date) throws {
        try pool.write { db in
            for d in days {
                try db.execute(
                    sql: """
                        INSERT INTO energy_daily (deviceKey, day, totalKWh, heatingKWh, coolingKWh, autoKWh, dryKWh, fanKWh,
                            otherKWh, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(deviceKey, day) DO UPDATE SET totalKWh = excluded.totalKWh,
                            heatingKWh = excluded.heatingKWh, coolingKWh = excluded.coolingKWh, autoKWh = excluded.autoKWh,
                            dryKWh = excluded.dryKWh, fanKWh = excluded.fanKWh, otherKWh = excluded.otherKWh,
                            updatedAt = excluded.updatedAt
                        """,
                    arguments: [
                        device.rawValue, d.day, d.totalKWh, d.heatingKWh, d.coolingKWh, d.autoKWh, d.dryKWh, d.fanKWh, d.otherKWh, now,
                    ])
            }
        }
    }

    public func energyDays(device: DeviceKey, fromDay: String, toDay: String) throws -> [EnergyDay] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT day, totalKWh, heatingKWh, coolingKWh, autoKWh, dryKWh, fanKWh, otherKWh FROM energy_daily
                    WHERE deviceKey = ? AND day >= ? AND day <= ? ORDER BY day
                    """,
                arguments: [device.rawValue, fromDay, toDay]
            ).map {
                EnergyDay(
                    day: $0["day"], totalKWh: $0["totalKWh"], heatingKWh: $0["heatingKWh"], coolingKWh: $0["coolingKWh"],
                    autoKWh: $0["autoKWh"], dryKWh: $0["dryKWh"], fanKWh: $0["fanKWh"], otherKWh: $0["otherKWh"])
            }
        }
    }

    public func latestEnergyDay(device: DeviceKey) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT MAX(day) FROM energy_daily WHERE deviceKey = ?", arguments: [device.rawValue])
        }
    }

    // MARK: Maintenance

    /// `device` nil when no device is known yet (the record then counts for every device).
    @discardableResult
    public func insertMaintenance(_ record: MaintenanceRecord, device: DeviceKey?) throws -> MaintenanceRecord {
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO maintenance_log (kind, ts, note, deviceKey) VALUES (?, ?, ?, ?)",
                arguments: [record.kind.rawValue, record.timestamp, record.note, device?.rawValue])
            var saved = record
            saved.id = db.lastInsertedRowID
            return saved
        }
    }

    /// Records for `device` (plus those tied to no device), or all with `device` nil.
    public func maintenanceRecords(device: DeviceKey?, kind: MaintenanceKind? = nil, limit: Int = 100) throws -> [MaintenanceRecord] {
        try pool.read { db in
            var sql = "SELECT id, kind, ts, note FROM maintenance_log WHERE \(Self.deviceFilter)"
            var arguments: StatementArguments = [device?.rawValue, device?.rawValue]
            if let kind {
                sql += " AND kind = ?"
                arguments += [kind.rawValue]
            }
            sql += " ORDER BY ts DESC LIMIT ?"
            arguments += [limit]
            return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
                guard let kind = MaintenanceKind(rawValue: row["kind"]) else { return nil }
                return MaintenanceRecord(id: row["id"], kind: kind, timestamp: row["ts"], note: row["note"])
            }
        }
    }

    // MARK: Change log

    /// Logs a change for `device` (nil when no device is known yet).
    @discardableResult
    public func logChange(_ record: ChangeRecord, device: DeviceKey?) throws -> Int64 {
        try pool.write { db in
            try Self.insertChange(record, device: device, db: db)
            return db.lastInsertedRowID
        }
    }

    private static func insertChange(_ record: ChangeRecord, device: DeviceKey?, batchId: Int64? = nil, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO change_log (ts, source, field, old, new, reason, result, error, batchId, deviceKey)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                record.timestamp, record.source.rawValue, record.field, record.oldValue, record.newValue,
                record.reason, record.result.rawValue, record.error, batchId, device?.rawValue,
            ])
    }

    /// `reserveChange` with the limits of `budget`.
    public func reserveChange(_ records: [ChangeRecord], device: DeviceKey, budget: ChangeBudgetPolicy) throws -> ChangeReservation {
        try reserveChange(records, device: device, limit: budget.maxChangesPerHour, window: budget.window, minSpacing: budget.minSpacing)
    }

    /// Batches of write requests the integration used since `since`, oldest first: rows of its
    /// devices (and rows tied to no device) that reached or may have reached the service.
    private static func usedWrites(integration: String, since: Date, db: Database) throws -> [Date] {
        try Date.fetchAll(
            db,
            sql: """
                SELECT MIN(ts) AS ts FROM change_log
                WHERE ts > ? AND result IN ('pending', 'ok', 'failed')
                    AND (deviceKey IS NULL OR substr(deviceKey, 1, ?) = ?)
                GROUP BY COALESCE(batchId, id) ORDER BY ts
                """,
            arguments: [since, integration.count + 1, integration + ":"])
    }

    /// Atomically checks write spacing and the rolling budget of the integration `device` belongs
    /// to (the account's limits) and, if both allow, inserts `records` as `pending` rows sharing
    /// one batch (= one write request). The budget counts batches with pending, ok or failed rows
    /// (they reached or may have reached the service); rejected rows do not count.
    public func reserveChange(
        _ records: [ChangeRecord], device: DeviceKey, limit: Int = ChangeBudget.maxChangesPerHour,
        window: TimeInterval = ChangeBudget.window, minSpacing: TimeInterval = ChangeBudget.minSpacing
    ) throws -> ChangeReservation {
        guard let first = records.first else { return .reserved(ids: []) }
        let now = first.timestamp
        let writeKey = Self.fetchKey(Self.writeKey, integration: device.integration)
        return try immediate { db in
            if let last = try Date.fetchOne(
                db, sql: "SELECT lastAttempt FROM fetch_state WHERE key = ?", arguments: [writeKey]),
                now.timeIntervalSince(last) < minSpacing
            {
                return .tooSoon(nextAllowed: last.addingTimeInterval(minSpacing))
            }
            let used = try Self.usedWrites(integration: device.integration, since: now.addingTimeInterval(-window), db: db)
            if used.count >= limit {
                return .exceeded(nextAllowed: used[used.count - limit].addingTimeInterval(window))
            }
            var ids: [Int64] = []
            var batchId: Int64?
            for record in records {
                var pending = record
                pending.result = .pending
                try Self.insertChange(pending, device: device, batchId: batchId, db: db)
                let id = db.lastInsertedRowID
                if batchId == nil {
                    batchId = id
                    try db.execute(sql: "UPDATE change_log SET batchId = ? WHERE id = ?", arguments: [id, id])
                }
                ids.append(id)
            }
            try db.execute(
                sql: """
                    INSERT INTO fetch_state (key, lastAttempt) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET lastAttempt = excluded.lastAttempt
                    """,
                arguments: [writeKey, now])
            return .reserved(ids: ids)
        }
    }

    /// The integration's write requests used in the rolling window, when the oldest of them
    /// leaves the window, and when its last write went out.
    public func writeUsage(
        integration: String, now: Date, window: TimeInterval = ChangeBudget.window
    ) throws -> (used: [Date], lastWrite: Date?) {
        try pool.read { db in
            let used = try Self.usedWrites(integration: integration, since: now.addingTimeInterval(-window), db: db)
            let last = try Date.fetchOne(
                db, sql: "SELECT lastAttempt FROM fetch_state WHERE key = ?",
                arguments: [Self.fetchKey(Self.writeKey, integration: integration)])
            return (used, last)
        }
    }

    public func finishChange(ids: [Int64], result: ChangeResult, error: String? = nil) throws {
        try pool.write { db in
            for id in ids {
                try db.execute(
                    sql: "UPDATE change_log SET result = ?, error = ? WHERE id = ?", arguments: [result.rawValue, error, id])
            }
        }
    }

    /// The newest changes for `device` (plus those tied to no device), or all with `device` nil.
    public func changes(device: DeviceKey?, limit: Int = 50, source: ChangeSource? = nil) throws -> [ChangeRecord] {
        try pool.read { db in
            var sql = "SELECT * FROM change_log WHERE \(Self.deviceFilter)"
            var arguments: StatementArguments = [device?.rawValue, device?.rawValue]
            if let source {
                sql += " AND source = ?"
                arguments += [source.rawValue]
            }
            sql += " ORDER BY ts DESC, id DESC LIMIT ?"
            arguments += [limit]
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                ChangeRecord(
                    id: row["id"], timestamp: row["ts"], source: ChangeSource(rawValue: row["source"]) ?? .app,
                    field: row["field"], oldValue: row["old"], newValue: row["new"], reason: row["reason"],
                    result: ChangeResult(rawValue: row["result"]) ?? .failed, error: row["error"])
            }
        }
    }

    /// Matches rows of the device bound twice (rows tied to no device always match; a nil device
    /// matches every row).
    static let deviceFilter = "(? IS NULL OR deviceKey IS NULL OR deviceKey = ?)"

    // MARK: Fetch coordination

    /// Atomically decides whether this process may call the network for `key`.
    /// Honours `blockingIntegration`'s stops first (credentials refused, global block), then the
    /// per-key minimum interval; on `.allowed` the attempt is recorded so other processes see it
    /// immediately. `blockingIntegration` is nil for third-party sources (prices, weather), which
    /// no integration's blocks stop.
    public func reserveFetch(
        key: String, minInterval: TimeInterval, now: Date, blockingIntegration: String?
    ) throws -> FetchDecision {
        try immediate { db in
            if let integration = blockingIntegration, try Date.fetchOne(
                db, sql: "SELECT blockedUntil FROM fetch_state WHERE key = ?",
                arguments: [Self.fetchKey(Self.credentialsKey, integration: integration)]) != nil
            {
                return .credentialsRejected
            }
            if let integration = blockingIntegration, let blocked = try Date.fetchOne(
                db, sql: "SELECT blockedUntil FROM fetch_state WHERE key = ?",
                arguments: [Self.fetchKey(Self.globalKey, integration: integration)]),
                blocked > now
            {
                return .blocked(until: blocked)
            }
            if let last = try Date.fetchOne(db, sql: "SELECT lastAttempt FROM fetch_state WHERE key = ?", arguments: [key]),
                now.timeIntervalSince(last) < minInterval
            {
                return .throttled(nextAllowed: last.addingTimeInterval(minInterval))
            }
            try db.execute(
                sql: """
                    INSERT INTO fetch_state (key, lastAttempt) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET lastAttempt = excluded.lastAttempt
                    """,
                arguments: [key, now])
            return .allowed
        }
    }

    public func recordFetchSuccess(key: String, now: Date) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fetch_state (key, lastAttempt, lastSuccess) VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET lastSuccess = excluded.lastSuccess
                    """,
                arguments: [key, now, now])
        }
    }

    /// Blocks every network call to `integration` from every process until `until` (keeps the
    /// later of two blocks, together with its reason).
    public func recordBlock(until: Date, reason: BlockReason, integration: String) throws {
        try immediate { db in
            try db.execute(
                sql: """
                    INSERT INTO fetch_state (key, blockedUntil, reason) VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        reason = CASE WHEN blockedUntil IS NULL OR blockedUntil < excluded.blockedUntil
                             THEN excluded.reason ELSE reason END,
                        blockedUntil = CASE WHEN blockedUntil IS NULL OR blockedUntil < excluded.blockedUntil
                             THEN excluded.blockedUntil ELSE blockedUntil END
                    """,
                arguments: [Self.fetchKey(Self.globalKey, integration: integration), until, reason.rawValue])
        }
    }

    /// The integration's active block with its reason (rows from before v3 count as rate limiting).
    public func blockStatus(now: Date, integration: String) throws -> BlockStatus? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT blockedUntil, reason FROM fetch_state WHERE key = ?",
                arguments: [Self.fetchKey(Self.globalKey, integration: integration)]),
                let until: Date = row["blockedUntil"], until > now
            else { return nil }
            let reason = (row["reason"] as String?).flatMap(BlockReason.init(rawValue:)) ?? .rateLimited
            return BlockStatus(until: until, reason: reason)
        }
    }

    /// Stops all network calls to `integration` until `clearCredentialsRejected(integration:)`
    /// (new credentials saved).
    public func recordCredentialsRejected(now: Date, integration: String) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fetch_state (key, lastAttempt, blockedUntil) VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET lastAttempt = excluded.lastAttempt, blockedUntil = excluded.blockedUntil
                    """,
                arguments: [Self.fetchKey(Self.credentialsKey, integration: integration), now, Self.indefinite])
        }
    }

    /// Stops automatic requests for one key (an endpoint refused this account) until `until`.
    /// Only the service's own check honours it; the integration's global block is not touched.
    public func recordKeyRefusal(key: String, until: Date) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fetch_state (key, blockedUntil) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET blockedUntil = excluded.blockedUntil
                    """,
                arguments: [key, until])
        }
    }

    public func clearKeyRefusal(key: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE fetch_state SET blockedUntil = NULL WHERE key = ?", arguments: [key])
        }
    }

    public func clearCredentialsRejected(integration: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM fetch_state WHERE key = ?", arguments: [Self.fetchKey(Self.credentialsKey, integration: integration)])
        }
    }

    public func credentialsRejected(integration: String) throws -> Bool {
        try pool.read { db in
            try Date.fetchOne(
                db, sql: "SELECT blockedUntil FROM fetch_state WHERE key = ?",
                arguments: [Self.fetchKey(Self.credentialsKey, integration: integration)]) != nil
        }
    }

    public func blockedUntil(now: Date, integration: String) throws -> Date? {
        try pool.read { db in
            guard let until = try Date.fetchOne(
                db, sql: "SELECT blockedUntil FROM fetch_state WHERE key = ?",
                arguments: [Self.fetchKey(Self.globalKey, integration: integration)])
            else { return nil }
            return until > now ? until : nil
        }
    }

    public func fetchState(key: String) throws -> FetchStateRow? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM fetch_state WHERE key = ?", arguments: [key]).map {
                FetchStateRow(key: $0["key"], lastAttempt: $0["lastAttempt"], lastSuccess: $0["lastSuccess"], blockedUntil: $0["blockedUntil"])
            }
        }
    }
}
