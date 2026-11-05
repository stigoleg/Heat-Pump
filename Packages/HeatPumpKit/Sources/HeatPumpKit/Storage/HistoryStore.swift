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

/// Why MELCloud requests are stopped. Drives the user-facing message.
public enum BlockReason: String, Codable, Sendable {
    /// HTTP 429, too much traffic.
    case rateLimited
    /// Too many login attempts (ErrorId 6).
    case loginThrottled
    /// HTTP 401 even after a fresh login.
    case unauthorized

    /// Norwegian explanation including when it ends.
    public func message(until: Date) -> String {
        let time = Norwegian.time(until)
        switch self {
        case .rateLimited:
            return "MELCloud har midlertidig stengt for oppdateringer fordi det har vært for mye trafikk. Prøv igjen kl. \(time)."
        case .loginThrottled:
            return "For mange innloggingsforsøk mot MELCloud. Prøv igjen kl. \(time)."
        case .unauthorized:
            return "MELCloud avviser tilgangen selv etter ny innlogging. Appen prøver igjen kl. \(time)."
        }
    }
}

public struct BlockStatus: Sendable, Equatable {
    public var until: Date
    public var reason: BlockReason
}

public enum ChangeBudget {
    /// Maximum `Device/SetAta` requests per rolling window, across processes.
    public static let maxChangesPerHour = 12
    public static let window: TimeInterval = 3600
    /// Minimum time between two write requests, across processes.
    public static let minSpacing: TimeInterval = 5
}

/// The full MELCloud device object as last seen (from `Device/Get` or a `SetAta` response).
public struct RawDevice: Sendable, Equatable {
    public var deviceId: Int
    public var fetchedAt: Date
    public var json: JSONValue
    /// `User/ListDevices` wrapper (name, limits, Wi-Fi, firmware), when known.
    public var listing: JSONValue?

    public init(deviceId: Int, fetchedAt: Date, json: JSONValue, listing: JSONValue? = nil) {
        self.deviceId = deviceId
        self.fetchedAt = fetchedAt
        self.json = json
        self.listing = listing
    }
}

/// Persists the raw device object so every process can build a full `SetAta` body.
public protocol RawDeviceCache: Sendable {
    func saveRawDevice(_ raw: RawDevice) throws
    func rawDevice(deviceId: Int) throws -> RawDevice?
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
    /// `fetch_state` key holding the global MELCloud block (HTTP 429 / login throttle).
    public static let globalKey = "global"
    /// `fetch_state` key set while MELCloud refuses the stored credentials.
    public static let credentialsKey = "credentials"
    /// `fetch_state` key whose `lastAttempt` is the last write request.
    public static let writeKey = "write"
    /// Stored as `blockedUntil` for blocks that only end on user action.
    static let indefinite = Date(timeIntervalSince1970: 253_402_300_799)  // 9999-12-31

    public let path: String
    private let pool: DatabasePool

    public init(path: String) throws {
        self.path = path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.busyMode = .timeout(10)
        config.label = "HeatPumpKit.HistoryStore"
        pool = try DatabasePool(path: path, configuration: config)
        try Self.migrator.migrate(pool)
    }

