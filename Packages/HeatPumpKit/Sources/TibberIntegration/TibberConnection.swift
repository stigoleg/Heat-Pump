import Foundation
import HeatPumpKit

/// The Tibber account: its homes are energy meters (`tibber:<home id>`), with hourly use over
/// HTTP and live power over one shared socket (`TibberLiveClient`) for homes with a real-time
/// reader (Pulse or Watty). Rate limiting across processes is the service's job; the socket
/// exists only while the app listens (the MCP helper never opens one).
public actor TibberConnection: EnergyMeterDriver, LivePowerDriver {
    public nonisolated let identifier = TibberIntegration.id
    private let api: TibberAPI
    private nonisolated let live: TibberLiveClient

    /// `token` reads the token when a request is made (the keychain item shared with prices).
    public init(
        token: @escaping @Sendable () -> String?, transport: any HTTPTransport = URLSessionTransport(),
        sockets: any WebSocketConnecting = URLSessionWebSocketConnector(), userAgent: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let api = TibberAPI(token: token, transport: transport, userAgent: userAgent, now: now)
        self.api = api
        live = TibberLiveClient(
            connector: sockets, token: token,
            prepare: {
                let (homes, url) = try await api.homes()
                guard let url else { throw HeatPumpError.decoding(L10n.tr("no address for live data")) }
                return (url, Set(homes.filter(\.realTime).map(\.id)))
            },
            userAgent: userAgent, now: now)
    }

    public nonisolated var capabilities: Set<Capability> { [.energyLog, .livePower] }

    /// Live power only for homes with a real-time reader (stored with the listing).
    public nonisolated func capabilities(of device: DeviceSummary) -> Set<Capability> {
        device.metadata[TibberIntegration.realTimeKey] == "true" ? [.energyLog, .livePower] : [.energyLog]
    }

    /// Tibber needs no login: every request carries the token.
    public func login() async throws {}

    public func listDevices() async throws -> [DeviceSummary] {
        try await api.homes().homes.map(Self.summary)
    }

    static func summary(_ home: TibberAPI.Home) -> DeviceSummary {
        DeviceSummary(
            key: DeviceKey(integration: TibberIntegration.id, nativeId: home.id), name: home.name, kind: .energyMeter,
            metadata: [TibberIntegration.realTimeKey: home.realTime ? "true" : "false"])
    }

    public func fetchHours(device: DeviceKey, lastHours: Int) async throws -> [HouseHour] {
        try await api.consumption(homeId: device.nativeId, lastHours: lastHours)
    }

    public nonisolated func liveReadings(device: DeviceKey) -> AsyncStream<LivePowerEvent> {
        live.stream(home: device.nativeId)
    }
}
