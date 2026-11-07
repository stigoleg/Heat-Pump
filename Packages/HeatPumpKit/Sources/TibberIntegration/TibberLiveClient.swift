import Foundation
import HeatPumpKit

/// A text WebSocket connection (the seam that lets tests script Tibber's side).
public protocol WebSocketChannel: Sendable {
    func send(_ text: String) async throws
    /// The next text message. Throws `WebSocketClosed` when the server closed the connection.
    func receive() async throws -> String
    /// Closes the connection; a pending `receive` then throws.
    func close(code: Int) async
}

/// Opens WebSocket connections.
public protocol WebSocketConnecting: Sendable {
    func connect(url: URL, headers: [String: String], protocols: [String]) async throws -> any WebSocketChannel
}

/// The server closed the connection with `code` (4403: invalid token; 1001: going away).
public struct WebSocketClosed: Error, Sendable, Equatable {
    public var code: Int
    public init(code: Int) { self.code = code }
}

/// Tibber's live measurements over one socket (`graphql-transport-ws`) for every home asked for.
///
/// Tibber allows two open sockets, so the app keeps one: every stream for a home shares it, and
/// it is closed when the last stream ends. Per Tibber's guidance: the address comes from
/// `viewer.websocketSubscriptionUrl` (never hard-coded), `User-Agent` goes on that request and on
/// the upgrade, the token in `connection_init`; homes without a real-time reader
/// (`features.realTimeConsumptionEnabled`) are not subscribed (checked again before each
/// reconnect). A dropped connection or a silence longer than `silenceTimeout` reconnects after an
/// exponential backoff with jitter; close code 1001 after a random 1–60 s; close code 4403 (invalid
/// token) or a refused token stops every stream for good, so a rejected token is never retried
/// (until `reset()`, after new credentials are saved). Before each attempt the service's gate is
/// asked: while the integration is blocked nothing is sent, and a "credentials rejected" stop ends
/// every stream; a refused token or 429 met here is reported to it.
actor TibberLiveClient {
    /// What one connection attempt needs from Tibber's HTTP API: the socket address and the
    /// homes that have live data.
    typealias Prepare = @Sendable () async throws -> (url: URL, realTimeHomes: Set<String>)

    static let subprotocol = "graphql-transport-ws"
    /// Reconnect when nothing arrived for this long (Tibber: "no data for several minutes").
    static let silenceTimeout: TimeInterval = 180
    static let ackTimeout: TimeInterval = 15
    /// First backoff; doubles per failed attempt up to `maxBackoff`.
    static let baseBackoff: TimeInterval = 10
    static let maxBackoff: TimeInterval = 600

    private let connector: any WebSocketConnecting
    private let token: @Sendable () -> String?
    private let prepare: Prepare
    private let userAgent: String
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let random: @Sendable (ClosedRange<Double>) -> Double

    private var subscribers: [String: [UUID: AsyncStream<LivePowerEvent>.Continuation]] = [:]
    private var run: Task<Void, Never>?
    private var channel: (any WebSocketChannel)?
    /// Homes subscribed on the open channel.
    private var subscribed: Set<String> = []
    /// The open channel's `connection_ack` arrived.
    private var acked = false
    /// Set after a refused token: nothing is sent again until `reset()`.
    private var rejected = false
    /// The service's gate (the newest stream's; every meter of the account shares one store).
    private var gate = LivePowerGate.open

    init(
        connector: any WebSocketConnecting, token: @escaping @Sendable () -> String?, prepare: @escaping Prepare, userAgent: String,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds(max(0, $0))) },
        random: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) {
        self.connector = connector
        self.token = token
        self.prepare = prepare
        self.userAgent = userAgent
        self.now = now
        self.sleep = sleep
        self.random = random
    }

    // MARK: Streams

    /// Live events for `home` until the stream is cancelled.
    nonisolated func stream(home: String, gate: LivePowerGate) -> AsyncStream<LivePowerEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { _ in Task { await self.remove(id, home: home) } }
            Task { await self.add(continuation, id: id, home: home, gate: gate) }
        }
    }

    /// New credentials were saved: a refused token may work now.
    func reset() {
        rejected = false
    }

    private func add(_ continuation: AsyncStream<LivePowerEvent>.Continuation, id: UUID, home: String, gate: LivePowerGate) async {
        self.gate = gate
        if rejected {
            continuation.yield(.state(.stopped(.unauthorized)))
            continuation.finish()
            return
        }
        let isNew = subscribers[home] == nil
        subscribers[home, default: [:]][id] = continuation
        if run == nil {
            run = Task { await self.loop() }
        } else if isNew, acked, let channel {
            try? await subscribe(home, on: channel)
        }
    }

    private func remove(_ id: UUID, home: String) async {
        subscribers[home]?[id] = nil
        guard subscribers[home]?.isEmpty == true else { return }
        subscribers[home] = nil
        if subscribed.remove(home) != nil, let channel { try? await channel.send(Self.message(["id": .string(home), "type": .string("complete")])) }
        if subscribers.isEmpty {
            run?.cancel()
            run = nil
            await channel?.close(code: 1000)
            channel = nil
            acked = false
            subscribed = []
        }
    }

    private func broadcast(_ event: LivePowerEvent, home: String? = nil) {
        for (key, continuations) in subscribers where home == nil || key == home {
            for continuation in continuations.values { continuation.yield(event) }
        }
    }

    /// Ends `home`'s streams with `reason` (the others go on).
    private func stop(home: String, _ reason: LivePowerStop) {
        for continuation in (subscribers[home] ?? [:]).values {
            continuation.yield(.state(.stopped(reason)))
            continuation.finish()
        }
        subscribers[home] = nil
        subscribed.remove(home)
    }

    // MARK: Connection

    private enum Failure: Error {
        /// Nothing arrived within the timeout.
        case silence
        /// The server said something the protocol does not allow here.
        case unexpected
        /// The server ended the subscriptions; connect again.
        case completed
    }

    private func loop() async {
        var attempt = 0
        while !Task.isCancelled, !subscribers.isEmpty {
            let delay: TimeInterval
            let decision = gate.check()
            if decision == .rejected {
                stopAll(.unauthorized)
                break
            }
            if case .blocked(let until) = decision {
                delay = until.timeIntervalSince(now())
            } else {
                do {
                    try await connectOnce(onLive: { attempt = 0 })
                    if subscribers.isEmpty || Task.isCancelled { break }
                    delay = backoff(attempt)
                    attempt += 1
                } catch let closed as WebSocketClosed where closed.code == 4403 {
                    gate.report(.invalidCredentials(nil))
                    stopAll(.unauthorized)
                    break
                } catch let error as HeatPumpError where error.isCredentialProblem || error == .missingCredentials {
                    if error.isCredentialProblem { gate.report(error) }
                    stopAll(.unauthorized)
                    break
                } catch let closed as WebSocketClosed where closed.code == 1001 {
                    delay = random(1...60)
                } catch HeatPumpError.rateLimited(let until) {
                    gate.report(.rateLimited(until: until))
                    delay = max(backoff(attempt), until.timeIntervalSince(now()))
                    attempt += 1
                } catch {
                    if Task.isCancelled { break }
                    delay = backoff(attempt)
                    attempt += 1
                }
            }
            // A cancelled loop leaves the channel to `remove` (and to a loop started after it).
            if Task.isCancelled { break }
            await channel?.close(code: 1000)
            channel = nil
            subscribed = []
            acked = false
            if subscribers.isEmpty { break }
            broadcast(.state(.waiting(until: now().addingTimeInterval(delay))))
            do { try await sleep(delay) } catch { break }
        }
        // A cancelled loop was replaced (or stopped) by `remove`; only a loop that ended by
        // itself clears the slot.
        if !Task.isCancelled { run = nil }
    }

    /// Exponential backoff with ±20 % jitter.
    func backoff(_ attempt: Int) -> TimeInterval {
        min(Self.maxBackoff, Self.baseBackoff * pow(2, Double(min(attempt, 10)))) * random(0.8...1.2)
    }

    private func stopAll(_ reason: LivePowerStop) {
        rejected = reason == .unauthorized
        for home in Array(subscribers.keys) { stop(home: home, reason) }
    }

    /// One connection: address and homes, upgrade, `connection_init` → ack, a subscription per
    /// home, then messages until the connection ends (throws) or no stream is left (returns).
    private func connectOnce(onLive: () -> Void) async throws {
        guard let token = token(), !token.isEmpty else { throw HeatPumpError.missingCredentials }
        broadcast(.state(.connecting))
        let (url, realTime) = try await prepare()
        for home in Array(subscribers.keys) where !realTime.contains(home) { stop(home: home, .notAvailable) }
        guard !subscribers.isEmpty else { return }
        let channel = try await connector.connect(url: url, headers: ["User-Agent": userAgent], protocols: [Self.subprotocol])
        if Task.isCancelled {
            await channel.close(code: 1000)
            throw CancellationError()
        }
        self.channel = channel
        try await channel.send(Self.message(["type": .string("connection_init"), "payload": .object(["token": .string(token)])]))
        let ack = try JSONValue.parse(Data(try await receive(channel, timeout: Self.ackTimeout).utf8))
        guard ack["type"]?.string == "connection_ack" else { throw Failure.unexpected }
        acked = true
        for home in subscribers.keys.sorted() { try await subscribe(home, on: channel) }
        broadcast(.state(.live))
        while !subscribers.isEmpty {
            let text = try await receive(channel, timeout: Self.silenceTimeout)
            guard let message = try? JSONValue.parse(Data(text.utf8)) else { continue }
            let id = message["id"]?.string
            switch message["type"]?.string {
            case "ping":
                try await channel.send(Self.message(["type": .string("pong")]))
            case "next":
                guard let id else { continue }
                let payload = message["payload"]
                if let errors = payload?["errors"]?.array, !errors.isEmpty {
                    try handleErrors(errors, home: id)
                    continue
                }
                if let reading = Self.reading(payload, now: now()) {
                    onLive()
                    broadcast(.reading(reading), home: id)
                }
            case "error":
                guard let id else { continue }
                try handleErrors(message["payload"]?.array ?? [], home: id)
            case "complete":
                // Tibber ended a subscription (e.g. after an unknown home's error): ask again later.
                if let id, subscribers[id] != nil { throw Failure.completed }
            default:
                continue
            }
        }
    }

    private func handleErrors(_ errors: [JSONValue], home: String) throws {
        do {
            try TibberAPI.checkErrors(.object(["errors": .array(errors)]))
        } catch HeatPumpError.deviceNotFound {
            stop(home: home, .notFound)
        }
    }

    private func subscribe(_ home: String, on channel: any WebSocketChannel) async throws {
        guard subscribed.insert(home).inserted else { return }
        try await channel.send(
            Self.message([
                "id": .string(home), "type": .string("subscribe"), "payload": .object(["query": .string(Self.subscription(home: home))]),
            ]))
    }

    /// The next message, or `Failure.silence` (the channel is closed) after `timeout`.
    private func receive(_ channel: any WebSocketChannel, timeout: TimeInterval) async throws -> String {
        let sleep = sleep
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await channel.receive() }
            group.addTask {
                try await sleep(timeout)
                // Unblocks the receive (it may not react to cancellation).
                await channel.close(code: 4000)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let text = first else { throw Failure.silence }
            return text
        }
    }

    // MARK: Messages

    static func subscription(home: String) -> String {
        "subscription{liveMeasurement(homeId:\(TibberAPI.quoted(home))){timestamp power accumulatedConsumption accumulatedCost currency powerProduction}}"
    }

    static func message(_ object: [String: JSONValue]) -> String {
        String(decoding: (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data(), as: UTF8.self)
    }

    /// A reading from a `next` payload; nil without `power`. Missing optional fields stay nil, a
    /// missing timestamp is `now`.
    static func reading(_ payload: JSONValue?, now: Date) -> LivePowerReading? {
        guard let measurement = payload?["data"]?["liveMeasurement"], let power = measurement["power"]?.double else { return nil }
        return LivePowerReading(
            at: TibberAPI.date(measurement["timestamp"]?.string) ?? now, powerW: power,
            consumptionTodayKWh: measurement["accumulatedConsumption"]?.double, costToday: measurement["accumulatedCost"]?.double,
            currency: measurement["currency"]?.string, productionW: measurement["powerProduction"]?.double)
    }
}

/// `URLSessionWebSocketTask` behind `WebSocketChannel`.
public struct URLSessionWebSocketConnector: WebSocketConnecting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(url: URL, headers: [String: String], protocols: [String]) async throws -> any WebSocketChannel {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionWebSocketChannel(task: task)
    }
}

/// `URLSessionWebSocketTask` is thread-safe; it has no Sendable annotation.
final class URLSessionWebSocketChannel: WebSocketChannel, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ text: String) async throws {
        do { try await task.send(.string(text)) } catch { throw closedOr(error) }
    }

    func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data): return String(decoding: data, as: UTF8.self)
            @unknown default: return ""
            }
        } catch {
            throw closedOr(error)
        }
    }

    func close(code: Int) async {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
    }

    private func closedOr(_ error: any Error) -> any Error {
        task.closeCode == .invalid ? error : WebSocketClosed(code: task.closeCode.rawValue)
    }
}
