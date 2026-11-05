import Foundation

/// Simulated local readings for demo mode (`VARMEPUMPE_BACKEND=mock`). A pure function of
/// time, consistent with `MockBackend`: the average power equals the growth of its energy
/// counter, split into compressor cycles of 300–1200 W with about 4 W idle in between.
public enum MockLocalSimulation {
    public static let host = "192.168.1.50"
    /// Hardware address of the simulated unit (same as `MockBackend`'s listing).
    public static let mac = "00:00:5e:00:53:01"
    static let idleW = 4.0

    /// Average power in W (0.0175 kWh per hour and degree below 17 °C, as in `MockBackend`).
    static func averageW(at t: Date) -> Double {
        max(idleW, 17.5 * (17 - MockBackend.outdoorTemperature(at: t)))
    }

    /// Compressor state at `t`. Mild weather gives short cycles (5 starts per hour), cold weather
    /// long ones (2 per hour), like a unit that is a bit large for the room.
    /// `shortCycling` (dev only, `VARMEPUMPE_MOCK_CYCLING=short`) makes every cycle 10 minutes,
    /// so the short-cycling health rule can be shown in demo screenshots.
    static func cycle(at t: Date, shortCycling: Bool = false) -> (running: Bool, watts: Double, hz: Int) {
        let average = averageW(at: t)
        let nominalW = min(1200, max(300, 250 + 1.6 * average))
        let periodMinutes = shortCycling ? 10 : MockBackend.outdoorTemperature(at: t) > 0 ? 12 : 30
        // Whole minutes of running per cycle; the running power is then set so the average
        // matches the counter exactly.
        let onMinutes = min(periodMinutes, max(1, Int((Double(periodMinutes) * (average - idleW) / (nominalW - idleW)).rounded())))
        let runningW = min(1200, idleW + (average - idleW) * Double(periodMinutes) / Double(onMinutes))
        let minute = Int((t.timeIntervalSince1970 / 60).rounded(.down)) % periodMinutes
        guard minute < onMinutes else { return (false, idleW, 0) }
        let ripple = 30 * sin(t.timeIntervalSince1970 / 97)
        return (true, runningW + ripple, Int(15 + runningW / 1200 * 65))
    }

    public static func sample(at t: Date, shortCycling: Bool = false) -> LocalSample {
        let outdoor = MockBackend.outdoorTemperature(at: t)
        let room = ((20.7 + 0.3 * sin(t.timeIntervalSince1970 / 3600 / 1.7 * 2 * .pi)) * 2).rounded() / 2
        let state = cycle(at: t, shortCycling: shortCycling)
        var s = LocalSample(timestamp: t)
        s.power = true
        s.setRaw(mode: 1, fan: 0, vaneVertical: 0, vaneHorizontal: 3)
        s.iSee = true
        s.setTemperature = 21
        s.roomTemperature = room
        s.roomTemperature2 = room - 0.5
        s.outdoorTemperature = (outdoor * 2).rounded() / 2
        s.compressorHz = state.hz
        s.operating = state.running
        s.powerW = Int(state.watts.rounded())
        s.energyKWh = MockBackend.counterKWh(at: t).truncatingRemainder(dividingBy: CN105Parser.counterWrapKWh)
        s.errorCode = CN105Parser.noError
        s.rssi = -55
        s.adapterVersion = "34.00"
        s.cloudConnected = true
        return s
    }

