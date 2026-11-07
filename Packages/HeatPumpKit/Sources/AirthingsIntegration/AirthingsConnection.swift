import Foundation
import HeatPumpKit

/// The Airthings account: its sensors (`airthings:<serial number>`), their newest values, hourly
/// history and thresholds over the Consumer API (`AirthingsAPI`). Read-only.
///
/// Each call sends one data request. Besides it, the access token is requested when there is none
/// or it has expired (and once more when a data request answers 401), and the account id once per
/// process; both are kept in memory only. Rate limiting, caching and blocks are the service's job
/// (`AirQualityService`); the budget the last answer reported is offered to it
/// (`requestBudget()`) so it stops before the hourly budget runs out.
public actor AirthingsConnection: AirQualityDriver, AirQualityLogReporting, RequestBudgetReporting {
    public nonisolated let identifier = AirthingsIntegration.id

    private let credentials: @Sendable () -> CredentialValues?
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private var token: (value: String, expires: Date)?
    private var accountId: String?
    private var budget: RequestBudget?
    private var listing: (devices: [DeviceSummary], at: Date)?

    public init(
        credentials: @escaping @Sendable () -> CredentialValues?, transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    public nonisolated var capabilities: Set<Capability> { [.airQuality, .airQualityLog] }

    /// Days per history request: 4800 hours, inside one page of `samplesPageSize`.
    public nonisolated var maxAirQualityLogDays: Int { 200 }

    public func resetSession() {
        token = nil
        accountId = nil
        listing = nil
    }

    /// Requests a token (the client values are checked there).
    public func login() async throws {
        _ = try await accessToken()
    }

    public func listDevices() async throws -> [DeviceSummary] {
        let account = try await account()
        let devices = AirthingsAPI.devices(from: try await get("accounts/\(account)/devices"))
        listing = (devices, now())
        return devices
    }

    /// The listing from the last hour, so the hub's daily discovery needs no request.
    public func recentListing() async -> [DeviceSummary]? {
        guard let listing, now().timeIntervalSince(listing.at) < 3600 else { return nil }
        return listing.devices
    }

    public func fetchLatest(devices: [DeviceKey]) async throws -> [AirQualityReading] {
        guard !devices.isEmpty else { return [] }
        let account = try await account()
        let query = devices.map { URLQueryItem(name: "sn", value: $0.nativeId) }
            + [URLQueryItem(name: "unit", value: "metric"), URLQueryItem(name: "pageNumber", value: "1")]
        return AirthingsAPI.readings(from: try await get("accounts/\(account)/sensors", query: query))
    }

    public func fetchHourly(device: DeviceKey, range: DateInterval) async throws -> [AirQualityHour] {
        let account = try await account()
        let query = [
            URLQueryItem(name: "start", value: AirthingsAPI.queryDate(range.start)),
            URLQueryItem(name: "end", value: AirthingsAPI.queryDate(range.end)),
            URLQueryItem(name: "resolution", value: "HOUR"),
            URLQueryItem(name: "pageSize", value: String(AirthingsAPI.samplesPageSize)),
            URLQueryItem(name: "unit", value: "metric"),
        ]
        // One page covers the range; the next fetch starts where this one ended.
        return AirthingsAPI.hours(from: try await get("accounts/\(account)/devices/\(device.nativeId)/samples", query: query))
    }

    public func fetchThresholds(device: DeviceKey) async throws -> AirQualityThresholds? {
        let account = try await account()
        let (json, response) = try await send(
            "accounts/\(account)/devices/\(device.nativeId)/thresholds", query: [URLQueryItem(name: "unit", value: "metric")])
        return AirthingsAPI.thresholds(from: json, maxAge: AirthingsAPI.maxAge(response.value(forHTTPHeaderField: "Cache-Control")))
    }

    public func requestBudget() -> RequestBudget? { budget }

    // MARK: Session

    private func account() async throws -> String {
        if let accountId { return accountId }
        let id = try AirthingsAPI.accountId(from: try await get("accounts"))
        accountId = id
        return id
    }

    /// The cached token, or a new one from the token endpoint.
    func accessToken() async throws -> String {
        if let token, token.expires > now() { return token.value }
        guard let values = credentials(), let id = values["clientId"], !id.isEmpty, let secret = values["clientSecret"], !secret.isEmpty
        else { throw HeatPumpError.missingCredentials }
        var request = URLRequest(url: AirthingsAPI.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            JSONValue.object([
                "grant_type": .string("client_credentials"), "client_id": .string(id), "client_secret": .string(secret),
                "scope": .array([.string(AirthingsAPI.scope)]),
            ]))
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300: break
        case 400, 401, 403:
            // `invalid_grant` / `invalid_client`: the client values are wrong; never retried.
            let code = (try? JSONValue.parse(data))?["error"]?.string
            throw HeatPumpError.invalidCredentials(code)
        default:
            throw AirthingsAPI.error(response, body: data, now: now()) ?? HeatPumpError.http(status: response.statusCode)
        }
        let fresh = try AirthingsAPI.token(from: try AirthingsAPI.json(data), now: now())
        token = fresh
        return fresh.value
    }

    // MARK: HTTP

    func get(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        try await send(path, query: query).json
    }

    /// One GET with the token; an answer of 401 gets one new token and one more try (the token
    /// expired early), a second 401 is `unauthorized`.
    private func send(_ path: String, query: [URLQueryItem]) async throws -> (json: JSONValue, response: HTTPURLResponse) {
        guard var components = URLComponents(url: AirthingsAPI.baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw HeatPumpError.decoding(path)
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw HeatPumpError.decoding(path) }
        for attempt in 1...2 {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await transport.send(request)
            if let budget = AirthingsAPI.budget(response, now: now()) { self.budget = budget }
            if response.statusCode == 401, attempt == 1 {
                token = nil
                continue
            }
            if let error = AirthingsAPI.error(response, body: data, now: now()) { throw error }
            return (try AirthingsAPI.json(data), response)
        }
        throw HeatPumpError.unauthorized
    }
}
