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
    @State private var outcome: (ok: Bool, message: String)?
    @State private var sending = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                StatusBanner()
                InsightCard(
                    title: "Når huset står tomt",
                    detail: "Frostsikring holder rommet mellom en laveste og høyeste temperatur selv om varmepumpen ellers er av. I feriemodus kan varmepumpen stå av i en periode du velger, og da er det frostsikringen som hindrer at huset blir for kaldt; derfor må frostsikring være på først. Begge deler lagres i MELCloud, så de virker selv om Macen er av.",
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
        let problem = frostChange.validationProblem(now: Date()) ?? frostChange.safetyProblem(current: model.away, now: Date())
        let unchanged = model.away?.frost.map { $0.enabled == frostEnabled && $0.minimum == frostMin && $0.maximum == frostMax } ?? false
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Frostsikring", hint: model.away?.frost.map { "Nå: \($0.summary)" })
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Toggle("Frostsikring på", isOn: $frostEnabled).toggleStyle(.switch)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Theme.Space.xl) { frostSteppers }
                        VStack(alignment: .leading, spacing: Theme.Space.s) { frostSteppers }
                    }
                    .disabled(!frostEnabled)
                    Text("Laveste 4–14 °C, høyeste 6–16 °C, minst 2 grader mellom. 8–12 °C passer for et hus eller en hytte som står tom.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let problem, !unchanged {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.Status.caution)
                    }
                    if let sent = model.away?.sentFrost, let at = model.away?.sentAt {
                        comparison(
                            sent: sent.summary, read: model.away?.pendingSince == nil ? model.away?.frost?.summary : nil, at: at,
                            matches: model.away?.frost.map { $0.enabled == sent.enabled && $0.minimum == sent.minimum && $0.maximum == sent.maximum } ?? false)
                    }
                    HStack {
                        Spacer()
                        Button("Lagre frostsikring…") { confirming = frostChange }
                            .disabled(problem != nil || unchanged || sending || model.away?.frost == nil)
                    }
                }
            }
        }
    }

    @ViewBuilder private var frostSteppers: some View {
        Stepper(value: $frostMin, in: FrostProtection.minimumRange, step: 1) {
            Text("Laveste: \(Text(Display.format("%.0f °C", frostMin)).monospacedDigit().bold())")
        }
        Stepper(value: $frostMax, in: FrostProtection.maximumRange, step: 1) {
            Text("Høyeste: \(Text(Display.format("%.0f °C", frostMax)).monospacedDigit().bold())")
        }
    }

    // MARK: Holiday mode

    private var holidayChange: AwayChange {
        .holidayMode(HolidayMode(enabled: holidayEnabled, start: holidayStart, end: holidayEnd))
    }

    private var holidayCard: some View {
        let problem = holidayChange.validationProblem(now: Date()) ?? holidayChange.safetyProblem(current: model.away, now: Date())
        let unchanged = model.away?.holiday.map {
            $0.enabled == holidayEnabled && (!holidayEnabled || ($0.start == holidayStart && $0.end == holidayEnd))
        } ?? false
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Feriemodus", hint: model.away?.holiday.map { "Nå: \($0.summary)" })
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Toggle("Feriemodus på", isOn: $holidayEnabled).toggleStyle(.switch)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Theme.Space.xl) { holidayPickers }
                        VStack(alignment: .leading, spacing: Theme.Space.s) { holidayPickers }
                    }
                    .disabled(!holidayEnabled)
                    Text(
                        "I feriemodus kan varmepumpen stå av; da er det frostsikringen som holder huset varmt nok"
                            + (model.away?.frost.map { $0.enabled ? Display.format(" (nå %.0f–%.0f °C)", $0.minimum, $0.maximum) : " – den er av nå, så slå den på først" } ?? " – appen vet ikke om den er på")
                            + ". Tidene er norsk tid.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let problem, !unchanged {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.Status.caution)
                    }
                    if let sent = model.away?.sentHoliday, let at = model.away?.sentAt {
                        let read = model.away?.pendingSince == nil ? model.away?.holiday : nil
                        comparison(
                            sent: sent.summary, read: read?.summary, at: at,
                            matches: read?.enabled == sent.enabled && (!sent.enabled || (read?.start == sent.start && read?.end == sent.end)))
                    }
                    HStack {
                        Spacer()
                        Button("Lagre feriemodus…") { confirming = holidayChange }
                            .disabled(problem != nil || unchanged || sending || model.away?.holiday == nil)
                    }
                }
            }
        }
    }

    @ViewBuilder private var holidayPickers: some View {
        DatePicker("Fra", selection: $holidayStart, displayedComponents: [.date, .hourAndMinute])
        DatePicker("Til", selection: $holidayEnd, in: holidayStart..., displayedComponents: [.date, .hourAndMinute])
    }

    /// What was sent next to what MELCloud reads back, so an offset in the times is obvious.
    private func comparison(sent: String, read: String?, at: Date, matches: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sendt \(Format.relative(at)): \(sent)")
            Text("MELCloud viser: \(read ?? "ikke lest ennå")")
            if read != nil && !matches {
                Label("Ikke det samme. Sjekk i MELCloud-appen hva som gjelder.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Status.caution)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Status

    @ViewBuilder private var statusFooter: some View {
        if let outcome {
            InsightCard(
                title: outcome.ok ? "Sendt til MELCloud" : "Ikke sendt", detail: .verbatim(outcome.message),
                systemImage: outcome.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: outcome.ok ? Theme.Status.good : Theme.Status.caution)
        }
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let away = model.away {
                if let message = away.message { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.Status.caution) }
                if away.refusedUntil != nil {
                    Button("Prøv igjen") { Task { await model.loadAway(manual: true); sync(force: true) } }
                }
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
            Text(change.displaySummary(frost: model.away?.frost)).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
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
            Display.format(
                "Når varmepumpen ellers står av, starter den av seg selv hvis rommet blir kaldere enn %.0f °C, og stopper rundt %.0f °C.",
                fp.minimum, fp.maximum)
        case .frostProtection:
            "Varmepumpen passer ikke lenger på at rommet ikke fryser når den står av."
        case .holidayMode(let hm) where hm.enabled:
            "I perioden kan varmepumpen stå av, og frostsikringen passer på at huset ikke blir for kaldt. Etterpå går den tilbake til slik den var. Tidene MELCloud lagrer vises på siden etterpå; sammenlign dem med det du valgte."
        case .holidayMode:
            "Varmepumpen går tilbake til de vanlige innstillingene."
        }
    }
}
