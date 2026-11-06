import DemoIntegration
import Foundation
import HeatPumpKit
import MELCloudIntegration
import TibberIntegration

/// The only list of integrations, and the factory the app and the MCP helper start from.
public enum IntegrationCatalog {
    public static let melcloud = MELCloudIntegration()
    public static let tibber = TibberIntegration()
    public static let demo = DemoIntegration()
    public static let demoMeter = DemoMeterIntegration()

    public static let all: [any Integration] = [melcloud, tibber, demo, demoMeter]

    /// The simulated integrations (demo mode only; never offered to add).
    public static let simulated: Set<String> = [demo.id, demoMeter.id]

    /// True when `VARMEPUMPE_BACKEND=mock` selects the demo integration.
    public static func isDemo(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        IntegrationContext.demoRequested(environment: environment)
    }

    /// The integration this process runs: the demo for `VARMEPUMPE_BACKEND=mock`, otherwise MELCloud.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> any Integration {
        isDemo(environment: environment) ? demo : melcloud
    }

    /// The hub for this process. Demo mode (`VARMEPUMPE_BACKEND=mock`): the demo integration (and
    /// the simulated Tibber home for `VARMEPUMPE_DEMO_DEVICES=…,meter`) only, with simulated
    /// providers and the units `VARMEPUMPE_DEMO_DEVICES` asks for (registered at once, no network). Otherwise the active integrations the user chose (`integrations` in
    /// `app_settings`; MELCloud until then) with keychain credentials, real price, weather and house
    /// providers and the local adapter on the network. The database comes from
    /// `VARMEPUMPE_DB_PATH` or Application Support (demo mode: its own file there); it is opened
    /// with this process's integration, which owns the rows from before device keys. Outside demo
    /// mode MELCloud's blocks and spacing are also kept under the plain keys a 1.x helper still
    /// running across the update uses (`HistoryStore.legacyKeyMirror`; remove after 2.1).
    public static func makeHub(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> DeviceHub {
        let store = try HistoryStore(
            path: HistoryStore.defaultPath(environment: environment), legacyIntegration: current(environment: environment).id,
            legacyKeyMirror: isDemo(environment: environment) ? nil : melcloud.id)
        if isDemo(environment: environment) {
            let units = DemoUnit.units(environment: environment)
            try store.syncDevices(MockBackend.listing(units), integration: demo.id)
            let meter = DemoUnit.wantsMeter(environment: environment)
            if meter {
                try store.syncDevices(MockMeter.listing, integration: demoMeter.id)
                try store.setDeviceEnabled(true, device: MockMeter.device)
            } else if try store.devices().contains(where: { $0.key == MockMeter.device }) {
                try store.setDeviceEnabled(false, device: MockMeter.device)
            }
            let local = LocalAccess.simulated(shortCycling: environment["VARMEPUMPE_MOCK_CYCLING"] == "short")
            let simulated = [demo.id] + (meter ? [demoMeter.id] : [])
            return try DeviceHub(
                store: store, catalog: all, fixedIntegrations: simulated, defaultIntegrations: simulated, isDemo: true,
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
            // The token is read only when consumption is actually fetched (at most hourly); with an
            // enabled Tibber meter the meter's own hours are used instead.
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
