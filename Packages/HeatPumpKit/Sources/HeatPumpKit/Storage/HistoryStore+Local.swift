import Foundation
import GRDB

extension HistoryStore {
    // MARK: Local samples

    /// Readings younger than this keep their full (about 1-minute) resolution.
    public static let localFullResolutionDays = 90
    /// Readings between 90 and 365 days old are thinned to one per 10 minutes, older ones to one per hour.
    public static let localMediumResolutionDays = 365

    public func insertLocalSample(_ sample: LocalSample) throws {
        try pool.write { db in try Self.insert(sample, db: db) }
    }

    /// Inserts many readings in one transaction (demo seeding).
    public func insertLocalSamples(_ samples: [LocalSample]) throws {
        try pool.write { db in
            for sample in samples { try Self.insert(sample, db: db) }
        }
    }

    private static func insert(_ s: LocalSample, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO local_samples (ts, power, mode, iSee, setTemperature, fan, vaneVertical, vaneHorizontal,
                    roomTemperature, roomTemperature2, outdoorTemperature, compressorHz, operating, powerW, energyKWh,
                    errorCode, rssi, adapterVersion, cloudConnected)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                s.timestamp, s.power, s.modeRaw, s.iSee, s.setTemperature, s.fanRaw, s.vaneVerticalRaw,
                s.vaneHorizontalRaw, s.roomTemperature, s.roomTemperature2, s.outdoorTemperature, s.compressorHz,
                s.operating, s.powerW, s.energyKWh, s.errorCode, s.rssi, s.adapterVersion, s.cloudConnected,
            ])
    }

    private static func localSample(_ row: Row) -> LocalSample {
        var s = LocalSample(timestamp: row["ts"])
        s.power = row["power"]
        s.setRaw(mode: row["mode"], fan: row["fan"], vaneVertical: row["vaneVertical"], vaneHorizontal: row["vaneHorizontal"])
        s.iSee = row["iSee"]
        s.setTemperature = row["setTemperature"]
        s.roomTemperature = row["roomTemperature"]
        s.roomTemperature2 = row["roomTemperature2"]
        s.outdoorTemperature = row["outdoorTemperature"]
        s.compressorHz = row["compressorHz"]
        s.operating = row["operating"]
        s.powerW = row["powerW"]
        s.energyKWh = row["energyKWh"]
        s.errorCode = row["errorCode"]
        s.rssi = row["rssi"]
        s.adapterVersion = row["adapterVersion"]
        s.cloudConnected = row["cloudConnected"]
        return s
    }

    /// Readings with `from <= ts <= to`, oldest first.
    public func localSamples(from: Date, to: Date) throws -> [LocalSample] {
        try pool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM local_samples WHERE ts >= ? AND ts <= ? ORDER BY ts", arguments: [from, to]
            ).map(Self.localSample)
        }
    }

    /// Energy counter readings only (cheap for long ranges).
    public func localCounterReadings(from: Date, to: Date) throws -> [(at: Date, kWh: Double)] {
        try pool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT ts, energyKWh FROM local_samples WHERE ts >= ? AND ts <= ? AND energyKWh IS NOT NULL ORDER BY ts",
                arguments: [from, to]
            ).map { (at: $0["ts"], kWh: $0["energyKWh"]) }
        }
    }

    public func latestLocalSample() throws -> LocalSample? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM local_samples ORDER BY ts DESC, id DESC LIMIT 1").map(Self.localSample)
        }
    }

    /// Power and compressor frequency per `bucketSeconds` (UTC-aligned buckets), for charts.
    public func localPowerBuckets(from: Date, to: Date, bucketSeconds: Int) throws -> [LocalPowerBucket] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT CAST(strftime('%s', ts) AS INTEGER) / ? AS bucket,
                        AVG(powerW) AS avgW, MAX(powerW) AS maxW, MIN(powerW) AS minW,
                        AVG(compressorHz) AS avgHz, MAX(compressorHz) AS maxHz,
                        AVG(CASE WHEN operating = 1 OR compressorHz > 0 THEN 1.0 ELSE 0.0 END) AS running,
                        COUNT(*) AS n
                    FROM local_samples WHERE ts >= ? AND ts <= ? AND powerW IS NOT NULL
                    GROUP BY bucket ORDER BY bucket
                    """,
                arguments: [bucketSeconds, from, to]
            ).map { row in
                let bucket: Int = row["bucket"]
                return LocalPowerBucket(
                    start: Date(timeIntervalSince1970: TimeInterval(bucket * bucketSeconds)),
                    averageW: row["avgW"] ?? 0, maxW: row["maxW"] ?? 0, minW: row["minW"] ?? 0,
                    averageHz: row["avgHz"] ?? 0, maxHz: row["maxHz"] ?? 0, runningShare: row["running"] ?? 0,
                    count: row["n"])
            }
        }
    }

    /// Thins old readings so the database stays small: full resolution for 90 days, then one
    /// per 10 minutes until a year, then one per hour. Returns the number of rows removed.
    @discardableResult
    public func pruneLocalSamples(now: Date) throws -> Int {
        let medium = now.addingTimeInterval(-Double(Self.localFullResolutionDays) * 86_400)
        let coarse = now.addingTimeInterval(-Double(Self.localMediumResolutionDays) * 86_400)
        return try pool.write { db in
            let before = db.totalChangesCount
            for (from, to, bucket) in [(coarse, medium, 600), (Date.distantPast, coarse, 3600)] {
                try db.execute(
                    sql: """
                        DELETE FROM local_samples WHERE ts >= ? AND ts < ? AND id NOT IN (
                            SELECT MIN(id) FROM local_samples WHERE ts >= ? AND ts < ?
                            GROUP BY CAST(strftime('%s', ts) AS INTEGER) / ?)
                        """,
                    arguments: [from, to, from, to, bucket])
            }
            return db.totalChangesCount - before
        }
    }
}
