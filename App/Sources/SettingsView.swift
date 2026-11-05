import AppKit
import HeatPumpKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Konto", systemImage: "person.crop.circle") { AccountSettings() }
            Tab("Claude", systemImage: "sparkles") { ClaudeSettings() }
            Tab("Data", systemImage: "externaldrive") { DataSettings() }
        }
        .frame(width: 560, height: 440)
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
        default: key
        }
    }
}
