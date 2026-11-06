import Foundation
import Testing
@testable import DemoIntegration
@testable import HeatPumpKit
@testable import Integrations
@testable import MELCloudIntegration

@Suite("Integrations, capabilities and rate-limit policy")
struct IntegrationTests {
    let clock = TestClock()

    /// Only the thermostat: every optional capability is missing.
    actor ThermostatOnly: DeviceConnection, ThermostatDriver {
        nonisolated let identifier = "thermostat-only"
        let inner: MockBackend
        init(now: @escaping @Sendable () -> Date) { inner = MockBackend(timeZone: .gmt, now: now) }
        func login() async throws {}
        func listDevices() async throws -> [DeviceSummary] { try await inner.listDevices() }
        func fetchState(device: DeviceKey) async throws -> DeviceState { try await inner.fetchState(device: device) }
        func apply(_ changes: ChangeSet) async throws -> DeviceState? { try await inner.apply(changes) }
    }

    // MARK: Catalog

    @Test func catalogBuildsTheDemoServiceForMock() throws {
        let service = try IntegrationCatalog.makeService(
            environment: ["VARMEPUMPE_BACKEND": "mock", "VARMEPUMPE_DB_PATH": temporaryDatabasePath()])
        #expect(service.isDemo)
        #expect(service.backend is MockBackend)
        #expect(service.backend.identifier == "mock")
        #expect(service.credentials == nil)
        #expect(service.policy == .standard)
        #expect(IntegrationCatalog.isDemo(environment: ["VARMEPUMPE_BACKEND": "MOCK"]))
    }

    @Test func catalogBuildsMELCloudOtherwiseWithoutNetwork() throws {
        let service = try IntegrationCatalog.makeService(environment: ["VARMEPUMPE_DB_PATH": temporaryDatabasePath()])
        #expect(!service.isDemo)
        #expect(service.backend is MELCloudClassicBackend)
        #expect(service.backend.identifier == "melcloud-classic")
        #expect(service.credentials is KeychainCredentialStore)
        #expect(service.policy == .standard)
        #expect(!IntegrationCatalog.isDemo(environment: [:]))
    }

    @Test func catalogListsEachIntegrationOnce() {
        let ids = IntegrationCatalog.all.map(\.id)
        #expect(ids == ["melcloud-classic", "tibber", "demo", "demo-meter"])
        #expect(IntegrationCatalog.tibber.credentialFields.map(\.kind) == [.token])
        #expect(IntegrationCatalog.melcloud.displayName == "MELCloud")
        #expect(IntegrationCatalog.melcloud.credentialFields.map(\.kind) == [.email, .password])
        #expect(IntegrationCatalog.demo.credentialFields.isEmpty)
    }

