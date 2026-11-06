import Foundation

/// Errors from electricity price sources. `errorDescription` is display text (via `L10n`).
public enum PriceError: Error, Sendable, Equatable, LocalizedError {
    case missingToken
    case unauthorized
    case http(status: Int)
    case network(String)
    case decoding(String)
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: L10n.tr("No Tibber token. Enter it under Settings → Electricity price.")
        case .unauthorized: L10n.tr("Tibber did not accept the token. Check that it was copied correctly.")
        case .http(let status): L10n.format("Price data: the server answered with HTTP error %lld.", status)
        case .network(let detail): L10n.format("Price data: network error (%@).", detail)
        case .decoding(let detail): L10n.format("Price data could not be interpreted: %@", detail)
        case .server(let detail): L10n.format("Price data: %@", detail)
        }
    }
}

/// A source of hourly spot prices.
public protocol PriceProvider: Sendable {
    /// `tibber`, `hvakosterstrommen` or `mock`.
    var source: String { get }
    /// Price area (`NO1`…) or `tibber`.
    var area: String { get }
    /// Whether one request covers many past days (otherwise one request per day).
    var fetchesRangesInOneRequest: Bool { get }
    /// Hourly prices for the given local days (start of day). Quarter-hourly data is averaged per hour.
    func fetchPrices(days: [Date], timeZone: TimeZone) async throws -> [HourPrice]
}

enum PriceAggregation {
    /// Averages entries by the hour they start in.
    static func hourly(
        _ entries: [(start: Date, spotOre: Double, totalOre: Double, level: String?)], area: String, source: String,
        timeZone: TimeZone
    ) -> [HourPrice] {
        let calendar = WireDate.calendar(timeZone)
        var groups: [Date: [(Double, Double, String?)]] = [:]
        for entry in entries {
            guard let hour = calendar.dateInterval(of: .hour, for: entry.start)?.start else { continue }
            groups[hour, default: []].append((entry.spotOre, entry.totalOre, entry.level))
        }
        return groups.keys.sorted().map { hour in
            let values = groups[hour] ?? []
            let n = Double(max(values.count, 1))
            return HourPrice(
                hour: hour, area: area, source: source,
                spotOre: values.map(\.0).reduce(0, +) / n, totalOre: values.map(\.1).reduce(0, +) / n,
                level: values.compactMap(\.2).first)
        }
    }

    static func iso(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let d = try? Date(string, strategy: .iso8601) { return d }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return try? fractional.parse(string)
    }
}

/// hvakosterstrommen.no — free, open API with day-ahead prices per area (excl. VAT).
/// Format: `GET /api/v1/prices/YYYY/MM-DD_NOx.json` → `[{ NOK_per_kWh, EUR_per_kWh, EXR,
/// time_start, time_end }]` (hourly or 15-minute entries). Prices exclude VAT; NO4 has none.
/// Tomorrow's prices are published from about 13:00. Source: https://www.hvakosterstrommen.no/strompris-api
public struct HvaKosterStrommenProvider: PriceProvider {
    public let source = "hvakosterstrommen"
    public let priceArea: PriceArea
    public var area: String { priceArea.rawValue }
    public let fetchesRangesInOneRequest = false
    private let transport: any HTTPTransport

    public init(area: PriceArea, transport: any HTTPTransport = URLSessionTransport()) {
        self.priceArea = area
        self.transport = transport
    }

    public func fetchPrices(days: [Date], timeZone: TimeZone) async throws -> [HourPrice] {
        var result: [HourPrice] = []
        for day in days {
            let calendar = WireDate.calendar(timeZone)
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = c.year, let m = c.month, let d = c.day,
                let url = URL(string: String(format: "https://www.hvakosterstrommen.no/api/v1/prices/%04d/%02d-%02d_%@.json", y, m, d, area))
            else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Varmepumpe/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await sendMapped(request)
                if response.statusCode == 404 { continue }  // not published yet
                guard (200..<300).contains(response.statusCode) else { throw PriceError.http(status: response.statusCode) }
                result += try Self.parse(data, area: priceArea, timeZone: timeZone)
            } catch {
                // Keep the days already fetched; the rest is tried again next hour.
                if result.isEmpty { throw error }
                break
            }
        }
        return result
    }

    static func parse(_ data: Data, area: PriceArea, timeZone: TimeZone) throws -> [HourPrice] {
        let json: JSONValue
        do { json = try JSONValue.parse(data) } catch { throw PriceError.decoding(L10n.tr("invalid JSON")) }
        guard let array = json.array else { throw PriceError.decoding(L10n.tr("expected a list")) }
        let entries = array.compactMap { entry -> (Date, Double, Double)? in
            guard let start = PriceAggregation.iso(entry["time_start"]?.string), let nok = entry["NOK_per_kWh"]?.double
            else { return nil }
            let spot = nok * 100
            return (start, spot, spot * area.vatFactor)
        }
        return PriceAggregation.hourly(
            entries.map { (start: $0.0, spotOre: $0.1, totalOre: $0.2, level: nil) }, area: area.rawValue,
            source: "hvakosterstrommen", timeZone: timeZone)
    }

    private func sendMapped(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await transport.send(request) } catch let error as HeatPumpError {
            if case .network(let detail) = error { throw PriceError.network(detail) }
            throw PriceError.network(error.localizedDescription)
        }
    }
}

