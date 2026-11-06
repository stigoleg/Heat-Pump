import HeatPumpKit
import SwiftUI

/// Settings → Local connection: read-only access to the Wi-Fi adapter on the home network.
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
                    Label { Text("Read the heat pump directly on the home network") } icon: {
                        IconBadge(systemImage: "wifi.router", color: .teal)
                    }
                }
                LabeledContent("IP address") {
                    HStack {
                        TextField("IP address", text: $host, prompt: Text("for example 192.168.1.50"))
                            .labelsHidden().frame(width: 170).multilineTextAlignment(.trailing)
                            .font(.body.monospacedDigit())
                    }
                }
                HStack {
                    Button("Find Automatically") { Task { await discover() } }
                        .disabled(working)
                    Button("Test") { Task { await runTest() } }
                        .disabled(working || host.trimmingCharacters(in: .whitespaces).isEmpty)
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Save") { Task { await save() } }
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
                Text("Local connection")
            } footer: {
                Text(
                    "The app asks the heat pump's Wi-Fi adapter for its status directly over the home network: every minute while the app is open, and when Claude asks for fresh status (also when the app is closed). Never more often than every 20 seconds, and only when the Mac is on the same network as the heat pump. This gives you power in watts, whether the compressor is running, and accurate electricity consumption per hour. The app only reads: all control still goes through MELCloud, and no settings in the adapter are changed."
                )
            }

            Section("Status") {
                status
            }

            Section {
                Label("Read only. The app only sends a status request and cannot change anything in the heat pump or the adapter.", systemImage: "lock.shield")
                Label("This is not an official Mitsubishi feature. It may stop working after a firmware update of the adapter (for example version 43.00 or later). The rest of the app then works as before.", systemImage: "exclamationmark.triangle")
                Label("“Find Automatically” only searches the local network the Mac is connected to, and recognizes the heat pump by the hardware address from MELCloud. The address is not shown. Consider giving the heat pump a fixed IP address in the router.", systemImage: "magnifyingglass")
            } header: {
                Text("Good to know")
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
            LabeledContent("State") { Text("Off") }
        } else if reach?.onHomeNetwork == false {
            LabeledContent("State") {
                Label("Not on the home network", systemImage: "house.slash").foregroundStyle(.secondary)
            }
            Text("Local reading is paused until the Mac is on the same network as the heat pump. Control through MELCloud works as before.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            LabeledContent("State") {
                if let failures = reach?.consecutiveFailures, failures > 0 {
                    Label("Not responding (\(failures) attempts in a row)", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(Theme.Status.caution)
                } else if reach?.lastSuccess != nil {
                    Label("Online", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.Status.good)
                } else {
                    Text("Waiting for the first reading")
                }
            }
            LabeledContent("Last read", value: Format.relative(reach?.lastSuccess))
            if let error = reach?.lastError, (reach?.consecutiveFailures ?? 0) > 0 {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if let next = reach?.nextAttemptAllowed, (reach?.consecutiveFailures ?? 0) > 0 {
                LabeledContent("Next attempt", value: Display.time(next))
            }
        }
        if let sample = model.live?.sample {
            LabeledContent("Adapter firmware", value: sample.adapterVersion ?? "–")
            if let rssi = sample.rssi { LabeledContent("Wi-Fi signal", value: "\(rssi) dBm") }
        }
    }

    private func testDetails(_ sample: LocalSample) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.xs) {
            GridRow { Text("Firmware").foregroundStyle(.secondary); Text(sample.adapterVersion ?? "–") }
            GridRow { Text("Wi-Fi signal").foregroundStyle(.secondary); Text(sample.rssi.map { "\($0) dBm" } ?? "–") }
            GridRow { Text("Power").foregroundStyle(.secondary); Text(Format.watts(sample.powerW.map(Double.init))) }
            GridRow {
                Text("Compressor").foregroundStyle(.secondary)
                if !sample.isRunning {
                    Text("Stopped")
                } else if let hz = sample.compressorHz {
                    Text("Running · \(hz) Hz")
                } else {
                    Text("Running")
                }
            }
            GridRow { Text("Indoor").foregroundStyle(.secondary); Text(Format.temperature(sample.roomTemperature)) }
            GridRow { Text("Outdoor").foregroundStyle(.secondary); Text(Format.temperature(sample.outdoorTemperature)) }
        }
        .font(.callout.monospacedDigit())
    }

    private func save() async {
        working = true
        defer { working = false }
        if let error = await model.saveLocalSettings(draft) {
            message = (false, error)
        } else {
            message = (true, enabled
                ? String(localized: "Saved. The app reads the adapter every minute while it is open, and Claude when needed.")
                : String(localized: "Saved. Local connection is off."))
            host = model.localSettings.host ?? ""
        }
    }

    private func runTest() async {
        working = true
        defer { working = false }
        let result = await model.testLocal(host: host)
        test = result
        message = (result.ok, result.ok ? String(localized: "Connected to the Wi-Fi adapter.") : result.message)
    }

    private func discover() async {
        working = true
        defer { working = false }
        let result = await model.discoverLocal()
        if let found = result.host { host = found }
        message = (result.host != nil, result.message)
    }
}
