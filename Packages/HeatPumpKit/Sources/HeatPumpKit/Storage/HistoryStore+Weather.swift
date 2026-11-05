import Foundation
import GRDB

extension HistoryStore {
    // MARK: Weather forecast

    /// Replaces the stored forecast from the first new hour on (older hours are kept for a while,
    /// then pruned after 30 days).
    public func replaceForecast(_ hours: [ForecastHour], fetchedAt: Date) throws {
        guard let first = hours.map(\.time).min() else { return }
        try pool.write { db in
            try db.execute(sql: "DELETE FROM weather_forecast WHERE hour >= ? OR hour < ?", arguments: [first, fetchedAt.addingTimeInterval(-30 * 86_400)])
            for h in hours {
                try db.execute(
                    sql: """
                        INSERT INTO weather_forecast (hour, temp, wind, humidity, cloud, precipitation, symbol, fetchedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(hour) DO UPDATE SET temp = excluded.temp, wind = excluded.wind, humidity = excluded.humidity,
                            cloud = excluded.cloud, precipitation = excluded.precipitation, symbol = excluded.symbol,
                            fetchedAt = excluded.fetchedAt
                        """,
                    arguments: [h.time, h.temperature, h.windSpeed, h.humidity, h.cloudFraction, h.precipitation, h.symbol, fetchedAt])
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
                    cloudFraction: $0["cloud"], precipitation: $0["precipitation"], symbol: $0["symbol"])
            }
        }
    }

    /// Mean outdoor temperature per UTC hour from the MELCloud log, snapshots and local readings
    /// (Norway's offsets are whole hours, so these are also local hours).
    public func hourlyOutdoorMeans(deviceId: Int?, from: Date, to: Date) throws -> [Date: Double] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT CAST(strftime('%s', ts) AS INTEGER) / 3600 AS h, AVG(v) AS v FROM (
                        SELECT ts, outdoor AS v FROM temperature_log
                            WHERE deviceId = ? AND ts >= ? AND ts < ? AND outdoor IS NOT NULL
                        UNION ALL SELECT ts, outdoorTemperature FROM snapshots
                            WHERE deviceId = ? AND ts >= ? AND ts < ? AND outdoorTemperature IS NOT NULL
                        UNION ALL SELECT ts, outdoorTemperature FROM local_samples
                            WHERE ts >= ? AND ts < ? AND outdoorTemperature IS NOT NULL
                    ) GROUP BY h
                    """,
                arguments: [deviceId ?? -1, from, to, deviceId ?? -1, from, to, from, to])
            var result: [Date: Double] = [:]
            for row in rows {
                let hour: Int = row["h"]
                result[Date(timeIntervalSince1970: TimeInterval(hour * 3600))] = row["v"]
            }
            return result
        }
    }
}

extension HistoryStore {
    // MARK: House consumption

    public func upsertHouseHours(_ hours: [HouseHour]) throws {
        try pool.write { db in
            for h in hours {
                try db.execute(
                    sql: """
                        INSERT INTO house_consumption_hourly (hour, kWh, cost, unitPrice) VALUES (?, ?, ?, ?)
                        ON CONFLICT(hour) DO UPDATE SET kWh = excluded.kWh, cost = excluded.cost, unitPrice = excluded.unitPrice
                        """,
                    arguments: [h.hour, h.kWh, h.costNok, h.unitPriceOre])
            }
        }
    }

    /// House hours with `from <= hour < to`.
    public func houseHours(from: Date, to: Date) throws -> [HouseHour] {
        try pool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM house_consumption_hourly WHERE hour >= ? AND hour < ? ORDER BY hour", arguments: [from, to]
            ).map { HouseHour(hour: $0["hour"], kWh: $0["kWh"], costNok: $0["cost"], unitPriceOre: $0["unitPrice"]) }
        }
    }

    public func latestHouseHour() throws -> Date? {
        try pool.read { db in try Date.fetchOne(db, sql: "SELECT MAX(hour) FROM house_consumption_hourly") }
    }
}
