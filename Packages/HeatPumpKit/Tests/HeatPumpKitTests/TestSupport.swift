import Foundation
import Synchronization
@testable import HeatPumpKit
@testable import DemoIntegration
@testable import MELCloudIntegration

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> JSONValue {
        try JSONValue.parse(data(name))
    }
}

/// Controllable clock shared across actors.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_793_872_800)) {  // 2026-11-05T10:00:00Z
        current = Mutex(start)
    }

    var now: Date { current.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
    var provider: @Sendable () -> Date { { self.now } }
    /// Sleeper for `HeatPumpService` that advances this clock instead of waiting.
    var sleeper: @Sendable (TimeInterval) async -> Void { { self.advance($0) } }
}

func temporaryDatabasePath() -> String {
    FileManager.default.temporaryDirectory
        .appending(path: "heatpumpkit-tests-\(UUID().uuidString)")
        .appending(path: "test.sqlite").path
}

/// Wraps `MockBackend`, counts network-style calls and can inject errors.
actor CountingBackend: HeatPumpBackend {
    nonisolated let identifier = "counting"
    let inner: MockBackend
    private(set) var fetchStateCalls = 0
    private(set) var applyCalls = 0
    private(set) var reportCalls = 0
    private(set) var energyRanges: [DateInterval] = []
    var nextError: HeatPumpError?

    init(now: @escaping @Sendable () -> Date) {
        inner = MockBackend(timeZone: .gmt, now: now)
    }

    func failNext(with error: HeatPumpError?) { nextError = error }
    func appliedChanges() async -> [ChangeSet] { await inner.appliedChanges }

    private func maybeThrow() throws {
        if let error = nextError {
            nextError = nil
            throw error
        }
    }

    func login() async throws {}
    func listDevices() async throws -> [DeviceSummary] { try await inner.listDevices() }
    func fetchState(device: DeviceKey) async throws -> DeviceState {
        fetchStateCalls += 1
        try maybeThrow()
        return try await inner.fetchState(device: device)
    }
    func apply(_ changes: ChangeSet) async throws -> DeviceState? {
        applyCalls += 1
        try maybeThrow()
        return try await inner.apply(changes)
    }
    func fetchErrorLog(device: DeviceKey, range: DateInterval) async throws -> [ErrorLogEntry] {
        reportCalls += 1
        try maybeThrow()
        return try await inner.fetchErrorLog(device: device, range: range)
    }
    func fetchTemperatureLog(device: DeviceKey, range: DateInterval) async throws -> [TemperaturePoint] {
        reportCalls += 1
        return try await inner.fetchTemperatureLog(device: device, range: range)
    }
    func fetchEnergy(device: DeviceKey, range: DateInterval) async throws -> [EnergyDay] {
        reportCalls += 1
        energyRanges.append(range)
        return try await inner.fetchEnergy(device: device, range: range)
    }
    func fetchSignalStrength(device: DeviceKey) async throws -> Int? { -62 }
}

/// Canned HTTP responses keyed by path suffix; records requests.
final class StubTransport: HTTPTransport {
    struct Reply: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    private let state = Mutex<(replies: [String: [Reply]], requests: [URLRequest])>(([:], []))

    func enqueue(_ pathSuffix: String, status: Int = 200, body: Data, headers: [String: String] = [:]) {
        state.withLock { $0.replies[pathSuffix, default: []].append(Reply(status: status, body: body, headers: headers)) }
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let reply: Reply? = state.withLock { s in
            s.requests.append(request)
            guard let key = s.replies.keys.first(where: { path.hasSuffix($0) }), var queue = s.replies[key], !queue.isEmpty
            else { return nil }
            let first = queue.removeFirst()
            s.replies[key] = queue
            return first
        }
        guard let reply else { throw HeatPumpError.network("no stub for \(path)") }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (reply.body, response)
    }
}

/// The device `makeState` describes (device id 1 before device keys).
let testDevice = DeviceKey(integration: DemoIntegration.id, nativeId: "1")

func makeState(
    at date: Date, power: Bool = true, mode: OperationMode = .heat, set: Double = 21, room: Double = 20.5,
    outdoor: Double? = -5, hasError: Bool = false, errorCode: Int? = 8000, offline: Bool = false,
    lastCommunication: Date? = nil, wifi: Int? = -60, firmware: FirmwareInfo = FirmwareInfo()
) -> DeviceState {
    DeviceState(
        key: testDevice, name: "Test", power: power, mode: mode, setTemperature: set,
        roomTemperature: room, outdoorTemperature: outdoor, fanSpeed: 0, numberOfFanSpeeds: 5,
        hasError: hasError, errorCode: errorCode, offline: offline,
        lastCommunication: lastCommunication ?? date, wifiSignal: wifi, firmware: firmware, fetchedAt: date)
}

// MARK: Tests run as MELCloud
//
// The core takes the integration (or its service name) explicitly. These overloads keep the
// suites' calls as they were and pass the MELCloud integration, which names the service exactly
// as the texts did before the core became vendor-neutral. The demo integration names it the same.

let testIntegration: any Integration = MELCloudIntegration()

