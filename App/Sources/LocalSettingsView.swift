import HeatPumpKit
import SwiftUI

/// Settings → Lokal tilkobling: read-only access to the Wi-Fi adapter on the home network.
struct LocalSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var enabled = false
    @State private var host = ""
    @State private var loaded = false
    @State private var working = false
    @State private var message: (ok: Bool, text: String)?
    @State private var test: LocalTestResult?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    Label { Text("Les varmepumpen direkte på hjemmenettet") } icon: {
                        IconBadge(systemImage: "wifi.router", color: .teal)
                    }
                }
                LabeledContent("IP-adresse") {
                    HStack {
                        TextField("IP-adresse", text: $host, prompt: Text("for eksempel 192.168.1.50"))
                            .labelsHidden().frame(width: 170).multilineTextAlignment(.trailing)
                            .font(.body.monospacedDigit())
                    }
                }
                HStack {
                    Button("Finn automatisk") { Task { await discover() } }
                        .disabled(working)
                    Button("Test") { Task { await runTest() } }
                        .disabled(working || host.trimmingCharacters(in: .whitespaces).isEmpty)
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Lagre") { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || !changed)
                }
                if let message {
                    Label(message.text, systemImage: message.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(message.ok ? Theme.Status.good : Theme.Status.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let sample = test?.sample { testDetails(sample) }
            } header: {
                Text("Lokal tilkobling")
            } footer: {
                Text(
                    "Appen spør Wi-Fi-modulen i varmepumpen om status direkte over hjemmenettet: hvert minutt mens appen er åpen, og når Claude ber om fersk status (også når appen er lukket). Aldri oftere enn hvert 20. sekund, og bare når Macen er på samme nett som varmepumpen. Da får du effekt i watt, om kompressoren går, og et nøyaktig strømforbruk per time. Appen bare leser: all styring går fortsatt via MELCloud, og ingen innstillinger i modulen endres."
                )
            }

            Section("Status") {
                status
            }

            Section {
                Label("Bare lesing. Appen sender kun en statusforespørsel og kan ikke endre noe i varmepumpen eller modulen.", systemImage: "lock.shield")
                Label("Dette er ikke en offisiell funksjon fra Mitsubishi. Den kan slutte å virke etter en fastvareoppdatering av modulen (for eksempel versjon 43.00 eller nyere). Da virker resten av appen som før.", systemImage: "exclamationmark.triangle")
                Label("«Finn automatisk» leter bare på det lokale nettet Macen er koblet til, og kjenner igjen varmepumpen på maskinvareadressen fra MELCloud. Adressen vises ikke. Gi gjerne varmepumpen fast IP-adresse i ruteren.", systemImage: "magnifyingglass")
            } header: {
                Text("Godt å vite")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task {
            guard !loaded else { return }
            loaded = true
            await model.reloadLocal()
            enabled = model.localSettings.enabled
            host = model.localSettings.host ?? ""
        }
    }

    private var draft: LocalSettings {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        return LocalSettings(enabled: enabled, host: trimmed.isEmpty ? nil : trimmed)
    }

    private var changed: Bool { draft != model.localSettings }

    @ViewBuilder private var status: some View {
        let reach = model.live?.reachability
        if reach?.enabled != true {
            LabeledContent("Tilstand", value: "Av")
        } else if reach?.onHomeNetwork == false {
            LabeledContent("Tilstand") {
                Label("Ikke på hjemmenettet", systemImage: "house.slash").foregroundStyle(.secondary)
            }
            Text("Lokal avlesning er satt på pause til Macen er på samme nett som varmepumpen. Styring via MELCloud virker som før.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            LabeledContent("Tilstand") {
                if let failures = reach?.consecutiveFailures, failures > 0 {
                    Label("Svarer ikke (\(failures) forsøk på rad)", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(Theme.Status.caution)
                } else if reach?.lastSuccess != nil {
                    Label("Tilkoblet", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.Status.good)
                } else {
                    Text("Venter på første avlesning")
                }
            }
            LabeledContent("Sist lest", value: Format.relative(reach?.lastSuccess))
            if let error = reach?.lastError, (reach?.consecutiveFailures ?? 0) > 0 {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if let next = reach?.nextAttemptAllowed, (reach?.consecutiveFailures ?? 0) > 0 {
                LabeledContent("Neste forsøk", value: Display.time(next))
            }
        }
        if let sample = model.live?.sample {
            LabeledContent("Fastvare i modulen", value: sample.adapterVersion ?? "–")
            if let rssi = sample.rssi { LabeledContent("Wi-Fi-signal", value: "\(rssi) dBm") }
        }
    }

    private func testDetails(_ sample: LocalSample) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.xs) {
            GridRow { Text("Fastvare").foregroundStyle(.secondary); Text(sample.adapterVersion ?? "–") }
            GridRow { Text("Wi-Fi-signal").foregroundStyle(.secondary); Text(sample.rssi.map { "\($0) dBm" } ?? "–") }
            GridRow { Text("Effekt").foregroundStyle(.secondary); Text(Format.watts(sample.powerW.map(Double.init))) }
            GridRow {
                Text("Kompressor").foregroundStyle(.secondary)
                Text(sample.isRunning ? "Går" + (sample.compressorHz.map { " · \($0) Hz" } ?? "") : "Står")
            }
            GridRow { Text("Inne").foregroundStyle(.secondary); Text(Format.temperature(sample.roomTemperature)) }
            GridRow { Text("Ute").foregroundStyle(.secondary); Text(Format.temperature(sample.outdoorTemperature)) }
        }
        .font(.callout.monospacedDigit())
    }

    private func save() async {
        working = true
        defer { working = false }
        if let error = await model.saveLocalSettings(draft) {
            message = (false, error)
        } else {
            message = (true, enabled ? "Lagret. Appen leser modulen hvert minutt mens den er åpen, og Claude ved behov." : "Lagret. Lokal tilkobling er av.")
            host = model.localSettings.host ?? ""
        }
    }

    private func runTest() async {
        working = true
        defer { working = false }
        let result = await model.testLocal(host: host)
        test = result
        message = (result.ok, result.ok ? "Kontakt med Wi-Fi-modulen." : result.message)
    }

    private func discover() async {
        working = true
        defer { working = false }
        let result = await model.discoverLocal()
        if let found = result.host { host = found }
        message = (result.host != nil, result.message)
    }
}
