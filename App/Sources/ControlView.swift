import HeatPumpKit
import SwiftUI

struct ControlView: View {
    @Environment(AppModel.self) private var model
    /// Only the fields the user has touched; everything else shows live state.
    @State private var edits = ControlEdits()
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
        let live = ControlSettings(state)
        let shown = edits.displayed(over: live)
        let pending = edits.changes(from: live)
        let range = state.limits.range(for: shown.mode)
        let step = state.temperatureIncrement > 0 ? state.temperatureIncrement : 0.5
        func field<T>(_ edit: WritableKeyPath<ControlEdits, T?>, _ value: KeyPath<ControlSettings, T>) -> Binding<T> {
            Binding(get: { edits[keyPath: edit] ?? live[keyPath: value] }, set: { edits[keyPath: edit] = $0 })
        }
        let mode = Binding<OperationMode>(
            get: { shown.mode },
            set: { newMode in
                edits.mode = newMode
                edits.clampSetpoint(over: live, limits: state.limits, step: step)
            })

        return Form {
            if model.isAwaitingConfirmation {
                Section {
                    Label("Venter på bekreftelse fra varmepumpen. Verdiene under er det du har sendt.", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Av/på") {
                Toggle("Varmepumpen er på", isOn: field(\.power, \.power))
            }

            Section {
                Picker("Modus", selection: mode) {
                    ForEach([OperationMode.heat, .cool, .dry, .fan, .auto], id: \.self) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                    }
                }
                Stepper(value: field(\.setTemperature, \.setTemperature), in: range, step: step) {
                    LabeledContent("Ønsket temperatur", value: Format.temperature(shown.setTemperature))
                }
            } header: {
                Text("Varme og temperatur")
            } footer: {
                Text(
                    Norwegian.format(
                        "Tillatt i %@: %.0f–%.0f °C. Varme er riktig valg om vinteren. Små justeringer (1–2 grader) er nok.",
                        shown.mode.displayName.lowercased(), range.lowerBound, range.upperBound))
            }

            Section {
                Picker("Viftehastighet", selection: field(\.fanSpeed, \.fanSpeed)) {
                    if state.hasAutomaticFanSpeed { Text("Auto").tag(0) }
                    ForEach(1...max(state.numberOfFanSpeeds, 1), id: \.self) { speed in
                        Text("\(speed)").tag(speed)
                    }
                }
                Picker("Vertikalt spjeld (opp/ned)", selection: field(\.vaneVertical, \.vaneVertical)) {
                    ForEach(VaneVertical.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Horisontalt spjeld (venstre/høyre)", selection: field(\.vaneHorizontal, \.vaneHorizontal)) {
                    ForEach(VaneHorizontal.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text("Luftstrøm")
            } footer: {
                Text("Spjeldene styrer hvor luften blåser. Ved oppvarming er nederste stilling eller Auto best, så varmen når gulvet.")
            }

            Section {
                HStack {
                    Button("Tilbakestill") { edits = ControlEdits() }
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
        // Edits that live state has caught up with are no longer pending.
        .onChange(of: live) { edits.prune(against: live) }
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
        if outcomes.allSatisfy({ $0.result == .ok }) { edits = ControlEdits() }
    }
}