    /// The status frames the adapter would send for `sample`.
    static func frames(for s: LocalSample) -> [String] {
        func temperature(_ value: Double?) -> UInt8 { UInt8(clamping: Int(0x80 + ((value ?? 0) * 2).rounded())) }
        let set = s.setTemperature ?? 21
        let counter = Int(((s.energyKWh ?? 0) * 10).rounded()) & 0xFFFF
        let watts = max(0, min(0xFFFF, s.powerW ?? 0))
        return [
            CN105Parser.frame(
                group: 0x02,
                payload: [
                    8: s.power == true ? 1 : 0, 9: UInt8(s.modeRaw ?? 1) | (s.iSee == true ? 0x08 : 0),
                    10: UInt8(clamping: 31 - Int(set)), 11: UInt8(s.fanRaw ?? 0), 12: UInt8(s.vaneVerticalRaw ?? 0),
                    15: UInt8(s.vaneHorizontalRaw ?? 0), 16: temperature(set),
                ]),
            CN105Parser.frame(
                group: 0x03,
                payload: [
                    8: UInt8(clamping: Int(s.roomTemperature ?? 20) - 10), 10: temperature(s.outdoorTemperature),
                    11: temperature(s.roomTemperature), 12: temperature(s.roomTemperature2),
                ]),
            CN105Parser.frame(group: 0x04, payload: [9: UInt8((s.errorCode ?? CN105Parser.noError) >> 8), 10: UInt8((s.errorCode ?? 0) & 0xFF)]),
            CN105Parser.frame(group: 0x05, payload: [:]),
            CN105Parser.frame(
                group: 0x06,
                payload: [
                    8: UInt8(clamping: s.compressorHz ?? 0), 9: s.operating == true ? 1 : 0, 10: UInt8(watts >> 8),
                    11: UInt8(watts & 0xFF), 12: UInt8(counter >> 8), 13: UInt8(counter & 0xFF),
                ]),
        ]
    }

    /// Readings every `step` seconds from `from` to `to` (demo seeding).
    public static func samples(from: Date, to: Date, step: TimeInterval = 60, shortCycling: Bool = false) -> [LocalSample] {
        var out: [LocalSample] = []
        var t = from
        while t <= to {
            out.append(sample(at: t, shortCycling: shortCycling))
            t = t.addingTimeInterval(step)
        }
        return out
    }
}

/// Answers `/smart` like the adapter, from `MockLocalSimulation`, through the real crypto and
/// parsing path. Anything but the `<CSV></CSV>` status request gets HTTP 400.
public struct MockLocalTransport: HTTPTransport {
    private let now: @Sendable () -> Date
    private let shortCycling: Bool

    public init(now: @escaping @Sendable () -> Date = { Date() }, shortCycling: Bool = false) {
        self.now = now
        self.shortCycling = shortCycling
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw LocalAccessError.network("ingen adresse") }
        let plaintext = request.httpBody.flatMap(LocalSmartClient.decryptRequestBody)
        guard request.httpMethod == "POST", url.path == LocalSmartClient.path, plaintext == LocalSmartClient.statusPayload,
            url.host == MockLocalSimulation.host
        else {
            if url.host != MockLocalSimulation.host { throw LocalAccessError.network("Tidsavbrudd (simulert)") }
            return (Data(), HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!)  // literal status
        }
        let sample = MockLocalSimulation.sample(at: now(), shortCycling: shortCycling)
        let xml =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><LSV><CONNECT>ON</CONNECT><STATUS>NORMAL</STATUS>"
            + "<APP_VER>\(sample.adapterVersion ?? "")</APP_VER><RSSI>\(sample.rssi ?? 0)</RSSI><CODE>"
            + MockLocalSimulation.frames(for: sample).map { "<VALUE>\($0)</VALUE>" }.joined() + "</CODE></LSV>"
        let body = try LocalSmartClient.envelope(xml, iv: LocalSmartClient.randomIV())
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)  // valid URL
    }
}

/// Finds the simulated adapter when asked for the simulated MAC.
public struct MockLocalScanner: LocalNetworkScanning {
    public init() {}
    public func hosts(matchingMAC mac: String) async throws -> [String] {
        normalizedMAC(mac) == normalizedMAC(MockLocalSimulation.mac) ? [MockLocalSimulation.host] : []
    }
}

extension LocalAccess {
    /// Demo mode: the simulated adapter at `MockLocalSimulation.host`.
    public static func simulated(now: @escaping @Sendable () -> Date = { Date() }, shortCycling: Bool = false) -> LocalAccess {
        LocalAccess(
            makeClient: { try LocalSmartClient(host: $0, transport: MockLocalTransport(now: now, shortCycling: shortCycling)) },
            scanner: MockLocalScanner(), simulatedShortCycling: shortCycling)
    }
}
