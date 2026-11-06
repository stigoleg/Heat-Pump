import Foundation
import Synchronization

/// What the hub needs to run one integration: the connection every device of the integration
/// shares (so its session, blocks and change budget are one), its credential store and the local
/// network access its devices use.
public struct IntegrationRuntime: Sendable {
    public var integration: any Integration
    public var connection: any DeviceConnection
    public var credentials: (any CredentialProviding)?
    public var local: LocalAccess

    public init(
        integration: any Integration, connection: any DeviceConnection,
        credentials: (any CredentialProviding)? = nil, local: LocalAccess = .unavailable
    ) {
        self.integration = integration
        self.connection = connection
        self.credentials = credentials
        self.local = local
    }
}

/// The active integrations' runtimes, readable from the energy context's closures.
final class ActiveRuntimes: Sendable {
    private let runtimes: Mutex<[IntegrationRuntime]>

    init(_ runtimes: [IntegrationRuntime]) { self.runtimes = Mutex(runtimes) }

    func withLock<T: Sendable>(_ body: (inout [IntegrationRuntime]) -> T) -> T { runtimes.withLock { body(&$0) } }
}

/// A device's service, by kind.
public enum DeviceService: Sendable {
    case heatPump(HeatPumpService)
    case energyMeter(EnergyMeterService)

    /// The heat pump service, or nil for another kind.
    public var heatPump: HeatPumpService? {
        switch self {
        case .heatPump(let service): service
        case .energyMeter: nil
        }
    }

    /// The energy meter service, or nil for another kind.
    public var energyMeter: EnergyMeterService? {
        switch self {
        case .energyMeter(let service): service
        case .heatPump: nil
        }
    }
}

