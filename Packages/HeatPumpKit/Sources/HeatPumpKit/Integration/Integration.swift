import Foundation

/// A vendor's cloud or local API, built into the app as its own module and listed in
/// `IntegrationCatalog`. Each integration owns its rules: sign-in fields, rate limits and how it
/// talks to the unit.
public protocol Integration: Sendable {
    /// Stable identifier, e.g. `melcloud-classic` or `demo`.
    var id: String { get }
    /// The service name shown in texts, e.g. "MELCloud".
    var displayName: String { get }
    var vendorName: String { get }
    var credentialFields: [CredentialField] { get }
    var rateLimitPolicy: RateLimitPolicy { get }
    /// The connection to the unit. Throws when the context lacks what it needs (e.g. credentials).
    func makeConnection(_ context: IntegrationContext) throws -> any DeviceConnection & ThermostatDriver
}

/// What an integration gets to build its connection.
public struct IntegrationContext: Sendable {
    public var environment: [String: String]
    public var store: HistoryStore
    /// Nil when the integration needs none (demo).
    public var credentials: (any CredentialProviding)?
    public var timeZone: TimeZone
    public var now: @Sendable () -> Date

    public init(
        environment: [String: String], store: HistoryStore, credentials: (any CredentialProviding)? = nil,
        timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.environment = environment
        self.store = store
        self.credentials = credentials
        self.timeZone = timeZone
        self.now = now
    }

    /// Dev switch: `VARMEPUMPE_BACKEND=mock` selects the demo integration (simulated data, no network).
    public static func demoRequested(environment: [String: String]) -> Bool {
        environment["VARMEPUMPE_BACKEND"]?.lowercased() == "mock"
    }
}
