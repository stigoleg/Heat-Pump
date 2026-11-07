import Foundation
import HeatPumpKit
import Synchronization

/// The Tibber account: its homes are energy meters (`tibber:<home id>`), with hourly use over
/// HTTP and live power over one shared socket (`TibberLiveClient`) for homes with a real-time
/// reader (Pulse or Watty). Rate limiting across processes is the service's job; the socket
/// exists only while the app listens (the MCP helper never opens one). The homes and the socket
/// address are listed at most hourly: a connection attempt reuses the last listing from the hour.
public actor TibberConnection: EnergyMeterDriver, LivePowerDriver {
    public nonisolated let identifier = TibberIntegration.id
    /// How long a listing (homes and socket address) is reused.
    static let listingMaxAge: TimeInterval = 3600

    private let api: TibberAPI
    private nonisolated let live: TibberLiveClient
    private nonisolated let listing: ListingCache

    /// `token` reads the token when a request is made (the keychain item shared with prices).
    public init(
        token: @escaping @Sendable () -> String?, transport: any HTTPTransport = URLSessionTransport(),
        sockets: any WebSocketConnecting = URLSessionWebSocketConnector(), userAgent: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let api = TibberAPI(token: token, transport: transport, userAgent: userAgent, now: now)
        let listing = ListingCache(api: api, now: now)
        self.api = api
        self.listing = listing
        live = TibberLiveClient(
            connector: sockets, token: token,
            prepare: {
                let (homes, url): ListingCache.Listing
                if let recent = listing.recent() { (homes, url) = recent } else { (homes, url) = try await listing.fetch() }
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

    /// New credentials: forgets the listing (another account's homes) and lets a refused token's
    /// live stream try again.
    public func resetSession() async {
        listing.forget()
        await live.reset()
    }

    public func listDevices() async throws -> [DeviceSummary] {
        try await listing.fetch().homes.map(Self.summary)
    }

    /// The listing from the last hour, so the hub's daily discovery needs no request.
    public func recentListing() async -> [DeviceSummary]? {
        listing.recent()?.homes.map(Self.summary)
    }

    static func summary(_ home: TibberAPI.Home) -> DeviceSummary {
        DeviceSummary(
            key: DeviceKey(integration: TibberIntegration.id, nativeId: home.id), name: home.name, kind: .energyMeter,
            metadata: [TibberIntegration.realTimeKey: home.realTime ? "true" : "false"])
    }

    public func fetchHours(device: DeviceKey, lastHours: Int) async throws -> [HouseHour] {
        try await api.consumption(homeId: device.nativeId, lastHours: lastHours)
    }

    public nonisolated func liveReadings(device: DeviceKey, gate: LivePowerGate) -> AsyncStream<LivePowerEvent> {
        live.stream(home: device.nativeId, gate: gate)
    }
}

/// The last listing of homes with the socket address, reused for an hour.
private final class ListingCache: Sendable {
    typealias Listing = (homes: [TibberAPI.Home], websocket: URL?)

    private let api: TibberAPI
    private let now: @Sendable () -> Date
    private let cached = Mutex<(listing: Listing, at: Date)?>(nil)

    init(api: TibberAPI, now: @escaping @Sendable () -> Date) {
        self.api = api
        self.now = now
    }

    /// The listing when it is younger than `TibberConnection.listingMaxAge`.
    func recent() -> Listing? {
        let now = now()
        return cached.withLock { $0.flatMap { now.timeIntervalSince($0.at) < TibberConnection.listingMaxAge ? $0.listing : nil } }
    }

    /// Lists the homes (one request) and keeps the answer.
    func fetch() async throws -> Listing {
        let listing = try await api.homes()
        let at = now()
        cached.withLock { $0 = (listing, at) }
        return listing
    }

    func forget() { cached.withLock { $0 = nil } }
}
