import HeatPumpKit
import SwiftUI

// Settings for two or more devices or integrations. With one heat pump none of this is shown.

/// One active integration (two or more): sign-in state, the sign-in form, sign out and remove.
struct IntegrationSection: View {
    @Environment(AppModel.self) private var app
    let integration: any Integration
    @State private var signedIn: Bool?
    @State private var confirmingRemove = false
    @State private var message: String?

    var body: some View {
        Section(integration.displayName) {
            if signedIn == true || app.credentialFields(for: integration).isEmpty {
                LabeledContent("Status") {
                    Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.Status.good)
                }
            } else if signedIn == false {
                LoginForm(integration: integration) { Task { await check() } }
            }
            HStack {
                if signedIn == true, !app.credentialFields(for: integration).isEmpty {
                    Button("Sign Out") {
                        Task {
                            await app.signOut(integration: integration)
                            await check()
                        }
                    }
                }
                Spacer()
                Button("Remove…", role: .destructive) { confirmingRemove = true }
            }
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.caution)
            }
        }
        .task { await check() }
        .confirmationDialog("Remove \(integration.displayName)?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) {
                Task { message = await app.removeIntegration(integration) }
            }
        } message: {
            if integration.credentialMapping.isShared {
                Text("The app stops fetching from \(integration.displayName). The token stays in the keychain, because the electricity price uses it too. The devices' history is kept and comes back if you add it again.")
            } else {
                Text("The sign-in is deleted from the keychain and the app stops fetching from \(integration.displayName). The devices' history is kept and comes back if you add it again.")
            }
        }
    }

    private func check() async {
        signedIn = await app.hasCredentials(integration: integration.id)
    }
}

/// Every device of the active integrations: its name (rename), kind, integration and whether
/// the app uses it.
struct DevicesSection: View {
    @Environment(AppModel.self) private var app
    let devices: [DeviceDescriptor]
    /// Rereads the list after a change.
    let reload: () async -> Void
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Section {
            ForEach(devices, id: \.key) { device in
                DeviceRow(device: device, reload: reload)
            }
            HStack {
                Button("Refresh Device List") {
                    Task {
                        working = true
                        message = await app.refreshDeviceList()
                        await reload()
                        working = false
                    }
                }
                .disabled(working)
                if working { ProgressView().controlSize(.small) }
            }
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.caution)
            }
        } header: {
            Text("Devices")
        } footer: {
            Text("A device that is turned off keeps its history; the app and Claude leave it alone until you turn it on again. Refreshing the list asks each service once, within its limits.")
        }
    }
}

private struct DeviceRow: View {
    @Environment(AppModel.self) private var app
    let device: DeviceDescriptor
    let reload: () async -> Void
    @State private var name = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.m) {
                IconBadge(systemImage: device.kind.systemImage, color: device.isEnabled ? .orange : .gray)
                TextField("Name", text: $name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit { Task { await rename() } }
                Spacer()
                Toggle(
                    "In use",
                    isOn: Binding(
                        get: { device.isEnabled },
                        set: { on in
                            Task {
                                message = await app.setEnabled(on, device: device.key)
                                await reload()
                            }
                        })
                )
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Whether the app and Claude use this device")
            }
            Text(verbatim: "\(device.kind.title) · \(app.hub?.integration(for: device.key)?.displayName ?? device.integrationId)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message {
                Text(message).font(.caption).foregroundStyle(Theme.Status.caution)
            }
        }
        .task(id: device.name) { name = device.name }
    }

    private func rename() async {
        guard name != device.name else { return }
        message = await app.rename(device.key, to: name)
        await reload()
    }
}

/// Choose an integration that is not in use yet and sign in to it.
struct AddIntegrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    let integrations: [any Integration]
    /// Dev only: `VARMEPUMPE_SETTINGS_SHEET=add-integration/<id>` opens on that integration.
    @State private var chosen: String? = ProcessInfo.processInfo.environment["VARMEPUMPE_SETTINGS_SHEET"]
        .flatMap { $0.hasPrefix("add-integration/") ? String($0.dropFirst("add-integration/".count)) : nil }
    /// Values already stored per integration (a token saved for the electricity price).
    @State private var stored: [String: [String: String]] = [:]

    var body: some View {
        let integration = integrations.first { $0.id == chosen } ?? integrations.first
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Label("Add Integration", systemImage: "plus.circle").font(.title2.bold())
            Text("Connect another service, so its devices show up in the app next to the ones you have.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if integrations.count > 1 {
                Picker("Service", selection: Binding(get: { integration?.id }, set: { chosen = $0 })) {
                    ForEach(integrations, id: \.id) { Text($0.displayName).tag(Optional($0.id)) }
                }
            } else if let integration {
                LabeledContent("Service") { Text(integration.displayName).font(.headline) }
            }
            if let integration {
                LoginForm(integration: integration, stored: stored[integration.id] ?? [:], adding: true) { dismiss() }
                    .id("\(integration.id)-\(stored[integration.id]?.isEmpty == false)")
                if stored[integration.id]?.isEmpty == false {
                    Text("The token you saved for the electricity price is filled in.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
        .task {
            for integration in integrations where stored[integration.id] == nil {
                stored[integration.id] = await app.storedValues(for: integration)
            }
        }
    }
}

/// Settings → Local connection: the device's own section; with two or more devices that have
/// one, a device picker on top.
struct LocalConnectionTab: View {
    @Environment(AppModel.self) private var app
    @Environment(HeatPumpDeviceModel.self) private var selected
    @State private var chosen: DeviceKey?

    var body: some View {
        let devices = DeviceUIRegistry.localConnectionDevices(app.devices)
        if devices.count >= 2 {
            let device = devices.first { $0.key == (chosen ?? selected.key) } ?? devices[0]
            VStack(spacing: 0) {
                Picker("Device", selection: Binding(get: { device.key }, set: { chosen = $0 })) {
                    ForEach(devices, id: \.key) { Text($0.displayName).tag($0.key) }
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.l)
                LocalSettingsView()
                    .environment(device)
                    .id(device.key)
            }
        } else {
            LocalSettingsView()
        }
    }
}

extension DeviceKind {
    var title: String {
        switch self {
        case .airToAirHeatPump: String(localized: "Air-to-air heat pump")
        case .energyMeter: String(localized: "Energy meter")
        case .airQualitySensor: String(localized: "Air quality sensor")
        }
    }

    var systemImage: String {
        switch self {
        case .airToAirHeatPump: "fan.fill"
        case .energyMeter: "bolt.fill"
        case .airQualitySensor: "aqi.medium"
        }
    }
}