    /// `VARMEPUMPE_DB_PATH`, or `~/Library/Application Support/Varmepumpe/varmepumpe.sqlite`.
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["VARMEPUMPE_DB_PATH"], !override.isEmpty { return override }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: "Varmepumpe/varmepumpe.sqlite").path
    }

    // MARK: Migrations

    static var migrator: DatabaseMigrator {
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

    public func insertSnapshot(_ state: DeviceState) throws {
        let json = String(decoding: try Self.encoder.encode(state), as: UTF8.self)
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO snapshots (ts, deviceId, power, mode, setTemperature, roomTemperature,
                        outdoorTemperature, hasError, errorCode, offline, wifiSignal, stateJSON)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    state.fetchedAt, state.deviceId, state.power, state.mode?.rawValue, state.setTemperature,
                    state.roomTemperature, state.outdoorTemperature, state.hasError, state.errorCode,
                    state.offline, state.wifiSignal, json,
                ])
        }
    }

    public struct Snapshot: Sendable, Equatable {
        public var state: DeviceState
        public var stale: Bool
    }

    public func latestSnapshot(deviceId: Int? = nil) throws -> Snapshot? {
        try pool.read { db in
            let row: Row?
            if let deviceId {
                row = try Row.fetchOne(
                    db, sql: "SELECT stateJSON, stale FROM snapshots WHERE deviceId = ? ORDER BY ts DESC, id DESC LIMIT 1",
                    arguments: [deviceId])
            } else {
                row = try Row.fetchOne(db, sql: "SELECT stateJSON, stale FROM snapshots ORDER BY ts DESC, id DESC LIMIT 1")
            }
            guard let row, let state = Self.decodeState(row["stateJSON"]) else { return nil }
            return Snapshot(state: state, stale: row["stale"])
        }
    }

    public func snapshots(deviceId: Int, from: Date, to: Date) throws -> [DeviceState] {
        try pool.read { db in
            try String.fetchAll(
                db, sql: "SELECT stateJSON FROM snapshots WHERE deviceId = ? AND ts >= ? AND ts <= ? ORDER BY ts",
                arguments: [deviceId, from, to]
            ).compactMap(Self.decodeState)
        }
    }

    public func markLatestSnapshotStale(deviceId: Int) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    UPDATE snapshots SET stale = 1 WHERE id =
                        (SELECT id FROM snapshots WHERE deviceId = ? ORDER BY ts DESC, id DESC LIMIT 1)
                    """,
                arguments: [deviceId])
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
                    INSERT INTO expected_state (deviceId, ts, stateJSON) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId) DO UPDATE SET ts = excluded.ts, stateJSON = excluded.stateJSON
                    """,
                arguments: [state.deviceId, at, json])
        }
    }

    public func expectedState(deviceId: Int) throws -> (state: DeviceState, at: Date)? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT ts, stateJSON FROM expected_state WHERE deviceId = ?", arguments: [deviceId]),
                let state = Self.decodeState(row["stateJSON"])
            else { return nil }
            return (state, row["ts"])
        }
    }

    // MARK: Raw device object

    public func saveRawDevice(_ raw: RawDevice) throws {
        let json = String(decoding: try JSONEncoder().encode(raw.json), as: UTF8.self)
        let listing = try raw.listing.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO device_raw (deviceId, ts, json, listingJSON) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId) DO UPDATE SET ts = excluded.ts, json = excluded.json,
                        listingJSON = COALESCE(excluded.listingJSON, listingJSON)
                    """,
                arguments: [raw.deviceId, raw.fetchedAt, json, listing])
        }
    }

    public func rawDevice(deviceId: Int) throws -> RawDevice? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT ts, json, listingJSON FROM device_raw WHERE deviceId = ?", arguments: [deviceId]),
                let json = try? JSONValue.parse(Data((row["json"] as String).utf8))
            else { return nil }
            let listing = (row["listingJSON"] as String?).flatMap { try? JSONValue.parse(Data($0.utf8)) }
            return RawDevice(deviceId: deviceId, fetchedAt: row["ts"], json: json, listing: listing)
        }
    }

    // MARK: Prices

    public func upsertPrices(_ prices: [HourPrice]) throws {
        try pool.write { db in
            for p in prices {
                try db.execute(
                    sql: """
                        INSERT INTO price_hourly (hour, area, source, spotOre, totalOre) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(hour, source, area) DO UPDATE SET spotOre = excluded.spotOre, totalOre = excluded.totalOre
                        """,
                    arguments: [p.hour, p.area, p.source, p.spotOre, p.totalOre])
            }
        }
    }

    /// Prices with `from <= hour < to` for one source and area.
    public func prices(source: String, area: String, from: Date, to: Date) throws -> [HourPrice] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT hour, area, source, spotOre, totalOre FROM price_hourly
                    WHERE source = ? AND area = ? AND hour >= ? AND hour < ? ORDER BY hour
                    """,
                arguments: [source, area, from, to]
            ).map {
                HourPrice(hour: $0["hour"], area: $0["area"], source: $0["source"], spotOre: $0["spotOre"], totalOre: $0["totalOre"])
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
                        INSERT INTO error_events (deviceId, start, "end", message, code, source) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(deviceId, start, message) DO UPDATE SET "end" = excluded."end",
                            code = COALESCE(excluded.code, code)
                        """,
                    arguments: [entry.deviceId, entry.start, entry.end, entry.message, entry.code, entry.source])
            }
            return (try Int.fetchOne(db, sql: countSQL) ?? 0) - before
        }
    }

    public func errorEvents(deviceId: Int? = nil, since: Date) throws -> [ErrorLogEntry] {
        try pool.read { db in
            var sql = #"SELECT deviceId, start, "end", message, code, source FROM error_events WHERE start >= ?"#
            var arguments: StatementArguments = [since]
            if let deviceId {
                sql += " AND deviceId = ?"
                arguments += [deviceId]
            }
            sql += " ORDER BY start DESC"
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                ErrorLogEntry(
                    deviceId: row["deviceId"], start: row["start"], end: row["end"], message: row["message"],
                    code: row["code"], source: row["source"])
            }
        }
    }

    // MARK: Temperature log

    public func upsertTemperaturePoints(_ points: [TemperaturePoint], deviceId: Int) throws {
        try pool.write { db in
            for p in points {
                try db.execute(
                    sql: """
                        INSERT INTO temperature_log (deviceId, ts, room, "set", outdoor) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(deviceId, ts) DO UPDATE SET room = excluded.room, "set" = excluded."set",
                            outdoor = excluded.outdoor
                        """,
                    arguments: [deviceId, p.timestamp, p.room, p.set, p.outdoor])
            }
        }
    }

    public func temperaturePoints(deviceId: Int, from: Date, to: Date) throws -> [TemperaturePoint] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: #"SELECT ts, room, "set", outdoor FROM temperature_log WHERE deviceId = ? AND ts >= ? AND ts <= ? ORDER BY ts"#,
                arguments: [deviceId, from, to]
            ).map { TemperaturePoint(timestamp: $0["ts"], room: $0["room"], set: $0["set"], outdoor: $0["outdoor"]) }
        }
    }

    public func latestTemperaturePointDate(deviceId: Int) throws -> Date? {
        try pool.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(ts) FROM temperature_log WHERE deviceId = ?", arguments: [deviceId])
        }
    }

    // MARK: Energy

    public func upsertEnergyDays(_ days: [EnergyDay], deviceId: Int, now: Date) throws {
        try pool.write { db in
            for d in days {
                try db.execute(
                    sql: """
                        INSERT INTO energy_daily (deviceId, day, totalKWh, heatingKWh, coolingKWh, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(deviceId, day) DO UPDATE SET totalKWh = excluded.totalKWh,
                            heatingKWh = excluded.heatingKWh, coolingKWh = excluded.coolingKWh, updatedAt = excluded.updatedAt
                        """,
                    arguments: [deviceId, d.day, d.totalKWh, d.heatingKWh, d.coolingKWh, now])
            }
        }
    }

    public func energyDays(deviceId: Int, fromDay: String, toDay: String) throws -> [EnergyDay] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT day, totalKWh, heatingKWh, coolingKWh FROM energy_daily WHERE deviceId = ? AND day >= ? AND day <= ? ORDER BY day",
                arguments: [deviceId, fromDay, toDay]
            ).map { EnergyDay(day: $0["day"], totalKWh: $0["totalKWh"], heatingKWh: $0["heatingKWh"], coolingKWh: $0["coolingKWh"]) }
        }
    }

    public func latestEnergyDay(deviceId: Int) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT MAX(day) FROM energy_daily WHERE deviceId = ?", arguments: [deviceId])
        }
    }

    // MARK: Maintenance

    @discardableResult
    public func insertMaintenance(_ record: MaintenanceRecord) throws -> MaintenanceRecord {
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO maintenance_log (kind, ts, note) VALUES (?, ?, ?)",
                arguments: [record.kind.rawValue, record.timestamp, record.note])
            var saved = record
            saved.id = db.lastInsertedRowID
            return saved
        }
    }

    public func maintenanceRecords(kind: MaintenanceKind? = nil, limit: Int = 100) throws -> [MaintenanceRecord] {
        try pool.read { db in
            var sql = "SELECT id, kind, ts, note FROM maintenance_log"
            var arguments: StatementArguments = []
            if let kind {
                sql += " WHERE kind = ?"
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

    @discardableResult
    public func logChange(_ record: ChangeRecord) throws -> Int64 {
        try pool.write { db in
            try Self.insertChange(record, db: db)
            return db.lastInsertedRowID
        }
    }

    private static func insertChange(_ record: ChangeRecord, batchId: Int64? = nil, db: Database) throws {
        try db.execute(
            sql: "INSERT INTO change_log (ts, source, field, old, new, reason, result, error, batchId) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            arguments: [
                record.timestamp, record.source.rawValue, record.field, record.oldValue, record.newValue,
                record.reason, record.result.rawValue, record.error, batchId,
            ])
    }

    /// Atomically checks write spacing and the rolling budget and, if both allow, inserts
    /// `records` as `pending` rows sharing one batch (= one write request).
    /// The budget counts batches with pending, ok or failed rows (they reached or may have
    /// reached MELCloud); rejected rows do not count.
    public func reserveChange(
        _ records: [ChangeRecord], limit: Int = ChangeBudget.maxChangesPerHour, window: TimeInterval = ChangeBudget.window,
        minSpacing: TimeInterval = ChangeBudget.minSpacing
    ) throws -> ChangeReservation {
        guard let first = records.first else { return .reserved(ids: []) }
        let now = first.timestamp
        return try immediate { db in
            if let last = try Date.fetchOne(
                db, sql: "SELECT lastAttempt FROM fetch_state WHERE key = ?", arguments: [Self.writeKey]),
                now.timeIntervalSince(last) < minSpacing
            {
                return .tooSoon(nextAllowed: last.addingTimeInterval(minSpacing))
            }
            let used = try Date.fetchAll(
                db,
                sql: """
                    SELECT MIN(ts) AS ts FROM change_log
                    WHERE ts > ? AND result IN ('pending', 'ok', 'failed')
                    GROUP BY COALESCE(batchId, id) ORDER BY ts
                    """,
                arguments: [now.addingTimeInterval(-window)])
            if used.count >= limit {
                return .exceeded(nextAllowed: used[used.count - limit].addingTimeInterval(window))
            }
            var ids: [Int64] = []
            var batchId: Int64?
            for record in records {
                var pending = record
                pending.result = .pending
                try Self.insertChange(pending, batchId: batchId, db: db)
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
                arguments: [Self.writeKey, now])
            return .reserved(ids: ids)
        }
    }

    /// Write requests used in the rolling window, when the oldest of them leaves the window,
    /// and when the last write went out.
    public func writeUsage(now: Date, window: TimeInterval = ChangeBudget.window) throws -> (used: [Date], lastWrite: Date?) {
        try pool.read { db in
            let used = try Date.fetchAll(
                db,
                sql: """
                    SELECT MIN(ts) AS ts FROM change_log
                    WHERE ts > ? AND result IN ('pending', 'ok', 'failed')
                    GROUP BY COALESCE(batchId, id) ORDER BY ts
                    """,
                arguments: [now.addingTimeInterval(-window)])
            let last = try Date.fetchOne(db, sql: "SELECT lastAttempt FROM fetch_state WHERE key = ?", arguments: [Self.writeKey])
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

    public func changes(limit: Int = 50, source: ChangeSource? = nil) throws -> [ChangeRecord] {
        try pool.read { db in
            var sql = "SELECT * FROM change_log"
            var arguments: StatementArguments = []
            if let source {
                sql += " WHERE source = ?"
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

    // MARK: Fetch coordination

    /// Atomically decides whether this process may call the network for `key`.
    /// Honours the global block first, then the per-key minimum interval; on `.allowed` the
    /// attempt is recorded so other processes see it immediately.
    /// `melcloud` false for third-party sources (prices), which MELCloud blocks do not stop.
    public func reserveFetch(key: String, minInterval: TimeInterval, now: Date, melcloud: Bool = true) throws -> FetchDecision {
        try immediate { db in
            if melcloud, try Date.fetchOne(
                db, sql: "SELECT blockedUntil FROM fetch_state WHERE key = ?", arguments: [Self.credentialsKey]) != nil
            {
                return .credentialsRejected
            }
            if melcloud, let blocked = try Date.fetchOne(
                db, sql: "SELECT blockedUntil FROM fetch_state WHERE key = ?", arguments: [Self.globalKey]),
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

    /// Blocks every network call from every process until `until` (keeps the later of two
    /// blocks, together with its reason).
    public func recordBlock(until: Date, reason: BlockReason) throws {
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
                arguments: [Self.globalKey, until, reason.rawValue])
        }
    }

    /// The active block with its reason (rows from before v3 count as rate limiting).
    public func blockStatus(now: Date) throws -> BlockStatus? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT blockedUntil, reason FROM fetch_state WHERE key = ?", arguments: [Self.globalKey]),
                let until: Date = row["blockedUntil"], until > now
            else { return nil }
            let reason = (row["reason"] as String?).flatMap(BlockReason.init(rawValue:)) ?? .rateLimited
            return BlockStatus(until: until, reason: reason)
        }
    }

    /// Stops all network calls until `clearCredentialsRejected()` (new credentials saved).
    public func recordCredentialsRejected(now: Date) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fetch_state (key, lastAttempt, blockedUntil) VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET lastAttempt = excluded.lastAttempt, blockedUntil = excluded.blockedUntil
                    """,
                arguments: [Self.credentialsKey, now, Self.indefinite])
        }
    }

    public func clearCredentialsRejected() throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM fetch_state WHERE key = ?", arguments: [Self.credentialsKey])
        }
    }

    public func credentialsRejected() throws -> Bool {
        try pool.read { db in
            try Date.fetchOne(
                db, sql: "SELECT blockedUntil FROM fetch_state WHERE key = ?", arguments: [Self.credentialsKey]) != nil
        }
    }

    public func blockedUntil(now: Date) throws -> Date? {
        try pool.read { db in
            guard let until = try Date.fetchOne(
                db, sql: "SELECT blockedUntil FROM fetch_state WHERE key = ?", arguments: [Self.globalKey])
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
