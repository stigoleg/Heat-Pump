import HeatPumpKit
import SwiftUI

/// Frost protection and holiday mode in MELCloud. Unlike Control these are not sent
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
                    title: "When the house is empty",
                    detail: "Frost protection keeps the room between a lowest and a highest temperature even when the heat pump is otherwise off. In holiday mode the heat pump can be off for a period you choose, and frost protection is then what keeps the house from getting too cold; that is why frost protection must be on first. Both are stored in \(model.serviceName), so they work even when the Mac is off.",
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
        let problem = frostChange.validationProblem(now: Date()) ?? frostChange.safetyProblem(current: model.away, now: Date(), serviceName: model.serviceName)
        let unchanged = model.away?.frost.map { $0.enabled == frostEnabled && $0.minimum == frostMin && $0.maximum == frostMax } ?? false
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Frost protection", hint: model.away?.frost.map { "Now: \($0.summary)" })
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Toggle("Frost protection on", isOn: $frostEnabled).toggleStyle(.switch)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Theme.Space.xl) { frostSteppers }
                        VStack(alignment: .leading, spacing: Theme.Space.s) { frostSteppers }
                    }
                    .disabled(!frostEnabled)
                    Text("Lowest 4–14 °C, highest 6–16 °C, at least 2 degrees apart. 8–12 °C suits an empty house or cabin.")
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
                        Button("Save Frost Protection…") { confirming = frostChange }
                            .disabled(problem != nil || unchanged || sending || model.away?.frost == nil)
                    }
                }
            }
        }
    }

    @ViewBuilder private var frostSteppers: some View {
        Stepper(value: $frostMin, in: FrostProtection.minimumRange, step: 1) {
            Text("Lowest: \(Text(Display.format("%.0f °C", frostMin)).monospacedDigit().bold())")
        }
        Stepper(value: $frostMax, in: FrostProtection.maximumRange, step: 1) {
            Text("Highest: \(Text(Display.format("%.0f °C", frostMax)).monospacedDigit().bold())")
        }
    }

    // MARK: Holiday mode

    private var holidayChange: AwayChange {
        .holidayMode(HolidayMode(enabled: holidayEnabled, start: holidayStart, end: holidayEnd))
    }

    private var holidayCard: some View {
        let problem = holidayChange.validationProblem(now: Date()) ?? holidayChange.safetyProblem(current: model.away, now: Date(), serviceName: model.serviceName)
        let unchanged = model.away?.holiday.map {
            $0.enabled == holidayEnabled && (!holidayEnabled || ($0.start == holidayStart && $0.end == holidayEnd))
        } ?? false
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Holiday mode", hint: model.away?.holiday.map { "Now: \($0.summary)" })
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Toggle("Holiday mode on", isOn: $holidayEnabled).toggleStyle(.switch)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Theme.Space.xl) { holidayPickers }
                        VStack(alignment: .leading, spacing: Theme.Space.s) { holidayPickers }
                    }
                    .disabled(!holidayEnabled)
                    Text(holidayNote)
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
                        Button("Save Holiday Mode…") { confirming = holidayChange }
                            .disabled(problem != nil || unchanged || sending || model.away?.holiday == nil)
                    }
                }
            }
        }
    }

    @ViewBuilder private var holidayPickers: some View {
        DatePicker("From", selection: $holidayStart, displayedComponents: [.date, .hourAndMinute])
        DatePicker("To", selection: $holidayEnd, in: holidayStart..., displayedComponents: [.date, .hourAndMinute])
    }

    private var holidayNote: String {
        guard let frost = model.away?.frost else {
            return String(localized: "In holiday mode the heat pump may be off; frost protection then keeps the house warm enough – the app does not know whether it is on. Times are Norwegian time.")
        }
        guard frost.enabled else {
            return String(localized: "In holiday mode the heat pump may be off; frost protection then keeps the house warm enough – it is off now, so turn it on first. Times are Norwegian time.")
        }
        let range = Display.format("%.0f–%.0f °C", frost.minimum, frost.maximum)
        return String(localized: "In holiday mode the heat pump may be off; frost protection then keeps the house warm enough (now \(range)). Times are Norwegian time.")
    }

    /// What was sent next to what MELCloud reads back, so an offset in the times is obvious.
    private func comparison(sent: String, read: String?, at: Date, matches: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sent \(Format.relative(at)): \(sent)")
            Text("\(model.serviceName) shows: \(read ?? String(localized: "not read yet"))")
            if read != nil && !matches {
                Label("Not the same. Check in the \(model.serviceName) app which applies.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Status.caution)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Status

    @ViewBuilder private var statusFooter: some View {
        if let outcome {
            InsightCard(
                title: outcome.ok ? "Sent to \(model.serviceName)" : "Not sent", detail: .verbatim(outcome.message),
                systemImage: outcome.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: outcome.ok ? Theme.Status.good : Theme.Status.caution)
        }
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let away = model.away {
                if let message = away.message { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.Status.caution) }
                if away.refusedUntil != nil {
                    Button("Try Again") { Task { await model.loadAway(manual: true); sync(force: true) } }
                }
                Text(
                    away.fetchedAt.map { String(localized: "Fetched from \(model.serviceName) \(Format.relative($0)).") }
                        ?? String(localized: "For now from \(model.serviceName)’s device list; fetched directly at most once an hour."))
                if away.pendingSince != nil { Text("The latest change has been sent and will be confirmed at the next fetch.") }
            } else {
                Text("Fetching from \(model.serviceName)…")
            }
            Text("These are new features that have not been tried against your account yet. Feel free to check in the \(model.serviceName) app that the change has been registered. Each change counts as one of 12 sends per hour.")
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Confirmation

    private func confirmSheet(_ change: AwayChange) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Label("Confirm change", systemImage: "suitcase.fill").font(.title2.bold())
            Text(change.displaySummary(frost: model.away?.frost)).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Text(explanation(change)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { confirming = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Send to \(model.serviceName)") {
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
            String(
                localized: "When the heat pump is otherwise off, it starts by itself if the room gets colder than \(Display.format("%.0f °C", fp.minimum)), and stops around \(Display.format("%.0f °C", fp.maximum)).")
        case .frostProtection:
            String(localized: "The heat pump no longer keeps the room from freezing when it is off.")
        case .holidayMode(let hm) where hm.enabled:
            String(localized: "During the period the heat pump may be off, and frost protection makes sure the house does not get too cold. Afterwards it goes back to how it was. The times \(model.serviceName) stores are shown on the page afterwards; compare them with what you chose.")
        case .holidayMode:
            String(localized: "The heat pump goes back to the usual settings.")
        }
    }
}
