import Foundation
import HeatPumpKit

/// The user's Tibber homes as energy meters: hourly use and cost, and live power where a
/// real-time reader (Pulse, Watty) is paired. The reference example of an integration that is not
/// a heat pump: it supplies a connection (`TibberConnection`), its sign-in field, its limits and
/// its documents; the core does the rest (`EnergyMeterService`).
public struct TibberIntegration: Integration {
    public init() {}

    /// `Integration.id`; the integration part of every home's `DeviceKey` (`tibber:<home id>`). Persisted.
    public static let id = "tibber"
    static let displayName = "Tibber"
    /// Device metadata: whether the home has live data (`features.realTimeConsumptionEnabled`).
    static let realTimeKey = "realTime"
    /// Where a user creates a personal access token.
    public static let tokenURL = URL(string: "https://developer.tibber.com/settings/access-token")!  // constant literal

    public var id: String { Self.id }
    public var displayName: String { Self.displayName }
    public var vendorName: String { "Tibber" }
    public var unitDescription: String { "Tibber energy meter (the home's electricity use)" }
    public var setupSummary: String { L10n.tr("Your home's electricity use and cost per hour, and live power with Tibber Pulse.") }
    public var deviceKind: DeviceKind { .energyMeter }

    public var credentialFields: [CredentialField] {
        [CredentialField(id: "token", kind: .token, isSecret: true, helpURL: Self.tokenURL)]
    }

    /// The token the electricity price source already uses (`tibber-token`), so prices and the
    /// meter share one token and removing the integration keeps it for prices.
    public var credentialMapping: CredentialMapping {
        CredentialMapping(
            integrationId: Self.id, serviceName: Self.displayName,
            items: [CredentialMapping.Item(account: KeychainCredentialStore.tibberTokenAccount, fields: ["token"])], isShared: true)
    }

    /// Tibber allows about 100 requests per 5 minutes per IP. Homes are listed at most every
    /// 5 minutes (sign-in, "Refresh Device List") and daily for discovery, consumption hourly per
    /// home; there are no writes.
    public var rateLimitPolicy: RateLimitPolicy {
        RateLimitPolicy(
            maxAge: 3600, minRefreshInterval: 300, reportInterval: 3600, defaultLoginBlock: 30 * 60, unauthorizedBlock: 3600,
            maxWriteWait: 0, writeBaseMaxAge: 0, changeBudget: ChangeBudgetPolicy(maxChangesPerHour: 0, window: 3600, minSpacing: 0))
    }

    /// Meters have no error codes.
    public var errorCodes: any ErrorCodeExplaining { NoErrorCodes() }

    public var knowledge: KnowledgeSource {
        KnowledgeSource(names: ["energy-meter"], documents: KnowledgeContent.documents)
    }

    public func makeConnection(_ context: IntegrationContext) throws -> any DeviceConnection {
        guard let credentials = context.credentials else { throw HeatPumpError.missingCredentials }
        let mapping = credentialMapping
        return TibberConnection(
            token: { (try? credentials.loadValues(for: mapping))?["token"] },
            userAgent: TibberAPI.userAgent(version: HeatPumpService.appVersion), now: context.now)
    }
}
