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
                    errorCode, rssi, adapterVersion, cloudConnected, subMode, stage, autoSubMode, runtimeMinutes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                s.timestamp, s.power, s.modeRaw, s.iSee, s.setTemperature, s.fanRaw, s.vaneVerticalRaw,
                s.vaneHorizontalRaw, s.roomTemperature, s.roomTemperature2, s.outdoorTemperature, s.compressorHz,
                s.operating, s.powerW, s.energyKWh, s.errorCode, s.rssi, s.adapterVersion, s.cloudConnected,
                s.subMode, s.stage, s.autoSubMode, s.runtimeMinutes,
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
        s.subMode = row["subMode"]
        s.stage = row["stage"]
        s.autoSubMode = row["autoSubMode"]
        s.runtimeMinutes = row["runtimeMinutes"]
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

    /// Energy counter readings for hourly energy: the first reading of every 5 minutes plus the
    /// newest one, so long ranges stay cheap (a year is ~100k readings, ~10k after thinning).
    /// Deltas between kept readings are still exact; only the split inside 5 minutes is linear.
    public func localCounterReadings(from: Date, to: Date) throws -> [(at: Date, kWh: Double)] {
        try pool.read { db in
            var rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT MIN(ts) AS ts, energyKWh FROM local_samples
                    WHERE ts >= ? AND ts <= ? AND energyKWh IS NOT NULL
                    GROUP BY CAST(strftime('%s', ts) AS INTEGER) / 300 ORDER BY ts
                    """,
                arguments: [from, to]
            ).map { (at: $0["ts"] as Date, kWh: $0["energyKWh"] as Double) }
            if let last = try Row.fetchOne(
                db,
                sql: """
                    SELECT ts, energyKWh FROM local_samples WHERE ts >= ? AND ts <= ? AND energyKWh IS NOT NULL
                    ORDER BY ts DESC LIMIT 1
                    """,
                arguments: [from, to]), let at: Date = last["ts"], at > (rows.last?.at ?? .distantPast)
            {
                rows.append((at, last["energyKWh"]))
            }
            return rows
        }
    }

    public func localSampleCount(from: Date, to: Date) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM local_samples WHERE ts >= ? AND ts <= ?", arguments: [from, to]) ?? 0
        }
    }

    public func latestLocalSample() throws -> LocalSample? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM local_samples ORDER BY ts DESC, id DESC LIMIT 1").map(Self.localSample)
        }
    }

    /// Aggregates per `bucketSeconds` from `origin` (default: UTC-aligned buckets), computed in
    /// SQL so long ranges never load individual readings. Compressor starts and observed/running
    /// time come from consecutive readings at most `CompressorCycles.maxGap` apart (the pair
    /// belongs to the bucket of the later reading; the reading just before `from` is used too).
    /// A reading exactly at `to` is put in the last bucket.
    public func localPowerBuckets(from: Date, to: Date, bucketSeconds: Int, origin: Date? = nil) throws -> [LocalPowerBucket] {
        let bucket = max(1, bucketSeconds)
        let originSeconds = Int((origin ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970.rounded(.down))
        let fromSeconds = Int(from.timeIntervalSince1970.rounded(.down))
        let span = (to.timeIntervalSince1970 - Double(originSeconds)) / Double(bucket)
        let maxIndex = max(0, Int(min(span.rounded(.up), Double(Int32.max))) - 1)
        let gap = Int(CompressorCycles.maxGap)
        return try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    WITH s AS (
                        SELECT ts, CAST(strftime('%s', ts) AS INTEGER) AS t, powerW, compressorHz,
                            CASE WHEN operating = 1 OR compressorHz > 0 THEN 1 ELSE 0 END AS run,
                            CASE WHEN operating IS NOT NULL OR compressorHz IS NOT NULL THEN 1 ELSE 0 END AS hasc,
                            CASE WHEN power = 1 AND mode = 1 THEN 1.0 WHEN power IS NULL THEN NULL ELSE 0.0 END AS heat,
                            roomTemperature - outdoorTemperature AS delta, outdoorTemperature AS outdoor,
                            CASE WHEN subMode = 2 THEN 1 WHEN subMode IS NULL THEN NULL ELSE 0 END AS def
                        FROM local_samples WHERE ts >= ? AND ts <= ?
                    ), p AS (
                        SELECT *, LAG(t) OVER w AS pt, LAG(run) OVER w AS prun, LAG(hasc) OVER w AS phasc,
                            LAG(def) OVER w AS pdef
                        FROM s WINDOW w AS (ORDER BY ts)
                    ), q AS (
                        SELECT *, CASE WHEN hasc = 1 AND phasc = 1 AND t - pt > 0 AND t - pt <= ? THEN t - pt ELSE 0 END AS dt
                        FROM p WHERE t >= ?
                    )
                    SELECT MIN((t - ?) / ?, ?) AS idx, COUNT(*) AS n,
                        AVG(powerW) AS avgW, MAX(powerW) AS maxW, MIN(powerW) AS minW,
                        AVG(compressorHz) AS avgHz, MAX(compressorHz) AS maxHz,
                        AVG(CASE WHEN run = 1 THEN compressorHz END) AS runHz,
                        AVG(run) AS running, AVG(heat) AS heating, AVG(delta) AS delta,
                        SUM(dt) AS observed, SUM(CASE WHEN prun = 1 THEN dt ELSE 0 END) AS runningSeconds,
                        SUM(CASE WHEN dt > 0 AND prun = 0 AND run = 1 THEN 1 ELSE 0 END) AS starts,
                        SUM(CASE WHEN dt > 0 AND pdef = 0 AND def = 1 THEN 1 ELSE 0 END) AS defrosts,
                        SUM(CASE WHEN pdef = 1 THEN dt ELSE 0 END) AS defrostSeconds,
                        COUNT(def) AS phaseCount, AVG(outdoor) AS outdoor
                    FROM q GROUP BY idx ORDER BY idx
                    """,
                arguments: [
                    from.addingTimeInterval(-CompressorCycles.maxGap), to, gap, fromSeconds, originSeconds, bucket, maxIndex,
                ]
            ).map { row in
                let index: Int = row["idx"]
                return LocalPowerBucket(
                    start: Date(timeIntervalSince1970: TimeInterval(originSeconds + index * bucket)),
                    averageW: row["avgW"], maxW: row["maxW"], minW: row["minW"],
                    averageHz: row["avgHz"], maxHz: row["maxHz"], averageRunningHz: row["runHz"],
                    runningShare: row["running"] ?? 0, heatingShare: row["heating"], averageDelta: row["delta"],
                    observedSeconds: row["observed"] ?? 0, runningSeconds: row["runningSeconds"] ?? 0,
                    starts: row["starts"] ?? 0, count: row["n"], defrosts: row["defrosts"] ?? 0,
                    defrostSeconds: row["defrostSeconds"] ?? 0, phaseCount: row["phaseCount"] ?? 0,
                    averageOutdoor: row["outdoor"])
            }
        }
    }

    /// Stretches of the same operating kind (running, rest, defrost, …) between `from` and `to`.
    /// Only the readings where the kind changes or a gap (> 5 min) starts or ends are loaded; a
    /// stretch before a gap ends one minute after its last reading.
    public func localPhaseSpans(from: Date, to: Date) throws -> [LocalPhaseSpan] {
        let gap = Int(CompressorCycles.maxGap)
        let rows = try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    WITH s AS (
                        SELECT ts, CAST(strftime('%s', ts) AS INTEGER) AS t,
                            CASE WHEN power = 0 OR subMode = 16 THEN 'off'
                                 WHEN subMode = 2 THEN 'defrost'
                                 WHEN subMode IN (1, 4) THEN 'startup'
                                 WHEN subMode = 8 THEN 'rest'
                                 WHEN operating = 1 OR compressorHz > 0 THEN 'running'
                                 WHEN operating IS NOT NULL OR compressorHz IS NOT NULL THEN 'rest'
                                 ELSE 'unknown' END AS kind
                        FROM local_samples WHERE ts >= ? AND ts <= ?
                    ), p AS (
                        SELECT *, LAG(kind) OVER w AS pk, LAG(t) OVER w AS pt, LEAD(t) OVER w AS nt
                        FROM s WINDOW w AS (ORDER BY ts)
                    )
                    SELECT ts, kind,
                        CASE WHEN pk IS NULL OR pk != kind OR t - pt > ? THEN 1 ELSE 0 END AS isStart,
                        CASE WHEN nt IS NULL OR nt - t > ? THEN 1 ELSE 0 END AS isEnd
                    FROM p WHERE pk IS NULL OR pk != kind OR t - pt > ? OR nt IS NULL OR nt - t > ?
                    ORDER BY ts
                    """,
                arguments: [from, to, gap, gap, gap, gap])
        }
        var spans: [LocalPhaseSpan] = []
        var open: (kind: LocalPhaseSpan.Kind, start: Date)?
        for row in rows {
            let ts: Date = row["ts"]
            let kind = LocalPhaseSpan.Kind(rawValue: row["kind"]) ?? .unknown
            if (row["isStart"] as Int) == 1 {
                if let current = open { spans.append(LocalPhaseSpan(kind: current.kind, start: current.start, end: ts)) }
                open = (kind, ts)
            }
            if (row["isEnd"] as Int) == 1, let current = open {
                spans.append(LocalPhaseSpan(kind: current.kind, start: current.start, end: ts.addingTimeInterval(60)))
                open = nil
            }
        }
        return spans
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
