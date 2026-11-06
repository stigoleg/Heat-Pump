import AppKit
import Foundation
import HeatPumpKit
import Integrations
import MCP

let instructions = """
    Tools for the user's Mitsubishi MSZ-RW25VG wall heat pump (MELCloud Classic).
    Read tools are safe to call freely. Write tools (set_*) change the physical heat pump: \
    propose the change, explain why in plain words, and only call the tool after the user \
    agrees in the conversation. Each set_* call then opens a confirmation dialog on the user's Mac \
    ("\(L10n.tr("Approve"))"/"\(L10n.tr("Reject"))", rejected after 120 s without an answer); the change is only sent if the \
    user clicks \(L10n.tr("Approve")). Never chain several changes without asking. The user is not a heat-pump \
    expert; answer in the user's language (the app and its texts are set to \(L10n.language == .norwegian ? "Norwegian bokmål" : "English")). \
    Data may be cached: check meta.dataAgeSeconds and \
    meta.blockedUntil. MELCloud blocks accounts that poll too often, so do not call refresh repeatedly. \
    When local access is on, get_live_status gives live power (W), compressor activity and starts per \
    hour straight from the adapter on the home network (read-only); use it for "what is it doing now" \
    (heating, resting, defrosting). get_forecast combines the MET Norway forecast with prices and an \
    estimate for tomorrow; get_house_consumption shows the heat pump's share of the house (Tibber). \
    Frost protection and holiday mode (get_away_settings, set_frost_protection, set_holiday_mode) are \
    bigger changes: explain what happens and get a clear yes first. Weather data: MET Norway (CC BY 4.0).
    """

let healthCheckPrompt = L10n.tr(
    "Do a health check of the heat pump. Steps:\n1. Call get_status.\n2. Call get_health_report.\n3. Call get_error_log with days=90.\n4. Call get_history for room_temperature and outdoor_temperature for the last 7 days.\n5. Call get_maintenance_status.\n6. Call get_live_status (only returns data if the local connection is turned on; otherwise skip it).\n\nThen write a short, prioritized summary in English for someone who knows nothing about heat pumps:\n- **This is fine**\n- **This should be done now** (with concrete steps, and “call the dealer” when needed)\n- **Keep an eye on this**\nMention how old the data is if it is older than an hour, and whether MELCloud has blocked refreshing.\nDo not change anything on the heat pump. You may suggest changes, but they should only be carried out if the user says yes."
)

// The helper is an accessory AppKit app (no Dock icon) so it can show its own approval
// dialog. AppKit runs the main thread; the MCP server runs in a task.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let service: HeatPumpService
do {
    service = try IntegrationCatalog.makeService()
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
        try await runServer(service: service, approver: approver)
    } catch {
        Log.error("fatal: \(error)")
        exit(1)
    }
    exit(0)
}
application.run()

func runServer(service: HeatPumpService, approver: any ChangeApprover) async throws {
    let server = Server(
        name: "varmepumpe",
        version: "0.2.0",
        title: L10n.tr("Heat Pump"),
        instructions: instructions,
        capabilities: .init(
            prompts: .init(listChanged: false),
            resources: .init(subscribe: false, listChanged: false),
            tools: .init(listChanged: false)))
    let handler = ToolHandler(service: service, approver: approver)

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: ToolCatalog.all)
    }
    await server.withMethodHandler(CallTool.self) { params in
        await handler.handle(params)
    }
    await server.withMethodHandler(ListResources.self) { _ in
        ListResources.Result(
            resources: Knowledge.all().map {
                Resource(name: $0.name, uri: $0.uri, title: $0.title, description: L10n.tr("Knowledge document"), mimeType: "text/markdown")
            })
    }
    await server.withMethodHandler(ReadResource.self) { params in
        guard let name = params.uri.split(separator: "/").last.map(String.init),
            params.uri.hasPrefix("varmepumpe://knowledge/"),
            let document = Knowledge.document(named: name)
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
            messages: [.user(.text(text: healthCheckPrompt))])
    }

    try await server.start(transport: StdioTransport()) { client, _ in
        Log.info("client \(client.name) \(client.version)")
    }
    Log.info("started (backend: \(service.backend.identifier), db: \(service.store.path))")
    await server.waitUntilCompleted()
}
