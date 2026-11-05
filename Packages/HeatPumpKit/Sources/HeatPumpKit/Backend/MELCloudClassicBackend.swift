import Foundation

/// Minimal HTTP abstraction so the backend can be tested with canned responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HeatPumpError.network("Ugyldig svar") }
            return (data, http)
        } catch let error as HeatPumpError {
            throw error
        } catch {
            throw HeatPumpError.network(error.localizedDescription)
        }
    }
}

/// MELCloud Classic (`app.melcloud.com`) backend.
///
/// One `fetchState` costs one `Device/Get` call, plus a `User/ListDevices` call when the
/// cached listing (limits, Wi-Fi signal, firmware, energy counters) is older than
/// `listingMaxAge`. Rate limiting across processes is the service's job.
public actor MELCloudClassicBackend: HeatPumpBackend {
    public nonisolated let identifier = "melcloud-classic"

    public static let baseURL = URL(string: "https://app.melcloud.com/Mitsubishi.Wifi.Client")!  // constant literal
    static let appVersion = "1.19.1.1"
    /// MELCloud language code for Norwegian; affects the language of `ErrorMessage` texts.
    static let languageNorwegian = 13

    private let transport: any HTTPTransport
    private let credentials: any CredentialProviding
    private let timeZone: TimeZone
    private let listingMaxAge: TimeInterval
    private let now: @Sendable () -> Date

    private var contextKey: String?
    private var listing: (fetchedAt: Date, devices: [JSONValue])?

    public init(
        credentials: any CredentialProviding,
        transport: any HTTPTransport = URLSessionTransport(),
        timeZone: TimeZone = .current,
        listingMaxAge: TimeInterval = 30 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.transport = transport
        self.timeZone = timeZone
        self.listingMaxAge = listingMaxAge
        self.now = now
        self.contextKey = credentials.loadContextKey()
    }

    // MARK: HeatPumpBackend

    public func login() async throws {
        guard let creds = try credentials.loadCredentials() else { throw HeatPumpError.missingCredentials }
        let body: [String: JSONValue] = [
            "Email": .string(creds.email),
            "Password": .string(creds.password),
            "Language": .number(Double(Self.languageNorwegian)),
            "AppVersion": .string(Self.appVersion),
            "Persist": .bool(true),
            "CaptchaResponse": .null,
        ]
        let request = try makeRequest("POST", "Login/ClientLogin", body: .object(body), authenticated: false)
        let (data, response) = try await transport.send(request)
        try checkStatus(response)
        let json = try parse(data)
        switch MELCloudClassicParser.parseLogin(json, now: now()) {
        case .success(let key, _):
            contextKey = key
            try? credentials.saveContextKey(key)
        case .throttled(let until):
            throw HeatPumpError.loginThrottled(until: until)
        case .refused(let errorId, let message):
            throw HeatPumpError.invalidCredentials(message ?? errorId.map { "ErrorId \($0)" })
        }
    }

    public func listDevices() async throws -> [DeviceSummary] {
        try await refreshListing().compactMap(MELCloudClassicParser.summary)
    }

    public func fetchState(deviceId: Int) async throws -> DeviceState {
        var devices = listing.flatMap { now().timeIntervalSince($0.fetchedAt) < listingMaxAge ? $0.devices : nil }
        if devices == nil { devices = try await refreshListing() }
        guard let wrapper = devices?.first(where: { $0["DeviceID"]?.int == deviceId }) else {
            throw HeatPumpError.deviceNotFound
        }
        let buildingId = wrapper["BuildingID"]?.int ?? 0
        let get = try await authorizedJSON(
            "GET", "Device/Get",
            query: [URLQueryItem(name: "id", value: String(deviceId)), URLQueryItem(name: "buildingID", value: String(buildingId))])
        return try MELCloudClassicParser.state(listing: wrapper, get: get, fetchedAt: now())
    }

    public func apply(_ changes: ChangeSet) async throws {
        let body = MELCloudClassicParser.setAtaPayload(changes)
        let response = try await authorizedJSON("POST", "Device/SetAta", body: .object(body))
        if let attributeErrors = response["AttributeErrors"]?.object, !attributeErrors.isEmpty {
            throw HeatPumpError.server(attributeErrors.keys.sorted().joined(separator: ", "))
        }
    }

    public func fetchErrorLog(deviceId: Int, range: DateInterval) async throws -> [ErrorLogEntry] {
        let body: JSONValue = .object([
            "DeviceIDs": .array([.number(Double(deviceId))]),
            "FromDate": .string(WireDate.day(range.start, timeZone: timeZone)),
            "ToDate": .string(WireDate.day(range.end, timeZone: timeZone)),
        ])
        let json = try await authorizedJSON("POST", "Report/GetUnitErrorLog2", body: body)
        return try MELCloudClassicParser.errorLog(json, timeZone: timeZone)
    }

    public func fetchTemperatureLog(deviceId: Int, range: DateInterval) async throws -> [TemperaturePoint] {
        let body: JSONValue = .object([
            "DeviceID": .number(Double(deviceId)),
            "FromDate": .string(WireDate.localTimestamp(range.start, timeZone: timeZone)),
            "ToDate": .string(WireDate.localTimestamp(range.end, timeZone: timeZone)),
        ])
        let json = try await authorizedJSON("POST", "Report/GetTemperatureLog2", body: body)
        return MELCloudClassicParser.temperatureLog(json, timeZone: timeZone)
    }

    public func fetchEnergy(deviceId: Int, range: DateInterval) async throws -> [EnergyDay] {
        let calendar = WireDate.calendar(timeZone)
        let body: JSONValue = .object([
            "DeviceID": .number(Double(deviceId)),
            "FromDate": .string(WireDate.localTimestamp(calendar.startOfDay(for: range.start), timeZone: timeZone)),
            "ToDate": .string(WireDate.localTimestamp(calendar.startOfDay(for: range.end), timeZone: timeZone)),
            "UseCurrency": .bool(false),
        ])
        let json = try await authorizedJSON("POST", "EnergyCost/Report", body: body)
        return MELCloudClassicParser.energy(json, range: range, timeZone: timeZone)
    }

    public func fetchSignalStrength(deviceId: Int) async throws -> Int? {
        let devices = try await refreshListing()
        return devices.first { $0["DeviceID"]?.int == deviceId }?["Device"]?["WifiSignalStrength"]?.int
    }

    public func resetSession() async {
        contextKey = nil
        listing = nil
    }

    // MARK: Internals

    private func refreshListing() async throws -> [JSONValue] {
        let json = try await authorizedJSON("GET", "User/ListDevices")
        let devices = MELCloudClassicParser.listedDevices(json)
        listing = (now(), devices)
        return devices
    }

    /// Sends an authenticated request. On HTTP 401 it first tries the ContextKey from the
    /// keychain (another process may have logged in already; logging in again would
    /// invalidate that key), then logs in once. A 401 after a fresh login is `.unauthorized`.
    private func authorizedJSON(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil
    ) async throws -> JSONValue {
        if contextKey == nil { contextKey = credentials.loadContextKey() }
        if contextKey == nil { try await login() }
        var triedStoredKey = false
        var loggedIn = false
        while true {
            let usedKey = contextKey
            let request = try makeRequest(method, path, query: query, body: body, authenticated: true)
            let (data, response) = try await transport.send(request)
            if response.statusCode == 401 {
                if !triedStoredKey {
                    triedStoredKey = true
                    if let stored = credentials.loadContextKey(), stored != usedKey {
                        contextKey = stored
                        continue
                    }
                }
                if !loggedIn {
                    loggedIn = true
                    try await login()
                    continue
                }
                throw HeatPumpError.unauthorized
            }
            try checkStatus(response)
            return try parse(data)
        }
    }

    private func checkStatus(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300: return
        case 429:
            throw HeatPumpError.rateLimited(
                until: MELCloudClassicParser.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now()))
        default:
            throw HeatPumpError.http(status: response.statusCode)
        }
    }

    private func parse(_ data: Data) throws -> JSONValue {
        if data.isEmpty { return .null }
        do {
            return try JSONValue.parse(data)
        } catch {
            throw HeatPumpError.decoding(error.localizedDescription)
        }
    }

    private func makeRequest(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue?, authenticated: Bool
    ) throws -> URLRequest {
        guard var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        else { throw HeatPumpError.network("Ugyldig adresse") }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw HeatPumpError.network("Ugyldig adresse") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("Varmepumpe/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        if authenticated, let contextKey {
            request.setValue(contextKey, forHTTPHeaderField: "X-MitsContextKey")
        }
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }
}