    @Test func melcloudNeedsCredentials() throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        #expect(throws: HeatPumpError.missingCredentials) {
            try MELCloudIntegration().makeConnection(IntegrationContext(environment: [:], store: store))
        }
    }

    // MARK: Policy

    @Test func policyKeepsTodaysNumbers() {
        let policy = RateLimitPolicy.standard
        #expect(policy.maxAge == 10 * 60)
        #expect(policy.minRefreshInterval == 60)
        #expect(policy.reportInterval == 3600)
        #expect(policy.defaultLoginBlock == 30 * 60)
        #expect(policy.unauthorizedBlock == 3600)
        #expect(policy.maxWriteWait == 10)
        #expect(policy.writeBaseMaxAge == 60)
        #expect(policy.changeBudget == ChangeBudgetPolicy(maxChangesPerHour: 12, window: 3600, minSpacing: 5))
        #expect(ChangeBudget.maxChangesPerHour == 12)
        #expect(ChangeBudget.window == 3600)
        #expect(ChangeBudget.minSpacing == 5)
        #expect(MELCloudIntegration().rateLimitPolicy == .standard)
        #expect(DemoIntegration().rateLimitPolicy == .standard)
    }

    @Test func serviceUsesItsPolicyForTheRefreshSpacing() async throws {
        var policy = RateLimitPolicy.standard
        policy.minRefreshInterval = 300
        let service = HeatPumpService(
            backend: CountingBackend(now: clock.provider), store: try HistoryStore(path: temporaryDatabasePath()), policy: policy,
            timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        #expect(try await service.currentState().refreshed)
        clock.advance(120)
        let second = try await service.currentState(force: true)
        #expect(!second.refreshed)
        #expect(second.nextRefreshAllowed == clock.now.addingTimeInterval(180))
    }

    // MARK: Capabilities

    @Test func missingCapabilityThrowsTheOldError() async throws {
        let service = HeatPumpService(
            backend: ThermostatOnly(now: clock.provider), store: try HistoryStore(path: temporaryDatabasePath()), timeZone: .gmt,
            now: clock.provider, sleep: clock.sleeper)
        #expect(HeatPumpError.notSupported == .validation("Not supported by this connection."))
        #expect(throws: HeatPumpError.notSupported) { try service.driver((any AwayModesDriver).self) }
        #expect(throws: HeatPumpError.notSupported) { try service.driver((any FirmwareDriver).self) }
        #expect(service.weeklyTimerFormat == nil)
        _ = try await service.currentState()
        let away = try await service.awaySettings()
        #expect(away.message?.hasSuffix("Not supported by this connection.") == true)
        let reports = try await service.syncHistory()
        #expect(reports.allSatisfy { $0.status == .failed && $0.message == "Not supported by this connection." })
    }

    @Test func capabilitiesFollowConformances() {
        #expect(ThermostatOnly(now: clock.provider).capabilities == [.thermostat, .fanSpeed, .airflow])
        let melcloud = MELCloudClassicBackend(credentials: InMemoryCredentialStore(), transport: StubTransport())
        #expect(melcloud.capabilities == Set(Capability.allCases))
        #expect(MockBackend().capabilities == Set(Capability.allCases).subtracting([.location]))
    }

    // MARK: MELCloud answers what the service used to parse itself

    @Test func melcloudDriverReadsTheStoredListing() throws {
        let wrapper = try #require(MELCloudClassicParser.listedDevices(try Fixture.json("list_devices")).first)
        let backend = MELCloudClassicBackend(credentials: InMemoryCredentialStore(), transport: StubTransport())
        let location = try #require(backend.location(fromStoredListing: wrapper))
        #expect(location.latitude == 59.9139)
        #expect(location.longitude == 10.7522)
        #expect(backend.hardwareAddress(fromStoredListing: wrapper) == "00:00:5e:00:53:aa")
        let away = try #require(backend.awaySettings(fromStoredListing: wrapper))
        #expect(away == MELCloudClassicParser.awayFromListing(wrapper))
        #expect(away.frost == FrostProtection(enabled: false, minimum: 8, maximum: 12, defined: away.frost?.defined))
        #expect(backend.location(fromStoredListing: nil) == nil)
        #expect(backend.hardwareAddress(fromStoredListing: nil) == nil)
        #expect(backend.awaySettings(fromStoredListing: nil) == nil)
    }

    @Test func melcloudDriverDeclaresItsLimits() {
        let backend = MELCloudClassicBackend(credentials: InMemoryCredentialStore(), transport: StubTransport())
        #expect(backend.unknownModeProblem == MELCloudClassicParser.invalidModeMessage)
        #expect(backend.maxTemperatureLogDays == 7)
        #expect(backend.maxEnergyReportDays == 28)
        #expect(MockBackend().unknownModeProblem == nil)
        #expect(MockBackend().maxTemperatureLogDays == 7)
        #expect(MockBackend().maxEnergyReportDays == 28)
    }

    @Test func melcloudTimerFormatMatchesTheWireBody() throws {
        let timer = MELCloudClassicParser.weeklyTimer(try Fixture.json("timer_get2_seasons"))
        var edited = timer
        edited.seasons[0].events[0].setTemperature = 19.5
        let format = MELCloudTimerFormat()
        let body = MELCloudClassicParser.timerSetBody(timer: edited, deviceId: 7)
        let expected = MELCloudClassicParser.weeklyTimer(
            .object(["Enabled": body["TimerEnabled"] ?? .null, "Seasons": body["Seasons"] ?? .array([])]))
        #expect(format.savedForm(of: edited, device: .melcloud(7)) == expected)
        #expect(timer.events.allSatisfy(format.isAsRead))
        #expect(!format.isAsRead(edited.seasons[0].events[0]))
        #expect(edited.hasSameContent(as: format.savedForm(of: edited, device: .melcloud(7)), format: format))
        #expect(!edited.hasSameContent(as: timer, format: format))
    }
}