/// Runs every device of every active integration side by side, sharing one database, one
/// connection per integration and one energy context (prices, weather, house consumption).
/// The app and the MCP helper each build one (`IntegrationCatalog.makeHub`).
///
/// The hub reads the device registry (`HistoryStore.devices()`) on every call that lists or looks
/// up devices, so a device enabled, disabled or renamed in the other process shows up without a
/// restart. Each enabled device of an active integration has a `HeatPumpService` fixed to it; an
/// active integration without an enabled device has one service that resolves its first device
/// by itself (first sign-in), which the hub then keeps as that device's service.
///
/// With one device everything behaves as before the hub: `primaryService()` is the service the
/// app and the helper used to create.
public actor DeviceHub {
    /// `app_settings` key of the active integrations (`[Integration.id]`).
    public static let integrationsKey = "integrations"
    /// `app_settings` key of the device price control steers (`DeviceKey`).
    public static let priceControlDeviceKey = "priceControlDevice"

    public nonisolated let store: HistoryStore
    /// Prices, weather, house consumption and the price outlook, shared by every device.
    public nonisolated let energy: EnergyContextService
    /// Demo mode: simulated devices and sources, the demo integration only (fixed).
    public nonisolated let isDemo: Bool
    /// Every integration this build knows (`IntegrationCatalog.all`).
    public nonisolated let catalog: [any Integration]
    /// The primary device's service when the hub was built, for code that needs one before it
    /// can await (the app's model). The hub keeps serving that object for its device.
    public nonisolated let primaryAtLaunch: HeatPumpService?

    nonisolated let timeZone: TimeZone
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async -> Void
    let makeRuntime: @Sendable (any Integration) throws -> IntegrationRuntime
    /// The active integrations when they cannot change (demo mode), else nil.
    let fixedIntegrations: [String]?
    let defaultIntegrations: [String]
    /// The active integrations' runtimes in their order, shared with the energy context's
    /// reference-device closures.
    private let active: ActiveRuntimes
    private var services: [DeviceKey: HeatPumpService]
    /// Per active integration without an enabled device: a service that resolves one itself.
    private var unresolved: [String: HeatPumpService]
    /// The enabled energy meters' services.
    private var meters: [DeviceKey: EnergyMeterService] = [:]
    /// Per active meter integration without an enabled meter: a service that signs in and lists.
    private var meterAccounts: [String: EnergyMeterService] = [:]

    /// - Parameters:
    ///   - fixedIntegrations: the active integrations when they are not the user's choice (demo).
    ///   - defaultIntegrations: the active integrations until the user changes them.
    ///   - makeRuntime: builds an integration's connection; throws when it lacks what it needs.
    public init(
        store: HistoryStore, catalog: [any Integration], fixedIntegrations: [String]? = nil, defaultIntegrations: [String],
        isDemo: Bool = false, timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(max(0, seconds)))
        },
        priceProvider: @escaping @Sendable (PriceSettings) -> (any PriceProvider)? = { _ in nil },
        weatherProvider: @escaping @Sendable (WeatherSettings) -> (any WeatherProviding)? = { _ in nil },
        houseProvider: @escaping @Sendable () -> (any HouseConsumptionProviding)? = { nil },
        makeRuntime: @escaping @Sendable (any Integration) throws -> IntegrationRuntime
    ) throws {
        self.store = store
        self.catalog = catalog
        self.isDemo = isDemo
        self.timeZone = timeZone
        self.now = now
        self.sleep = sleep
        self.makeRuntime = makeRuntime
        self.fixedIntegrations = fixedIntegrations
        self.defaultIntegrations = defaultIntegrations
        let stored = try store.setting([String].self, key: Self.integrationsKey)
        let ids = fixedIntegrations ?? stored ?? defaultIntegrations
        var runtimes: [IntegrationRuntime] = []
        for id in Self.unique(ids) {
            guard let integration = catalog.first(where: { $0.id == id }) else { continue }
            runtimes.append(try makeRuntime(integration))
        }
        let active = ActiveRuntimes(runtimes)
        self.active = active
        let reference: @Sendable () throws -> DeviceKey? = {
            let ids = active.withLock { $0.map(\.integration.id) }
            return try store.devices().first { $0.enabled && ids.contains($0.key.integration) }?.key
        }
        energy = EnergyContextService(
            store: store, timeZone: timeZone, isDemo: isDemo, now: now, priceProvider: priceProvider,
            weatherProvider: weatherProvider, houseProvider: houseProvider,
            houseMeter: {
                // The first enabled meter of an active integration whose connection reports hours.
                let runtimes = active.withLock { $0 }
                for record in try store.devices() where record.enabled && record.kind == .energyMeter {
                    guard let runtime = runtimes.first(where: { $0.integration.id == record.key.integration }),
                        let driver = runtime.connection as? any EnergyMeterDriver
                    else { continue }
                    return HouseMeterSource(device: record.key, driver: driver, serviceName: runtime.integration.displayName)
                }
                return nil
            },
            referenceDevice: reference,
            referenceLocation: {
                guard let key = try reference(),
                    let connection = active.withLock({ $0.first { $0.integration.id == key.integration }?.connection }),
                    let reporter = connection as? any DeviceLocationReporting
                else { return nil }
                return reporter.location(fromStoredListing: try store.rawDevice(key)?.listing)
            })

        // The services for what the registry holds now (no network).
        var services: [DeviceKey: HeatPumpService] = [:]
        var unresolved: [String: HeatPumpService] = [:]
        var meters: [DeviceKey: EnergyMeterService] = [:]
        var meterAccounts: [String: EnergyMeterService] = [:]
        let records = try store.devices()
        for runtime in runtimes {
            let enabled = records.filter { $0.enabled && $0.key.integration == runtime.integration.id }
            if let thermostat = runtime.connection as? any DeviceConnection & ThermostatDriver {
                let heatPumps = enabled.filter { $0.kind != .energyMeter }
                for record in heatPumps {
                    services[record.key] = Self.makeService(
                        runtime, thermostat, device: record.key, store: store, energy: energy, timeZone: timeZone, now: now,
                        sleep: sleep)
                }
                if heatPumps.isEmpty {
                    unresolved[runtime.integration.id] = Self.makeService(
                        runtime, thermostat, device: nil, store: store, energy: energy, timeZone: timeZone, now: now, sleep: sleep)
                }
            }
            if let meter = runtime.connection as? any EnergyMeterDriver {
                let enabledMeters = enabled.filter { $0.kind == .energyMeter }
                for record in enabledMeters {
                    meters[record.key] = Self.makeMeter(runtime, meter, device: record.key, store: store, energy: energy, timeZone: timeZone, now: now)
                }
                if enabledMeters.isEmpty {
                    meterAccounts[runtime.integration.id] = Self.makeMeter(
                        runtime, meter, device: nil, store: store, energy: energy, timeZone: timeZone, now: now)
                }
            }
        }
        self.services = services
        self.unresolved = unresolved
        self.meters = meters
        self.meterAccounts = meterAccounts
        let primary = Self.primary(
            records: records, active: runtimes.map(\.integration.id), services: services, unresolved: unresolved)
        primaryAtLaunch = primary
        HeatPumpError.serviceName = primary?.serviceName ?? runtimes.first?.integration.displayName ?? ""
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func makeService(
        _ runtime: IntegrationRuntime, _ thermostat: any DeviceConnection & ThermostatDriver, device: DeviceKey?, store: HistoryStore,
        energy: EnergyContextService, timeZone: TimeZone, now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (TimeInterval) async -> Void
    ) -> HeatPumpService {
        HeatPumpService(
            backend: thermostat, store: store, credentials: runtime.credentials, integration: runtime.integration,
            policy: runtime.integration.rateLimitPolicy, timeZone: timeZone, now: now, sleep: sleep, local: runtime.local,
            energy: energy, device: device, resolutionScope: runtime.integration.id)
    }

    private func makeService(
        _ runtime: IntegrationRuntime, _ thermostat: any DeviceConnection & ThermostatDriver, device: DeviceKey?
    ) -> HeatPumpService {
        Self.makeService(runtime, thermostat, device: device, store: store, energy: energy, timeZone: timeZone, now: now, sleep: sleep)
    }

    private static func makeMeter(
        _ runtime: IntegrationRuntime, _ meter: any EnergyMeterDriver, device: DeviceKey?, store: HistoryStore,
        energy: EnergyContextService, timeZone: TimeZone, now: @escaping @Sendable () -> Date
    ) -> EnergyMeterService {
        EnergyMeterService(
            connection: meter, store: store, credentials: runtime.credentials, integration: runtime.integration, energy: energy,
            device: device, timeZone: timeZone, now: now)
    }

    /// The first enabled device's service in registry order, else the first active integration's
    /// unresolved service.
    private static func primary(
        records: [DeviceRecord], active: [String], services: [DeviceKey: HeatPumpService], unresolved: [String: HeatPumpService]
    ) -> HeatPumpService? {
        if let record = records.first(where: { $0.enabled && services[$0.key] != nil }) { return services[record.key] }
        return active.lazy.compactMap { unresolved[$0] }.first
    }

    private var runtimes: [IntegrationRuntime] { active.withLock { $0 } }

    private func runtime(_ id: String) -> IntegrationRuntime? { runtimes.first { $0.integration.id == id } }

    // MARK: Devices

    /// The enabled devices of the active integrations, in the registry's order (the user's sort
    /// order). The first is the primary device.
    public func devices() async throws -> [DeviceDescriptor] {
        try await allDevices().filter(\.isEnabled)
    }

    /// Every device of the active integrations, enabled ones first.
    public func allDevices() async throws -> [DeviceDescriptor] {
        let records = try await reconcile()
        let runtimes = runtimes
        return records.compactMap { record in
            guard let runtime = runtimes.first(where: { $0.integration.id == record.key.integration }) else { return nil }
            return DeviceDescriptor(
                key: record.key, name: record.displayName, kind: record.kind, capabilities: runtime.connection.capabilities(of: record.summary),
                isEnabled: record.enabled)
        }
    }

    /// The primary device: the first enabled one. Nil until a device is known (first sign-in).
    public var primaryDevice: DeviceDescriptor? {
        get async throws { try await devices().first }
    }

    /// The service of the primary device; before any device is known, the first active
    /// integration's service that finds its device on the first fetch. What the app serves.
    public func primaryService() async throws -> HeatPumpService? {
        let records = try await reconcile()
        return Self.primary(records: records, active: runtimes.map(\.integration.id), services: services, unresolved: unresolved)
    }

    /// The service of an enabled device, by kind.
    public func service(for key: DeviceKey) async throws -> DeviceService? {
        _ = try await reconcile()
        if let service = services[key] { return .heatPump(service) }
        return meters[key].map(DeviceService.energyMeter)
    }

    /// The energy meter service of an enabled meter.
    public func meterService(for key: DeviceKey) async throws -> EnergyMeterService? {
        _ = try await reconcile()
        return meters[key]
    }

    /// The heat pump service of an enabled device.
    public func heatPumpService(for key: DeviceKey) async throws -> HeatPumpService? {
        _ = try await reconcile()
        return services[key]
    }

    /// The integration that owns `key`'s device, if this build knows it.
    public nonisolated func integration(for key: DeviceKey) -> (any Integration)? {
        catalog.first { $0.id == key.integration }
    }

    /// Turns a device on or off. A disabled device keeps its data but has no service. Turning off
    /// the device price control steers while it is on first turns price control off, which sets
    /// that device's temperature back (as choosing another device does); returns that restore's
    /// outcome, or nil.
    @discardableResult
    public func setEnabled(_ enabled: Bool, for key: DeviceKey) async throws -> ChangeOutcome? {
        let outcome = enabled ? nil : try await stopPriceControl(on: [key])
        try store.setDeviceEnabled(enabled, device: key)
        _ = try await reconcile()
        return outcome
    }

    /// Turns price control off (restoring the temperature) when it is on and steers one of `keys`.
    private func stopPriceControl(on keys: [DeviceKey]) async throws -> ChangeOutcome? {
        guard let controlled = try await priceControlDevice(), keys.contains(controlled), let service = services[controlled],
            try await service.priceControlSettings().enabled
        else { return nil }
        return try await service.disablePriceControl()
    }

    /// Gives a device the user's own name; nil or empty goes back to the integration's name.
    public func rename(_ key: DeviceKey, to name: String?) throws {
        try store.renameDevice(key, to: name)
    }

    /// Lists the devices of `integration` (every active one when nil) again: one listing request
    /// each, under that integration's state spacing and blocks. New devices are registered and
    /// enabled; devices an account no longer lists are disabled. Returns the devices afterwards.
    @discardableResult
    public func refreshDeviceList(integration id: String? = nil) async throws -> [DeviceDescriptor] {
        _ = try await reconcile()
        for runtime in runtimes where id == nil || runtime.integration.id == id {
            guard let service = anyService(of: runtime.integration.id) else { continue }
            _ = try await service.refreshDeviceList()
        }
        return try await devices()
    }

    /// Makes the hub's services match the registry and the active integrations. Returns the
    /// registry.
    @discardableResult
    private func reconcile() async throws -> [DeviceRecord] {
        let records = try store.devices()
        let runtimes = runtimes
        // A service may have moved to another device (sign-in with another account).
        var byDevice: [DeviceKey: HeatPumpService] = [:]
        for service in services.values {
            if let key = try await service.currentDevice() { byDevice[key] = byDevice[key] ?? service }
        }
        var next: [DeviceKey: HeatPumpService] = [:]
        var nextUnresolved: [String: HeatPumpService] = [:]
        var nextMeters: [DeviceKey: EnergyMeterService] = [:]
        var nextAccounts: [String: EnergyMeterService] = [:]
        for runtime in runtimes {
            let id = runtime.integration.id
            let enabled = records.filter { $0.enabled && $0.key.integration == id }
            if let thermostat = runtime.connection as? any DeviceConnection & ThermostatDriver {
                let heatPumps = enabled.filter { $0.kind != .energyMeter }
                for record in heatPumps {
                    if let service = byDevice[record.key] {
                        next[record.key] = service
                    } else if let service = unresolved[id], try await service.currentDevice() == record.key {
                        await service.pin(to: record.key)
                        next[record.key] = service
                    } else {
                        next[record.key] = makeService(runtime, thermostat, device: record.key)
                    }
                }
                if heatPumps.isEmpty { nextUnresolved[id] = unresolved[id] ?? makeService(runtime, thermostat, device: nil) }
            }
            if let meter = runtime.connection as? any EnergyMeterDriver {
                let enabledMeters = enabled.filter { $0.kind == .energyMeter }
                for record in enabledMeters {
                    nextMeters[record.key] =
                        meters[record.key]
                        ?? Self.makeMeter(runtime, meter, device: record.key, store: store, energy: energy, timeZone: timeZone, now: now)
                }
                if enabledMeters.isEmpty {
                    nextAccounts[id] =
                        meterAccounts[id]
                        ?? Self.makeMeter(runtime, meter, device: nil, store: store, energy: energy, timeZone: timeZone, now: now)
                }
            }
        }
        services = next
        unresolved = nextUnresolved
        meters = nextMeters
        meterAccounts = nextAccounts
        let primary = Self.primary(records: records, active: runtimes.map(\.integration.id), services: next, unresolved: nextUnresolved)
        if let name = primary?.serviceName { HeatPumpError.serviceName = name }
        return records
    }

    /// Every account-capable service of an integration (its devices', or its unresolved one).
    private func accounts(of id: String) -> [any DeviceAccount] {
        let heatPumps: [any DeviceAccount] =
            services.filter { $0.key.integration == id }.sorted { $0.key < $1.key }.map(\.value) + (unresolved[id].map { [$0] } ?? [])
        let meters: [any DeviceAccount] =
            self.meters.filter { $0.key.integration == id }.sorted { $0.key < $1.key }.map(\.value) + (meterAccounts[id].map { [$0] } ?? [])
        return heatPumps + meters
    }

    /// The service that speaks for an integration's account: its first device's (registry
    /// order), else its unresolved one.
    private func anyService(of id: String) -> (any DeviceAccount)? {
        let order = (try? store.devices()) ?? []
        for record in order where record.enabled && record.key.integration == id {
            if let service = services[record.key] { return service }
            if let meter = meters[record.key] { return meter }
        }
        return unresolved[id] ?? meterAccounts[id] ?? accounts(of: id).first
    }

    // MARK: Discovery

    /// `fetch_state` name of an integration's daily device discovery.
    static let discoveryName = "discovery"
    /// How often each integration's device list is checked for new devices.
    public static let discoveryInterval: TimeInterval = 86_400

    /// Registers devices that appeared on an account (enabled) and disables the ones it no longer
    /// lists, at most once a day per integration: from the listing the connection fetched anyway
    /// when it has one, else with one listing request under the integration's spacing. Nothing in
    /// demo mode. Returns whether the registry may have changed.
    @discardableResult
    public func discoverDevices() async throws -> Bool {
        guard !isDemo else { return false }
        _ = try await reconcile()
        var changed = false
        for runtime in runtimes {
            let id = runtime.integration.id
            let key = HistoryStore.fetchKey(Self.discoveryName, integration: id)
            let t = now()
            if let last = try store.fetchState(key: key)?.lastSuccess, t.timeIntervalSince(last) < Self.discoveryInterval { continue }
            guard let account = anyService(of: id), await account.hasCredentials() else { continue }
            if let listed = await runtime.connection.recentListing(), !listed.isEmpty {
                _ = try store.syncDevices(listed, integration: id)
            } else if try await account.refreshDeviceList() == nil {
                continue
            }
            try store.recordFetchSuccess(key: key, now: t)
            changed = true
        }
        if changed { _ = try await reconcile() }
        return changed
    }

    /// The integrations whose sign-in values are shared with the price source (the price token was
    /// saved or tested in Settings → Electricity price): lifts their "credentials rejected" stop
    /// and forgets the cached answer to "are credentials stored?".
    public func sharedCredentialsChanged() async throws {
        for runtime in runtimes where runtime.integration.credentialMapping.isShared {
            try store.clearCredentialsRejected(integration: runtime.integration.id)
            for account in accounts(of: runtime.integration.id) { await account.forgetCredentialCache() }
        }
    }

    // MARK: Integrations

    /// The active integrations, in order.
    public var activeIntegrations: [any Integration] { runtimes.map(\.integration) }

    /// The sign-in fields of an integration this build knows (empty when it needs none).
    public nonisolated func credentialFields(for id: String) -> [CredentialField] {
        catalog.first { $0.id == id }?.credentialFields ?? []
    }

    /// Whether the integration's sign-in values are stored (true when it needs none).
    public func hasCredentials(integration id: String) async -> Bool {
        guard let service = anyService(of: id) else { return false }
        return await service.hasCredentials()
    }

    /// Starts using an integration: stores it as active, builds its connection and, when it has
    /// sign-in fields or `credentials` are given, signs in (saves the values, lists the account's
    /// devices and fetches the first one's state; see `signIn`). Returns that fetch's result, or
    /// nil when nothing was signed in. Refused in demo mode and for an integration this build
    /// does not know.
    @discardableResult
    public func addIntegration(id: String, credentials: CredentialValues = CredentialValues()) async throws -> StateResult? {
        guard fixedIntegrations == nil else { throw HeatPumpError.validation(L10n.tr("Not available in demo mode.")) }
        guard let integration = catalog.first(where: { $0.id == id }) else { throw HeatPumpError.notSupported }
        if runtime(id) == nil {
            let runtime = try makeRuntime(integration)
            active.withLock { $0.append(runtime) }
            try saveActiveIntegrations()
        }
        _ = try await reconcile()
        guard !integration.credentialFields.isEmpty || !credentials.fields.isEmpty else { return nil }
        return try await signIn(integration: id, values: credentials)
    }

    /// Stops using an integration: forgets its sign-in values and session (unless they are shared
    /// with the price source, `CredentialMapping.isShared`) and drops its services. Its devices
    /// keep their data and come back when the integration is added again.
    public func removeIntegration(id: String) async throws {
        guard fixedIntegrations == nil else { throw HeatPumpError.validation(L10n.tr("Not available in demo mode.")) }
        _ = try await stopPriceControl(on: try await devices().filter { $0.integrationId == id }.map(\.key))
        // Values shared with the price source stay; signing out deletes them.
        if let service = anyService(of: id), runtime(id)?.integration.credentialMapping.isShared != true { try await service.signOut() }
        active.withLock { $0.removeAll { $0.integration.id == id } }
        try saveActiveIntegrations()
        _ = try await reconcile()
    }

    private func saveActiveIntegrations() throws {
        try store.saveSetting(runtimes.map(\.integration.id), key: Self.integrationsKey)
    }

    /// Saves an integration's sign-in values, forgets its session and does the test fetch: one
    /// login, the account's device list and the first device's state, under the integration's
    /// sign-in spacing and blocks. Devices the account lists are registered; its devices the
    /// account does not list are disabled (another account was signed in). The service that was
    /// serving the integration's first device moves to the new account's first device when its
    /// own is gone, so a model holding it keeps working.
    public func signIn(integration id: String, values: CredentialValues) async throws -> StateResult {
        _ = try await reconcile()
        guard let service = anyService(of: id) else { throw HeatPumpError.notSupported }
        let result = try await service.signIn(values)
        for other in accounts(of: id) where other !== service { await other.forgetCredentialCache() }
        _ = try await reconcile()
        return result
    }

    /// Removes an integration's sign-in values and session.
    public func signOut(integration id: String) async throws {
        guard let service = anyService(of: id) else { return }
        try await service.signOut()
        for other in accounts(of: id) where other !== service { await other.forgetCredentialCache() }
    }

    // MARK: Price control

    /// The device price control steers: the chosen one while it is enabled, else the first
    /// enabled air-to-air heat pump (with one heat pump, that one).
    public func priceControlDevice() async throws -> DeviceKey? {
        let devices = try await devices()
        if let chosen = try store.setting(DeviceKey.self, key: Self.priceControlDeviceKey), devices.contains(where: { $0.key == chosen }) {
            return chosen
        }
        return devices.first { $0.kind == .airToAirHeatPump }?.key
    }

    /// Chooses the device price control steers (nil: the first air-to-air heat pump). Price
    /// control's settings and memory are not per device; turn it off before choosing another.
    public func setPriceControlDevice(_ key: DeviceKey?) throws {
        if let key {
            try store.saveSetting(key, key: Self.priceControlDeviceKey)
        } else {
            try store.saveSetting(JSONValue.null, key: Self.priceControlDeviceKey)
        }
    }

    /// The service price control runs on (see `priceControlDevice`); the primary service before
    /// any device is known.
    public func priceControlService() async throws -> HeatPumpService? {
        guard let key = try await priceControlDevice() else { return try await primaryService() }
        return services[key]
    }

    // MARK: Change log

    /// The newest changes of every device with the device's name (nil for changes tied to no
    /// device or to a device the registry no longer has). Filter by `device` for one device's.
    public func changeLog(limit: Int = 50, source: ChangeSource? = nil) async throws -> [(device: DeviceDescriptor?, record: ChangeRecord)] {
        let devices = try await allDevices()
        return try store.changesByDevice(limit: limit, source: source).map { row in
            (row.device.flatMap { key in devices.first { $0.key == key } }, row.record)
        }
    }

    // MARK: Demo

    /// Demo mode: fills every simulated device's history on first launch (no network).
    public func seedDemoHistoryIfNeeded() async throws {
        _ = try await reconcile()
        for (_, service) in services.sorted(by: { $0.key < $1.key }) {
            try await service.seedDemoHistoryIfNeeded()
        }
        for (_, meter) in meters.sorted(by: { $0.key < $1.key }) {
            try await meter.seedDemoIfNeeded()
        }
    }
}