/// Tibber GraphQL API (`https://api.tibber.com/v1-beta/gql`, `Authorization: Bearer <token>`).
///
/// Schema checked by introspection on 2026-11-05: `Subscription.priceInfo(resolution: HOURLY |
/// QUARTER_HOURLY)` with `today`/`tomorrow`, and `Subscription.priceInfoRange(resolution:, last:)`
/// (replaces `priceInfo.range`; HOURLY capped at 744 items). `Price.total` = energy + tax, where
/// `energy` is the Nord Pool spot price and `tax` is VAT plus guarantee-of-origin certificates, so
/// `total` already includes VAT and must not get VAT added again.
public struct TibberPriceProvider: PriceProvider {
    public static let endpoint = URL(string: "https://api.tibber.com/v1-beta/gql")!  // constant literal
    public let source = "tibber"
    public let area = "tibber"
    public let fetchesRangesInOneRequest = true
    private let token: String
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(token: String, transport: any HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.token = token
        self.transport = transport
        self.now = now
    }

    static func query(rangeHours: Int) -> String {
        let fields = "total energy tax startsAt level"
        var parts = ["priceInfo(resolution: HOURLY) { current { \(fields) } today { \(fields) } tomorrow { \(fields) } }"]
        if rangeHours > 0 {
            parts.append("priceInfoRange(resolution: HOURLY, last: \(min(rangeHours, 744))) { nodes { \(fields) } }")
        }
        return "{ viewer { homes { currentSubscription { \(parts.joined(separator: " ")) } } } }"
    }

    public func fetchPrices(days: [Date], timeZone: TimeZone) async throws -> [HourPrice] {
        let calendar = WireDate.calendar(timeZone)
        let today = calendar.startOfDay(for: now())
        let earliest = days.min() ?? today
        let rangeHours = earliest < today ? Int(now().timeIntervalSince(earliest) / 3600) + 1 : 0
        let all = try await request(query: Self.query(rangeHours: rangeHours), timeZone: timeZone)
        let wanted = Set(days.map { calendar.startOfDay(for: $0) })
        return all.filter { wanted.contains(calendar.startOfDay(for: $0.hour)) }
    }

    /// One small request to check the token ("Test" in Settings). Returns today's hour count.
    public func test(timeZone: TimeZone) async throws -> Int {
        try await request(query: Self.query(rangeHours: 0), timeZone: timeZone).count
    }

    private func request(query: String, timeZone: TimeZone) async throws -> [HourPrice] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Varmepumpe/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(["query": .string(query)]))
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await transport.send(request) } catch let error as HeatPumpError {
            if case .network(let detail) = error { throw PriceError.network(detail) }
            throw PriceError.network(error.localizedDescription)
        }
        if response.statusCode == 401 || response.statusCode == 403 { throw PriceError.unauthorized }
        guard (200..<300).contains(response.statusCode) else { throw PriceError.http(status: response.statusCode) }
        return try Self.parse(data, timeZone: timeZone)
    }

    static func parse(_ data: Data, timeZone: TimeZone) throws -> [HourPrice] {
        let json: JSONValue
        do { json = try JSONValue.parse(data) } catch { throw PriceError.decoding(L10n.tr("invalid JSON")) }
        if let errors = json["errors"]?.array, !errors.isEmpty {
            let message = errors.compactMap { $0["message"]?.string }.joined(separator: "; ")
            if message.lowercased().contains("unauthor") || message.lowercased().contains("token") { throw PriceError.unauthorized }
            throw PriceError.server(message)
        }
        let homes = json["data"]?["viewer"]?["homes"]?.array ?? []
        guard let subscription = homes.compactMap({ $0["currentSubscription"] }).first(where: { !$0.isNull }) else {
            throw PriceError.server(L10n.tr("Found no active electricity subscription on the Tibber account."))
        }
        let info = subscription["priceInfo"]
        let lists = [info?["today"], info?["tomorrow"], subscription["priceInfoRange"]?["nodes"]]
        var entries: [(start: Date, spotOre: Double, totalOre: Double, level: String?)] = []
        for list in lists {
            for price in list?.array ?? [] {
                guard let start = PriceAggregation.iso(price["startsAt"]?.string), let total = price["total"]?.double
                else { continue }
                let energy = price["energy"]?.double ?? total / 1.25
                entries.append((start, energy * 100, total * 100, price["level"]?.string))
            }
        }
        // Today/tomorrow and the range overlap; keep one value per start time.
        var seen = Set<Date>()
        entries = entries.filter { seen.insert($0.start).inserted }
        return PriceAggregation.hourly(entries, area: "tibber", source: "tibber", timeZone: timeZone)
    }
}

/// Deterministic Norwegian winter price curve for `VARMEPUMPE_BACKEND=mock`: cheap nights,
/// morning and evening peaks, a different level each day. Spot in NO1 (25 % VAT).
public struct MockPriceProvider: PriceProvider {
    public let source = "mock"
    public let area = "NO1"
    public let fetchesRangesInOneRequest = true

    public init() {}

    public func fetchPrices(days: [Date], timeZone: TimeZone) async throws -> [HourPrice] {
        let calendar = WireDate.calendar(timeZone)
        return days.flatMap { day -> [HourPrice] in
            let start = calendar.startOfDay(for: day)
            let dayIndex = start.timeIntervalSince1970 / 86_400
            let level = 85 + 35 * sin(dayIndex * 0.9) + 15 * sin(dayIndex * 0.37)
            return (0..<24).compactMap { h -> HourPrice? in
                guard let hour = calendar.date(byAdding: .hour, value: h, to: start) else { return nil }
                let hh = Double(h)
                let morning = 45 * exp(-pow((hh - 8) / 1.6, 2))
                let evening = 60 * exp(-pow((hh - 18) / 2.0, 2))
                let night: Double = hh < 5 ? -25 : 0
                let spot = max(5, level + morning + evening + night)
                let rounded = (spot * 100).rounded() / 100
                return HourPrice(hour: hour, area: area, source: source, spotOre: rounded, totalOre: rounded * 1.25)
            }
        }
    }
}
