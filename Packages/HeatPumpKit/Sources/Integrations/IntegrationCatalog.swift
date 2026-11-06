import DemoIntegration
import Foundation
import HeatPumpKit
import MELCloudIntegration

/// The only list of integrations, and the factory the app and the MCP helper start from.
public enum IntegrationCatalog {
    public static let melcloud = MELCloudIntegration()
    public static let demo = DemoIntegration()

    public static let all: [any Integration] = [melcloud, demo]

    /// True when `VARMEPUMPE_BACKEND=mock` selects the demo integration.
    public static func isDemo(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        IntegrationContext.demoRequested(environment: environment)
    }

    /// The integration this process runs: the demo for `VARMEPUMPE_BACKEND=mock`, otherwise MELCloud.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> any Integration {
        isDemo(environment: environment) ? demo : melcloud
    }

    /// The hub for this process. Demo mode (`VARMEPUMPE_BACKEND=mock`): the demo integration only,
    /// with simulated providers and the units `VARMEPUMPE_DEMO_DEVICES` asks for (registered at
    /// once, no network). Otherwise the active integrations the user chose (`integrations` in
    /// `app_settings`; MELCloud until then) with keychain credentials, real price, weather and house
    /// providers and the local adapter on the network. The database comes from
    /// `VARMEPUMPE_DB_PATH` or Application Support; it is opened with this process's integration,
    /// which owns the rows from before device keys.
    public static func makeHub(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> DeviceHub {
        let store = try HistoryStore(
            path: HistoryStore.defaultPath(environment: environment), legacyIntegration: current(environment: environment).id)
        if isDemo(environment: environment) {
            let units = DemoUnit.units(environment: environment)
            try store.syncDevices(MockBackend.listing(units), integration: demo.id)
            let local = LocalAccess.simulated(shortCycling: environment["VARMEPUMPE_MOCK_CYCLING"] == "short")
            return try DeviceHub(
                store: store, catalog: all, fixedIntegrations: [demo.id], defaultIntegrations: [demo.id], isDemo: true,
                priceProvider: { _ in MockPriceProvider() }, weatherProvider: { _ in MockWeatherProvider() },
                houseProvider: { MockHouseConsumptionProvider() },
                makeRuntime: { integration in
                    let context = IntegrationContext(environment: environment, store: store)
                    return IntegrationRuntime(integration: integration, connection: try integration.makeConnection(context), local: local)
                })
        }
        let credentials = KeychainCredentialStore(environment: environment, mappings: all.map(\.credentialMapping))
        return try DeviceHub(
            store: store, catalog: all, defaultIntegrations: [melcloud.id],
            priceProvider: { settings in
                switch settings.agreement {
                case .norgespris: return nil
                case .spot: return HvaKosterStrommenProvider(area: settings.area)
                case .tibber:
                    // Read only when prices are actually fetched (at most hourly).
                    return credentials.loadTibberToken().map { TibberPriceProvider(token: $0) }
                }
            },
            weatherProvider: { settings in
                METForecastProvider(
                    userAgent: METForecastProvider.userAgent(version: HeatPumpService.appVersion, contact: settings.contactEmail))
            },
            // The token is read only when consumption is actually fetched (at most hourly).
            houseProvider: { credentials.loadTibberToken().map { TibberConsumptionProvider(token: $0) } },
            makeRuntime: { integration in
                let context = IntegrationContext(environment: environment, store: store, credentials: credentials)
                let local: LocalAccess =
                    switch integration.id {
                    case melcloud.id: .network
                    case demo.id: .simulated(shortCycling: false)
                    default: .unavailable
                    }
                return IntegrationRuntime(
                    integration: integration, connection: try integration.makeConnection(context), credentials: credentials, local: local)
            })
    }

    /// The primary device's service of `makeHub` (what the app and the helper served before the
    /// hub). Kept for code that runs one device only.
    public static func makeService(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> HeatPumpService {
        guard let service = try makeHub(environment: environment).primaryAtLaunch else { throw HeatPumpError.deviceNotFound }
        return service
    }
}
