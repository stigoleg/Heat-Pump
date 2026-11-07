import Foundation
import HeatPumpKit

/// Airthings' Consumer API (`https://consumer-api.airthings.com/v1`, OpenAPI 1.0.0, "limited
/// read-only consumer version … for personal use only"; one API client per consumer).
///
/// - Auth: OAuth2 client credentials. `POST https://accounts-api.airthings.com/v1/token` with a
///   JSON body (`scope` is an array); the token lives `expires_in` seconds, there is no refresh
///   token. An expired token answers 401. Wrong client values answer 400 `invalid_grant` (seen,
///   not documented).
/// - Endpoints: `GET /accounts` (the account id is constant for a consumer), `/accounts/{id}/devices`
///   (`serialNumber`, `home`, `name`, `type`, `sensors`), `/accounts/{id}/sensors?sn=…&unit=metric`
///   (newest values, 50 devices per page), `/accounts/{id}/devices/{sn}/samples` (history in
///   columns: `data.time[]` and one array per sensor, a `cursor` for the next page; `resolution`
///   HOUR, `pageSize` up to 5000), `/accounts/{id}/devices/{sn}/thresholds` (GOOD/FAIR/POOR
///   ranges per sensor; cache by `Cache-Control: max-age`).
/// - Limits: an hourly budget per client that every request counts against (rejected ones too),
///   reported in `X-RateLimit-Limit`/`-Remaining`/`-Reset` (Unix seconds); the number is not
///   documented (120 is reported by others, unverified, and assumed when the headers are
///   missing). Over it: 429 with `X-RateLimit-Retry-After` in seconds.
/// - Errors: `{"message": …}`; 400 bad parameter, 401 token, 403 device not in the account.
/// - Data: with a hub, sensors report every 5 minutes and radon hourly; without one, only when the
///   phone app syncs over Bluetooth.
enum AirthingsAPI {
    static let baseURL = URL(string: "https://consumer-api.airthings.com/v1/")!  // constant literal
    static let tokenURL = URL(string: "https://accounts-api.airthings.com/v1/token")!  // constant literal
    /// The only scope a consumer client has.
    static let scope = "read:device:current_values"
    /// Where a user creates the API client (client ID and secret).
    static let dashboardURL = URL(string: "https://consumer-api-doc.airthings.com/dashboard")!  // constant literal
    /// How long to stay away after 429 when the answer does not say.
    static let rateLimitPause: TimeInterval = 15 * 60
    /// The hourly budget assumed when the answer has no rate limit headers (unverified).
    static let assumedHourlyLimit = 120
    /// Entries per history page: a little over 200 days of hours fits in one request.
    static let samplesPageSize = 5000
    /// Device types that are not sensors: the hub relays, the Renew purifier is controlled.
    static let skippedTypes: Set<String> = ["HUB", "AP_1"]

    /// The vendor's sensor types → the core's metrics (unknown types are left out).
    static let metrics: [String: AirQualityMetric] = [
        "radonShortTermAvg": .radonShortTerm, "radonLongTermAvg": .radonLongTerm, "co2": .co2, "voc": .voc, "pm25": .pm25,
        "pm1": .pm1, "humidity": .humidity, "temp": .temperature, "pressure": .pressure,
    ]

    // MARK: Parsing

    /// An answer's JSON, or `decoding`.
    static func json(_ data: Data) throws -> JSONValue {
        do { return try JSONValue.parse(data) } catch { throw HeatPumpError.decoding(L10n.tr("invalid JSON")) }
    }

    /// The access token and when it expires (a minute early, so a request never carries a token
    /// about to expire).
    static func token(from json: JSONValue, now: Date) throws -> (value: String, expires: Date) {
        guard let token = json["access_token"]?.string, !token.isEmpty else { throw HeatPumpError.decoding(L10n.tr("no access token")) }
        let lifetime = json["expires_in"]?.double ?? 3600
        return (token, now.addingTimeInterval(max(60, lifetime - 60)))
    }

    static func accountId(from json: JSONValue) throws -> String {
        guard let id = json["accounts"]?.array?.first?["id"]?.string, !id.isEmpty else { throw HeatPumpError.deviceNotFound }
        return id
    }

    /// The account's sensors (hubs and the purifier left out).
    static func devices(from json: JSONValue) -> [DeviceSummary] {
        (json["devices"]?.array ?? []).compactMap { device in
            guard let serial = device["serialNumber"]?.string, !serial.isEmpty else { return nil }
            let type = device["type"]?.string ?? ""
            guard !skippedTypes.contains(type.uppercased()) else { return nil }
            let name = device["name"]?.string?.trimmingCharacters(in: .whitespaces)
            var metadata = [AirthingsIntegration.typeKey: type]
            if let home = device["home"]?.string, !home.isEmpty { metadata[AirthingsIntegration.homeKey] = home }
            return DeviceSummary(
                key: DeviceKey(integration: AirthingsIntegration.id, nativeId: serial), name: name.flatMap { $0.isEmpty ? nil : $0 } ?? serial,
                kind: .airQualitySensor, metadata: metadata)
        }
    }

