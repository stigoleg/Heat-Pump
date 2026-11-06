import Foundation
import GRDB

/// What belongs to one device rather than to its integration: cached settings in `app_settings`
/// (away, weekly timer, firmware status, local connection) and the spacing of requests that ask
/// about one unit (reports, away, timer, firmware, the local adapter). Blocks, credential stops,
/// the state spacing, the change budget and endpoint refusals stay the integration's (they are the
/// account's), as do third-party sources (prices, weather, house), which belong to nobody.
extension HistoryStore {
    /// Identifier of the migration that scoped caches and spacing per device.
    static let deviceScopeMigration = "v13"

    /// `app_settings` names that hold one device's cache.
    public static let deviceSettingNames = ["awaySettings", "weeklyTimer", "firmwareStatus", "localConnection", "localStatus"]

    /// `fetch_state` names whose spacing is per device (`report.*` too).
    public static let deviceFetchNames = [
        "away", "away.verify", "timer", "timer.verify", "timer.presave", "firmware", "local", "local.discovery",
        "local.autodiscovery",
    ]

    /// The `app_settings` key of `name` for `device`, e.g. `localConnection@melcloud-classic:12345`.
    public static func deviceSettingKey(_ name: String, device: DeviceKey) -> String { "\(name)@\(device.rawValue)" }

    /// The `fetch_state` key of `name` for `device`, in its integration's namespace, e.g.
    /// `melcloud-classic/away@12345`.
    public static func fetchKey(_ name: String, device: DeviceKey) -> String {
        fetchKey("\(name)@\(device.nativeId)", integration: device.integration)
    }

    // MARK: Device settings

    /// `device`'s copy of the setting `name`. A copy saved before any device was known (under the
    /// plain name) becomes the first asking device's.
    public func deviceSetting<T: Decodable>(_ type: T.Type, name: String, device: DeviceKey) throws -> T? {
        let key = Self.deviceSettingKey(name, device: device)
        if let value = try setting(type, key: key) { return value }
        guard try setting(JSONValue.self, key: name) != nil else { return nil }
        try pool.write { db in try Self.adoptSetting(name, to: key, db: db) }
        return try setting(type, key: key)
    }

    public func saveDeviceSetting<T: Encodable>(_ value: T, name: String, device: DeviceKey) throws {
        try saveSetting(value, key: Self.deviceSettingKey(name, device: device))
    }

    /// Moves the plain-named setting to `key` unless `key` already has one.
    static func adoptSetting(_ name: String, to key: String, db: Database) throws {
        try db.execute(
            sql: "INSERT INTO app_settings (key, json) SELECT ?, json FROM app_settings WHERE key = ? ON CONFLICT(key) DO NOTHING",
            arguments: [key, name])
        try db.execute(sql: "DELETE FROM app_settings WHERE key = ?", arguments: [name])
    }

    // MARK: Registry changes

    /// Turns a device on or off. Disabled devices keep their data but are not served.
    public func setDeviceEnabled(_ enabled: Bool, device: DeviceKey) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE devices SET enabled = ? WHERE key = ?", arguments: [enabled, device.rawValue])
        }
    }

    /// The user's own name for the device; nil or empty goes back to the integration's name.
    public func renameDevice(_ device: DeviceKey, to name: String?) throws {
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try pool.write { db in
            try db.execute(
                sql: "UPDATE devices SET customName = ? WHERE key = ?",
                arguments: [clean?.isEmpty == false ? clean : nil, device.rawValue])
        }
    }

    /// Registers what `integration`'s account lists (new devices enabled) and disables its devices
    /// the account no longer lists. An empty listing disables nothing (a service hiccup must not
    /// switch every device off). Returns the keys that were disabled.
    @discardableResult
    public func syncDevices(_ listed: [DeviceSummary], integration: String) throws -> [DeviceKey] {
        try pool.write { db in
            for device in listed { try Self.upsertDevice(device, seen: nil, full: true, db: db) }
            guard !listed.isEmpty else { return [] }
            let keep = Set(listed.map(\.key.rawValue))
            let stale = try String.fetchAll(
                db, sql: "SELECT key FROM devices WHERE integration = ? AND enabled = 1", arguments: [integration]
            ).filter { !keep.contains($0) }
            for key in stale { try db.execute(sql: "UPDATE devices SET enabled = 0 WHERE key = ?", arguments: [key]) }
            return stale.compactMap(DeviceKey.init)
        }
    }

    // MARK: Migration to device scope (v13)

    /// Adds `devices.customName`; moves the device caches in `app_settings` to the current device
    /// (the first enabled one), and copies the last attempt and success of each integration's
    /// per-device `fetch_state` rows to its current device, so spacing carries over. The
    /// integration's rows stay: they keep endpoint refusals, and older helpers still read them.
    static func migrateToDeviceScope(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE devices ADD COLUMN customName TEXT")
        let order = "ORDER BY enabled DESC, sortOrder, key LIMIT 1"
        if let current = try String.fetchOne(db, sql: "SELECT key FROM devices \(order)").flatMap(DeviceKey.init) {
            for name in deviceSettingNames {
                try adoptSetting(name, to: deviceSettingKey(name, device: current), db: db)
            }
        }
        let integrations = try String.fetchAll(db, sql: "SELECT DISTINCT integration FROM devices")
        for integration in integrations {
            guard
                let current = try String.fetchOne(
                    db, sql: "SELECT key FROM devices WHERE integration = ? \(order)", arguments: [integration]
                ).flatMap(DeviceKey.init)
            else { continue }
            let prefix = fetchKey("", integration: integration)
            let rows = try Row.fetchAll(
                db, sql: "SELECT key, lastAttempt, lastSuccess FROM fetch_state WHERE key LIKE ? || '%'", arguments: [prefix])
            for row in rows {
                let name = String((row["key"] as String).dropFirst(prefix.count))
                guard deviceFetchNames.contains(name) || name.hasPrefix("report.") else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO fetch_state (key, lastAttempt, lastSuccess) VALUES (?, ?, ?)
                        ON CONFLICT(key) DO NOTHING
                        """,
                    arguments: [fetchKey(name, device: current), row["lastAttempt"] as Date?, row["lastSuccess"] as Date?])
            }
        }
    }
}

/// A change-log row with the device it belongs to (nil: tied to no device, e.g. refused before
/// any status was known).
public struct DeviceChangeRecord: Sendable, Equatable {
    public var device: DeviceKey?
    public var record: ChangeRecord
}

extension HistoryStore {
    /// The newest changes of every device, each with its device.
    public func changesByDevice(limit: Int = 50, source: ChangeSource? = nil) throws -> [DeviceChangeRecord] {
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
                DeviceChangeRecord(
                    device: (row["deviceKey"] as String?).flatMap(DeviceKey.init),
                    record: ChangeRecord(
                        id: row["id"], timestamp: row["ts"], source: ChangeSource(rawValue: row["source"]) ?? .app,
                        field: row["field"], oldValue: row["old"], newValue: row["new"], reason: row["reason"],
                        result: ChangeResult(rawValue: row["result"]) ?? .failed, error: row["error"]))
            }
        }
    }
}
