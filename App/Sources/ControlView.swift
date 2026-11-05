import HeatPumpKit
import SwiftUI

struct ControlView: View {
    @Environment(AppModel.self) private var model
    @State private var draft: ControlSettings?
    @State private var confirming = false
    @State private var sending = false
    @State private var outcomes: [ChangeOutcome] = []

    var body: some View {
        Group {
            if let base = model.effectiveState ?? model.state {
                form(base: base)
            } else {
                ContentUnavailableView(
                    "Ingen status ennå", systemImage: "slider.horizontal.3",
                    description: Text("Kontrollene blir tilgjengelige når status er hentet."))
            }
        }
    }

    private func form(base state: DeviceState) -> some View {
        let original = ControlSettings(state)
        let binding = Binding<ControlSettings>(
            get: { draft ?? original },
            set: { draft = $0 })
        let pending = binding.wrappedValue.changes(from: original)
        let range = state.limits.range(for: binding.wrappedValue.mode)
        let step = state.temperatureIncrement > 0 ? state.temperatureIncrement : 0.5

        return Form {
            if model.isAwaitingConfirmation {
                Section {
                    Label("Venter på bekreftelse fra varmepumpen. Verdiene under er det du har sendt.", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Av/på") {
                Toggle("Varmepumpen er på", isOn: binding.power)
            }

            Section {
                Picker("Modus", selection: binding.mode) {
                    ForEach([OperationMode.heat, .cool, .dry, .fan, .auto], id: \.self) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .onChange(of: binding.wrappedValue.mode) {
                    var value = binding.wrappedValue
                    value.clampSetpoint(to: state.limits, step: step)
                    binding.wrappedValue = value
                }
                Stepper(value: binding.setTemperature, in: range, step: step) {
                    LabeledContent("Ønsket temperatur", value: Format.temperature(binding.wrappedValue.setTemperature))
                }
            } header: {
                Text("Varme og temperatur")
            } footer: {
                Text(
                    Norwegian.format(
                        "Tillatt i %@: %.0f–%.0f °C. Varme er riktig valg om vinteren. Små justeringer (1–2 grader) er nok.",
                        binding.wrappedValue.mode.displayName.lowercased(), range.lowerBound, range.upperBound))
            }

            Section {
                Picker("Viftehastighet", selection: binding.fanSpeed) {
                    if state.hasAutomaticFanSpeed { Text("Auto").tag(0) }
                    ForEach(1...max(state.numberOfFanSpeeds, 1), id: \.self) { speed in
                        Text("\(speed)").tag(speed)
                    }
                }
                Picker("Vertikalt spjeld (opp/ned)", selection: binding.vaneVertical) {
                    ForEach(VaneVertical.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Horisontalt spjeld (venstre/høyre)", selection: binding.vaneHorizontal) {
                    ForEach(VaneHorizontal.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text("Luftstrøm")
            } footer: {
                Text("Spjeldene styrer hvor luften blåser. Ved oppvarming er nederste stilling eller Auto best, så varmen når gulvet.")
            }

            Section {
                HStack {
                    Button("Tilbakestill") { draft = nil }
                        .disabled(pending.isEmpty || sending)
                    Spacer()
                    if sending { ProgressView().controlSize(.small) }
                    Button("Send til varmepumpen") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(pending.isEmpty || sending || model.service == nil)
                }
            } footer: {
                Text(
                    "Endringene sendes samlet. Det kan ta et par minutter før varmepumpen bekrefter. Maks \(ChangeBudget.maxChangesPerHour) sendinger per time, til sammen for appen og Claude."
                )
            }

            if !outcomes.isEmpty {
                Section("Resultat") {
                    ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                        Label {
                            Text(outcome.message)
                        } icon: {
                            Image(systemName: outcome.result == .ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(outcome.result == .ok ? .green : .red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top, spacing: 0) { StatusBanner(inset: 16) }
        .confirmationDialog("Sende endringene til varmepumpen?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Send") { Task { await send(pending) } }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text(pending.map(\.displaySummary).joined(separator: "\n"))
        }
    }

    private func send(_ changes: [DeviceChange]) async {
        sending = true
        defer { sending = false }
        outcomes = await model.send(changes)
        if outcomes.allSatisfy({ $0.result == .ok }) { draft = nil }
    }
}
