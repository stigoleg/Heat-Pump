import AppKit
import Foundation
import HeatPumpKit
import Integrations
import MCP

/// The server instructions; the integration names the unit and the service. With two or more
/// devices they list them and explain the `device` argument.
func instructions(for integration: any Integration, devices: [DeviceDescriptor] = [], hub: DeviceHub? = nil) -> String {
    guard devices.count >= 2 else { return baseInstructions(for: integration) }
    let list = devices.map { device in
        let unit = hub?.integration(for: device.key)?.unitDescription ?? device.kind.rawValue
        return "\(device.name) (\(device.key.rawValue), \(unit))"
    }
    let meter =
        devices.contains { $0.kind == .energyMeter }
        ? " get_meter_status gives the home's energy meter: live power and today's use and cost; get_house_consumption reads the house's use from it." : ""
    let air =
        devices.contains { $0.kind == .airQualitySensor }
        ? " get_air_quality gives the indoor air quality sensors' newest values (radon, CO2, humidity, …) with levels and advice; get_air_quality_history their hourly history. Judge radon by the long-term average, not a single short-term value."
        : ""
    return baseInstructions(for: integration, opening: "Tools for the user's \(devices.count) devices: \(list.joined(separator: "; ")).")
        + " " + """
        Every tool about a device takes an optional device argument: the device's key or name from \
        list_devices. When it is left out and more than one device could answer, the tool returns an \
        error listing the choices; ask the user which device they mean when it is not clear. get_prices \
        is shared by all devices.
        """ + meter + air
}

private func baseInstructions(for integration: any Integration, opening: String? = nil) -> String {
    """
    \(opening ?? "Tools for the user's \(integration.unitDescription).")
    Read tools are safe to call freely. Write tools (set_*) change the physical heat pump: \
    propose the change, explain why in plain words, and only call the tool after the user \
    agrees in the conversation. Each set_* call then opens a confirmation dialog on the user's Mac \
    ("\(L10n.tr("Approve"))"/"\(L10n.tr("Reject"))", rejected after 120 s without an answer); the change is only sent if the \
    user clicks \(L10n.tr("Approve")). Never chain several changes without asking. The user is not a heat-pump \
    expert; answer in the user's language (the app and its texts are set to \(L10n.language == .norwegian ? "Norwegian bokmål" : "English")). \
    Data may be cached: check meta.dataAgeSeconds and \
    meta.blockedUntil. \(integration.displayName) blocks accounts that poll too often, so do not call refresh repeatedly. \
    When local access is on, get_live_status gives live power (W), compressor activity and starts per \
    hour straight from the adapter on the home network (read-only); use it for "what is it doing now" \
    (heating, resting, defrosting). get_forecast combines the MET Norway forecast with prices and an \
    estimate for tomorrow; get_house_consumption shows the heat pump's share of the house (Tibber). \
    Frost protection and holiday mode (get_away_settings, set_frost_protection, set_holiday_mode) are \
    bigger changes: explain what happens and get a clear yes first. Weather data: MET Norway (CC BY 4.0).
    """
}

func healthCheckPrompt(serviceName: String) -> String {
    L10n.format(
        "Do a health check of the heat pump. Steps:\n1. Call get_status.\n2. Call get_health_report.\n3. Call get_error_log with days=90.\n4. Call get_history for room_temperature and outdoor_temperature for the last 7 days.\n5. Call get_maintenance_status.\n6. Call get_live_status (only returns data if the local connection is turned on; otherwise skip it).\n\nThen write a short, prioritized summary in English for someone who knows nothing about heat pumps:\n- **This is fine**\n- **This should be done now** (with concrete steps, and “call the dealer” when needed)\n- **Keep an eye on this**\nMention how old the data is if it is older than an hour, and whether %@ has blocked refreshing.\nDo not change anything on the heat pump. You may suggest changes, but they should only be carried out if the user says yes.",
        serviceName)
}

// The helper is an accessory AppKit app (no Dock icon) so it can show its own approval
// dialog. AppKit runs the main thread; the MCP server runs in a task.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let hub: DeviceHub
do {
    hub = try IntegrationCatalog.makeHub()
} catch {
    Log.error("fatal: \(error)")
    exit(1)
}
let environment = ProcessInfo.processInfo.environment
let approver = ApprovalPolicy.approver(environment: environment, interactive: DialogApprover())
if !(approver is DialogApprover) {
    Log.info("VARMEPUMPE_APPROVAL=\(environment["VARMEPUMPE_APPROVAL"] ?? "") with mock backend: approval dialog bypassed (dev only)")
}

Task {
    do {
        try await runServer(hub: hub, approver: approver)
    } catch {
        Log.error("fatal: \(error)")
        exit(1)
    }
    exit(0)
}
application.run()

func runServer(hub: DeviceHub, approver: any ChangeApprover) async throws {
    guard let service = try await hub.primaryService() else {
        Log.error("fatal: no active integration")
        exit(1)
    }
    let server = Server(
        name: "varmepumpe",
        version: "0.2.0",
        title: L10n.tr("Heat Pump"),
        instructions: instructions(for: service.integration, devices: try await hub.devices(), hub: hub),
        capabilities: .init(
            prompts: .init(listChanged: false),
            resources: .init(subscribe: false, listChanged: false),
            tools: .init(listChanged: false)))
    let router = ToolRouter(hub: hub, approver: approver)
    // The heat pump's documents, then those of an enabled meter's or sensor's integration.
    var integrations: [any Integration] = [service.integration]
    for device in try await hub.devices() where device.kind != .airToAirHeatPump {
        if let integration = hub.integration(for: device.key), !integrations.contains(where: { $0.id == integration.id }) {
            integrations.append(integration)
        }
    }
    let knowledge = Knowledge(integrations: integrations)

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: await router.tools())
    }
    await server.withMethodHandler(CallTool.self) { params in
        await router.handle(params)
    }
    await server.withMethodHandler(ListResources.self) { _ in
        ListResources.Result(
            resources: knowledge.all().map {
                Resource(name: $0.name, uri: $0.uri, title: $0.title, description: L10n.tr("Knowledge document"), mimeType: "text/markdown")
            })
    }
    await server.withMethodHandler(ReadResource.self) { params in
        guard let name = params.uri.split(separator: "/").last.map(String.init),
            params.uri.hasPrefix("varmepumpe://knowledge/"),
            let document = knowledge.document(named: name)
        else {
            throw MCPError.invalidParams(L10n.format("Unknown resource: %@", params.uri))
        }
        return ReadResource.Result(contents: [.text(document.markdown, uri: document.uri, mimeType: "text/markdown")])
    }
    await server.withMethodHandler(ListPrompts.self) { _ in
        ListPrompts.Result(prompts: [
            Prompt(
                name: "helsesjekk", title: L10n.tr("Health check"),
                description: L10n.tr("Full health check of the heat pump with a prioritized summary."))
        ])
    }
    await server.withMethodHandler(GetPrompt.self) { params in
        guard params.name == "helsesjekk" else { throw MCPError.invalidParams(L10n.format("Unknown prompt: %@", params.name)) }
        return GetPrompt.Result(
            description: L10n.tr("Health check of the heat pump"),
            messages: [.user(.text(text: healthCheckPrompt(serviceName: service.serviceName)))])
    }

    try await server.start(transport: StdioTransport()) { client, _ in
        Log.info("client \(client.name) \(client.version)")
    }
    Log.info("started (backend: \(service.backend.identifier), db: \(service.store.path))")
    await server.waitUntilCompleted()
}