    /// The newest values per device; null sensors and devices without any value are left out.
    static func readings(from json: JSONValue) -> [AirQualityReading] {
        (json["results"]?.array ?? []).compactMap { result in
            guard let serial = result["serialNumber"]?.string else { return nil }
            var values: [AirQualityMetric: Double] = [:]
            for sensor in result["sensors"]?.array ?? [] {
                guard let type = sensor["sensorType"]?.string, let metric = metrics[type], let value = sensor["value"]?.double else { continue }
                values[metric] = value
            }
            if let battery = result["batteryPercentage"]?.double { values[.battery] = battery }
            guard !values.isEmpty else { return nil }
            return AirQualityReading(
                device: DeviceKey(integration: AirthingsIntegration.id, nativeId: serial), recorded: date(result["recorded"]?.string),
                values: values)
        }
    }

    /// Hourly averages from a samples page (columns); a null column or value is left out.
    static func hours(from json: JSONValue) -> [AirQualityHour] {
        guard let data = json["data"], let times = data["time"]?.array else { return [] }
        var hours = times.map { AirQualityHour(hour: date($0.string) ?? .distantPast, values: [:]) }
        for (type, metric) in metrics {
            guard let column = data[type]?.array else { continue }
            for (index, value) in column.enumerated() where index < hours.count {
                if let value = value.double { hours[index].values[metric] = value }
            }
        }
        return hours.filter { $0.hour != .distantPast && !$0.values.isEmpty }
    }

    /// The vendor's ratings per sensor; ratings other than GOOD, FAIR and POOR are left out.
    static func thresholds(from json: JSONValue, maxAge: TimeInterval?) -> AirQualityThresholds {
        var ranges: [AirQualityMetric: [AirQualityRange]] = [:]
        for entry in json["sensorThresholds"]?.array ?? [] {
            guard let type = entry["sensorType"]?.string, let metric = metrics[type] else { continue }
            let list = (entry["ranges"]?.array ?? []).compactMap { range -> AirQualityRange? in
                guard let level = level(range["rating"]?.string) else { return nil }
                return AirQualityRange(from: range["from"]?.double, to: range["to"]?.double, level: level)
            }
            if !list.isEmpty { ranges[metric] = list }
        }
        return AirQualityThresholds(ranges: ranges, maxAge: maxAge)
    }

    static func level(_ rating: String?) -> AirQualityLevel? {
        switch rating?.uppercased() {
        case "GOOD": .good
        case "FAIR": .fair
        case "POOR": .poor
        default: nil
        }
    }

    /// `max-age` of a `Cache-Control` header, in seconds.
    static func maxAge(_ header: String?) -> TimeInterval? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "max-age", let seconds = Double(pair[1]) { return seconds }
        }
        return nil
    }

    /// The budget from the rate limit headers; nil when the answer has none.
    static func budget(_ response: HTTPURLResponse, now: Date) -> RequestBudget? {
        guard let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init) else { return nil }
        let limit = response.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Int.init) ?? assumedHourlyLimit
        let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        return RequestBudget(limit: limit, remaining: remaining, resetsAt: reset ?? now.addingTimeInterval(3600))
    }

    /// The error a status means (nil for success), from the answer's headers and body.
    static func error(_ response: HTTPURLResponse, body: Data, now: Date) -> HeatPumpError? {
        switch response.statusCode {
        case 200..<300:
            return nil
        case 429:
            let seconds = (response.value(forHTTPHeaderField: "X-RateLimit-Retry-After") ?? response.value(forHTTPHeaderField: "Retry-After"))
                .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return .rateLimited(until: now.addingTimeInterval(max(seconds ?? rateLimitPause, 1)))
        case 403, 404:
            return .deviceNotFound
        case 401:
            return .unauthorized
        default:
            if let message = (try? JSONValue.parse(body))?["message"]?.string, !message.isEmpty { return .server(message) }
            return .http(status: response.statusCode)
        }
    }

    /// An ISO 8601 date with or without fractional seconds or a zone (the API's times are UTC).
    static func date(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = try? Date(string, strategy: .iso8601) { return date }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
        return try? Date(string + "Z", strategy: .iso8601)
    }

    /// `date` as the API wants it in a query (UTC, seconds).
    static func queryDate(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
    }
}
