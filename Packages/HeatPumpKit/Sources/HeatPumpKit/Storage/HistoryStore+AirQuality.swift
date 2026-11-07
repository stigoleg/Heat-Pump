import Foundation
import GRDB

/// Air quality sensors: the newest value per device and metric (`air_quality_latest`) and hourly
/// averages per device and metric (`air_quality_hourly`, kept for two years). Thresholds and how
/// far the history has been fetched are device settings (`AirQualityService`).
extension HistoryStore {
    /// Identifier of the migration that added the air quality tables.
    static let airQualityMigration = "v16"

    /// Hourly averages older than this are deleted.
    public static let airQualityRetention: TimeInterval = 2 * 365 * 86_400

    /// v16: the air quality tables.
    static func createAirQualityTables(_ db: Database) throws {
        try db.execute(
            sql: """
                CREATE TABLE air_quality_latest (
                    deviceKey TEXT NOT NULL,
                    metric TEXT NOT NULL,
                    value DOUBLE NOT NULL,
                    recorded DATETIME,
                    fetchedAt DATETIME NOT NULL,
                    PRIMARY KEY(deviceKey, metric)
                );
                CREATE TABLE air_quality_hourly (
                    deviceKey TEXT NOT NULL,
                    hour DATETIME NOT NULL,
                    metric TEXT NOT NULL,
                    value DOUBLE NOT NULL,
                    PRIMARY KEY(deviceKey, hour, metric)
                );
                """)
    }

    /// Copies the file before v16 when it is at v15 (an older file got its copy before v12 or v14,
    /// which holds the same rows).
    func backUpBeforeAirQualityIfNeeded(_ migrator: DatabaseMigrator) throws {
        let applied = try pool.read { db in try migrator.appliedIdentifiers(db) }
        guard applied.contains(Self.legacyKeysMigration), !applied.contains(Self.airQualityMigration) else { return }
        try backUp(to: Self.backupPath(for: path, before: Self.airQualityMigration))
    }

    // MARK: Newest values

    /// Replaces `reading.device`'s newest values (a metric the sensor no longer reports is dropped).
    public func saveAirQualityReading(_ reading: AirQualityReading, fetchedAt: Date) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM air_quality_latest WHERE deviceKey = ?", arguments: [reading.device.rawValue])
            for (metric, value) in reading.values {
                try db.execute(
                    sql: "INSERT INTO air_quality_latest (deviceKey, metric, value, recorded, fetchedAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: [reading.device.rawValue, metric.rawValue, value, reading.recorded, fetchedAt])
            }
        }
    }

    /// `device`'s newest values and when they were fetched; nil before the first fetch.
    public func latestAirQuality(device: DeviceKey) throws -> (reading: AirQualityReading, fetchedAt: Date)? {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM air_quality_latest WHERE deviceKey = ?", arguments: [device.rawValue])
            guard let first = rows.first else { return nil }
            var values: [AirQualityMetric: Double] = [:]
            for row in rows {
                guard let metric = AirQualityMetric(rawValue: row["metric"]) else { continue }
                values[metric] = row["value"]
            }
            return (AirQualityReading(device: device, recorded: first["recorded"], values: values), first["fetchedAt"])
        }
    }

    // MARK: Hourly averages

    /// Stores (or replaces) hours and deletes `device`'s hours older than the retention.
    public func upsertAirQualityHours(_ hours: [AirQualityHour], device: DeviceKey, now: Date = Date()) throws {
        try pool.write { db in
            for hour in hours {
                for (metric, value) in hour.values {
                    try db.execute(
                        sql: """
                            INSERT INTO air_quality_hourly (deviceKey, hour, metric, value) VALUES (?, ?, ?, ?)
                            ON CONFLICT(deviceKey, hour, metric) DO UPDATE SET value = excluded.value
                            """,
                        arguments: [device.rawValue, hour.hour, metric.rawValue, value])
                }
            }
            try db.execute(
                sql: "DELETE FROM air_quality_hourly WHERE deviceKey = ? AND hour < ?",
                arguments: [device.rawValue, now.addingTimeInterval(-Self.airQualityRetention)])
        }
    }

    /// `device`'s hours with `from <= hour < to`, oldest first.
    public func airQualityHours(device: DeviceKey, from: Date, to: Date) throws -> [AirQualityHour] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT hour, metric, value FROM air_quality_hourly WHERE deviceKey = ? AND hour >= ? AND hour < ? ORDER BY hour",
                arguments: [device.rawValue, from, to])
            var hours: [AirQualityHour] = []
            for row in rows {
                let hour: Date = row["hour"]
                guard let metric = AirQualityMetric(rawValue: row["metric"]) else { continue }
                if hours.last?.hour != hour { hours.append(AirQualityHour(hour: hour, values: [:])) }
                hours[hours.count - 1].values[metric] = row["value"]
            }
            return hours
        }
    }

    public func latestAirQualityHour(device: DeviceKey) throws -> Date? {
        try pool.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(hour) FROM air_quality_hourly WHERE deviceKey = ?", arguments: [device.rawValue])
        }
    }
}
