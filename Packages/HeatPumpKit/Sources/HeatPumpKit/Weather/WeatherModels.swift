import Foundation

/// One hour of the MET Norway forecast.
public struct ForecastHour: Codable, Sendable, Equatable {
    public var time: Date
    public var temperature: Double
    /// m/s
    public var windSpeed: Double?
    /// %
    public var humidity: Double?
    /// %
    public var cloudFraction: Double?
    /// mm the next hour (nil beyond the hourly part of the forecast).
    public var precipitation: Double?
    /// MET symbol code for the next hour, e.g. `clearsky_day` (beyond the hourly part: the next 6 hours).
    public var symbol: String?
    /// mm the next 6 hours (MET gives this for every entry; beyond the hourly part it is the only amount).
    public var precipitation6h: Double?

    public init(
        time: Date, temperature: Double, windSpeed: Double? = nil, humidity: Double? = nil, cloudFraction: Double? = nil,
        precipitation: Double? = nil, symbol: String? = nil, precipitation6h: Double? = nil
    ) {
        self.precipitation6h = precipitation6h
        self.time = time
        self.temperature = temperature
        self.windSpeed = windSpeed
        self.humidity = humidity
        self.cloudFraction = cloudFraction
        self.precipitation = precipitation
        self.symbol = symbol
    }
}

/// User settings for the weather forecast (shared by the app and the MCP helper).
public struct WeatherSettings: Codable, Sendable, Equatable {
    /// Typed by the user; used instead of the MELCloud building location when both are set.
    public var latitude: Double?
    public var longitude: Double?
    /// Name shown instead of coordinates, e.g. "Home" or a town. Optional.
    public var placeName: String?
    /// Optional e-mail sent in the User-Agent so MET can reach the developer if the app misbehaves.
    /// Never filled in automatically.
    public var contactEmail: String?

    public init(latitude: Double? = nil, longitude: Double? = nil, placeName: String? = nil, contactEmail: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.contactEmail = contactEmail
    }

    public static let `default` = WeatherSettings()
}

/// Where the forecast is for. Coordinates are rounded to 2 decimals (about 1 km) and never shown.
public struct WeatherLocation: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case manual, demo
        /// The building's location as the heat pump service stores it. Persisted as "melcloud".
        case service = "melcloud"
    }

    public var latitude: Double
    public var longitude: Double
    public var placeName: String?
    public var source: Source

    public init(latitude: Double, longitude: Double, placeName: String?, source: Source) {
        self.latitude = Self.round(latitude)
        self.longitude = Self.round(longitude)
        self.placeName = placeName
        self.source = source
    }

    static func round(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// Key that changes when the (rounded) place changes.
    var key: String { String(format: "%.2f,%.2f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude) }

    /// Description without coordinates; `serviceName` names where a `.service` location comes from.
    public func displayName(serviceName: String) -> String {
        if let placeName, !placeName.trimmingCharacters(in: .whitespaces).isEmpty { return placeName }
        switch source {
        case .manual: return L10n.tr("Chosen place")
        case .service: return L10n.format("The building in %@", serviceName)
        case .demo: return L10n.tr("Oslo (demo)")
        }
    }
}

/// Fetch bookkeeping for the forecast, shared across processes (`app_settings`).
struct WeatherFetchMeta: Codable, Sendable, Equatable {
    var locationKey: String?
    var lastModified: String?
    var expires: Date?
    var fetchedAt: Date?
    var lastError: String?
}

/// Result of a forecast update.
public struct WeatherSync: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case noLocation, upToDate, fetched, notModified, skipped, failed
    }

    public var status: Status
    public var count: Int = 0
    public var message: String?
    public var nextAllowed: Date?
}

/// Stored forecast for the app and `get_forecast`.
public struct WeatherForecast: Sendable, Equatable {
    public var location: WeatherLocation?
    public var hours: [ForecastHour]
    public var fetchedAt: Date?
    /// Required by MET's licence (CC BY 4.0).
    public static let attribution = L10n.tr("Weather data: MET Norway (yr.no), CC BY 4.0")
}

/// What MET answered.
public struct WeatherResponse: Sendable, Equatable {
    /// 200, 203 (deprecated but valid) or 304 (not modified).
    public var status: Int
    public var hours: [ForecastHour]
    public var lastModified: String?
    public var expires: Date?

    package init(status: Int, hours: [ForecastHour], lastModified: String?, expires: Date?) {
        self.status = status
        self.hours = hours
        self.lastModified = lastModified
        self.expires = expires
    }
}

public enum WeatherError: Error, Sendable, Equatable, LocalizedError {
    /// 403: MET refuses the request (usually a missing or bad User-Agent).
    case forbidden
    /// 429: too many requests; wait.
    case throttled(until: Date?)
    case http(status: Int)
    case network(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .forbidden: L10n.tr("MET rejected the request (HTTP 403). The app tries again in an hour.")
        case .throttled: L10n.tr("MET asks for fewer requests (HTTP 429). The app waits before asking again.")
        case .http(let status): L10n.format("Weather forecast: the server answered with HTTP error %lld.", status)
        case .network(let detail): L10n.format("Weather forecast: network error (%@).", detail)
        case .decoding(let detail): L10n.format("The weather forecast could not be interpreted: %@", detail)
        }
    }
}

/// A forecast source. Injected so tests and demo mode never call MET.
public protocol WeatherProviding: Sendable {
    func fetch(latitude: Double, longitude: Double, ifModifiedSince: String?) async throws -> WeatherResponse
}
