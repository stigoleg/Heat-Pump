import AppKit
import HeatPumpKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            Tab("General", systemImage: "gearshape", value: "generelt") { GeneralSettings() }
            Tab("Account", systemImage: "person.crop.circle", value: "konto") { AccountSettings() }
            Tab("Electricity price", systemImage: "bolt.horizontal.circle", value: "strompris") { PriceSettingsView() }
            // The local connection is the integration's own section (MELCloud's adapter on the
            // home network), shown while a device has it.
            if !DeviceUIRegistry.localConnectionDevices(model.devices).isEmpty {
                Tab("Local connection", systemImage: "wifi.router", value: "lokal") { LocalConnectionTab() }
            }
            Tab("Weather", systemImage: "cloud.sun", value: "vaer") { WeatherSettingsView() }
            Tab("Claude", systemImage: "sparkles", value: "claude") { ClaudeSettings() }
            Tab("Data", systemImage: "externaldrive", value: "data") { DataSettings() }
        }
        // Resizable down to 560 × 480; opens at the ideal size.
        .frame(minWidth: 560, idealWidth: 700, maxWidth: .infinity, minHeight: 480, idealHeight: 600, maxHeight: .infinity)
        .background(ResizableWindow())
        // The device shown in the main window, or the only one.
        .environment(model.selectedHeatPump)
    }
}

/// An integration's sign-in fields (`CredentialField`) → one login and state fetch through the
/// hub. MELCloud's are e-mail and password.
struct LoginForm: View {
    @Environment(AppModel.self) private var model
    let integration: any Integration
    /// Adds the integration (Add Integration…) instead of signing in to an active one.
    var adding = false
    @State private var values: [String: String]
    @State private var working = false
    @State private var result: (ok: Bool, message: String)?
    private let onSuccess: () -> Void

    init(integration: any Integration, email: String = "", adding: Bool = false, onSuccess: @escaping () -> Void = {}) {
        self.integration = integration
        self.adding = adding
        _values = State(initialValue: Dictionary(
            integration.credentialFields.filter { $0.kind == .email }.map { ($0.id, email) }, uniquingKeysWith: { a, _ in a }))
        self.onSuccess = onSuccess
    }

