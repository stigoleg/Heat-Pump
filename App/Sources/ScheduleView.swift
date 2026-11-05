import HeatPumpKit
import SwiftUI

/// MELCloud's weekly timer. Edits go into a draft; "Lagre i MELCloud" shows the differences and
/// sends the whole plan after confirmation. A plan the app could not decode is never editable.
struct ScheduleView: View {
    @Environment(AppModel.self) private var model
    /// The plan as read from MELCloud and the edited copy.
    @State private var base: WeeklyTimer?
    @State private var draft: WeeklyTimer?
    @State private var season = 0
    @State private var editor: EditorItem?
    @State private var confirming = false
    @State private var template: TimerTemplate?
    @State private var outcome: (ok: Bool, message: String)?
    @State private var sending = false
    @State private var fetching = false
    @State private var confirmingReload = false
    @State private var width: CGFloat = 1000

    /// Seven columns from this content width; a list of days below it.
    private static let weekGridMinWidth: CGFloat = 700

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                StatusBanner()
                header
                if let draft, draft.decoded {
                    editorSection(draft)
                        .disabled(sending)
                } else if let timer = model.weeklyTimer, !timer.decoded {
                    InsightCard(
                        title: timer.eventCount == 0 ? "Ukeplanen kunne ikke leses" : "Planen har \(timer.eventCount) hendelser i et ukjent format",
                        detail: "Appen viser og endrer bare planer den kan lese helt, så den ikke sletter hendelser den ikke forstår. Se og endre planen i MELCloud-appen, eller trykk «Hent nå».",
                        systemImage: "questionmark.circle.fill", tint: Theme.Status.caution)
                }
                footer
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width - 2 * Theme.Space.xl }) { width = $0 }
        }
        .task {
            if let kept = model.scheduleDraft {
                // Unsaved edits from the last visit.
                base = kept.base
                draft = kept.draft
                season = kept.season
                model.scheduleDraft = nil
            } else {
                sync(force: true)
            }
            await model.loadWeeklyTimerForEditing()
            sync(force: false)
        }
        .onChange(of: model.weeklyTimer) { _, _ in sync(force: false) }
        .onDisappear {
            if hasChanges, let base, let draft { model.scheduleDraft = ScheduleDraft(base: base, draft: draft, season: season) }
        }
        .sheet(item: $editor) { item in
            EventEditorSheet(
                item: item, limits: model.state?.limits ?? TemperatureLimits(), fanSpeeds: model.state?.numberOfFanSpeeds ?? 5,
                hasAutomaticFan: model.state?.hasAutomaticFanSpeed ?? true,
                apply: { event, days in
                    draft?.put(event, on: days, replacing: item.original, season: season)
                    outcome = nil
                },
                delete: item.original.map { original in
                    {
                        draft?.remove(original, season: season)
                        outcome = nil
                    }
                })
        }
        .sheet(isPresented: $confirming) { confirmSheet }
        .confirmationDialog("Hente planen på nytt?", isPresented: $confirmingReload) {
            Button("Forkast endringene og hent planen", role: .destructive) { Task { await reload() } }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Endringene du har gjort her forsvinner. Planen hentes fra MELCloud, og du kan gjøre endringene igjen.")
        }
        .confirmationDialog(
            "Bruke malen «\(template?.title ?? "")»?", isPresented: Binding(get: { template != nil }, set: { if !$0 { template = nil } }),
            presenting: template
        ) { template in
            Button("Erstatt alle hendelser", role: .destructive) { applyTemplate(template, replace: true) }
            Button("Legg til i planen") { applyTemplate(template, replace: false) }
            Button("Avbryt", role: .cancel) {}
        } message: { template in
            Text("\(template.detail) Varme. Du kan endre temperaturene etterpå. Ingenting lagres før du trykker «Lagre i MELCloud».")
        }
    }

    // MARK: Draft

    private var hasChanges: Bool {
        guard let draft, let base else { return false }
        return !draft.differences(from: base).isEmpty
    }

    /// MELCloud's plan (as last read) is no longer the one the draft was made from.
    private var changedElsewhere: Bool {
        guard hasChanges, let base, let latest = model.weeklyTimer else { return false }
        return !latest.hasSameContent(as: base)
    }

    /// Takes the stored plan as base and draft, unless the user has unsaved edits: then both stay,
    /// so a save is checked against the plan the edits were made on.
    private func sync(force: Bool) {
        guard let timer = model.weeklyTimer else { return }
        guard force || !hasChanges else { return }
        base = timer
        var copy = timer
        if copy.decoded { copy.ensureSeason() }
        draft = copy
        season = min(timer.activeSeasonIndex(on: Date(), timeZone: .current) ?? 0, max(copy.seasons.count - 1, 0))
    }

    private func discard() {
        outcome = nil
        sync(force: true)
    }

    /// "Hent planen på nytt": reads the plan (the save attempt usually just did) and drops the draft.
    private func reload() async {
        fetching = true
        await model.loadWeeklyTimerForEditing()
        fetching = false
        discard()
    }

    /// A new event starts from the unit's current settings.
    private func newEvent(days: Set<Int>) -> EditorItem {
        let state = model.state
        let mode = state?.mode ?? .heat
        let range = (state?.limits ?? TemperatureLimits()).range(for: mode)
        let temperature = min(max(((state?.setTemperature ?? 21) * 2).rounded() / 2, range.lowerBound), range.upperBound)
        let event = TimerEvent(
            weekday: days.min() ?? 1, minuteOfDay: 7 * 60, power: true, mode: mode, setTemperature: temperature,
            fanSpeed: state?.fanSpeed ?? 0, vaneHorizontal: state?.vaneHorizontal ?? .auto, vaneVertical: state?.vaneVertical ?? .auto)
        return EditorItem(original: nil, event: event, days: days)
    }

    private func applyTemplate(_ template: TimerTemplate, replace: Bool) {
        draft?.apply(template, base: newEvent(days: []).event, replace: replace, season: season)
        outcome = nil
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Ukeplan", hint: model.weeklyTimer?.fetchedAt.map { "Hentet \(Format.relative($0))" }) {
                Button {
                    fetching = true
                    Task {
                        await model.refreshWeeklyTimer()
                        fetching = false
                    }
                } label: {
                    if fetching { ProgressView().controlSize(.small) } else { Text("Hent nå") }
                }
                .disabled(fetching || hasChanges)
                .help(hasChanges ? "Lagre eller forkast endringene først." : "Henter ukeplanen fra MELCloud (høyst hvert 10. minutt; ellers automatisk hver 6. time).")
            }
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let until = model.timerRefusedUntil {
                        Label(
                            "MELCloud tillot ikke å lese ukeplanen for denne kontoen. Appen prøver igjen \(Format.relative(until)), eller trykk «Hent nå».",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(Theme.Status.caution)
                    }
                    if let draft, draft.decoded, draft.enabled == nil {
                        // MELCloud did not say: never shown (or saved) as off by guess.
                        LabeledContent("Ukjent om ukeplanen er på") {
                            Picker("Ukeplanen", selection: Binding(get: { draft.enabled }, set: { self.draft?.enabled = $0; outcome = nil })) {
                                Text("På").tag(Bool?.some(true))
                                Text("Av").tag(Bool?.some(false))
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                        .font(.body.weight(.medium))
                        .disabled(sending)
                        Text("MELCloud oppga ikke om planen er på. Velg på eller av før du lagrer.")
                            .font(.callout).foregroundStyle(Theme.Status.caution)
                    } else if let draft, draft.decoded {
                        Toggle(
                            "Ukeplanen er på",
                            isOn: Binding(get: { draft.enabled == true }, set: { self.draft?.enabled = $0; outcome = nil })
                        )
                        .toggleStyle(.switch)
                        .font(.body.weight(.medium))
                        .disabled(sending)
                    } else if model.weeklyTimer == nil {
                        Text("Ukeplanen hentes fra MELCloud …").foregroundStyle(.secondary)
                    }
                    Text(
                        "Planen ligger i MELCloud og kjører også når Macen er av, og den samme planen vises i MELCloud-appen. Endringer du gjør i Kontroll varer til neste hendelse i planen."
                    )
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let next = model.weeklyTimer?.nextEvent(after: Date(), timeZone: .current) {
                        Label(
                            "Neste: \(next.event.weekdayName) kl. \(next.event.timeText) – \(next.event.summary)",
                            systemImage: "clock")
                        .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Week

    private func editorSection(_ draft: WeeklyTimer) -> some View {
        let current = draft.seasons.indices.contains(season) ? draft.seasons[season] : TimerSeason()
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            FlowLayout(spacing: Theme.Space.m, alignment: .center) {
                if draft.seasons.count > 1 {
                    Picker("Sesong", selection: $season) {
                        ForEach(draft.seasons.indices, id: \.self) { index in
                            Text(draft.seasons[index].displayName).tag(index)
                        }
                    }
                    .fixedSize()
                }
                Button {
                    editor = newEvent(days: TimerEvent.weekdays)
                } label: {
                    Label("Ny hendelse", systemImage: "plus")
                }
                Menu {
                    ForEach(TimerTemplate.allCases) { item in
                        Button("\(item.title): \(item.detail)") { template = item }
                    }
                } label: {
                    Label("Mal", systemImage: "wand.and.stars")
                }
                .fixedSize()
            }
            CardSurface(padding: Theme.Space.m) {
                if width >= Self.weekGridMinWidth {
                    HStack(alignment: .top, spacing: Theme.Space.s) {
                        ForEach(1...7, id: \.self) { day in
                            VStack(alignment: .leading, spacing: 4) {
                                dayHeader(day, season: current)
                                ForEach(Array(current.events(on: day).enumerated()), id: \.offset) { _, event in
                                    chip(event, fill: true)
                                }
                                addButton(day)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(1...7, id: \.self) { day in
                            VStack(alignment: .leading, spacing: 4) {
                                dayHeader(day, season: current, long: true)
                                FlowLayout(spacing: 4, lineSpacing: 4, alignment: .center) {
                                    ForEach(Array(current.events(on: day).enumerated()), id: \.offset) { _, event in chip(event) }
                                    addButton(day)
                                }
                            }
                            if day < 7 { Divider() }
                        }
                    }
                }
            }
            if current.events.isEmpty {
                Text("Ingen hendelser ennå. Legg til en hendelse eller velg en mal.").font(.callout).foregroundStyle(.secondary)
            }
            saveBar(draft)
        }
    }

    private func dayHeader(_ day: Int, season: TimerSeason, long: Bool = false) -> some View {
        HStack(spacing: 2) {
            Text(long ? TimerEvent.weekdayNames[day - 1].capitalized : TimerEvent.shortWeekdayNames[day - 1].capitalized)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Menu {
                Section("Kopier \(TimerEvent.weekdayNames[day - 1]) til") {
                    Button("Hverdager") { copy(day, to: TimerEvent.weekdays) }
                    Button("Helg") { copy(day, to: TimerEvent.weekend) }
                    Button("Alle dager") { copy(day, to: TimerEvent.allDays) }
                    Divider()
                    ForEach((1...7).filter { $0 != day }, id: \.self) { target in
                        Button(TimerEvent.weekdayNames[target - 1].capitalized) { copy(day, to: [target]) }
                    }
                }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(season.events(on: day).isEmpty)
            .help("Kopier dag til …")
        }
    }

    private func copy(_ day: Int, to targets: Set<Int>) {
        draft?.copyDay(day, to: targets, season: season)
        outcome = nil
    }

    private func addButton(_ day: Int) -> some View {
        Button {
            editor = newEvent(days: [day])
        } label: {
            Image(systemName: "plus").font(.caption).frame(maxWidth: .infinity, minHeight: 18)
        }
        .buttonStyle(.borderless)
        .help("Ny hendelse \(TimerEvent.weekdayNames[day - 1])")
        .frame(minWidth: 28)
    }

    /// `fill` stretches the chip to the column width.
    private func chip(_ event: TimerEvent, fill: Bool = false) -> some View {
        Button {
            editor = EditorItem(original: event, event: event, days: draft?.days(of: event, season: season) ?? [event.weekday])
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(event.timeText).font(.caption.monospacedDigit().weight(.semibold))
                Text(event.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
            .background(
                (event.power == false ? Color.gray : (event.mode?.tint ?? .orange)).opacity(0.15), in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Endre hendelsen")
    }

    // MARK: Saving

    @ViewBuilder private func saveBar(_ draft: WeeklyTimer) -> some View {
        let problem = draft.validationProblem(limits: model.state?.limits)
        if changedElsewhere || outcome?.message.contains(HeatPumpService.timerChangedMessage) == true {
            InsightCard(
                title: "Planen er endret i MELCloud",
                detail: "Planen i MELCloud er ikke lenger den du begynte å redigere, så appen lagrer ikke over den. Hent planen på nytt og gjør endringene igjen.",
                systemImage: "arrow.triangle.2.circlepath", tint: Theme.Status.caution)
            Button("Hent planen på nytt…") { confirmingReload = true }
                .disabled(fetching || sending)
        }
        if hasChanges {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.Status.caution)
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Endringene er ikke lagret ennå.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    saveButtons(problem: problem)
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Endringene er ikke lagret ennå.").font(.callout).foregroundStyle(.secondary)
                    HStack { saveButtons(problem: problem) }
                }
            }
        }
    }

    @ViewBuilder private func saveButtons(problem: String?) -> some View {
        Button("Forkast endringer", role: .destructive) { discard() }
            .disabled(sending)
        Button("Lagre i MELCloud…") { confirming = true }
            .buttonStyle(.borderedProminent)
            .disabled(problem != nil || sending)
    }

    @ViewBuilder private var footer: some View {
        if sending {
            ProgressView("Lagrer i MELCloud …").controlSize(.small)
        }
        if let outcome {
            InsightCard(
                title: outcome.ok ? "Lagret i MELCloud" : "Ikke lagret", detail: outcome.message,
                systemImage: outcome.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: outcome.ok ? Theme.Status.good : Theme.Status.caution)
        }
        Text("Lagringen er ny og ikke prøvd mot din konto ennå. Sjekk gjerne i MELCloud-appen at planen er riktig. Hver lagring teller som én av \(ChangeBudget.maxChangesPerHour) sendinger i timen.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var confirmSheet: some View {
        let lines = draft.flatMap { d in base.map { d.differences(from: $0) } } ?? []
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            Label("Lagre ukeplanen i MELCloud", systemImage: "calendar.badge.clock").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text("• " + line).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            Text(
                "Hele planen sendes (\(draft?.summary.lowercased() ?? "")). Den gjelder fra neste hendelse og kjører i MELCloud også når Macen er av."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Avbryt", role: .cancel) { confirming = false }
                    .keyboardShortcut(.cancelAction)
                Button("Lagre i MELCloud") {
                    confirming = false
                    guard let draft, let base else { return }
                    sending = true
                    Task {
                        outcome = await model.saveWeeklyTimer(draft, base: base)
                        sending = false
                        if outcome?.ok == true { sync(force: true) }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 500)
    }
}

/// Unsaved edits of the Ukeplan page, kept in `AppModel` while another page is shown.
struct ScheduleDraft {
    var base: WeeklyTimer
    var draft: WeeklyTimer
    var season: Int
}

/// An event being edited: the original (nil for a new one) and the days it occurs on.
struct EditorItem: Identifiable {
    let id = UUID()
    var original: TimerEvent?
    var event: TimerEvent
    var days: Set<Int>
}

/// Sheet for one event: days, time, on/off, mode, temperature, fan and vanes. Changes go into the
/// draft ("Bruk"); nothing is sent from here.
struct EventEditorSheet: View {
    let item: EditorItem
    let limits: TemperatureLimits
    let fanSpeeds: Int
    let hasAutomaticFan: Bool
    let apply: (TimerEvent, Set<Int>) -> Void
    let delete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var event: TimerEvent
    @State private var days: Set<Int>

    init(
        item: EditorItem, limits: TemperatureLimits, fanSpeeds: Int, hasAutomaticFan: Bool,
        apply: @escaping (TimerEvent, Set<Int>) -> Void, delete: (() -> Void)?
    ) {
        self.item = item
        self.limits = limits
        self.fanSpeeds = fanSpeeds
        self.hasAutomaticFan = hasAutomaticFan
        self.apply = apply
        self.delete = delete
        _event = State(initialValue: item.event)
        _days = State(initialValue: item.days)
    }

    private var mode: OperationMode { event.mode ?? .heat }
    private var range: ClosedRange<Double> { limits.range(for: mode) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(item.original == nil ? "Ny hendelse" : "Endre hendelse").font(.title2.bold())
            Form {
                LabeledContent("Dager") {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        FlowLayout(spacing: 4, lineSpacing: 4) {
                            ForEach(1...7, id: \.self) { day in
                                Toggle(
                                    TimerEvent.shortWeekdayNames[day - 1].prefix(2).capitalized,
                                    isOn: Binding(
                                        get: { days.contains(day) },
                                        set: { on in if on { days.insert(day) } else { days.remove(day) } })
                                )
                                .toggleStyle(.button)
                            }
                        }
                        HStack(spacing: Theme.Space.s) {
                            Button("Hverdager") { days = TimerEvent.weekdays }
                            Button("Helg") { days = TimerEvent.weekend }
                            Button("Alle dager") { days = TimerEvent.allDays }
                        }
                        .controlSize(.small)
                    }
                }
                LabeledContent("Tid") {
                    HStack(spacing: 4) {
                        Picker("Time", selection: $event.minuteOfDay.hour) {
                            ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Text(":")
                        Picker("Minutt", selection: $event.minuteOfDay.minute) {
                            ForEach(minuteOptions, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                Picker("Av/på", selection: Binding(get: { event.power != false }, set: { event.power = $0 })) {
                    Text("På").tag(true)
                    Text("Av").tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Group {
                    Picker("Modus", selection: Binding(get: { mode }, set: { setMode($0) })) {
                        ForEach(OperationMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .fixedSize()
                    Stepper(
                        value: Binding(get: { event.setTemperature ?? range.lowerBound }, set: { event.setTemperature = $0 }), in: range,
                        step: 0.5
                    ) {
                        Text("Temperatur: \(Text(Format.temperature(event.setTemperature)).monospacedDigit().bold())")
                    }
                    Picker("Vifte", selection: Binding(get: { event.fanSpeed ?? 0 }, set: { event.fanSpeed = $0 })) {
                        ForEach(fanOptions, id: \.self) { Text($0 == 0 ? "Auto" : "\($0)").tag($0) }
                    }
                    .fixedSize()
                    Picker("Spjeld opp/ned", selection: Binding(get: { event.vaneVertical ?? .auto }, set: { event.vaneVertical = $0 })) {
                        ForEach(VaneVertical.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .fixedSize()
                    Picker("Spjeld side", selection: Binding(get: { event.vaneHorizontal ?? .auto }, set: { event.vaneHorizontal = $0 })) {
                        ForEach(VaneHorizontal.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .fixedSize()
                }
                .disabled(event.power == false)
            }
            Text("Endringen lagres i MELCloud først når du trykker «Lagre i MELCloud» på siden.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let delete {
                    Button("Slett", role: .destructive) {
                        delete()
                        dismiss()
                    }
                    .help("Sletter hendelsen kl. \(item.event.timeText) på alle dagene den gjelder")
                }
                Spacer()
                Button("Avbryt", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Bruk") {
                    apply(event, days)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(days.isEmpty)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 580)
    }

    /// Five-minute steps, plus the event's own minute when it is between them.
    private var minuteOptions: [Int] {
        Array(Set(Array(stride(from: 0, to: 60, by: 5)) + [event.minuteOfDay % 60])).sorted()
    }

    private var fanOptions: [Int] {
        (hasAutomaticFan ? [0] : []) + Array(1...max(fanSpeeds, 1))
    }

    /// Keeps the temperature inside the new mode's limits.
    private func setMode(_ newMode: OperationMode) {
        event.mode = newMode
        let range = limits.range(for: newMode)
        if let value = event.setTemperature { event.setTemperature = min(max(value, range.lowerBound), range.upperBound) }
    }
}

extension Int {
    /// Hour of a minute-of-day value (for pickers).
    fileprivate var hour: Int {
        get { self / 60 }
        set { self = newValue * 60 + self % 60 }
    }

    /// Minute of a minute-of-day value (for pickers).
    fileprivate var minute: Int {
        get { self % 60 }
        set { self = (self / 60) * 60 + newValue }
    }
}
