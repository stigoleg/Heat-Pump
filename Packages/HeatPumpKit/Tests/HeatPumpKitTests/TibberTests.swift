import Foundation
import Synchronization
import Testing
@testable import HeatPumpKit
@testable import TibberIntegration

@Suite("Tibber: homes, hourly use and errors")
struct TibberAPITests {
    let clock = TestClock()

    func connection(_ transport: StubTransport, token: String? = "TOKEN") -> TibberConnection {
        TibberConnection(
            token: { token }, transport: transport, sockets: FakeSockets(), userAgent: "Varmepumpe/9.9 (macOS)", now: clock.provider)
    }

    @Test func homesBecomeMetersWithAndWithoutLivePower() async throws {
        let transport = StubTransport()
        transport.enqueue("gql", body: try Fixture.data("tibber_homes"))
        let tibber = connection(transport)
        let listed = try await tibber.listDevices()
        #expect(listed.map(\.key.rawValue) == ["tibber:96a14971-525a-4420-aae9-e5aedaa129ff", "tibber:68e6938b-91a6-4199-a0d4-f24c22be87bb"])
        #expect(listed.map(\.name) == ["Hjemme", "Storgata 1"])  // nickname, else the address
        #expect(listed.allSatisfy { $0.kind == .energyMeter })
        #expect(tibber.capabilities(of: listed[0]) == [.energyLog, .livePower])
        #expect(tibber.capabilities(of: listed[1]) == [.energyLog])
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Varmepumpe/9.9 (macOS)")
    }

    @Test func hourlyUseOfOneHomeSkipsTheUnfinishedHour() async throws {
        let transport = StubTransport()
        transport.enqueue("gql", body: try Fixture.data("tibber_home_consumption"))
        let home = DeviceKey(integration: TibberIntegration.id, nativeId: "96a14971-525a-4420-aae9-e5aedaa129ff")
        let hours = try await connection(transport).fetchHours(device: home, lastHours: 5000)
        #expect(hours.count == 2)
        #expect(hours[0].hour == Date(timeIntervalSince1970: 1_793_862_000))  // 2026-11-05T07:00Z
        #expect(hours[0].kWh == 2.0)
        #expect(hours[0].costNok == 2.4)
        #expect(hours[0].unitPriceOre == 120)
        let body = try JSONValue.parse(try #require(transport.requests.first?.httpBody))
        let query = try #require(body["query"]?.string)
        #expect(query.contains(#"home(id: "96a14971-525a-4420-aae9-e5aedaa129ff")"#))
        #expect(query.contains("last: 744"))  // Tibber's cap
    }

    @Test func unauthenticatedIsHTTP200WithAnErrorCode() async throws {
        let transport = StubTransport()
        transport.enqueue("gql", body: try Fixture.data("tibber_unauthenticated"))
        await #expect(throws: HeatPumpError.invalidCredentials(nil)) { try await connection(transport).listDevices() }
        // The token-only house source maps it to the price token's error.
        #expect(throws: PriceError.unauthorized) { try TibberConsumptionProvider.parse(try Fixture.data("tibber_unauthenticated")) }
    }

    @Test func unknownHomeIsDeviceNotFound() async throws {
        let transport = StubTransport()
        transport.enqueue("gql", body: try Fixture.data("tibber_home_not_found"))
        await #expect(throws: HeatPumpError.deviceNotFound) {
            try await connection(transport).fetchHours(device: DeviceKey(integration: "tibber", nativeId: "gone"), lastHours: 3)
        }
    }

    @Test func tooManyRequestsBlocksForAWhile() async throws {
        let transport = StubTransport()
        transport.enqueue("gql", status: 429, body: Data())
        await #expect(throws: HeatPumpError.rateLimited(until: clock.now.addingTimeInterval(TibberAPI.rateLimitPause))) {
            try await connection(transport).listDevices()
        }
    }

    @Test func noTokenSendsNothing() async throws {
        let transport = StubTransport()
        await #expect(throws: HeatPumpError.missingCredentials) { try await connection(transport, token: nil).listDevices() }
        #expect(transport.requests.isEmpty)
    }

    @Test func theIntegrationSharesThePriceToken() {
        let mapping = TibberIntegration().credentialMapping
        #expect(mapping.items.map(\.account) == ["tibber-token"])
        #expect(mapping.isShared)
        #expect(TibberIntegration().credentialFields.first?.helpURL == TibberIntegration.tokenURL)
        let store = InMemoryCredentialStore()
        try? store.saveTibberToken("price-token")
        #expect((try? store.loadValues(for: mapping))?["token"] == "price-token")
        #expect(store.hasValues(for: mapping))
    }
}

