import Foundation
import GRDB

/// Energy meters: hourly use per meter (`meter_hourly`) and a rolling 48 hours of live power per
/// minute (`meter_live`).
///
/// The house's consumption is the house meter's hours (`houseMeterKey()`). Before a meter is
/// registered, hours fetched with the price token alone are kept under `pendingMeterKey`; the
/// first energy meter registered adopts them, so the history and every figure built on it stay
/// the same whether the house's use comes from the token or from an enabled meter.
extension HistoryStore {
    /// Identifier of the migration that made house consumption per meter.
    static let meterMigration = "v14"

    /// Where the house's hours live until a meter is registered. Not a real integration.
    public static let pendingMeterKey = DeviceKey(integration: "house", nativeId: "meter")

    /// Live minutes older than this are deleted.
    public static let liveRetention: TimeInterval = 48 * 3600

    /// v14: `house_consumption_hourly` becomes `meter_hourly` under the first registered energy
    /// meter (the placeholder when there is none), and `meter_live` is created.
    static func migrateToMeters(_ db: Database) throws {
        try db.execute(
            sql: """
                CREATE TABLE meter_hourly (
                    deviceKey TEXT NOT NULL,
                    hour DATETIME NOT NULL,
                    kWh DOUBLE NOT NULL,
                    costNok DOUBLE,
                    unitPriceOre DOUBLE,
                    PRIMARY KEY(deviceKey, hour)
                );
                CREATE TABLE meter_live (
                    deviceKey TEXT NOT NULL,
                    minute DATETIME NOT NULL,
                    powerW DOUBLE NOT NULL,
                    maxPowerW DOUBLE NOT NULL,
                    consumptionTodayKWh DOUBLE,
                    lastReading DATETIME NOT NULL,
                    PRIMARY KEY(deviceKey, minute)
                );
                """)
        let meter = try String.fetchOne(
            db, sql: "SELECT key FROM devices WHERE kind = ? ORDER BY enabled DESC, sortOrder, key LIMIT 1",
            arguments: [DeviceKind.energyMeter.rawValue]) ?? pendingMeterKey.rawValue
        try db.execute(
            sql: """
                INSERT INTO meter_hourly (deviceKey, hour, kWh, costNok, unitPriceOre)
                SELECT ?, hour, kWh, cost, unitPrice FROM house_consumption_hourly;
                DROP TABLE house_consumption_hourly;
                """,
            arguments: [meter])
    }

    /// Copies the file before v14 when it already had device keys (an older file got its copy
    /// before v12, which holds the same rows).
    func backUpBeforeMetersIfNeeded(_ migrator: DatabaseMigrator) throws {
        let applied = try pool.read { db in try migrator.appliedIdentifiers(db) }
        guard applied.contains(Self.deviceKeyMigration), !applied.contains(Self.meterMigration) else { return }
        try backUp(to: Self.backupPath(for: path, before: Self.meterMigration))
    }

    /// Moves the placeholder's hours to `meter` unless it has its own for the same hour (the first
    /// energy meter registered).
    static func adoptPendingMeterHours(to meter: DeviceKey, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO meter_hourly (deviceKey, hour, kWh, costNok, unitPriceOre)
                SELECT ?, hour, kWh, costNok, unitPriceOre FROM meter_hourly WHERE deviceKey = ?
                ON CONFLICT(deviceKey, hour) DO NOTHING;
                DELETE FROM meter_hourly WHERE deviceKey = ?;
                """,
            arguments: [meter.rawValue, pendingMeterKey.rawValue, pendingMeterKey.rawValue])
    }

    // MARK: Hourly use

    /// The meter the house's consumption is read from and stored under: the first enabled energy
    /// meter, else the first registered one, else the placeholder.
    public func houseMeterKey() throws -> DeviceKey {
        try devices().first { $0.kind == .energyMeter }?.key ?? Self.pendingMeterKey
    }

    public func upsertMeterHours(_ hours: [HouseHour], device: DeviceKey) throws {
        try pool.write { db in
            for h in hours {
                try db.execute(
                    sql: """
                        INSERT INTO meter_hourly (deviceKey, hour, kWh, costNok, unitPriceOre) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(deviceKey, hour) DO UPDATE SET kWh = excluded.kWh, costNok = excluded.costNok,
                            unitPriceOre = excluded.unitPriceOre
                        """,
                    arguments: [device.rawValue, h.hour, h.kWh, h.costNok, h.unitPriceOre])
            }
        }
    }

    /// `device`'s hours with `from <= hour < to`.
    public func meterHours(device: DeviceKey, from: Date, to: Date) throws -> [HouseHour] {
        try pool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM meter_hourly WHERE deviceKey = ? AND hour >= ? AND hour < ? ORDER BY hour",
                arguments: [device.rawValue, from, to]
            ).map { HouseHour(hour: $0["hour"], kWh: $0["kWh"], costNok: $0["costNok"], unitPriceOre: $0["unitPriceOre"]) }
        }
    }

    public func latestMeterHour(device: DeviceKey) throws -> Date? {
        try pool.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(hour) FROM meter_hourly WHERE deviceKey = ?", arguments: [device.rawValue])
        }
    }

    // MARK: House consumption (the house meter's hours)

    public func upsertHouseHours(_ hours: [HouseHour]) throws {
        try upsertMeterHours(hours, device: houseMeterKey())
    }

    /// House hours with `from <= hour < to`.
    public func houseHours(from: Date, to: Date) throws -> [HouseHour] {
        try meterHours(device: houseMeterKey(), from: from, to: to)
    }

    public func latestHouseHour() throws -> Date? {
        try latestMeterHour(device: houseMeterKey())
    }

    // MARK: Live power

    /// Stores (or replaces) one minute and deletes `device`'s minutes older than the retention.
    public func saveLiveMinute(_ minute: LiveMinute, device: DeviceKey) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meter_live (deviceKey, minute, powerW, maxPowerW, consumptionTodayKWh, lastReading)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceKey, minute) DO UPDATE SET powerW = excluded.powerW, maxPowerW = excluded.maxPowerW,
                        consumptionTodayKWh = excluded.consumptionTodayKWh, lastReading = excluded.lastReading
                    """,
                arguments: [
                    device.rawValue, minute.minute, minute.powerW, minute.maxPowerW, minute.consumptionTodayKWh, minute.lastReading,
                ])
            try db.execute(
                sql: "DELETE FROM meter_live WHERE deviceKey = ? AND minute < ?",
                arguments: [device.rawValue, minute.minute.addingTimeInterval(-Self.liveRetention)])
        }
    }

    /// `device`'s minutes with `from <= minute < to`, oldest first.
    public func liveMinutes(device: DeviceKey, from: Date, to: Date) throws -> [LiveMinute] {
        try pool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM meter_live WHERE deviceKey = ? AND minute >= ? AND minute < ? ORDER BY minute",
                arguments: [device.rawValue, from, to]
            ).map(Self.liveMinute)
        }
    }

    public func latestLiveMinute(device: DeviceKey) throws -> LiveMinute? {
        try pool.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM meter_live WHERE deviceKey = ? ORDER BY minute DESC LIMIT 1", arguments: [device.rawValue]
            ).map(Self.liveMinute)
        }
    }

    private static func liveMinute(_ row: Row) -> LiveMinute {
        LiveMinute(
            minute: row["minute"], powerW: row["powerW"], maxPowerW: row["maxPowerW"], consumptionTodayKWh: row["consumptionTodayKWh"],
            lastReading: row["lastReading"])
    }
}
