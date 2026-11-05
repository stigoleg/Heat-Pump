import AppKit
import HeatPumpKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Konto", systemImage: "person.crop.circle") { AccountSettings() }
            Tab("Strømpris", systemImage: "bolt.horizontal.circle") { PriceSettingsView() }
            Tab("Claude", systemImage: "sparkles") { ClaudeSettings() }
            Tab("Data", systemImage: "externaldrive") { DataSettings() }
        }
        .frame(width: 600, height: 560)
    }
}

/// E-mail + password → one login and state fetch through the service.
struct LoginForm: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("E-post", text: $email)
                .textContentType(.username)
            SecureField("Passord", text: $password)
                .textContentType(.password)
            HStack {
                Button("Logg inn og test") {
                    Task {
                        working = true
                        let outcome = await model.signIn(email: email, password: password)
                        result = (outcome.0, outcome.1)
                        if outcome.0 { password = "" }
                        working = false
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
                Text("Demo-modus: innlogging er ikke i bruk.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}

struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingSignOut = false

    var body: some View {
        Form {
            Section {
                LoginForm()
            } header: {
                Text("MELCloud-innlogging")
            } footer: {
                Text("E-post og passord lagres i nøkkelringen på Macen. Første gang MCP-serveren for Claude bruker dem, spør macOS om tilgang: velg «Tillat alltid».")
            }
            Section {
                LabeledContent("Status", value: model.hasCredentials ? "Innlogging lagret" : "Ikke innlogget")
                Button("Logg ut", role: .destructive) { confirmingSignOut = true }
                    .disabled(!model.hasCredentials || model.isDemo)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Logge ut?", isPresented: $confirmingSignOut) {
            Button("Logg ut", role: .destructive) { Task { await model.signOut() } }
        } message: {
            Text("E-post, passord og økt slettes fra nøkkelringen. Historikken beholdes.")
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
                Text("Kjør denne kommandoen én gang i Terminal for å koble Claude Code til varmepumpen:")
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                Button(copied ? "Kopiert" : "Kopier kommando") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
            } header: {
                Text("Koble til Claude")
            } footer: {
                Text("Flytter du appen (for eksempel til Programmer-mappen), må kommandoen kjøres på nytt med den nye stien.")
            }
            Section("Sikkerhet") {
                Label(
                    "Hver endring Claude vil gjøre på varmepumpen vises i et eget godkjenningsvindu på Macen («Godkjenn» / «Avvis»). Det gjelder uansett hvordan Claude Code er satt opp. Uten svar innen 2 minutter blir endringen avvist.",
                    systemImage: "hand.raised")
                Label(
                    "Legg likevel ikke set_*-verktøyene til i Claudes liste over verktøy som er tillatt uten å spørre.",
                    systemImage: "exclamationmark.shield")
                Label("Claude kan lese fritt, men alle endringer logges under Claude-aktivitet.", systemImage: "list.bullet.rectangle")
            }
        }
        .formStyle(.grouped)
    }
}

struct DataSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Database") {
                Text(model.dbPath).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Button("Vis i Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.dbPath)])
                }
            }
            Section {
                if let until = model.stateResult?.blockedUntil {
                    LabeledContent("Blokkert til", value: Norwegian.dateTime(until))
                } else {
                    LabeledContent("Blokkering", value: "Ingen")
                }
                ForEach(model.fetchStatus, id: \.key) { row in
                    LabeledContent(label(row.key)) {
                        VStack(alignment: .trailing) {
                            Text("Sist forsøkt: \(row.lastAttempt.map(Norwegian.dateTime) ?? "–")")
                            Text("Sist vellykket: \(row.lastSuccess.map(Norwegian.dateTime) ?? "–")")
                        }
                        .font(.caption)
                    }
                }
            } header: {
                Text("Henting fra MELCloud")
            } footer: {
                Text("Status hentes høyst én gang i minuttet og ellers fra lageret (10 minutter). Historikk hentes høyst én gang i timen.")
            }
        }
        .formStyle(.grouped)
        .task { await model.reloadLocal() }
    }

    private func label(_ key: String) -> String {
        switch key {
        case "state": "Status"
        case "global": "MELCloud-blokkering"
        case "report.errorLog": "Feillogg"
        case "report.temperatureLog": "Temperaturlogg"
        case "report.energy": "Energi"
        case let key where key.hasPrefix("prices."): "Strømpriser"
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
                    Label { Text("Strømavtale") } icon: { IconBadge(systemImage: "bolt.fill", color: .yellow) }
                }
                switch draft.agreement {
                case .norgespris:
                    LabeledContent("Pris inkl. mva") {
                        HStack {
                            TextField("øre/kWh", value: $draft.norgesprisOre, format: .number.precision(.fractionLength(0...2)))
                                .labelsHidden().frame(width: 80).multilineTextAlignment(.trailing)
                            Text("øre/kWh")
                        }
                    }
                case .tibber:
                    SecureField("Tibber-nøkkel (personal access token)", text: $token, prompt: Text(tokenStored ? "Lagret i nøkkelringen" : "Lim inn nøkkelen"))
                    HStack {
                        Button("Lagre og test") {
                            Task {
                                testing = true
                                testResult = await model.saveAndTestTibberToken(token)
                                tokenStored = model.hasTibberToken
                                token = ""
                                testing = false
                            }
                        }
                        .disabled(token.isEmpty || testing)
                        if testing { ProgressView().controlSize(.small) }
                        Spacer()
                        Link("Hent nøkkel på developer.tibber.com", destination: URL(string: "https://developer.tibber.com/settings/access-token")!)
                            .font(.callout)
                    }
                    if let testResult { Text(testResult).font(.callout).foregroundStyle(.secondary) }
                case .spot:
                    Picker("Prisområde", selection: $draft.area) {
                        ForEach(PriceArea.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    LabeledContent("Påslag fra strømselskapet") {
                        HStack {
                            TextField("øre/kWh", value: $draft.markupOre, format: .number.precision(.fractionLength(0...2)))
                                .labelsHidden().frame(width: 80).multilineTextAlignment(.trailing)
                            Text("øre/kWh inkl. mva")
                        }
                    }
                }
            } header: {
                Text("Strømpris")
            } footer: {
                Text(agreementFooter)
            }

            Section {
                LabeledContent("Dag (hverdager 06–22)") { oreField($draft.grid.dayOre) }
                LabeledContent("Natt, helg og helligdager") { oreField($draft.grid.nightOre) }
                Button("Bruk Elvias satser") { draft.grid = .elvia2026 }
                    .disabled(draft.grid == .elvia2026)
            } header: {
                Text("Nettleie – energiledd")
            } footer: {
                Text(
                    "Kilde: \(GridTariff.elviaSource), per \(GridTariff.elviaAsOf). Satsene er inkludert forbruksavgift, Enova-påslag og mva. Kapasitetsleddet (fastleddet) er ikke med: det avhenger av hele husets høyeste forbruk, så det kan ikke fordeles på varmepumpen."
                )
            }

            Section {
                HStack {
                    if let message = model.priceMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.caution)
                    }
                    Spacer()
                    Button("Lagre") { Task { await model.savePriceSettings(draft) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == model.priceSettings)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            guard !loaded else { return }
            loaded = true
            draft = model.priceSettings
            tokenStored = model.hasTibberToken
        }
    }

    private var agreementFooter: String {
        switch draft.agreement {
        case .norgespris:
            "Norgespris er en fast pris per kWh fra staten. Med Norgespris får du ikke strømstøtte."
        case .tibber:
            "Timeprisene hentes fra Tibber-kontoen din (høyst én gang i timen). Nøkkelen lagres i nøkkelringen. Strømstøtte trekkes fra: staten dekker 90 % av timeprisen over 96,25 øre/kWh inkl. mva (2026)."
        case .spot:
            "Timeprisene hentes fra hvakosterstrommen.no (høyst én gang i timen) og tillegges mva. Strømstøtte trekkes fra: staten dekker 90 % av timeprisen over 96,25 øre/kWh inkl. mva (2026)."
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