// MARK: Live

/// One scripted connection: messages the server sends, what the client sent, and how it ends.
final class FakeChannel: WebSocketChannel {
    private struct State {
        var incoming: [Result<String, WebSocketClosed>] = []
        var sent: [String] = []
        var closed: Int?
        var waiters: [CheckedContinuation<Result<String, WebSocketClosed>, Never>] = []
    }

    private let state = Mutex(State())

    init(_ script: [Result<String, WebSocketClosed>] = []) {
        state.withLock { $0.incoming = script }
    }

    var sent: [String] { state.withLock { $0.sent } }
    var closedWith: Int? { state.withLock { $0.closed } }

    /// Messages the server sends later.
    func push(_ item: Result<String, WebSocketClosed>) {
        let waiter: CheckedContinuation<Result<String, WebSocketClosed>, Never>? = state.withLock {
            if $0.waiters.isEmpty {
                $0.incoming.append(item)
                return nil
            }
            return $0.waiters.removeFirst()
        }
        waiter?.resume(returning: item)
    }

    func send(_ text: String) async throws { state.withLock { $0.sent.append(text) } }

    func receive() async throws -> String {
        let result: Result<String, WebSocketClosed> = await withCheckedContinuation { continuation in
            let ready: Result<String, WebSocketClosed>? = state.withLock {
                if let closed = $0.closed { return .failure(WebSocketClosed(code: closed)) }
                if !$0.incoming.isEmpty { return $0.incoming.removeFirst() }
                $0.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        return try result.get()
    }

    func close(code: Int) async {
        let waiters = state.withLock {
            if $0.closed == nil { $0.closed = code }
            defer { $0.waiters = [] }
            return $0.waiters
        }
        for waiter in waiters { waiter.resume(returning: .failure(WebSocketClosed(code: code))) }
    }
}

/// Hands out scripted channels in order and records the upgrade requests.
final class FakeSockets: WebSocketConnecting {
    private let state = Mutex<(channels: [FakeChannel], requests: [(URL, [String: String], [String])])>(([], []))

    init(_ channels: [FakeChannel] = []) {
        state.withLock { $0.channels = channels }
    }

    var connects: Int { state.withLock { $0.requests.count } }
    var requests: [(URL, [String: String], [String])] { state.withLock { $0.requests } }

    func connect(url: URL, headers: [String: String], protocols: [String]) async throws -> any WebSocketChannel {
        let channel: FakeChannel? = state.withLock {
            $0.requests.append((url, headers, protocols))
            return $0.channels.isEmpty ? nil : $0.channels.removeFirst()
        }
        guard let channel else { throw HeatPumpError.network("no more scripted sockets") }
        return channel
    }
}

/// Sleeps: the ack and silence timeouts wait briefly in real time (a scripted message wins);
/// every other wait (backoff) is recorded and returns at once.
final class RecordingSleeper: Sendable {
    let waits = Mutex<[TimeInterval]>([])

    var sleep: @Sendable (TimeInterval) async throws -> Void {
        { seconds in
            if seconds == TibberLiveClient.ackTimeout || seconds == TibberLiveClient.silenceTimeout {
                try await Task.sleep(for: .milliseconds(150))
            } else {
                self.waits.withLock { $0.append(seconds) }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }
}

@Suite("Tibber: live power over the socket")
struct TibberLiveTests {
    let home = "96a14971-525a-4420-aae9-e5aedaa129ff"
    let url = URL(string: "wss://websocket-api.tibber.com/v1-beta/gql/subscriptions")!
    let sleeper = RecordingSleeper()

    /// `prepare` replaces the homes request (`prepares` counts the calls).
    func client(
        _ sockets: FakeSockets, realTime: Set<String>? = nil, prepares: Counter? = nil,
        prepare: (@Sendable () async throws -> Void)? = nil
    ) -> TibberLiveClient {
        let url = url
        let homes = realTime ?? [home]
        return TibberLiveClient(
            connector: sockets, token: { "TOKEN" },
            prepare: {
                prepares?.increment()
                try await prepare?()
                return (url, homes)
            }, userAgent: "Varmepumpe/9.9 (macOS)",
            now: { Date(timeIntervalSince1970: 1_793_872_800) }, sleep: sleeper.sleep,
            random: { ($0.lowerBound + $0.upperBound) / 2 })
    }

    /// A gate that answers `decisions` in turn (then allows) and records what it is told.
    final class ScriptedGate: Sendable {
        let decisions: Mutex<[LivePowerGate.Decision]>
        let reported = Mutex<[HeatPumpError]>([])

        init(_ decisions: [LivePowerGate.Decision] = []) { self.decisions = Mutex(decisions) }

        var gate: LivePowerGate {
            LivePowerGate(
                check: { self.decisions.withLock { $0.isEmpty ? .allowed : $0.removeFirst() } },
                report: { error in self.reported.withLock { $0.append(error) } })
        }
    }

    static let ack = #"{"type":"connection_ack"}"#
    func next(power: Double) -> String {
        #"{"id":"\#(home)","type":"next","payload":{"data":{"liveMeasurement":{"timestamp":"2026-11-05T11:00:02.000+01:00","power":\#(power),"accumulatedConsumption":12.5,"accumulatedCost":null,"currency":null}}}}"#
    }

    /// The events until `count` readings or a stop arrived.
    func collect(_ stream: AsyncStream<LivePowerEvent>, readings count: Int) async -> [LivePowerEvent] {
        var events: [LivePowerEvent] = []
        for await event in stream {
            events.append(event)
            if events.filter({ if case .reading = $0 { true } else { false } }).count >= count { break }
            if case .state(.stopped) = event { break }
        }
        return events
    }

    @Test func handshakeSubscribeAndReadings() async throws {
        let channel = FakeChannel([.success(Self.ack), .success(#"{"type":"ping"}"#), .success(next(power: 1830)), .success(next(power: 1750))])
        let sockets = FakeSockets([channel])
        let events = await collect(client(sockets).stream(home: home, gate: .open), readings: 2)
        let readings = events.compactMap { if case .reading(let r) = $0 { r } else { nil } }
        #expect(readings.map(\.powerW) == [1830, 1750])
        #expect(readings[0].consumptionTodayKWh == 12.5)
        #expect(readings[0].costToday == nil)  // null without a Tibber power deal
        #expect(readings[0].at == Date(timeIntervalSince1970: 1_793_872_802))
        #expect(events.contains(.state(.live)))
        let (requestedURL, headers, protocols) = try #require(sockets.requests.first)
        #expect(requestedURL == url)
        #expect(headers["User-Agent"] == "Varmepumpe/9.9 (macOS)")
        #expect(protocols == ["graphql-transport-ws"])
        let sent = channel.sent.map { try? JSONValue.parse(Data($0.utf8)) }
        #expect(sent.first??["type"]?.string == "connection_init")
        #expect(sent.first??["payload"]?["token"]?.string == "TOKEN")
        #expect(sent.contains { $0?["type"]?.string == "subscribe" && $0?["id"]?.string == home })
        #expect(sent.contains { $0?["type"]?.string == "pong" })
        // Ending the stream completes the subscription and closes the socket.
        try await Task.sleep(for: .milliseconds(100))
        #expect(channel.closedWith == 1000)
    }

    @Test func invalidTokenStopsForGood() async throws {
        let channel = FakeChannel([.failure(WebSocketClosed(code: 4403))])
        let sockets = FakeSockets([channel, FakeChannel([.success(Self.ack)])])
        let live = client(sockets)
        let events = await collect(live.stream(home: home, gate: .open), readings: 1)
        #expect(events.last == .state(.stopped(.unauthorized)))
        #expect(sockets.connects == 1)
        // A new stream is refused without a connection: the token is never retried.
        let again = await collect(live.stream(home: home, gate: .open), readings: 1)
        #expect(again == [.state(.stopped(.unauthorized))])
        #expect(sockets.connects == 1)
    }

    @Test func goingAwayWaitsOneToSixtySeconds() async throws {
        let first = FakeChannel([.success(Self.ack), .failure(WebSocketClosed(code: 1001))])
        let second = FakeChannel([.success(Self.ack), .success(next(power: 900))])
        let sockets = FakeSockets([first, second])
        let events = await collect(client(sockets).stream(home: home, gate: .open), readings: 1)
        #expect(sleeper.waits.withLock { $0 } == [30.5])  // random(1...60), here its middle
        #expect(events.contains(.state(.waiting(until: Date(timeIntervalSince1970: 1_793_872_800 + 30.5)))))
        #expect(sockets.connects == 2)
    }

    @Test func silenceReconnectsWithBackoff() async throws {
        let quiet = FakeChannel([.success(Self.ack)])
        let second = FakeChannel([.success(Self.ack)])
        let third = FakeChannel([.success(Self.ack), .success(next(power: 640))])
        let sockets = FakeSockets([quiet, second, third])
        let events = await collect(client(sockets).stream(home: home, gate: .open), readings: 1)
        #expect(events.last.map { if case .reading = $0 { true } else { false } } == true)
        // Base 10 s, doubled for the second failure (jitter at its middle, × 1).
        #expect(sleeper.waits.withLock { $0 } == [10, 20], "\(sleeper.waits.withLock { $0 })")
        #expect(quiet.closedWith != nil)
        #expect(sockets.connects == 3)
    }

    @Test func unknownHomeStopsItsStream() async throws {
        let notFound =
            #"{"id":"\#(home)","type":"next","payload":{"errors":[{"message":"Could not find home","extensions":{"code":"HOME_NOT_FOUND"}}]}}"#
        let sockets = FakeSockets([FakeChannel([.success(Self.ack), .success(notFound), .success(#"{"id":"\#(home)","type":"complete"}"#)])])
        let events = await collect(client(sockets).stream(home: home, gate: .open), readings: 1)
        #expect(events.last == .state(.stopped(.notFound)))
    }

    @Test func homeWithoutRealTimeReaderIsNotSubscribed() async throws {
        let sockets = FakeSockets([FakeChannel([.success(Self.ack)])])
        let events = await collect(client(sockets, realTime: []).stream(home: home, gate: .open), readings: 1)
        #expect(events.last == .state(.stopped(.notAvailable)))
        #expect(sockets.connects == 0)
    }

    @Test func aBlockedIntegrationWaitsWithoutARequest() async throws {
        let until = Date(timeIntervalSince1970: 1_793_872_800 + 900)
        let gate = ScriptedGate([.blocked(until: until)])
        let prepares = Counter()
        let sockets = FakeSockets([FakeChannel([.success(Self.ack), .success(next(power: 700))])])
        let events = await collect(client(sockets, prepares: prepares).stream(home: home, gate: gate.gate), readings: 1)
        #expect(events.first == .state(.waiting(until: until)))
        #expect(sleeper.waits.withLock { $0 } == [900])
        #expect(prepares.count == 1)  // only after the block
        #expect(sockets.connects == 1)
    }

    @Test func rejectedCredentialsSendNothing() async throws {
        let gate = ScriptedGate([.rejected])
        let prepares = Counter()
        let sockets = FakeSockets([FakeChannel([.success(Self.ack)])])
        let live = client(sockets, prepares: prepares)
        let events = await collect(live.stream(home: home, gate: gate.gate), readings: 1)
        #expect(events == [.state(.stopped(.unauthorized))])
        #expect(prepares.count == 0)
        #expect(sockets.connects == 0)
    }

    @Test func aRefusedTokenIsReportedAndNotRetried() async throws {
        let gate = ScriptedGate()
        let prepares = Counter()
        let sockets = FakeSockets()
        let events = await collect(
            client(sockets, prepares: prepares, prepare: { throw HeatPumpError.invalidCredentials(nil) }).stream(home: home, gate: gate.gate),
            readings: 1)
        #expect(events.last == .state(.stopped(.unauthorized)))
        #expect(gate.reported.withLock { $0 } == [.invalidCredentials(nil)])
        #expect(prepares.count == 1)

        // The socket's own refusal (4403) is reported too.
        let socketGate = ScriptedGate()
        let refused = FakeSockets([FakeChannel([.failure(WebSocketClosed(code: 4403))])])
        _ = await collect(client(refused).stream(home: home, gate: socketGate.gate), readings: 1)
        #expect(socketGate.reported.withLock { $0 } == [.invalidCredentials(nil)])
    }

    @Test func aRateLimitIsReportedAndWaitedOut() async throws {
        let until = Date(timeIntervalSince1970: 1_793_872_800 + TibberAPI.rateLimitPause)
        let gate = ScriptedGate()
        let attempts = Counter()
        let sockets = FakeSockets([FakeChannel([.success(Self.ack), .success(next(power: 700))])])
        let live = client(sockets, prepare: {
            attempts.increment()
            if attempts.count == 1 { throw HeatPumpError.rateLimited(until: until) }
        })
        let events = await collect(live.stream(home: home, gate: gate.gate), readings: 1)
        #expect(gate.reported.withLock { $0 } == [.rateLimited(until: until)])
        #expect(events.contains(.state(.waiting(until: until))))
        #expect(sleeper.waits.withLock { $0 } == [TibberAPI.rateLimitPause])
    }

    @Test func resetLetsANewTokenTryAgain() async throws {
        let sockets = FakeSockets([FakeChannel([.failure(WebSocketClosed(code: 4403))]), FakeChannel([.success(Self.ack), .success(next(power: 500))])])
        let live = client(sockets)
        #expect(await collect(live.stream(home: home, gate: .open), readings: 1).last == .state(.stopped(.unauthorized)))
        #expect(await collect(live.stream(home: home, gate: .open), readings: 1) == [.state(.stopped(.unauthorized))])
        await live.reset()
        let events = await collect(live.stream(home: home, gate: .open), readings: 1)
        #expect(events.contains(.state(.live)))
        #expect(sockets.connects == 2)
    }

    @Test func theConnectionReusesItsListingAndANewTokenResumes() async throws {
        let transport = StubTransport()
        transport.enqueue("gql", body: try Fixture.data("tibber_homes"))
        let sockets = FakeSockets([
            FakeChannel([.failure(WebSocketClosed(code: 4403))]), FakeChannel([.success(Self.ack), .success(next(power: 800))]),
        ])
        let tibber = TibberConnection(
            token: { "TOKEN" }, transport: transport, sockets: sockets, userAgent: "Varmepumpe/9.9 (macOS)",
            now: { Date(timeIntervalSince1970: 1_793_872_800) })
        _ = try await tibber.listDevices()
        #expect(await tibber.recentListing()?.count == 2)
        let device = DeviceKey(integration: TibberIntegration.id, nativeId: home)
        let refused = await collect(tibber.liveReadings(device: device, gate: .open), readings: 1)
        #expect(refused.last == .state(.stopped(.unauthorized)))
        #expect(transport.requests.count == 1)  // address and homes from the listing
        #expect(sockets.connects == 1)
        // New credentials (sign-in or the price token saved) lift the stop and forget the listing.
        await tibber.resetSession()
        #expect(await tibber.recentListing() == nil)
        transport.enqueue("gql", body: try Fixture.data("tibber_homes"))
        let events = await collect(tibber.liveReadings(device: device, gate: .open), readings: 1)
        #expect(events.contains(.state(.live)))
        #expect(transport.requests.count == 2)
        #expect(sockets.connects == 2)
    }

    @Test func measurementWithMissingFields() {
        let now = Date(timeIntervalSince1970: 1_793_872_800)
        let bare = try? JSONValue.parse(Data(#"{"data":{"liveMeasurement":{"power":420}}}"#.utf8))
        let reading = TibberLiveClient.reading(bare, now: now)
        #expect(reading == LivePowerReading(at: now, powerW: 420))
        let noPower = try? JSONValue.parse(Data(#"{"data":{"liveMeasurement":{"timestamp":"2026-11-05T11:00:00+01:00"}}}"#.utf8))
        #expect(TibberLiveClient.reading(noPower, now: now) == nil)
    }
}
