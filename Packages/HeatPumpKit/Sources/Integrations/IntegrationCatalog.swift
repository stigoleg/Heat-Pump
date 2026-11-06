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

    /// The service for this process: the demo integration with simulated providers for
    /// `VARMEPUMPE_BACKEND=mock`, otherwise MELCloud with keychain credentials, real price, weather
    /// and house providers and the local adapter on the network. The database comes from
    /// `VARMEPUMPE_DB_PATH` or Application Support. The store is opened with this process's
    /// integration, which owns the rows from before device keys.
    public static func makeService(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> HeatPumpService {
        let store = try HistoryStore(
            path: HistoryStore.defaultPath(environment: environment), legacyIntegration: current(environment: environment).id)
        if isDemo(environment: environment) {
            let context = IntegrationContext(environment: environment, store: store)
            return HeatPumpService(
                backend: try demo.makeConnection(context), store: store, integration: demo, policy: demo.rateLimitPolicy,
                priceProvider: { _ in MockPriceProvider() },
                local: .simulated(shortCycling: environment["VARMEPUMPE_MOCK_CYCLING"] == "short"),
                weatherProvider: { _ in MockWeatherProvider() }, houseProvider: { MockHouseConsumptionProvider() })
        }
        let credentials = KeychainCredentialStore(environment: environment, mappings: all.map(\.credentialMapping))
        let context = IntegrationContext(environment: environment, store: store, credentials: credentials)
        return HeatPumpService(
            backend: try melcloud.makeConnection(context), store: store, credentials: credentials, integration: melcloud,
            policy: melcloud.rateLimitPolicy,
            priceProvider: { settings in
                switch settings.agreement {
                case .norgespris: return nil
                case .spot: return HvaKosterStrommenProvider(area: settings.area)
                case .tibber:
                    // Read only when prices are actually fetched (at most hourly).
                    return credentials.loadTibberToken().map { TibberPriceProvider(token: $0) }
                }
            }, local: .network,
            weatherProvider: { settings in
                METForecastProvider(
                    userAgent: METForecastProvider.userAgent(version: HeatPumpService.appVersion, contact: settings.contactEmail))
            },
            // The token is read only when consumption is actually fetched (at most hourly).
            houseProvider: { credentials.loadTibberToken().map { TibberConsumptionProvider(token: $0) } })
    }
}
