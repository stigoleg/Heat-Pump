import AppKit
import HeatPumpKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            Tab("Konto", systemImage: "person.crop.circle", value: "konto") { AccountSettings() }
            Tab("Strømpris", systemImage: "bolt.horizontal.circle", value: "strompris") { PriceSettingsView() }
            Tab("Lokal tilkobling", systemImage: "wifi.router", value: "lokal") { LocalSettingsView() }
            Tab("Claude", systemImage: "sparkles", value: "claude") { ClaudeSettings() }
            Tab("Data", systemImage: "externaldrive", value: "data") { DataSettings() }
        }
        .frame(width: 640, height: 600)
    }
}

/// E-mail + password → one login and state fetch through the service.
struct LoginForm: View {
    @Environment(AppModel.self) private var model
    @State private var email: String
    @State private var password = ""
    @State private var working = false
    @State private var result: (ok: Bool, message: String)?
    private let onSuccess: () -> Void

    init(email: String = "", onSuccess: @escaping () -> Void = {}) {
        _email = State(initialValue: email)
        self.onSuccess = onSuccess
    }

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
                        working = false
                        if outcome.0 {
                            password = ""
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
                Text("Demo-modus: innlogging er ikke i bruk.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}

/// Signed in: account details. Not signed in, or password refused: the login form.
struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingSignOut = false
    @State private var switchingAccount = false
    @State private var email: String?

    /// Stored credentials that MELCloud has not refused.
    private var signedIn: Bool {
        model.hasCredentials && model.stateResult?.needsLogin != true
    }

    var body: some View {
        Form {
            if model.isDemo {
                Section("MELCloud-konto") {
                    Label("Demo-modus: appen viser simulerte data, og innlogging er ikke i bruk.", systemImage: "play.rectangle")
                        .foregroundStyle(.secondary)
                }
                deviceSection
            } else if signedIn && !switchingAccount {
                accountSection
                deviceSection
            } else {
                loginSection
            }
        }
        .formStyle(.grouped)
        .task(id: model.hasCredentials) { email = await model.accountEmail() }
        .confirmationDialog("Logge ut av MELCloud?", isPresented: $confirmingSignOut) {
            Button("Logg ut", role: .destructive) {
                Task {
                    await model.signOut()
                    email = nil
                }
            }
        } message: {
            Text("E-post, passord og økt slettes fra nøkkelringen. Historikken beholdes. Claude mister også tilgangen til varmepumpen til du logger inn igjen.")
        }
    }

    private var accountSection: some View {
        Section("MELCloud-konto") {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue.gradient)
                VStack(alignment: .leading, spacing: 3) {
                    Text(email ?? "MELCloud-konto").font(.headline)
                    Label("Innlogget", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            LabeledContent("Lagret i", value: "Nøkkelringen på denne Macen")
            HStack {
                Button("Bytt konto…") { switchingAccount = true }
                Spacer()
                Button("Logg ut", role: .destructive) { confirmingSignOut = true }
            }
        }
    }

    @ViewBuilder private var deviceSection: some View {
        Section("Varmepumpe") {
            if let state = model.state {
                LabeledContent("Navn", value: state.name)
                LabeledContent("Tilkobling") {
                    Label(state.offline ? "Frakoblet" : "Tilkoblet", systemImage: state.offline ? "wifi.slash" : "wifi")
                        .foregroundStyle(state.offline ? .orange : .green)
                }
                LabeledContent("Siste kontakt", value: Format.relative(state.lastCommunication))
                LabeledContent("Data hentet", value: Format.relative(state.fetchedAt))
                LabeledContent("Wi-Fi-modul") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(state.firmware.version.map { "Fastvare \($0)" } ?? "Fastvare ukjent")
                        if state.firmware.updateAvailable {
                            Text("Oppdatering tilgjengelig – startes i MELCloud-appen")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Ingen data hentet ennå.").foregroundStyle(.secondary)
            }
        }
    }

    private var loginSection: some View {
        Section {
            if model.hasCredentials && model.stateResult?.needsLogin == true && !switchingAccount {
                Label("MELCloud avviste innloggingen. Skriv inn passordet på nytt.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            LoginForm(email: email ?? "") { switchingAccount = false }
            if switchingAccount {
                Button("Avbryt") { switchingAccount = false }
            }
        } header: {
            Text(switchingAccount ? "Bytt MELCloud-konto" : "Logg inn på MELCloud")
        } footer: {
            Text("Bruk samme e-post og passord som i MELCloud-appen. De lagres i nøkkelringen på Macen. Første gang Claude bruker dem, spør macOS om tilgang: velg «Tillat alltid».")
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
        case "local": "Lokal tilkobling"
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
                                await model.checkTibberToken()
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
            draft = await model.loadPriceSettings()
            await model.checkTibberToken()
            tokenStored = model.hasTibberToken
        }
    }

    private var agreementFooter: String {
        switch draft.agreement {
        case .norgespris:
            "Norgespris er en fast pris per kWh fra staten: 50 øre inkl. mva, eller 40 øre i Nord-Norge (NO4), der det ikke er mva. Med Norgespris får du ikke strømstøtte."
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
