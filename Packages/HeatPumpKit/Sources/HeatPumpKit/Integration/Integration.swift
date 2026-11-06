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
    /// The vendor as texts name it in passing ("the … app", "… support"). Defaults to `vendorName`.
    var brandName: String { get }
    /// The unit model as reported to Claude (`get_device_info`); nil when the integration does
    /// not know it.
    var modelName: String? { get }
    /// What Claude is told it controls, in the first line of the MCP server instructions.
    /// Defaults to "\(displayName) heat pump".
    var unitDescription: String { get }
    /// Stored with rows the integration produced (error log, away settings). Persisted, so it
    /// never changes for an existing integration. Defaults to `id`.
    var sourceTag: String { get }
    var credentialFields: [CredentialField] { get }
    var rateLimitPolicy: RateLimitPolicy { get }
    /// Explains the unit's error codes in the health check, the error log and the MCP helper.
    var errorCodes: any ErrorCodeExplaining { get }
    /// Health rules that only make sense for this integration's units. Defaults to none.
    var healthChecks: any HealthCheckProviding { get }
    /// The maintenance tasks the unit has (health check, maintenance status, reminders).
    /// Defaults to none.
    var maintenanceKinds: [MaintenanceKind] { get }
    /// Knowledge documents about the unit (MCP resources, the Health page). Defaults to none.
    var knowledge: KnowledgeSource { get }
    /// The connection to the unit. Throws when the context lacks what it needs (e.g. credentials).
    func makeConnection(_ context: IntegrationContext) throws -> any DeviceConnection & ThermostatDriver
}

extension Integration {
    public var brandName: String { vendorName }
    public var modelName: String? { nil }
    public var unitDescription: String { "\(displayName) heat pump" }
    public var sourceTag: String { id }
    public var healthChecks: any HealthCheckProviding { NoHealthChecks() }
    public var maintenanceKinds: [MaintenanceKind] { [] }
    public var knowledge: KnowledgeSource { KnowledgeSource() }
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
