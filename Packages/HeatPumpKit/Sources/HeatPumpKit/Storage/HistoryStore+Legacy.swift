import Foundation
import GRDB

/// Plain `fetch_state` keys for a helper from before device keys (1.x).
///
/// Claude Desktop keeps a running `varmepumpe-mcp` alive across an in-place app update, and that
/// old process keeps reading and writing `global`, `credentials`, `state`, `write` and `report.*`
/// without the integration's namespace. For the integration in `legacyKeyMirror` (MELCloud, the
/// only one 1.x had) the store keeps those rows in step: blocks, refused credentials and the
/// reservations of `state`, `write` and the reports are written to both keys, and every check
/// honours the more restrictive of the two, so neither process can overrun the other's spacing
/// or ignore its block. Transition only: remove after 2.1 (the mirror, `legacyKeysMigration`'s
/// restore and the copy in v12).
extension HistoryStore {
    /// Identifier of the migration that restores the plain rows (and moves price control's memory
    /// to its device, `movePriceControlRuntimeToDevice`).
    static let legacyKeysMigration = "v15"

    /// Names a 1.x helper keeps for the whole account (`state` is `HeatPumpService.stateKey`).
    static let legacyAccountNames: Set<String> = [globalKey, credentialsKey, writeKey, "state"]

    /// The keys of the account-wide `name` for `integration`: its namespaced key, and the plain
    /// one when `integration` is `legacyKeyMirror`.
    func integrationKeys(_ name: String, integration: String) -> [String] {
        [Self.fetchKey(name, integration: integration)] + (integration == legacyKeyMirror ? [name] : [])
    }

    /// The plain key a 1.x helper uses for the namespaced `key`, or nil: the account-wide names,
    /// and the reports of the device that helper serves (the integration's first in the registry;
    /// other devices' reports are their own).
    func legacyKey(_ key: String, db: Database) throws -> String? {
        guard let integration = legacyKeyMirror else { return nil }
        let prefix = Self.fetchKey("", integration: integration)
        guard key.hasPrefix(prefix) else { return nil }
        let name = String(key.dropFirst(prefix.count))
        if Self.legacyAccountNames.contains(name) { return name }
        guard name.hasPrefix("report.") else { return nil }
        let parts = name.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return name }  // before any device was known
        return try Self.legacyDevice(integration: integration, db: db) == parts[1] ? parts[0] : nil
    }

    /// Native id of the device a 1.x helper serves: the integration's first device in the
    /// registry (v12 gave the device that helper used sort order 0).
    static func legacyDevice(integration: String, db: Database) throws -> String? {
        try String.fetchOne(
            db, sql: "SELECT nativeId FROM devices WHERE integration = ? ORDER BY sortOrder, key LIMIT 1", arguments: [integration])
    }

    // MARK: Migration v15

    /// Copies `integration`'s namespaced rows back to the plain keys a 1.x helper reads, for files
    /// whose v12 moved them (an existing plain row is kept). The served device's reports take the
    /// later of the integration's row and the device's own.
    static func restoreLegacyFetchKeys(_ db: Database, integration: String?) throws {
        guard let integration else { return }
        let prefix = fetchKey("", integration: integration)
        let placeholders = legacyIntegrationFetchKeys.map { _ in "?" }.joined(separator: ", ")
        let start = prefix.count + 1
        var arguments: StatementArguments = [start, prefix.count, prefix, start]
        arguments += StatementArguments(legacyIntegrationFetchKeys)
        arguments += [start]
        try db.execute(
            sql: """
                INSERT INTO fetch_state (key, lastAttempt, lastSuccess, blockedUntil, reason)
                SELECT substr(key, ?), lastAttempt, lastSuccess, blockedUntil, reason FROM fetch_state
                WHERE substr(key, 1, ?) = ? AND instr(key, '@') = 0
                    AND (substr(key, ?) IN (\(placeholders)) OR substr(key, ?) LIKE 'report.%')
                ON CONFLICT(key) DO NOTHING
                """,
            arguments: arguments)
        guard let device = try legacyDevice(integration: integration, db: db) else { return }
        let suffix = "@\(device)"
        let rows = try Row.fetchAll(
            db, sql: "SELECT key, lastAttempt, lastSuccess FROM fetch_state WHERE substr(key, 1, ?) = ?",
            arguments: [prefix.count + 7, prefix + "report."])
        for row in rows {
            let key: String = row["key"]
            guard key.hasSuffix(suffix) else { continue }
            try db.execute(
                sql: """
                    INSERT INTO fetch_state (key, lastAttempt, lastSuccess) VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        lastAttempt = MAX(COALESCE(lastAttempt, excluded.lastAttempt), COALESCE(excluded.lastAttempt, lastAttempt)),
                        lastSuccess = MAX(COALESCE(lastSuccess, excluded.lastSuccess), COALESCE(excluded.lastSuccess, lastSuccess))
                    """,
                arguments: [String(key.dropFirst(prefix.count).dropLast(suffix.count)), row["lastAttempt"] as Date?, row["lastSuccess"] as Date?])
        }
    }

    /// Price control's memory (`priceControlRuntime`) becomes the device price control steers
    /// (the chosen one while it is enabled, else the first enabled air-to-air heat pump), together
    /// with the comfort temperature, which used to be kept for whichever device it steered. Without
    /// any such device the plain copy stays (and gets the comfort temperature); the first device to
    /// read it takes it over.
    static func movePriceControlRuntimeToDevice(_ db: Database) throws {
        let name = HeatPumpService.priceControlRuntimeKey
        guard var runtime = try String.fetchOne(db, sql: "SELECT json FROM app_settings WHERE key = ?", arguments: [name]) else {
            return
        }
        if let comfort = try Double.fetchOne(
            db, sql: "SELECT json_extract(json, '$.comfortTemperature') FROM app_settings WHERE key = ?",
            arguments: [HeatPumpService.priceControlKey])
        {
            runtime = try String.fetchOne(db, sql: "SELECT json_set(?, '$.comfortTemperature', ?)", arguments: [runtime, comfort]) ?? runtime
        }
        let heatPumps = "kind = '\(DeviceKind.airToAirHeatPump.rawValue)' AND enabled = 1"
        let chosen = try String.fetchOne(
            db,
            sql: """
                SELECT key FROM devices WHERE \(heatPumps)
                    AND key = (SELECT json_extract(json, '$') FROM app_settings WHERE key = ?)
                """,
            arguments: [DeviceHub.priceControlDeviceKey])
        let device = try chosen ?? String.fetchOne(db, sql: "SELECT key FROM devices WHERE \(heatPumps) ORDER BY sortOrder, key LIMIT 1")
        guard let device = device.flatMap(DeviceKey.init) else {
            try db.execute(sql: "UPDATE app_settings SET json = ? WHERE key = ?", arguments: [runtime, name])
            return
        }
        try db.execute(
            sql: "INSERT INTO app_settings (key, json) VALUES (?, ?) ON CONFLICT(key) DO NOTHING",
            arguments: [deviceSettingKey(name, device: device), runtime])
        try db.execute(sql: "DELETE FROM app_settings WHERE key = ?", arguments: [name])
    }
}
