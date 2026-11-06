import Foundation
import HeatPumpKit

/// The house's consumption with the price token alone (no meter enabled): Tibber
/// `viewer.homes[].consumption(resolution: HOURLY, last: N)`, nodes `from, to, unitPrice,
/// unitPriceVAT, consumption, cost, currency`, from the first home with data. Not real-time: the
/// last hours fill in late. Rate limit about 100 requests per 5 minutes per IP; asked at most
/// hourly. Errors are `PriceError`s, as for the price token.
public struct TibberConsumptionProvider: HouseConsumptionProviding {
    private let token: String
    private let transport: any HTTPTransport

    public init(token: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.token = token
        self.transport = transport
    }

    static func query(lastHours: Int) -> String {
        let last = min(max(lastHours, 1), 744)
        return "{ viewer { homes { consumption(resolution: HOURLY, last: \(last)) { nodes { from to unitPrice unitPriceVAT consumption cost currency } } } } }"
    }

    public func fetchConsumption(lastHours: Int) async throws -> [HouseHour] {
        var request = URLRequest(url: TibberAPI.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Varmepumpe/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(["query": .string(Self.query(lastHours: lastHours))]))
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await transport.send(request) } catch let error as HeatPumpError {
            if case .network(let detail) = error { throw PriceError.network(detail) }
            throw PriceError.network(error.localizedDescription)
        }
        if response.statusCode == 401 || response.statusCode == 403 { throw PriceError.unauthorized }
        guard (200..<300).contains(response.statusCode) else { throw PriceError.http(status: response.statusCode) }
        return try Self.parse(data)
    }

    /// Hours from the first home with consumption data; hours Tibber has not finished (null) are skipped.
    static func parse(_ data: Data) throws -> [HouseHour] {
        let json: JSONValue
        do { json = try JSONValue.parse(data) } catch { throw PriceError.decoding(L10n.tr("invalid JSON")) }
        do {
            try TibberAPI.checkErrors(json)
        } catch HeatPumpError.invalidCredentials {
            throw PriceError.unauthorized
        } catch HeatPumpError.server(let message) {
            throw PriceError.server(message)
        }
        let homes = json["data"]?["viewer"]?["homes"]?.array ?? []
        let consumption = homes.compactMap { $0["consumption"] }.first { !($0["nodes"]?.array ?? []).isEmpty }
        return TibberAPI.parseHours(consumption)
    }
}
