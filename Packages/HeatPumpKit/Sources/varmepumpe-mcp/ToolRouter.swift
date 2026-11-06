import Foundation
import HeatPumpKit
import MCP

/// Picks the device a tool call is about and hands the call to a `ToolHandler` for its service.
///
/// With one enabled device (or none yet) every call goes to the primary service, exactly as
/// before the hub: no `device` argument, no `list_devices`. With two or more, `device` (a key or a
/// name, case-insensitive) chooses; without it the one device that has the tool's capability
/// answers, and when several could, the call fails with the choices.
struct ToolRouter: Sendable {
    let hub: DeviceHub
    let approver: any ChangeApprover

    /// The catalog for the devices enabled now (the registry is read on every request).
    func tools() async -> [Tool] {
        let devices = (try? await hub.devices()) ?? []
        return ToolCatalog.tools(for: devices, service: await serviceNames(devices))
    }

    func handle(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            let devices = try await hub.devices()
            guard let primary = try await hub.primaryService() else {
                return ToolOutput.failure(L10n.tr("No heat pump service is set up. Sign in in the app."))
            }
            guard devices.count >= 2 else {
                return await ToolHandler(service: primary, approver: approver).handle(params)
            }
            if params.name == "list_devices" { return try await listDevices(devices, primary: primary) }
            guard let capability = ToolCatalog.requiredCapability[params.name] else {
                // Shared by every device (get_prices): price control's own device for its part.
                let control = try await hub.priceControlService()
                return await ToolHandler(service: primary, approver: approver, priceControlService: control).handle(params)
            }
            let device = try choose(devices, capability: capability, argument: Arguments(params.arguments).string("device"))
            guard let service = try await hub.heatPumpService(for: device.key) else {
                return ToolOutput.failure(L10n.format("Unknown device: %@. Choose one of: %@.", device.name, choices(devices)))
            }
            return await ToolHandler(service: service, approver: DeviceNamingApprover(base: approver, device: device.name))
                .handle(params)
        } catch let error as ArgumentError {
            return ToolOutput.failure(error.message)
        } catch {
            Log.error("\(params.name): \(error)")
            return ToolOutput.failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// The device `argument` names (key or name, case-insensitive), else the only device with
    /// `capability`.
    func choose(_ devices: [DeviceDescriptor], capability: Capability, argument: String?) throws -> DeviceDescriptor {
        let able = devices.filter { $0.capabilities.contains(capability) }
        if let argument = argument?.trimmingCharacters(in: .whitespacesAndNewlines), !argument.isEmpty {
            let wanted = argument.lowercased()
            guard
                let device = devices.first(where: { $0.key.rawValue.lowercased() == wanted })
                    ?? devices.first(where: { $0.name.lowercased() == wanted })
            else {
                throw ArgumentError(message: L10n.format("Unknown device: %@. Choose one of: %@.", argument, choices(devices)))
            }
            guard device.capabilities.contains(capability) else {
                throw ArgumentError(
                    message: L10n.format("%1$@ cannot answer this. Choose one of: %2$@.", device.name, choices(able.isEmpty ? devices : able)))
            }
            return device
        }
        switch able.count {
        case 0: throw ArgumentError(message: L10n.tr("None of the devices can answer this."))
        case 1: return able[0]
        default:
            throw ArgumentError(
                message: L10n.format("More than one device can answer this. Give device as one of: %@.", choices(able)))
        }
    }

    private func choices(_ devices: [DeviceDescriptor]) -> String {
        devices.map { "\($0.name) (\($0.key.rawValue))" }.joined(separator: ", ")
    }

    /// The service names the descriptions use: the active integrations' (one name with one).
    private func serviceNames(_ devices: [DeviceDescriptor]) async -> String {
        var names: [String] = []
        for device in devices {
            guard let name = hub.integration(for: device.key)?.displayName, !names.contains(name) else { continue }
            names.append(name)
        }
        if names.isEmpty, let primary = try? await hub.primaryService() { names = [primary.serviceName] }
        return names.joined(separator: " / ")
    }

    private func listDevices(_ devices: [DeviceDescriptor], primary: HeatPumpService) async throws -> CallTool.Result {
        struct Device: Encodable {
            var key: String
            var name: String
            var kind: String
            var integration: String
            var capabilities: [String]
            var online: Bool?
        }
        struct View: Encodable {
            var devices: [Device]
        }
        var views: [Device] = []
        for device in devices {
            let state = try? await hub.heatPumpService(for: device.key)?.cachedState()
            views.append(
                Device(
                    key: device.key.rawValue, name: device.name, kind: device.kind.rawValue,
                    integration: hub.integration(for: device.key)?.displayName ?? device.integrationId,
                    capabilities: device.capabilities.map(\.rawValue).sorted(), online: state.map { !$0.offline }))
        }
        return ToolOutput.json(Output(result: View(devices: views), meta: await Meta.current(service: primary)))
    }
}
