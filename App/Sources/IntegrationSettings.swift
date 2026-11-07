import HeatPumpKit
import SwiftUI

// Settings for services and devices: Add Device, Settings → Devices, and the per-integration
// sections of the Account tab with two or more integrations.

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
                IconBadge(systemImage: device.kind.systemImage, color: device.isEnabled ? device.kind.color : .gray)
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

/// Add Device: choose the service the equipment uses, sign in once, see what was found. Opened
/// from the sidebar, File → Add Device…, Settings → Devices and the electricity price tab.
struct AddDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var chosen: String?
    /// Values already stored per integration (a token saved for the electricity price).
    @State private var stored: [String: [String: String]] = [:]
    /// The devices the sign-in found; set once it succeeded.
    @State private var found: [DeviceDescriptor]?
    /// Whether to show the found device in the main window when closing (not from Settings).
    var showsDeviceOnDone = true

    init(choosing id: String? = nil, showsDeviceOnDone: Bool = true) {
        _chosen = State(initialValue: id)
        self.showsDeviceOnDone = showsDeviceOnDone
    }

    var body: some View {
        let integration = app.setupIntegrations.first { $0.id == chosen }
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Label("Add Device", systemImage: "plus.circle").font(.title2.bold())
            if let found, let integration {
                foundView(found, integration: integration)
            } else if let integration {
                signInView(integration)
            } else {
                chooserView
            }
            HStack {
                if found == nil, integration != nil {
                    Button("All Services", systemImage: "chevron.left") { chosen = nil }
                }
                Spacer()
                if found != nil {
                    Button("Done") { finish() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 500)
        .task {
            await app.loadIntegrations()
            for integration in app.setupIntegrations where stored[integration.id] == nil {
                stored[integration.id] = await app.storedValues(for: integration)
            }
        }
    }

    // MARK: Choose

    private var chooserView: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Choose the service your equipment uses. You sign in once, and every device on the account shows up in the sidebar.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(app.setupIntegrations, id: \.id) { integration in
                ServiceChoiceRow(integration: integration, connected: app.isActive(integration)) { chosen = integration.id }
            }
        }
    }

    // MARK: Sign in

    private func signInView(_ integration: any Integration) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ServiceHeader(integration: integration)
            Divider()
            if app.isActive(integration) {
                Label("\(integration.displayName) is already connected. Its devices are in the sidebar and under Settings → Devices.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Status.good)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LoginForm(integration: integration, stored: stored[integration.id] ?? [:], adding: true) {
                    Task { found = await app.allDevices().filter { $0.integrationId == integration.id } }
                }
                .id("\(integration.id)-\(stored[integration.id]?.isEmpty == false)")
                if stored[integration.id]?.isEmpty == false {
                    Text("The token you saved for the electricity price is filled in.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Found

    private func foundView(_ devices: [DeviceDescriptor], integration: any Integration) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label("Connected to \(integration.displayName)", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(Theme.Status.good)
            ForEach(devices, id: \.key) { device in
                HStack(spacing: Theme.Space.m) {
                    IconBadge(systemImage: device.kind.systemImage, color: device.kind.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: device.name).font(.body.weight(.medium))
                        Text(device.kind.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("The devices are in the sidebar. Rename them or turn them off under Settings → Devices.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func finish() {
        if showsDeviceOnDone, let key = found?.first(where: \.isEnabled)?.key {
            app.route = .device(key, .overview)
        }
        dismiss()
    }
}

/// A service in the Add Device list: icon, name, what it brings, and whether it is connected.
private struct ServiceChoiceRow: View {
    let integration: any Integration
    let connected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                IconBadge(systemImage: integration.deviceKind.systemImage, color: integration.deviceKind.color, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: integration.displayName).font(.headline)
                    Text(integration.setupSummary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.m)
                if connected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(Theme.Status.good)
                } else {
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: integration.displayName))
        .accessibilityHint(Text(integration.setupSummary))
    }
}

/// The chosen service above its sign-in form.
private struct ServiceHeader: View {
    let integration: any Integration

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            IconBadge(systemImage: integration.deviceKind.systemImage, color: integration.deviceKind.color, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: integration.displayName).font(.headline)
                Text(integration.setupSummary).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Settings → Devices: the services (connected or not) and every device, with Add Device.
struct DevicesSettings: View {
    @Environment(AppModel.self) private var app
    @State private var allDevices: [DeviceDescriptor] = []
    @State private var adding = false
    /// Dev only (screenshots): `VARMEPUMPE_SETTINGS_SHEET=add-integration` or `add-integration/<id>`.
    @State private var choice: String? = ProcessInfo.processInfo.environment["VARMEPUMPE_SETTINGS_SHEET"]
        .flatMap { $0.hasPrefix("add-integration/") ? String($0.dropFirst("add-integration/".count)) : nil }

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                ForEach(app.setupIntegrations, id: \.id) { integration in
                    serviceRow(integration)
                }
            } header: {
                HStack {
                    Text("Services")
                    Spacer()
                    Button("Add Device…", systemImage: "plus") { open(nil) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            } footer: {
                Text("Sign in once per service; every device on the account shows up. Sign-ins are stored in the keychain on this Mac.")
            }
            if !allDevices.isEmpty {
                DevicesSection(devices: allDevices) { allDevices = await app.allDevices() }
            }
        }
        .formStyle(.grouped)
        .task(id: app.devices.count) {
            await app.loadIntegrations()
            allDevices = await app.allDevices()
        }
        .task {
            if ProcessInfo.processInfo.environment["VARMEPUMPE_SETTINGS_SHEET"]?.hasPrefix("add-integration") == true { adding = true }
        }
        .sheet(isPresented: $adding, onDismiss: { Task { allDevices = await app.allDevices() } }) {
            AddDeviceSheet(choosing: choice, showsDeviceOnDone: false)
        }
    }

    private func serviceRow(_ integration: any Integration) -> some View {
        HStack(spacing: Theme.Space.m) {
            IconBadge(systemImage: integration.deviceKind.systemImage, color: integration.deviceKind.color, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: integration.displayName).font(.headline)
                Text(integration.setupSummary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            if app.isActive(integration) {
                let count = allDevices.filter { $0.integrationId == integration.id }.count
                VStack(alignment: .trailing, spacing: 2) {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.Status.good)
                    Button("Manage…") { app.settingsTab = "konto" }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Sign-in, sign out and remove are on the Account tab")
                    if count > 0 {
                        Text("\(count) devices").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Button("Connect…") { open(integration.id) }
            }
        }
    }

    private func open(_ id: String?) {
        choice = id
        adding = true
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

    var color: Color {
        switch self {
        case .airToAirHeatPump: .orange
        case .energyMeter: .indigo
        case .airQualitySensor: .teal
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
