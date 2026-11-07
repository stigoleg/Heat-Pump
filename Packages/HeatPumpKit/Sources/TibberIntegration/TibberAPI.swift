import Foundation
import HeatPumpKit

/// Tibber's GraphQL API over HTTP (`https://api.tibber.com/v1-beta/gql`, `Authorization: Bearer
/// <token>`). About 100 requests per 5 minutes per IP are allowed; callers ask for homes and
/// consumption at most hourly (the socket address comes with the homes, and a connection attempt
/// reuses a listing from the last hour).
///
/// Errors: HTTP 401/403 and GraphQL `UNAUTHENTICATED` (Tibber answers an invalid token with
/// HTTP 200 since 2025-01-03) are `invalidCredentials`, `HOME_NOT_FOUND` is `deviceNotFound`,
/// HTTP 429/428 is `rateLimited` (the format of Tibber's answer is undocumented, so a fixed pause).
struct TibberAPI: Sendable {
    static let endpoint = TibberPriceProvider.endpoint
    /// How long to stay away after HTTP 429/428.
    static let rateLimitPause: TimeInterval = 15 * 60

    let token: @Sendable () -> String?
    let transport: any HTTPTransport
    let userAgent: String
    let now: @Sendable () -> Date

    /// The `User-Agent` Tibber asks for on every request and the socket upgrade.
    static func userAgent(version: String) -> String { "Varmepumpe/\(version) (macOS)" }

    /// Sends `query` and returns `data`, or throws the mapped error.
    func query(_ query: String) async throws -> JSONValue {
        guard let value = token(), !value.isEmpty else { throw HeatPumpError.missingCredentials }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(["query": .string(query)]))
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 401, 403: throw HeatPumpError.invalidCredentials(nil)
        case 428, 429: throw HeatPumpError.rateLimited(until: now().addingTimeInterval(Self.rateLimitPause))
        case 200..<300: break
        default: throw HeatPumpError.http(status: response.statusCode)
        }
        let json: JSONValue
        do { json = try JSONValue.parse(data) } catch { throw HeatPumpError.decoding(L10n.tr("invalid JSON")) }
        try Self.checkErrors(json)
        guard let result = json["data"], !result.isNull else { throw HeatPumpError.decoding(L10n.tr("no data")) }
        return result
    }

    /// Throws for a GraphQL `errors` list: by `extensions.code`, falling back to the message.
    static func checkErrors(_ json: JSONValue) throws {
        guard let errors = json["errors"]?.array, !errors.isEmpty else { return }
        let codes = errors.compactMap { $0["extensions"]?["code"]?.string }
        let message = errors.compactMap { $0["message"]?.string }.joined(separator: "; ")
        if codes.contains("UNAUTHENTICATED") || message.lowercased().contains("unauthor") || message.lowercased().contains("token") {
            throw HeatPumpError.invalidCredentials(nil)
        }
        if codes.contains("HOME_NOT_FOUND") { throw HeatPumpError.deviceNotFound }
        throw HeatPumpError.server(message)
    }

    // MARK: Homes

    static let homesQuery =
        "{ viewer { websocketSubscriptionUrl homes { id appNickname address { address1 postalCode city } features { realTimeConsumptionEnabled } } } }"

    /// One home as Tibber lists it.
    struct Home: Sendable, Equatable {
        var id: String
        var name: String
        var realTime: Bool
    }

    /// The account's homes and the socket address for live data.
    func homes() async throws -> (homes: [Home], websocket: URL?) {
        let data = try await query(Self.homesQuery)
        return Self.parseHomes(data)
    }

    static func parseHomes(_ data: JSONValue) -> (homes: [Home], websocket: URL?) {
        let viewer = data["viewer"]
        let homes = (viewer?["homes"]?.array ?? []).compactMap { home -> Home? in
            guard let id = home["id"]?.string, !id.isEmpty else { return nil }
            let nickname = home["appNickname"]?.string?.trimmingCharacters(in: .whitespaces)
            let address = home["address"]?["address1"]?.string?.trimmingCharacters(in: .whitespaces)
            let name = [nickname, address].compactMap { $0 }.first { !$0.isEmpty } ?? TibberIntegration.displayName
            return Home(id: id, name: name, realTime: home["features"]?["realTimeConsumptionEnabled"]?.bool ?? false)
        }
        return (homes, viewer?["websocketSubscriptionUrl"]?.string.flatMap(URL.init(string:)))
    }

    // MARK: Consumption

    static func consumptionQuery(homeId: String, lastHours: Int) -> String {
        let last = min(max(lastHours, 1), 744)
        return "{ viewer { home(id: \(quoted(homeId))) { consumption(resolution: HOURLY, last: \(last)) { nodes { from to unitPrice unitPriceVAT consumption cost currency } } } } }"
    }

    /// One home's finished hours (Tibber caps `last` at 744).
    func consumption(homeId: String, lastHours: Int) async throws -> [HouseHour] {
        Self.parseHours(try await query(Self.consumptionQuery(homeId: homeId, lastHours: lastHours))["viewer"]?["home"]?["consumption"])
    }

    /// Hours from a `consumption` connection; hours Tibber has not finished (null) are left out.
    static func parseHours(_ consumption: JSONValue?) -> [HouseHour] {
        (consumption?["nodes"]?.array ?? []).compactMap { node in
            guard let from = date(node["from"]?.string), let kWh = node["consumption"]?.double else { return nil }
            return HouseHour(hour: from, kWh: kWh, costNok: node["cost"]?.double, unitPriceOre: node["unitPrice"]?.double.map { $0 * 100 })
        }
    }

    // MARK: Helpers

    /// An ISO 8601 date with or without fractional seconds.
    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = try? Date(string, strategy: .iso8601) { return date }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
    }

    /// `value` as a GraphQL string literal.
    static func quoted(_ value: String) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
    }
}
