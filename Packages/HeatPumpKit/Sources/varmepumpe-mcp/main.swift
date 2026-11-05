import Foundation
import HeatPumpKit
import MCP

let instructions = """
    Tools for the user's Mitsubishi MSZ-RW25VG wall heat pump (MELCloud Classic).
    Read tools are safe to call freely. Write tools (set_*) change the physical heat pump: \
    propose the change, explain why in plain Norwegian, and only call the tool after the user \
    explicitly agrees. Never chain several changes without asking. The user is not a heat-pump \
    expert; answer in Norwegian bokmål. Data may be cached: check meta.dataAgeSeconds and \
    meta.blockedUntil. MELCloud blocks accounts that poll too often, so do not call refresh repeatedly.
    """

let healthCheckPrompt = """
    Gjør en helsesjekk av varmepumpen. Steg:
    1. Kall get_status.
    2. Kall get_health_report.
    3. Kall get_error_log med days=90.
    4. Kall get_history for room_temperature og outdoor_temperature for de siste 7 dagene.
    5. Kall get_maintenance_status.

    Skriv deretter en kort, prioritert oppsummering på norsk bokmål for en som ikke kan noe om varmepumper:
    - **Dette er i orden**
    - **Dette bør gjøres nå** (med konkrete steg, og «ring forhandleren» når det trengs)
    - **Dette bør du følge med på**
    Nevn hvor gamle dataene er hvis de er eldre enn en time, og om MELCloud har blokkert oppdatering.
    Ikke endre noe på varmepumpen. Du kan foreslå endringer, men de skal bare utføres hvis brukeren sier ja.
    """

do {
    let service = try HeatPumpService.makeDefault()
    let capabilities = ClientCapabilities()
    let server = Server(
        name: "varmepumpe",
        version: "0.1.0",
        title: "Varmepumpe",
        instructions: instructions,
        capabilities: .init(
            prompts: .init(listChanged: false),
            resources: .init(subscribe: false, listChanged: false),
            tools: .init(listChanged: false)))
    let handler = ToolHandler(service: service, server: server, capabilities: capabilities)

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: ToolCatalog.all)
    }
    await server.withMethodHandler(CallTool.self) { params in
        await handler.handle(params)
    }
    await server.withMethodHandler(ListResources.self) { _ in
        ListResources.Result(
            resources: Knowledge.all().map {
                Resource(name: $0.name, uri: $0.uri, title: $0.title, description: "Kunnskapsdokument (norsk)", mimeType: "text/markdown")
            })
    }
    await server.withMethodHandler(ReadResource.self) { params in
        guard let name = params.uri.split(separator: "/").last.map(String.init),
            params.uri.hasPrefix("varmepumpe://knowledge/"),
            let document = Knowledge.document(named: name)
        else {
            throw MCPError.invalidParams("Ukjent ressurs: \(params.uri)")
        }
        return ReadResource.Result(contents: [.text(document.markdown, uri: document.uri, mimeType: "text/markdown")])
    }
    await server.withMethodHandler(ListPrompts.self) { _ in
        ListPrompts.Result(prompts: [
            Prompt(name: "helsesjekk", title: "Helsesjekk", description: "Full health check of the heat pump with a prioritized Norwegian summary.")
        ])
    }
    await server.withMethodHandler(GetPrompt.self) { params in
        guard params.name == "helsesjekk" else { throw MCPError.invalidParams("Ukjent prompt: \(params.name)") }
        return GetPrompt.Result(
            description: "Helsesjekk av varmepumpen",
            messages: [.user(.text(text: healthCheckPrompt))])
    }

    try await server.start(transport: StdioTransport()) { client, clientCapabilities in
        Log.info("client \(client.name) \(client.version), elicitation: \(clientCapabilities.elicitation != nil)")
        await capabilities.set(supportsElicitation: clientCapabilities.elicitation != nil)
    }
    Log.info("started (backend: \(service.backend.identifier), db: \(service.store.path))")
    await server.waitUntilCompleted()
} catch {
    Log.error("fatal: \(error)")
    exit(1)
}