    private var fields: [CredentialField] { model.credentialFields(for: integration) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(fields) { field in
                fieldView(field)
            }
            HStack {
                Button(adding ? "Add and Sign In" : "Sign In and Test") {
                    Task {
                        working = true
                        let outcome =
                            adding
                            ? await model.addIntegration(integration, values: values)
                            : await model.signIn(integration: integration, values: values)
                        result = (outcome.0, outcome.1)
                        working = false
                        if outcome.0 {
                            for field in fields where field.isSecret { values[field.id] = "" }
                            onSuccess()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || model.isDemo)
                if working { ProgressView().controlSize(.small) }
            }
            if let result {
                Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.ok ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isDemo {
                Text("Demo mode: sign-in is not used.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder private func fieldView(_ field: CredentialField) -> some View {
        let value = Binding(get: { values[field.id] ?? "" }, set: { values[field.id] = $0 })
        switch field.kind {
        case .email:
            TextField("Email", text: value)
                .textContentType(.username)
        case .password:
            SecureField("Password", text: value)
                .textContentType(.password)
        case .token:
            SecureField("Token", text: value)
        }
    }
}

/// Signed in: account details. Not signed in, or password refused: the login form. With two or
/// more integrations: a section per integration; with two or more devices: the device list.
struct AccountSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(HeatPumpDeviceModel.self) private var model
    @State private var confirmingSignOut = false
    @State private var switchingAccount = false
    @State private var addingIntegration = false
    @State private var email: String?
    @State private var allDevices: [DeviceDescriptor] = []

    /// Stored credentials that MELCloud has not refused.
    private var signedIn: Bool {
        model.hasCredentials && model.stateResult?.needsLogin != true
    }

    private var multipleIntegrations: Bool { app.activeIntegrations.count >= 2 }

    var body: some View {
        Form {
            if app.isDemo {
                Section("\(model.serviceName) account") {
                    Label("Demo mode: the app shows simulated data, and sign-in is not used.", systemImage: "play.rectangle")
                        .foregroundStyle(.secondary)
                }
                deviceSection
            } else if multipleIntegrations {
                ForEach(app.activeIntegrations, id: \.id) { integration in
                    IntegrationSection(integration: integration)
                }
                deviceSection
            } else if signedIn && !switchingAccount {
                accountSection
                deviceSection
            } else {
                loginSection
            }
            if allDevices.count >= 2 || multipleIntegrations {
                DevicesSection(devices: allDevices) { allDevices = await app.allDevices() }
            }
            if !app.addableIntegrations.isEmpty {
                Section {
                    Button("Add Integration…") { addingIntegration = true }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: model.hasCredentials) { email = await model.accountEmail() }
        .task(id: app.devices.count) {
            await app.loadIntegrations()
            allDevices = await app.allDevices()
        }
        .sheet(isPresented: $addingIntegration) {
            AddIntegrationSheet(integrations: app.addableIntegrations)
        }
        .confirmationDialog("Sign out of \(model.serviceName)?", isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive) {
                Task {
                    await app.signOut(integration: model.integration)
                    email = nil
                }
            }
        } message: {
            Text("Email, password and session are deleted from the keychain. The history is kept. Claude also loses access to the heat pump until you sign in again.")
        }
    }

    private var accountSection: some View {
        Section("\(model.serviceName) account") {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue.gradient)
                VStack(alignment: .leading, spacing: 3) {
                    Text(email ?? String(localized: "\(model.serviceName) account")).font(.headline)
                    Label("Signed in", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            LabeledContent("Stored in") { Text("The keychain on this Mac") }
            HStack {
                Button("Switch Account…") { switchingAccount = true }
                Spacer()
                Button("Sign Out", role: .destructive) { confirmingSignOut = true }
            }
        }
    }

    @ViewBuilder private var deviceSection: some View {
        Section("Heat pump") {
            if let state = model.state {
                LabeledContent("Name", value: state.name)
                LabeledContent("Connection") {
                    Label(state.offline ? "Offline" : "Online", systemImage: state.offline ? "wifi.slash" : "wifi")
                        .foregroundStyle(state.offline ? .orange : .green)
                }
                LabeledContent("Last contact", value: Format.relative(state.lastCommunication))
                LabeledContent("Data fetched", value: Format.relative(state.fetchedAt))
                LabeledContent("Wi-Fi adapter") {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let version = state.firmware.version {
                            Text("Firmware \(version)")
                        } else {
                            Text("Firmware unknown")
                        }
                        if state.firmware.updateAvailable {
                            Text("Update available – start it under Health → Firmware")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let hours = model.live?.sample?.runtimeHours {
                    LabeledContent("Total running time (per the indoor unit)") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(hours) hours").monospacedDigit()
                            Text("The indoor unit's own counter, read locally. Probably the time since installation.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("No data fetched yet.").foregroundStyle(.secondary)
            }
        }
    }

    private var loginSection: some View {
        Section {
            if model.hasCredentials && model.stateResult?.needsLogin == true && !switchingAccount {
                Label("\(model.serviceName) rejected the sign-in. Enter the password again.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            LoginForm(integration: model.integration, email: email ?? "") { switchingAccount = false }
            if switchingAccount {
                Button("Cancel") { switchingAccount = false }
            }
        } header: {
            Text(switchingAccount ? "Switch \(model.serviceName) account" : "Sign in to \(model.serviceName)")
        } footer: {
            Text("Use the same email and password as in the \(model.serviceName) app. They are stored in the keychain on the Mac. The first time Claude uses them, macOS asks for access: choose “Always Allow”.")
        }
    }
}

struct ClaudeSettings: View {
    @State private var copied = false

    private var helperPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/varmepumpe-mcp").path
    }

    private var command: String {
        "claude mcp add varmepumpe --scope user -- \"\(helperPath)\""
    }

    var body: some View {
        Form {
            Section {
                Text("Run this command once in Terminal to connect Claude Code to the heat pump:")
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                Button(copied ? "Copied" : "Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
            } header: {
                Text("Connect Claude")
            } footer: {
                Text("If you move the app (for example to the Applications folder), run the command again with the new path.")
            }
            Section("Security") {
                Label(
                    "Every change Claude wants to make to the heat pump is shown in a separate approval window on the Mac (“Approve” / “Reject”). This applies however Claude Code is set up. Without an answer within 2 minutes, the change is rejected.",
                    systemImage: "hand.raised")
                Label(
                    "Even so, do not add the set_* tools to Claude's list of tools allowed without asking.",
                    systemImage: "exclamationmark.shield")
                Label("Claude can read freely, but all changes are logged under Claude activity.", systemImage: "list.bullet.rectangle")
            }
        }
        .formStyle(.grouped)
    }
}

struct DataSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(HeatPumpDeviceModel.self) private var model

    var body: some View {
        Form {
            Section("Database") {
                Text(app.dbPath).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.dbPath)])
                }
            }
            Section {
                if let until = model.stateResult?.blockedUntil {
                    LabeledContent("Blocked until", value: Display.dateTime(until))
                } else {
                    LabeledContent("Block") { Text("None") }
                }
                ForEach(model.fetchStatus, id: \.key) { row in
                    LabeledContent(label(row.key)) {
                        VStack(alignment: .trailing) {
                            Text("Last attempt: \(row.lastAttempt.map(Display.dateTime) ?? "–")")
                            Text("Last success: \(row.lastSuccess.map(Display.dateTime) ?? "–")")
                        }
                        .font(.caption)
                    }
                }
            } header: {
                Text("Fetching from \(model.serviceName)")
            } footer: {
                Text("Status is fetched at most once a minute and otherwise from the cache (10 minutes). History is fetched at most once an hour.")
            }
        }
        .formStyle(.grouped)
        .task { await model.reloadLocal() }
    }

    private func label(_ key: String) -> String {
        switch key {
        case "state": String(localized: "Status")
        case "global": String(localized: "\(model.serviceName) block")
        case "report.errorLog": String(localized: "Error log")
        case "report.temperatureLog": String(localized: "Temperature log")
        case "report.energy": String(localized: "Energy")
        case let key where key.hasPrefix("prices."): String(localized: "Electricity prices")
        case "local": String(localized: "Local connection")
        case "away": String(localized: "Frost protection and holiday mode")
        case "timer": String(localized: "Weekly schedule")
        default: key
        }
    }
}

/// Price agreement, grid tariff and Tibber token.
struct PriceSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = PriceSettings.default
    @State private var token = ""
    @State private var tokenStored = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Picker(selection: $draft.agreement) {
                    ForEach(PriceAgreementKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                } label: {
                    Label { Text("Electricity contract") } icon: { IconBadge(systemImage: "bolt.fill", color: .yellow) }
                }
                switch draft.agreement {
                case .norgespris:
                    LabeledContent("Price incl. VAT") {
                        HStack {
                            TextField("øre/kWh", value: $draft.norgesprisOre, format: .number.precision(.fractionLength(0...2)))
                                .labelsHidden().frame(width: 80).multilineTextAlignment(.trailing)
                            Text("øre/kWh")
                        }
                    }
                case .tibber:
                    SecureField("Tibber token (personal access token)", text: $token, prompt: Text(tokenStored ? "Stored in the keychain" : "Paste the token"))
                    HStack {
                        Button("Save and Test") {
                            Task {
                                testing = true
                                testResult = await model.saveAndTestTibberToken(token)
                                await model.checkTibberToken()
                                tokenStored = model.hasTibberToken
                                token = ""
                                testing = false
                            }
                        }
                        .disabled(token.isEmpty || testing)
                        if testing { ProgressView().controlSize(.small) }
                        Spacer()
                        Link("Get a token at developer.tibber.com", destination: URL(string: "https://developer.tibber.com/settings/access-token")!)
                            .font(.callout)
                    }
                    if let testResult { Text(testResult).font(.callout).foregroundStyle(.secondary) }
                case .spot:
                    Picker("Price area", selection: $draft.area) {
                        ForEach(PriceArea.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    LabeledContent("Markup from the electricity supplier") {
                        HStack {
                            TextField("øre/kWh", value: $draft.markupOre, format: .number.precision(.fractionLength(0...2)))
                                .labelsHidden().frame(width: 80).multilineTextAlignment(.trailing)
                            Text("øre/kWh incl. VAT")
                        }
                    }
                }
            } header: {
                Text("Electricity price")
            } footer: {
                Text(agreementFooter)
            }

            Section {
                LabeledContent("Day (weekdays 06–22)") { oreField($draft.grid.dayOre) }
                LabeledContent("Night, weekends and public holidays") { oreField($draft.grid.nightOre) }
                Button("Use Elvia's Rates") { draft.grid = .elvia2026 }
                    .disabled(draft.grid == .elvia2026)
            } header: {
                Text("Grid tariff – energy charge")
            } footer: {
                Text(
                    "Source: \(GridTariff.elviaSource), as of \(GridTariff.elviaAsOf). The rates include electricity tax, the Enova fee and VAT. The capacity charge (fixed charge) is not included: it depends on the whole household's peak consumption, so it cannot be attributed to the heat pump."
                )
            }

            Section {
                HStack {
                    if let message = model.priceMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.caution)
                    }
                    Spacer()
                    Button("Save") { Task { await model.savePriceSettings(draft) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == model.priceSettings)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            guard !loaded else { return }
            loaded = true
            draft = await model.loadPriceSettings()
            await model.checkTibberToken()
            tokenStored = model.hasTibberToken
        }
    }

    private var agreementFooter: String {
        switch draft.agreement {
        case .norgespris:
            String(localized: "Norgespris (fixed price) is a fixed price per kWh from the state: 50 øre incl. VAT, or 40 øre in Northern Norway (NO4), where there is no VAT. With Norgespris you do not get the electricity subsidy.")
        case .tibber:
            String(localized: "Hourly prices are fetched from your Tibber account (at most once an hour). The token is stored in the keychain. The electricity subsidy is deducted: the state covers 90 percent of the hourly price above 96.25 øre/kWh incl. VAT (2026).")
        case .spot:
            String(localized: "Hourly prices are fetched from hvakosterstrommen.no (at most once an hour) and VAT is added. The electricity subsidy is deducted: the state covers 90 percent of the hourly price above 96.25 øre/kWh incl. VAT (2026).")
        }
    }

    private func oreField(_ value: Binding<Double>) -> some View {
        HStack {
            TextField("øre/kWh", value: value, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden().frame(width: 80).multilineTextAlignment(.trailing)
            Text("øre/kWh")
        }
    }
}
