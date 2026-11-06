import Foundation
import MCP
import Testing
@testable import DemoIntegration
@testable import HeatPumpKit
@testable import MELCloudIntegration
@testable import varmepumpe_mcp

@Suite("MCP catalog and device choice")
struct MCPCatalogTests {
    let clock = TestClock()
    let living = DemoUnit.unit(0).key
    let bedroom = DemoUnit.unit(1).key

    /// JSON with sorted keys, so encodings compare regardless of key order.
    func canonical(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }

    func canonical<T: Encodable>(_ value: T) throws -> String { try canonical(try JSONEncoder().encode(value)) }

    /// `tools/list` and the instructions as the helper answered them before the hub (demo mode,
    /// English), captured from the previous build.
    func golden() throws -> (instructions: String, tools: String) {
        let object = try #require(try JSONSerialization.jsonObject(with: Fixture.data("mcp_catalog_one_device")) as? [String: Any])
        let tools = try JSONSerialization.data(withJSONObject: try #require(object["tools"]))
        return (try #require(object["instructions"] as? String), try canonical(tools))
    }

    func descriptor(_ key: DeviceKey, _ name: String) -> DeviceDescriptor {
        DeviceDescriptor(key: key, name: name, kind: .airToAirHeatPump, capabilities: MockBackend(units: [.unit(0)]).capabilities)
    }

    @Test(.enabled(if: L10n.language == .english)) func oneDeviceKeepsTheCatalogAndInstructions() throws {
        let golden = try golden()
        let integration = DemoIntegration()
        #expect(try canonical(ToolCatalog.tools(for: [], service: integration.displayName)) == golden.tools)
        #expect(try canonical(ToolCatalog.tools(for: [descriptor(living, "Stue")], service: integration.displayName)) == golden.tools)
        #expect(instructions(for: integration) == golden.instructions)
        #expect(instructions(for: integration, devices: [descriptor(living, "Stue")]) == golden.instructions)
        // MELCloud's own unit has every capability the tools need too.
        let melcloud = MELCloudClassicBackend(credentials: InMemoryCredentialStore())
        #expect(ToolCatalog.requiredCapability.values.allSatisfy(melcloud.capabilities.contains))
    }

    @Test func twoDevicesAddTheDeviceArgumentAndListDevices() throws {
        let tools = ToolCatalog.tools(for: [descriptor(living, "Stue"), descriptor(bedroom, "Soverom")], service: "MELCloud")
        #expect(tools.first?.name == "list_devices")
        #expect(tools.count == ToolCatalog.all(service: "MELCloud").count + 1)
        for tool in tools {
            let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            let isDeviceTool = ToolCatalog.requiredCapability[tool.name] != nil
            #expect((properties["device"] != nil) == isDeviceTool, "\(tool.name)")
        }
        // Schemas otherwise unchanged.
        let before = Dictionary(uniqueKeysWithValues: ToolCatalog.all(service: "MELCloud").map { ($0.name, $0) })
        let status = try #require(tools.first { $0.name == "set_temperature" })
        #expect(status.inputSchema.objectValue?["required"] == before["set_temperature"]?.inputSchema.objectValue?["required"])
        #expect(status.description == before["set_temperature"]?.description)
        let text = instructions(for: DemoIntegration(), devices: [descriptor(living, "Stue"), descriptor(bedroom, "Soverom")])
        #expect(text.hasPrefix("Tools for the user's 2 devices: Stue (demo:100001"))
        #expect(text.contains("list_devices"))
    }

    @Test func toolsNeedAtLeastOneDeviceWithTheCapability() {
        var meter = descriptor(bedroom, "Meter")
        meter.capabilities = [.energyLog]
        let names = Set(ToolCatalog.tools(for: [meter], service: "X").map(\.name))
        #expect(names.contains("get_energy") && names.contains("get_prices"))
        #expect(!names.contains("set_temperature") && !names.contains("get_weekly_timer"))
    }

    @Test func choosingTheDevice() throws {
        let router = ToolRouter(hub: try makeHub(), approver: FixedApprover(.approved))
        let devices = [descriptor(living, "Living room (simulated)"), descriptor(bedroom, "Bedroom (simulated)")]
        #expect(try router.choose(devices, capability: .thermostat, argument: "BEDROOM (simulated)").key == bedroom)
        #expect(try router.choose(devices, capability: .thermostat, argument: "demo:100001").key == living)
        #expect(throws: ArgumentError.self) { try router.choose(devices, capability: .thermostat, argument: "kitchen") }
        do {
            _ = try router.choose(devices, capability: .thermostat, argument: nil)
            Issue.record("expected an ambiguity error")
        } catch let error as ArgumentError {
            #expect(error.message.contains("Living room (simulated) (demo:100001), Bedroom (simulated) (demo:100002)"))
        }
        var meter = devices[1]
        meter.capabilities = [.energyLog]
        #expect(try router.choose([devices[0], meter], capability: .thermostat, argument: nil).key == living)
    }

    func makeHub() throws -> DeviceHub {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider, units: [.unit(0), .unit(1)])
        try store.syncDevices(backend.listing, integration: DemoIntegration.id)
        return try DeviceHub(
            store: store, catalog: [DemoIntegration()], fixedIntegrations: [DemoIntegration.id],
            defaultIntegrations: [DemoIntegration.id], isDemo: true, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper,
            makeRuntime: { IntegrationRuntime(integration: $0, connection: backend) })
    }

    func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
    }

    @Test func toolCallsGoToTheChosenDevice() async throws {
        let router = ToolRouter(hub: try makeHub(), approver: FixedApprover(.approved))
        let names = await router.tools().map(\.name)
        #expect(names.first == "list_devices")

        let ambiguous = await router.handle(CallTool.Parameters(name: "get_status", arguments: [:]))
        #expect(ambiguous.isError == true)
        #expect(text(ambiguous).contains("demo:100002"))

        let status = await router.handle(CallTool.Parameters(name: "get_status", arguments: ["device": "bedroom (simulated)"]))
        #expect(status.isError != true)
        #expect(text(status).contains(#""setTemperature":19"#))  // the bedroom's setpoint

        let list = await router.handle(CallTool.Parameters(name: "list_devices", arguments: [:]))
        #expect(text(list).contains(#""key":"demo:100002""#))
        #expect(text(list).contains(#""online":true"#))

        let prices = await router.handle(CallTool.Parameters(name: "get_prices", arguments: [:]))
        #expect(prices.isError != true)
    }
}
