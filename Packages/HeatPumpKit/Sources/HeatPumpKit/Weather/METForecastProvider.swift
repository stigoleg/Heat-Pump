import Foundation

/// MET Norway Locationforecast 2.0, compact (`api.met.no`). Terms: an identifying User-Agent is
/// required (403 without, ban for fake ones), coordinates with at most 4 decimals (we send 2),
/// respect `Expires`, send `If-Modified-Since`, handle 203 (deprecated) and 429. Data is CC BY 4.0.
public struct METForecastProvider: WeatherProviding {
    public static let endpoint = "https://api.met.no/weatherapi/locationforecast/2.0/compact"
    public let userAgent: String
    private let transport: any HTTPTransport

    public init(userAgent: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.userAgent = userAgent
        self.transport = transport
    }

    /// `Varmepumpe-macOS/<version> (personlig bruk; kontakt: <e-mail>)`, without the contact part when
    /// the user has not entered one.
    public static func userAgent(version: String, contact: String?) -> String {
        let trimmed = contact?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "Varmepumpe-macOS/\(version) (personlig bruk" + (trimmed.isEmpty ? ")" : "; kontakt: \(trimmed))")
    }

    static func url(latitude: Double, longitude: Double) -> URL? {
        let posix = Locale(identifier: "en_US_POSIX")
        return URL(
            string: endpoint + "?lat=" + String(format: "%.2f", locale: posix, latitude) + "&lon="
                + String(format: "%.2f", locale: posix, longitude))
    }

    public func fetch(latitude: Double, longitude: Double, ifModifiedSince: String?) async throws -> WeatherResponse {
        guard let url = Self.url(latitude: latitude, longitude: longitude) else { throw WeatherError.network(L10n.tr("invalid address")) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let ifModifiedSince { request.setValue(ifModifiedSince, forHTTPHeaderField: "If-Modified-Since") }
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await transport.send(request) } catch let error as HeatPumpError {
            if case .network(let detail) = error { throw WeatherError.network(detail) }
            throw WeatherError.network(error.localizedDescription)
        }
        let lastModified = response.value(forHTTPHeaderField: "Last-Modified")
        let expires = Self.httpDate(response.value(forHTTPHeaderField: "Expires"))
        switch response.statusCode {
        case 304:
            return WeatherResponse(status: 304, hours: [], lastModified: lastModified ?? ifModifiedSince, expires: expires)
        case 200, 203:
            if response.statusCode == 203 {
                FileHandle.standardError.write(Data("[weather] MET answered 203: this API version is deprecated\n".utf8))
            }
            return WeatherResponse(status: response.statusCode, hours: try Self.parse(data), lastModified: lastModified, expires: expires)
        case 403: throw WeatherError.forbidden
        case 429: throw WeatherError.throttled(until: expires)
        default: throw WeatherError.http(status: response.statusCode)
        }
    }

    /// `properties.timeseries[]` → hours with `instant.details`, the next hour's symbol/precipitation
    /// and the next 6 hours' precipitation (and symbol where the hourly part has ended).
    static func parse(_ data: Data) throws -> [ForecastHour] {
        let json: JSONValue
        do { json = try JSONValue.parse(data) } catch { throw WeatherError.decoding(L10n.tr("invalid JSON")) }
        guard let series = json["properties"]?["timeseries"]?.array else { throw WeatherError.decoding(L10n.tr("timeseries missing")) }
        return series.compactMap { entry in
            guard let time = PriceAggregation.iso(entry["time"]?.string),
                let details = entry["data"]?["instant"]?["details"], let temperature = details["air_temperature"]?.double
            else { return nil }
            let next = entry["data"]?["next_1_hours"]
            let six = entry["data"]?["next_6_hours"]
            return ForecastHour(
                time: time, temperature: temperature, windSpeed: details["wind_speed"]?.double,
                humidity: details["relative_humidity"]?.double, cloudFraction: details["cloud_area_fraction"]?.double,
                precipitation: next?["details"]?["precipitation_amount"]?.double,
                symbol: next?["summary"]?["symbol_code"]?.string ?? six?["summary"]?["symbol_code"]?.string,
                precipitation6h: six?["details"]?["precipitation_amount"]?.double)
        }
    }

    static func httpDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}
