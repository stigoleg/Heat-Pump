import HeatPumpKit
import SwiftUI

/// Frost protection and holiday mode in MELCloud. Unlike Kontroll these are not sent
/// automatically: each change is confirmed in a sheet first.
struct AwayView: View {
    @Environment(AppModel.self) private var model
    @State private var frostEnabled = false
    @State private var frostMin = 8.0
    @State private var frostMax = 12.0
    @State private var holidayEnabled = false
    @State private var holidayStart = Date()
    @State private var holidayEnd = Date().addingTimeInterval(7 * 86_400)
    @State private var loadedAt: Date?
    @State private var confirming: AwayChange?
    @State private var outcome: ChangeOutcome?
    @State private var sending = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                StatusBanner()
                InsightCard(
                    title: "Når huset står tomt",
                    detail: "Frostsikring holder rommet mellom en laveste og høyeste temperatur selv om varmepumpen ellers er av. Feriemodus gjør at varmepumpen følger frostsikringen i en periode du velger, og går tilbake til vanlige innstillinger etterpå. Begge deler lagres i MELCloud, så de virker selv om Macen er av.",
                    systemImage: "house.lodge.fill", tint: Theme.Data.blue)
                frostCard
                holidayCard
                statusFooter
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
        .onChange(of: model.away) { _, _ in sync(force: false) }
        .sheet(item: Binding(get: { confirming.map(ConfirmItem.init) }, set: { confirming = $0?.change })) { item in
            confirmSheet(item.change)
        }
    }

    private struct ConfirmItem: Identifiable {
        let change: AwayChange
        var id: String { change.field + change.valueDescription }
    }

    private func load() async {
        await model.loadAway()
        sync(force: true)
    }

    /// Copies the stored values into the editors (only when the user has not started editing).
    private func sync(force: Bool) {
        guard let away = model.away, force || loadedAt == nil else { return }
        if let fp = away.frost {
            frostEnabled = fp.enabled
            frostMin = fp.minimum
            frostMax = fp.maximum
        }
        if let hm = away.holiday {
            holidayEnabled = hm.enabled
            if let start = hm.start { holidayStart = start }
            if let end = hm.end { holidayEnd = end }
        }
        loadedAt = Date()
    }

    // MARK: Frost protection

    private var frostChange: AwayChange {
        .frostProtection(FrostProtection(enabled: frostEnabled, minimum: frostMin, maximum: frostMax))
    }

    private var frostCard: some View {
        let problem = frostChange.validationProblem(now: Date())
        let unchanged = model.away?.frost.map { $0.enabled == frostEnabled && $0.minimum == frostMin && $0.maximum == frostMax } ?? false
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Frostsikring", hint: model.away?.frost.map { "Nå: \($0.summary)" })
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Toggle("Frostsikring på", isOn: $frostEnabled).toggleStyle(.switch)
                    HStack(spacing: Theme.Space.xl) {
                        Stepper(value: $frostMin, in: FrostProtection.minimumRange, step: 1) {
                            Text("Laveste: \(Text(Norwegian.format("%.0f °C", frostMin)).monospacedDigit().bold())")
                        }
                        Stepper(value: $frostMax, in: FrostProtection.maximumRange, step: 1) {
                            Text("Høyeste: \(Text(Norwegian.format("%.0f °C", frostMax)).monospacedDigit().bold())")
                        }
                    }
                    .disabled(!frostEnabled)
                    Text("Laveste 4–14 °C, høyeste 6–16 °C, minst 2 grader mellom. 8–12 °C passer for et hus eller en hytte som står tom.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.Status.caution) }
                    HStack {
                        Spacer()
                        Button("Lagre frostsikring…") { confirming = frostChange }
                            .disabled(problem != nil || unchanged || sending || model.away?.frost == nil)
                    }
                }
            }
        }
    }

    // MARK: Holiday mode

    private var holidayChange: AwayChange {
        .holidayMode(HolidayMode(enabled: holidayEnabled, start: holidayStart, end: holidayEnd))
    }

    private var holidayCard: some View {
        let problem = holidayChange.validationProblem(now: Date())
        let unchanged = model.away?.holiday.map {
            $0.enabled == holidayEnabled && (!holidayEnabled || ($0.start == holidayStart && $0.end == holidayEnd))
        } ?? false
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Feriemodus", hint: model.away?.holiday.map { "Nå: \($0.summary)" })
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Toggle("Feriemodus på", isOn: $holidayEnabled).toggleStyle(.switch)
                    HStack(spacing: Theme.Space.xl) {
                        DatePicker("Fra", selection: $holidayStart, displayedComponents: [.date, .hourAndMinute])
                        DatePicker("Til", selection: $holidayEnd, in: holidayStart..., displayedComponents: [.date, .hourAndMinute])
                    }
                    .disabled(!holidayEnabled)
                    Text(
                        "I perioden holder varmepumpen frostsikringens temperatur"
                            + (model.away?.frost.map { $0.enabled ? Norwegian.format(" (%.0f–%.0f °C)", $0.minimum, $0.maximum) : " (frostsikring er av nå – slå den på først)" } ?? "")
                            + ". Tidene er norsk tid.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.Status.caution) }
                    HStack {
                        Spacer()
                        Button("Lagre feriemodus…") { confirming = holidayChange }
                            .disabled(problem != nil || unchanged || sending || model.away?.holiday == nil)
                    }
                }
            }
        }
    }

    // MARK: Status

    @ViewBuilder private var statusFooter: some View {
        if let outcome {
            InsightCard(
                title: outcome.result == .ok ? "Sendt til MELCloud" : "Ikke sendt", detail: outcome.message,
                systemImage: outcome.result == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: outcome.result == .ok ? Theme.Status.good : Theme.Status.caution)
        }
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let away = model.away {
                if let message = away.message { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.Status.caution) }
                Text(
                    away.fetchedAt.map { "Hentet fra MELCloud \(Format.relative($0))." }
                        ?? "Foreløpig fra MELCloud sin enhetsliste; hentes direkte høyst én gang i timen.")
                if away.pendingSince != nil { Text("Siste endring er sendt og bekreftes ved neste henting.") }
            } else {
                Text("Hentes fra MELCloud …")
            }
            Text("Dette er nye funksjoner som ikke er prøvd mot din konto ennå. Sjekk gjerne i MELCloud-appen at endringen er registrert. Hver endring teller som én av 12 sendinger i timen.")
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Confirmation

    private func confirmSheet(_ change: AwayChange) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Label("Bekreft endring", systemImage: "suitcase.fill").font(.title2.bold())
            Text(change.displaySummary).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Text(explanation(change)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Avbryt", role: .cancel) { confirming = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Send til MELCloud") {
                    let change = change
                    confirming = nil
                    sending = true
                    Task {
                        outcome = await model.applyAway(change)
                        sending = false
                        sync(force: true)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
    }

    private func explanation(_ change: AwayChange) -> String {
        switch change {
        case .frostProtection(let fp) where fp.enabled:
            Norwegian.format(
                "Når varmepumpen ellers står av, starter den av seg selv hvis rommet blir kaldere enn %.0f °C, og stopper rundt %.0f °C.",
                fp.minimum, fp.maximum)
        case .frostProtection:
            "Varmepumpen passer ikke lenger på at rommet ikke fryser når den står av."
        case .holidayMode(let hm) where hm.enabled:
            "I perioden følger varmepumpen frostsikringen i stedet for de vanlige innstillingene. Etterpå går den tilbake til slik den var."
        case .holidayMode:
            "Varmepumpen går tilbake til de vanlige innstillingene."
        }
    }
}