extension HeatPumpService {
    init(
        backend: any DeviceConnection & ThermostatDriver, store: HistoryStore, credentials: (any CredentialProviding)? = nil,
        policy: RateLimitPolicy = .standard, timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(max(0, seconds)))
        },
        priceProvider: @escaping @Sendable (PriceSettings) -> (any PriceProvider)? = { _ in nil },
        local: LocalAccess = .unavailable,
        weatherProvider: @escaping @Sendable (WeatherSettings) -> (any WeatherProviding)? = { _ in nil },
        houseProvider: @escaping @Sendable () -> (any HouseConsumptionProviding)? = { nil }
    ) {
        self.init(
            backend: backend, store: store, credentials: credentials, integration: testIntegration, policy: policy, timeZone: timeZone,
            now: now, sleep: sleep, priceProvider: priceProvider, local: local, weatherProvider: weatherProvider,
            houseProvider: houseProvider)
    }

    static var timerChangedMessage: String { timerChangedMessage(serviceName: testIntegration.displayName) }

    func signIn(_ new: MELCloudCredentials) async throws -> StateResult { try await signIn(new.values) }
    func saveCredentials(_ new: MELCloudCredentials) throws { try saveCredentials(new.values) }
}

extension InMemoryCredentialStore {
    /// A store holding a MELCloud account (and its session key).
    convenience init(credentials: MELCloudCredentials?, contextKey: String? = nil) {
        self.init(
            values: credentials.map { [MELCloudIntegration.id: $0.values] } ?? [:],
            sessionKeys: contextKey.map { [MELCloudIntegration.id: $0] } ?? [:])
    }
}

extension DeviceState {
    var hasActiveError: Bool { hasActiveError(noErrorCodes: testIntegration.errorCodes.noErrorCodes) }
}

// MARK: Store calls as before device keys
//
// Blocks and credential stops are the test integration's (the service under test runs as it);
// rows the tests write directly belong to no device; reads see every device.

extension HistoryStore {
    /// The newest snapshot of any device.
    func latestSnapshot() throws -> Snapshot? {
        try devices().compactMap { try latestSnapshot(device: $0.key) }.max { $0.state.fetchedAt < $1.state.fetchedAt }
    }

    func changes(limit: Int = 50, source: ChangeSource? = nil) throws -> [ChangeRecord] {
        try changes(device: nil, limit: limit, source: source)
    }

    @discardableResult
    func logChange(_ record: ChangeRecord) throws -> Int64 { try logChange(record, device: nil) }

    /// Budget of the simulated unit (the service's device in the suites).
    func reserveChange(_ records: [ChangeRecord]) throws -> ChangeReservation {
        try reserveChange(records, device: MockBackend.device)
    }

    func reserveFetch(key: String, minInterval: TimeInterval, now: Date) throws -> FetchDecision {
        try reserveFetch(key: key, minInterval: minInterval, now: now, blockingIntegration: testIntegration.id)
    }

    func recordBlock(until: Date, reason: BlockReason) throws {
        try recordBlock(until: until, reason: reason, integration: testIntegration.id)
    }

    func blockStatus(now: Date) throws -> BlockStatus? { try blockStatus(now: now, integration: testIntegration.id) }

    func blockedUntil(now: Date) throws -> Date? { try blockedUntil(now: now, integration: testIntegration.id) }

    func insertLocalSample(_ sample: LocalSample) throws { try insertLocalSample(sample, device: nil) }

    func insertLocalSamples(_ samples: [LocalSample]) throws { try insertLocalSamples(samples, device: nil) }
}

extension HealthInput {
    init(
        latestState: DeviceState?, snapshots: [DeviceState] = [], temperaturePoints: [TemperaturePoint] = [],
        errorEvents: [ErrorLogEntry] = [], energyDays: [EnergyDay] = [], maintenance: [MaintenanceRecord] = [],
        now: Date, timeZone: TimeZone = .current, blockedUntil: Date? = nil, local: LocalHealthInput? = nil
    ) {
        self.init(
            latestState: latestState, snapshots: snapshots, temperaturePoints: temperaturePoints, errorEvents: errorEvents,
            energyDays: energyDays, maintenance: maintenance, now: now, timeZone: timeZone, blockedUntil: blockedUntil, local: local,
            integration: testIntegration)
    }
}

extension LocalHealth {
    static func evaluate(_ input: LocalHealthInput, cloudErrorShown: Bool, now: Date, timeZone: TimeZone) -> [HealthFinding] {
        evaluate(input, cloudErrorShown: cloudErrorShown, now: now, timeZone: timeZone, integration: testIntegration)
    }
}

extension NotificationPlanner {
    static func plan(
        state: DeviceState?, errorEvents: [ErrorLogEntry], maintenance: [MaintenanceStatus],
        memory: NotificationMemory, now: Date
    ) -> (notifications: [PlannedNotification], memory: NotificationMemory) {
        plan(
            state: state, errorEvents: errorEvents, maintenance: maintenance, memory: memory, now: now,
            serviceName: testIntegration.displayName, noErrorCodes: testIntegration.errorCodes.noErrorCodes)
    }
}

extension BlockReason {
    func message(until: Date) -> String { message(until: until, serviceName: testIntegration.displayName) }
}

extension FirmwareUpdatePhase {
    var displayText: String { displayText(serviceName: testIntegration.displayName) }
}

extension FirmwareUpdateStatus {
    var displayText: String { displayText(serviceName: testIntegration.displayName) }
}

extension WeatherLocation {
    var displayName: String { displayName(serviceName: testIntegration.displayName) }
}

extension ErrorLogEntry {
    init(device: DeviceKey, start: Date, end: Date? = nil, message: String, code: String? = nil) {
        self.init(device: device, start: start, end: end, message: message, code: code, source: testIntegration.sourceTag)
    }
}

extension Knowledge {
    static var names: [String] { testIntegration.knowledge.names }

    static func all(language: L10n.Language = L10n.language) -> [KnowledgeDocument] {
        Knowledge(integration: testIntegration).all(language: language)
    }

    static func document(named name: String, language: L10n.Language = L10n.language) -> KnowledgeDocument? {
        Knowledge(integration: testIntegration).document(named: name, language: language)
    }
}
