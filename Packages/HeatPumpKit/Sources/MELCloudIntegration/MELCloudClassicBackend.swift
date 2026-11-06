import Foundation
import HeatPumpKit

/// MELCloud Classic (`app.melcloud.com`) backend.
///
/// One `fetchState` costs one `Device/Get` call, plus a `User/ListDevices` call when the
/// cached listing (limits, Wi-Fi signal, firmware, energy counters) is older than
/// `listingMaxAge`. Rate limiting across processes is the service's job.
public actor MELCloudClassicBackend: HeatPumpBackend, AwayModesDriver, WeeklyScheduleDriver, FirmwareDriver,
    DeviceLocationReporting, HardwareAddressReporting
{
    public nonisolated let identifier = MELCloudIntegration.id

    public static let baseURL = URL(string: "https://app.melcloud.com/Mitsubishi.Wifi.Client")!  // constant literal
    static let appVersion = "1.19.1.1"
    /// MELCloud language code for Norwegian; affects the language of `ErrorMessage` texts.
    static let languageNorwegian = 13

    private let transport: any HTTPTransport
    private let credentials: any CredentialProviding
    private let timeZone: TimeZone
    private let listingMaxAge: TimeInterval
    private let now: @Sendable () -> Date
    private let rawCache: (any RawDeviceCache)?

    private var contextKey: String?
    private var listing: (fetchedAt: Date, devices: [JSONValue])?
    /// Last full device object per device (base of every SetAta body).
    private var raw: [DeviceKey: RawDevice] = [:]

    public init(
        credentials: any CredentialProviding,
        transport: any HTTPTransport = URLSessionTransport(),
        timeZone: TimeZone = .current,
        listingMaxAge: TimeInterval = 30 * 60,
        rawCache: (any RawDeviceCache)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rawCache = rawCache
        self.credentials = credentials
        self.transport = transport
        self.timeZone = timeZone
        self.listingMaxAge = listingMaxAge
        self.now = now
        // The ContextKey is read from the keychain lazily, right before the first request.
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

    /// The listing `fetchState` refreshes every `listingMaxAge` anyway (device discovery).
    public func recentListing() async -> [DeviceSummary]? {
        guard let listing, now().timeIntervalSince(listing.fetchedAt) < 3600 else { return nil }
        return listing.devices.compactMap(MELCloudClassicParser.summary)
    }

    public func fetchState(device: DeviceKey) async throws -> DeviceState {
        let deviceId = try Self.deviceId(device)
        var devices = listing.flatMap { now().timeIntervalSince($0.fetchedAt) < listingMaxAge ? $0.devices : nil }
        if devices == nil { devices = try await refreshListing() }
        let listingFetchedAt = listing?.fetchedAt
        guard let wrapper = devices?.first(where: { $0["DeviceID"]?.int == deviceId }) else {
            throw HeatPumpError.deviceNotFound
        }
        let buildingId = wrapper["BuildingID"]?.int ?? 0
        let get = try await authorizedJSON(
            "GET", "Device/Get",
            query: [URLQueryItem(name: "id", value: String(deviceId)), URLQueryItem(name: "buildingID", value: String(buildingId))])
        let t = now()
        let state = try MELCloudClassicParser.state(listing: wrapper, get: get, fetchedAt: t, listingFetchedAt: listingFetchedAt)
        if get.object != nil {
            remember(RawDevice(device: device, fetchedAt: t, json: get, listing: wrapper))
        }
        return state
    }

    public nonisolated var requiresFreshStateForWrites: Bool { true }

    /// MELCloud refuses a write without a valid mode.
    public nonisolated var unknownModeProblem: String? { MELCloudClassicParser.invalidModeMessage }

    public nonisolated var maxTemperatureLogDays: Int { MELCloudClassicParser.maxTemperatureRangeDays }

    public nonisolated var maxEnergyReportDays: Int { MELCloudClassicParser.maxEnergyRangeDays }

    /// The Wi-Fi adapter adds local readings and live power.
    public nonisolated var capabilities: Set<Capability> {
        Capability.derived(from: self).union([.localTelemetry, .livePower])
    }

    public func writeBaseFetchedAt(device: DeviceKey) async -> Date? {
        currentRaw(device)?.fetchedAt
    }

    /// Dry run of `apply`: would the body be refused locally (no object, missing fields,
    /// unknown mode)?
    public func localWriteProblem(_ changes: ChangeSet, requireBase: Bool) async -> String? {
        guard let base = currentRaw(changes.device) else {
            return requireBase ? MELCloudClassicParser.missingObjectMessage : nil
        }
        do {
            _ = try MELCloudClassicParser.setAtaPayload(changes, raw: base.json)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Sends the full device object with the changes applied (see
    /// `MELCloudClassicParser.setAtaPayload`) and returns the state from the response. The
    /// response, laid over what was sent, becomes the new device object.
    public func apply(_ changes: ChangeSet) async throws -> DeviceState? {
        guard let base = currentRaw(changes.device) else {
            throw HeatPumpError.validation(MELCloudClassicParser.missingObjectMessage)
        }
        let deviceId = try Self.deviceId(changes.device)
        let body = try MELCloudClassicParser.setAtaPayload(changes, raw: base.json)
        let response = try await authorizedJSON("POST", "Device/SetAta", body: .object(body))
        if let attributeErrors = response["AttributeErrors"]?.object, !attributeErrors.isEmpty {
            throw HeatPumpError.server(attributeErrors.keys.sorted().joined(separator: ", "))
        }
        let t = now()
        let isFullObject = response["DeviceID"] != nil
        let merged = MELCloudClassicParser.merged(raw: .object(body), response: response)
        let wrapper = base.listing ?? listing?.devices.first { $0["DeviceID"]?.int == deviceId }
        remember(RawDevice(device: changes.device, fetchedAt: isFullObject ? t : base.fetchedAt, json: merged, listing: wrapper))
        // Counter: listing time only when this process holds that listing; else dropped.
        let listingAt = listing.flatMap { l in
            l.devices.contains { $0["DeviceID"]?.int == deviceId } ? l.fetchedAt : nil
        }
        return try? MELCloudClassicParser.state(listing: wrapper, get: merged, fetchedAt: t, listingFetchedAt: listingAt)
    }

    public func fetchErrorLog(device: DeviceKey, range: DateInterval) async throws -> [ErrorLogEntry] {
        let body: JSONValue = .object([
            "DeviceIDs": .array([.number(Double(try Self.deviceId(device)))]),
            "FromDate": .string(WireDate.day(range.start, timeZone: timeZone)),
            "ToDate": .string(WireDate.day(range.end, timeZone: timeZone)),
        ])
        let json = try await authorizedJSON("POST", "Report/GetUnitErrorLog2", body: body)
        return try MELCloudClassicParser.errorLog(json, device: device, timeZone: timeZone)
    }

    public func fetchTemperatureLog(device: DeviceKey, range: DateInterval) async throws -> [TemperaturePoint] {
        let deviceId = try Self.deviceId(device)
        let location = listing?.devices.first { $0["DeviceID"]?.int == deviceId }?["Location"]?.int
            ?? currentRaw(device)?.listing?["Location"]?.int
        let body = MELCloudClassicParser.temperatureLogBody(
            deviceId: deviceId, range: range, location: location, timeZone: timeZone)
        let json = try await authorizedJSON("POST", "Report/GetTemperatureLog2", body: body)
        Self.diagnose("GetTemperatureLog2 response: \(MELCloudClassicParser.reportShape(json))")
        let points = try MELCloudClassicParser.temperatureLog(json, range: range, timeZone: timeZone)
        Self.diagnose("GetTemperatureLog2 parsed \(points.count) points")
        return points
    }

    public func fetchEnergy(device: DeviceKey, range: DateInterval) async throws -> [EnergyDay] {
        let calendar = WireDate.calendar(timeZone)
        let body: JSONValue = .object([
            "DeviceID": .number(Double(try Self.deviceId(device))),
            "FromDate": .string(WireDate.localTimestamp(calendar.startOfDay(for: range.start), timeZone: timeZone)),
            "ToDate": .string(WireDate.localTimestamp(calendar.startOfDay(for: range.end), timeZone: timeZone)),
            "UseCurrency": .bool(false),
        ])
        let json = try await authorizedJSON("POST", "EnergyCost/Report", body: body)
        return MELCloudClassicParser.energy(json, range: range, timeZone: timeZone)
    }

    public func fetchSignalStrength(device: DeviceKey) async throws -> Int? {
        let deviceId = try Self.deviceId(device)
        let devices = try await refreshListing()
        return devices.first { $0["DeviceID"]?.int == deviceId }?["Device"]?["WifiSignalStrength"]?.int
    }

    public func resetSession() async {
        contextKey = nil
        listing = nil
    }

    // MARK: Frost protection, holiday mode, weekly timer (unverified endpoints; shapes logged)

    private func settingsQuery(_ device: DeviceKey) throws -> [URLQueryItem] {
        [URLQueryItem(name: "id", value: String(try Self.deviceId(device))), URLQueryItem(name: "tableName", value: "DeviceLocation")]
    }

    public func fetchAwaySettings(device: DeviceKey) async throws -> AwaySettings {
        let frostJSON = try await authorizedJSON("GET", "FrostProtection/GetSettings", query: try settingsQuery(device), relogin: false)
        Self.diagnose("FrostProtection/GetSettings response: \(MELCloudClassicParser.redactedShape(frostJSON))")
        let holidayJSON = try await authorizedJSON("GET", "HolidayMode/GetSettings", query: try settingsQuery(device), relogin: false)
        Self.diagnose("HolidayMode/GetSettings response: \(MELCloudClassicParser.redactedShape(holidayJSON))")
        return AwaySettings(
            frost: try MELCloudClassicParser.frostProtection(frostJSON), holiday: try MELCloudClassicParser.holidayMode(holidayJSON),
            fetchedAt: now(), source: MELCloudIntegration.sourceTag)
    }

    public nonisolated func awaySettings(fromStoredListing listing: JSONValue?) -> AwaySettings? {
        MELCloudClassicParser.awayFromListing(listing)
    }

    public nonisolated func location(fromStoredListing listing: JSONValue?) -> (latitude: Double, longitude: Double)? {
        MELCloudClassicParser.buildingLocation(listing)
    }

    public nonisolated func hardwareAddress(fromStoredListing listing: JSONValue?) -> String? {
        listing?["Device"]?["MacAddress"]?.string ?? listing?["MacAddress"]?.string
    }

    public nonisolated var weeklyTimerFormat: any WeeklyTimerFormat { MELCloudTimerFormat() }

    public func applyAway(_ change: AwayChange, device: DeviceKey) async throws {
        let deviceId = try Self.deviceId(device)
        let (path, body): (String, JSONValue) =
            switch change {
            case .frostProtection(let fp): ("FrostProtection/Update", MELCloudClassicParser.frostProtectionBody(fp, deviceId: deviceId))
            case .holidayMode(let hm): ("HolidayMode/Update", MELCloudClassicParser.holidayModeBody(hm, deviceId: deviceId))
            }
        let response = try await authorizedJSON("POST", path, body: body, relogin: false)
        Self.diagnose("\(path) response: \(MELCloudClassicParser.redactedShape(response))")
        try MELCloudClassicParser.checkMutation(response)
    }

    public func fetchWeeklyTimer(device: DeviceKey) async throws -> WeeklyTimer {
        let json = try await authorizedJSON(
            "GET", "Timer/Get2", query: [URLQueryItem(name: "deviceId", value: String(try Self.deviceId(device)))], relogin: false)
        Self.diagnose("Timer/Get2 response: \(MELCloudClassicParser.redactedShape(json))")
        try MELCloudClassicParser.throwIfAttributeErrors(json)
        var timer = MELCloudClassicParser.weeklyTimer(json)
        timer.fetchedAt = now()
        return timer
    }

    public func saveWeeklyTimer(_ timer: WeeklyTimer, device: DeviceKey) async throws {
        let body = MELCloudClassicParser.timerSetBody(timer: timer, deviceId: try Self.deviceId(device))
        let response = try await authorizedJSON("POST", "Timer/SetAta2", body: body, relogin: false)
        Self.diagnose("Timer/SetAta2 response: \(MELCloudClassicParser.redactedShape(response))")
        try MELCloudClassicParser.throwIfAttributeErrors(response)
        if let message = MELCloudClassicParser.timerSaveError(response) { throw HeatPumpError.server(message) }
        try MELCloudClassicParser.checkMutation(response)
    }

    // MARK: Firmware updates (unverified endpoints; shapes logged)

    public func firmwareUpdates(device: DeviceKey) async throws -> [FirmwareUpdateStatus] {
        let deviceId = try Self.deviceId(device)
        let json = try await authorizedJSON(
            "POST", "FirmwareUpdate/List2", body: MELCloudClassicParser.firmwareListBody(deviceId: deviceId), relogin: false)
        Self.diagnose("FirmwareUpdate/List2 response: \(MELCloudClassicParser.redactedShape(json))")
        try MELCloudClassicParser.throwIfAttributeErrors(json)
        return MELCloudClassicParser.firmwareUpdates(json, timeZone: timeZone).filter {
            $0.device == nil || $0.device?.melcloudDeviceId == deviceId
        }
    }

    public func approveFirmwareUpdate(id: Int, device: DeviceKey) async throws {
        try await firmwareAction("FirmwareUpdate/Approve2", id: id, deviceId: try Self.deviceId(device))
    }

    public func cancelFirmwareUpdate(id: Int, device: DeviceKey) async throws {
        try await firmwareAction("FirmwareUpdate/Cancel2", id: id, deviceId: try Self.deviceId(device))
    }

    private func firmwareAction(_ path: String, id: Int, deviceId: Int) async throws {
        let response = try await authorizedJSON(
            "POST", path, body: MELCloudClassicParser.firmwareActionBody(id: id, deviceId: deviceId), relogin: false)
        Self.diagnose("\(path) response: \(MELCloudClassicParser.redactedShape(response))")
        try MELCloudClassicParser.checkMutation(response)
    }

    // MARK: Internals

    /// MELCloud's `DeviceID` inside a key (keys from this integration have a numeric native id).
    static func deviceId(_ device: DeviceKey) throws -> Int {
        guard let id = device.melcloudDeviceId else { throw HeatPumpError.deviceNotFound }
        return id
    }

    /// Newest device object from memory or the shared cache (another process may be newer).
    private func currentRaw(_ device: DeviceKey) -> RawDevice? {
        let cached = (try? rawCache?.rawDevice(device)) ?? nil
        let memory = raw[device]
        let newest = [memory, cached].compactMap { $0 }.max { $0.fetchedAt < $1.fetchedAt }
        if let newest { raw[device] = newest }
        return newest
    }

    private func remember(_ device: RawDevice) {
        raw[device.device] = device
        try? rawCache?.saveRawDevice(device)
    }

    /// Diagnostics on stderr (shapes and counts only, no personal data).
    static func diagnose(_ message: String) {
        FileHandle.standardError.write(Data("[melcloud] \(message)\n".utf8))
    }

    private func refreshListing() async throws -> [JSONValue] {
        let json = try await authorizedJSON("GET", "User/ListDevices")
        let devices = MELCloudClassicParser.listedDevices(json)
        listing = (now(), devices)
        return devices
    }

    /// Sends an authenticated request. On HTTP 401 it first tries the ContextKey from the
    /// keychain (another process may have logged in already; logging in again would
    /// invalidate that key), then logs in once. A 401 after a fresh login is `.unauthorized`.
    /// With `relogin` false (optional, unverified endpoints) it never logs in: a 401/403 that the
    /// stored key does not fix is `.endpointRefused`, so a refusing endpoint cannot cause logins.
    private func authorizedJSON(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil, relogin: Bool = true
    ) async throws -> JSONValue {
        if contextKey == nil { contextKey = credentials.loadContextKey() }
        if contextKey == nil {
            guard relogin else { throw HeatPumpError.validation(L10n.tr("No active MELCloud session yet. Trying again later.")) }
            try await login()
        }
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
                guard relogin else { throw HeatPumpError.endpointRefused(status: 401) }
                if !loggedIn {
                    loggedIn = true
                    try await login()
                    continue
                }
                throw HeatPumpError.unauthorized
            }
            if !relogin, response.statusCode == 403 { throw HeatPumpError.endpointRefused(status: 403) }
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
        else { throw HeatPumpError.network(L10n.tr("Invalid address")) }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw HeatPumpError.network(L10n.tr("Invalid address")) }
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
