import Foundation
import GRDB

extension HistoryStore {
    // MARK: Weather forecast

    /// Replaces the stored forecast from the first new hour on (older hours are kept for a while,
    /// then pruned after 30 days).
    /// Drops forecast hours from `from` on (the place changed); past hours stay.
    public func clearForecast(from: Date) throws {
        try pool.write { db in try db.execute(sql: "DELETE FROM weather_forecast WHERE hour >= ?", arguments: [from]) }
    }

    public func replaceForecast(_ hours: [ForecastHour], fetchedAt: Date) throws {
        guard let first = hours.map(\.time).min() else { return }
        try pool.write { db in
            try db.execute(sql: "DELETE FROM weather_forecast WHERE hour >= ? OR hour < ?", arguments: [first, fetchedAt.addingTimeInterval(-30 * 86_400)])
            for h in hours {
                try db.execute(
                    sql: """
                        INSERT INTO weather_forecast (hour, temp, wind, humidity, cloud, precipitation, precipitation6h, symbol, fetchedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(hour) DO UPDATE SET temp = excluded.temp, wind = excluded.wind, humidity = excluded.humidity,
                            cloud = excluded.cloud, precipitation = excluded.precipitation,
                            precipitation6h = excluded.precipitation6h, symbol = excluded.symbol,
                            fetchedAt = excluded.fetchedAt
                        """,
                    arguments: [
                        h.time, h.temperature, h.windSpeed, h.humidity, h.cloudFraction, h.precipitation, h.precipitation6h, h.symbol,
                        fetchedAt,
                    ])
            }
        }
    }

    /// Forecast hours with `from <= hour < to`.
    public func forecast(from: Date, to: Date) throws -> [ForecastHour] {
        try pool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM weather_forecast WHERE hour >= ? AND hour < ? ORDER BY hour", arguments: [from, to]
            ).map {
                ForecastHour(
                    time: $0["hour"], temperature: $0["temp"], windSpeed: $0["wind"], humidity: $0["humidity"],
                    cloudFraction: $0["cloud"], precipitation: $0["precipitation"], symbol: $0["symbol"],
                    precipitation6h: $0["precipitation6h"])
            }
        }
    }

    /// Mean outdoor temperature per UTC hour from the MELCloud log, snapshots and local readings
    /// (Norway's offsets are whole hours, so these are also local hours).
    public func hourlyOutdoorMeans(device: DeviceKey?, from: Date, to: Date) throws -> [Date: Double] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT CAST(strftime('%s', ts) AS INTEGER) / 3600 AS h, AVG(v) AS v FROM (
                        SELECT ts, outdoor AS v FROM temperature_log
                            WHERE deviceKey = ? AND ts >= ? AND ts < ? AND outdoor IS NOT NULL
                        UNION ALL SELECT ts, outdoorTemperature FROM snapshots
                            WHERE deviceKey = ? AND ts >= ? AND ts < ? AND outdoorTemperature IS NOT NULL
                        UNION ALL SELECT ts, outdoorTemperature FROM local_samples
                            WHERE ts >= ? AND ts < ? AND outdoorTemperature IS NOT NULL AND \(Self.deviceFilter)
                    ) GROUP BY h
                    """,
                arguments: [
                    device?.rawValue, from, to, device?.rawValue, from, to, from, to, device?.rawValue, device?.rawValue,
                ])
            var result: [Date: Double] = [:]
            for row in rows {
                let hour: Int = row["h"]
                result[Date(timeIntervalSince1970: TimeInterval(hour * 3600))] = row["v"]
            }
            return result
        }
    }
}
