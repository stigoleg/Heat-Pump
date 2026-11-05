import Foundation
import Synchronization
@testable import HeatPumpKit

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
    func fetchState(deviceId: Int) async throws -> DeviceState {
        fetchStateCalls += 1
        try maybeThrow()
        return try await inner.fetchState(deviceId: deviceId)
    }
    func apply(_ changes: ChangeSet) async throws -> DeviceState? {
        applyCalls += 1
        try maybeThrow()
        return try await inner.apply(changes)
    }
    func fetchErrorLog(deviceId: Int, range: DateInterval) async throws -> [ErrorLogEntry] {
        reportCalls += 1
        try maybeThrow()
        return try await inner.fetchErrorLog(deviceId: deviceId, range: range)
    }
    func fetchTemperatureLog(deviceId: Int, range: DateInterval) async throws -> [TemperaturePoint] {
        reportCalls += 1
        return try await inner.fetchTemperatureLog(deviceId: deviceId, range: range)
    }
    func fetchEnergy(deviceId: Int, range: DateInterval) async throws -> [EnergyDay] {
        reportCalls += 1
        energyRanges.append(range)
        return try await inner.fetchEnergy(deviceId: deviceId, range: range)
    }
    func fetchSignalStrength(deviceId: Int) async throws -> Int? { -62 }
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

func makeState(
    at date: Date, power: Bool = true, mode: OperationMode = .heat, set: Double = 21, room: Double = 20.5,
    outdoor: Double? = -5, hasError: Bool = false, errorCode: Int? = 8000, offline: Bool = false,
    lastCommunication: Date? = nil, wifi: Int? = -60, firmware: FirmwareInfo = FirmwareInfo()
) -> DeviceState {
    DeviceState(
        deviceId: 1, buildingId: 2, name: "Test", power: power, mode: mode, setTemperature: set,
        roomTemperature: room, outdoorTemperature: outdoor, fanSpeed: 0, numberOfFanSpeeds: 5,
        hasError: hasError, errorCode: errorCode, offline: offline,
        lastCommunication: lastCommunication ?? date, wifiSignal: wifi, firmware: firmware, fetchedAt: date)
}
