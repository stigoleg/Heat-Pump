import HeatPumpKit
import SwiftUI

/// Controls. Every edit goes into one draft that is sent automatically about 2 s after the
/// last change (see `ChangeDebouncer`); the chip at the top shows how far it has come.
struct ControlView: View {
    @Environment(AppModel.self) private var model
    /// True while the slider is dragged; edits then wait for the release.
    @State private var sliderEditing = false

    var body: some View {
        Group {
            if let state = model.state, let debouncer = model.debouncer {
                content(state: state, debouncer: debouncer)
            } else {
                ContentUnavailableView(
                    "Ingen status ennå", systemImage: "slider.horizontal.3",
                    description: Text("Kontrollene blir tilgjengelige når status er hentet."))
            }
        }
    }

    private func content(state: DeviceState, debouncer: ChangeDebouncer) -> some View {
        let shown = debouncer.displayed ?? ControlSettings(state)
        let mode = debouncer.displayedMode
        return ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: 0) {
                    StatusBanner(bottomSpacing: Theme.Space.l)
                    HStack(alignment: .center, spacing: Theme.Space.m) {
                        Text(
                            "Endringer sendes automatisk et par sekunder etter at du har stilt inn."
                                + (model.weeklyTimer?.enabled == true ? " Ukeplanen i MELCloud er på, så varmepumpen kan også endre seg selv." : ""))
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: Theme.Space.s)
                        StatusChip(status: debouncer.status, remaining: debouncer.remainingThisHour)
                    }
                }
                if mode == nil {
                    InsightCard(
                        title: "Modus ukjent – velg modus",
                        detail: "Varmepumpen rapporterer ingen gyldig modus. Velg for eksempel Varme under Modus før du endrer temperaturen.",
                        systemImage: "questionmark.circle.fill", tint: Theme.Status.caution)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.l) {
                        powerCard(shown, debouncer).frame(width: 220)
                        temperatureCard(shown, mode: mode, state: state, debouncer: debouncer).frame(minWidth: 380)
                    }
                    VStack(spacing: Theme.Space.l) {
                        powerCard(shown, debouncer)
                        temperatureCard(shown, mode: mode, state: state, debouncer: debouncer)
                    }
                }
                modeSection(mode, debouncer)
                fanSection(shown, state: state, debouncer: debouncer)
                vaneSection(shown, debouncer)
                WeeklyTimerSection().id("timer")
                Text(
                    "Det kan ta et par minutter før varmepumpen bekrefter. Maks \(ChangeBudget.maxChangesPerHour) sendinger per time, til sammen for appen og Claude; flere endringer rett etter hverandre samles i én sending."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .devScrollTarget(proxy)
        }
    }

    // MARK: Power

    private func powerCard(_ shown: ControlSettings, _ debouncer: ChangeDebouncer) -> some View {
        CardSurface {
            VStack(spacing: Theme.Space.m) {
                Button {
                    debouncer.edit(.power(!shown.power))
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(shown.power ? .white : .secondary)
                        .frame(width: 96, height: 96)
                        .background(
                            shown.power ? AnyShapeStyle(Theme.Status.good.gradient) : AnyShapeStyle(Color.primary.opacity(0.06)),
                            in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(shown.power ? "Slå av varmepumpen" : "Slå på varmepumpen")
                Text(shown.power ? "Varmepumpen er på" : "Varmepumpen er av")
                    .font(.headline)
                Text("Trykk for å slå \(shown.power ? "av" : "på").").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Temperature

    private func temperatureCard(_ shown: ControlSettings, mode: OperationMode?, state: DeviceState, debouncer: ChangeDebouncer) -> some View {
        let range = state.limits.range(for: mode ?? .heat)
        let step = state.temperatureIncrement > 0 ? state.temperatureIncrement : 0.5
        let tint = mode?.tint ?? .secondary
        // Keyboard and VoiceOver changes commit at once; a drag waits for the release.
        let binding = Binding<Double>(
            get: { shown.setTemperature },
            set: {
                debouncer.edit(
                    .temperature(min(max(($0 / step).rounded() * step, range.lowerBound), range.upperBound)),
                    commit: !sliderEditing)
            })
        return CardSurface {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Ønsket temperatur", systemImage: "thermometer.medium").foregroundStyle(.secondary)
                    Spacer()
                    Text("Inne nå \(Format.temperature(state.roomTemperature))").font(.callout).foregroundStyle(.secondary)
                }
                HStack(alignment: .center, spacing: Theme.Space.l) {
                    Text(Format.temperature(shown.setTemperature))
                        .font(.system(size: 52, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                    Spacer()
                    Stepper("Ønsket temperatur", value: Binding(get: { shown.setTemperature }, set: { debouncer.edit(.temperature($0)) }), in: range, step: step)
                        .labelsHidden()
                }
                Slider(value: binding, in: range, step: step) {
                    Text("Ønsket temperatur")
                } minimumValueLabel: {
                    Text(Norwegian.format("%.0f°", range.lowerBound)).font(.caption)
                } maximumValueLabel: {
                    Text(Norwegian.format("%.0f°", range.upperBound)).font(.caption)
                } onEditingChanged: { editing in
                    sliderEditing = editing
                    if !editing { debouncer.commit() }
                }
                .labelsHidden()
                .tint(tint)
                Text(
                    Norwegian.format(
                        "Tillatt i %@: %.0f–%.0f °C. Små justeringer (1–2 grader) er nok.",
                        (mode?.displayName ?? "varme").lowercased(), range.lowerBound, range.upperBound)
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Mode

    private func modeSection(_ current: OperationMode?, _ debouncer: ChangeDebouncer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Modus", hint: "Varme er riktig valg om vinteren")
            HStack(spacing: Theme.Space.m) {
                ForEach([OperationMode.heat, .cool, .dry, .fan, .auto], id: \.self) { mode in
                    let selected = current == mode
                    Button {
                        debouncer.edit(.mode(mode))
                    } label: {
                        VStack(spacing: Theme.Space.s) {
                            Image(systemName: mode.systemImage)
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(selected ? .white : mode.tint)
                                .frame(width: 56, height: 56)
                                .background(
                                    selected ? AnyShapeStyle(mode.tint.gradient) : AnyShapeStyle(mode.tint.opacity(0.12)),
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                            Text(mode.displayName).font(.callout.weight(selected ? .semibold : .regular))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Space.s)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text(current.map(modeHelp) ?? "Modus ukjent – velg modus.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func modeHelp(_ mode: OperationMode) -> String {
        switch mode {
        case .heat: "Varme: varmer opp rommet til ønsket temperatur."
        case .cool: "Kjøling: kjøler ned rommet om sommeren."
        case .dry: "Avfukting: tar fukt ut av lufta, med litt kjøling."
        case .fan: "Vifte: sirkulerer lufta uten å varme eller kjøle."
        case .auto: "Auto: velger selv mellom varme og kjøling."
        }
    }

    // MARK: Fan

    private func fanSection(_ shown: ControlSettings, state: DeviceState, debouncer: ChangeDebouncer) -> some View {
        let speeds = (state.hasAutomaticFanSpeed ? [0] : []) + Array(1...max(state.numberOfFanSpeeds, 1))
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Viftehastighet", hint: "Auto er stillest og passer nesten alltid")
            HStack(spacing: 0) {
                ForEach(speeds, id: \.self) { speed in
                    let selected = shown.fanSpeed == speed
                    Button {
                        debouncer.edit(.fanSpeed(speed))
                    } label: {
                        VStack(spacing: 4) {
                            if speed == 0 {
                                Image(systemName: "a.circle").font(.title3)
                                Text("Auto").font(.caption)
                            } else {
                                HStack(spacing: 2) {
                                    ForEach(1...max(state.numberOfFanSpeeds, 1), id: \.self) { i in
                                        Capsule()
                                            .fill(i <= speed ? AnyShapeStyle(Theme.Data.blue) : AnyShapeStyle(Color.primary.opacity(0.12)))
                                            .frame(width: 4, height: 6 + CGFloat(i) * 3)
                                    }
                                }
                                .frame(height: 22, alignment: .bottom)
                                Text("\(speed)").font(.caption)
                            }
                        }
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(
                            selected ? AnyShapeStyle(Theme.surface) : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                        .overlay {
                            if selected { RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Theme.Data.blue.opacity(0.6)) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(speed == 0 ? "Vifte auto" : "Viftehastighet \(speed)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(4)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.small + 4))
        }
    }

    // MARK: Vanes

    private func vaneSection(_ shown: ControlSettings, _ debouncer: ChangeDebouncer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Luftretning", hint: "Ved oppvarming: nederste stilling eller Auto, så varmen når gulvet")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: Theme.Space.l, alignment: .top)], spacing: Theme.Space.l) {
                CardSurface {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("Opp/ned").font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: Theme.Space.s) {
                            ForEach(VaneVertical.allCases, id: \.self) { vane in
                                VaneButton(
                                    selected: shown.vaneVertical == vane, title: vane.shortTitle,
                                    accessibility: "Opp/ned: \(vane.displayName)"
                                ) {
                                    VaneGlyph(kind: vane.glyph(vertical: true))
                                } action: { debouncer.edit(.vaneVertical(vane)) }
                            }
                        }
                    }
                }
                CardSurface {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("Venstre/høyre").font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: Theme.Space.s) {
                            ForEach(VaneHorizontal.allCases, id: \.self) { vane in
                                VaneButton(
                                    selected: shown.vaneHorizontal == vane, title: vane.shortTitle,
                                    accessibility: "Venstre/høyre: \(vane.displayName)"
                                ) {
                                    VaneGlyph(kind: vane.glyph)
                                } action: { debouncer.edit(.vaneHorizontal(vane)) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct VaneButton<Glyph: View>: View {
    let selected: Bool
    let title: String
    let accessibility: String
    @ViewBuilder var glyph: Glyph
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                glyph
                    .frame(width: 30, height: 30)
                    .foregroundStyle(selected ? Theme.Data.blue : Color.secondary)
                Text(title).font(.caption2).foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(minWidth: 38, minHeight: 50)
            .padding(.horizontal, 2)
            .background(
                selected ? AnyShapeStyle(Theme.Data.blue.opacity(0.1)) : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Small diagram of where the air goes.
enum VaneGlyphKind: Equatable {
    case auto, swing(vertical: Bool), split
    /// Angle in degrees from straight ahead (positive = down / right).
    case direction(Double, vertical: Bool)
}

struct VaneGlyph: View {
    let kind: VaneGlyphKind

    var body: some View {
        switch kind {
        case .auto: Image(systemName: "a.circle").font(.title3)
        case .swing(let vertical): Image(systemName: vertical ? "arrow.up.and.down" : "arrow.left.and.right").font(.title3)
        case .split: Image(systemName: "arrow.left.and.right.circle").font(.title3)
        case .direction(let angle, let vertical):
            Canvas { context, size in
                let origin = vertical ? CGPoint(x: 4, y: size.height / 2) : CGPoint(x: size.width / 2, y: 4)
                let length = (vertical ? size.width : size.height) - 8
                let radians = angle * .pi / 180
                let end =
                    vertical
                    ? CGPoint(x: origin.x + length * cos(radians), y: origin.y + length * sin(radians))
                    : CGPoint(x: origin.x + length * sin(radians), y: origin.y + length * cos(radians))
                var line = Path()
                line.move(to: origin)
                line.addLine(to: end)
                context.stroke(line, with: .foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: origin.x - 2.5, y: origin.y - 2.5, width: 5, height: 5)), with: .foreground)
                let head = CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)
                context.fill(Path(ellipseIn: head), with: .foreground)
            }
        }
    }
}

extension VaneVertical {
    var shortTitle: String {
        switch self {
        case .auto: "Auto"
        case .swing: "Sving"
        default: "\(rawValue)"
        }
    }

    func glyph(vertical: Bool) -> VaneGlyphKind {
        switch self {
        case .auto: .auto
        case .swing: .swing(vertical: true)
        // 1 = top (nearly horizontal) … 5 = bottom (pointing down).
        default: .direction(Double(rawValue - 1) * 17 - 5, vertical: true)
        }
    }
}

extension VaneHorizontal {
    var shortTitle: String {
        switch self {
        case .auto: "Auto"
        case .swing: "Sving"
        case .split: "Delt"
        default: "\(rawValue)"
        }
    }

    var glyph: VaneGlyphKind {
        switch self {
        case .auto: .auto
        case .swing: .swing(vertical: false)
        case .split: .split
        // 1 = left … 5 = right.
        default: .direction(Double(rawValue - 3) * 25, vertical: false)
        }
    }
}

/// MELCloud's weekly timer, read-only. Events are shown in a week grid when they could be
/// decoded; otherwise only whether the plan is on and how many events it has.
struct WeeklyTimerSection: View {
    @Environment(AppModel.self) private var model
    @State private var fetching = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Ukeplan", hint: "Fra MELCloud, kan bare leses") {
                Button {
                    fetching = true
                    Task {
                        await model.refreshWeeklyTimer()
                        fetching = false
                    }
                } label: {
                    if fetching { ProgressView().controlSize(.small) } else { Text("Hent nå") }
                }
                .disabled(fetching)
                .help("Henter ukeplanen fra MELCloud (høyst hvert 10. minutt; ellers automatisk hver 6. time).")
            }
            CardSurface {
                if let until = model.timerRefusedUntil {
                    Label(
                        "MELCloud tillot ikke å lese ukeplanen for denne kontoen. Appen prøver igjen \(Format.relative(until)), eller trykk «Hent nå».",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let timer = model.weeklyTimer {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        Label(
                            timer.enabled == true ? "Ukeplanen er på" : timer.enabled == false ? "Ukeplanen er av" : "Ukjent om ukeplanen er på",
                            systemImage: timer.enabled == true ? "calendar.badge.clock" : "calendar")
                        .font(.body.weight(.medium))
                        .foregroundStyle(timer.enabled == true ? Theme.Status.info : .secondary)
                        if timer.decoded {
                            grid(timer)
                            if let next = timer.nextEvent(after: Date(), timeZone: .current) {
                                Text("Neste: \(next.event.weekdayName) kl. \(next.event.timeText) – \(next.event.summary)")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(
                                timer.eventCount == 0
                                    ? "Ingen hendelser i planen."
                                    : "Planen har \(timer.eventCount) hendelser, men formatet er ukjent, så de kan ikke vises her ennå. Se planen i MELCloud-appen.")
                            .font(.callout).foregroundStyle(.secondary)
                        }
                        Text(
                            "Når ukeplanen er på, kan varmepumpen slå seg av og på eller endre temperatur etter planen, uavhengig av appen. "
                                + (timer.fetchedAt.map { "Hentet \(Format.relative($0))." } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Ukeplanen hentes fra MELCloud …").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// One column per weekday with the day's events in time order.
    private func grid(_ timer: WeeklyTimer) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            ForEach(1...7, id: \.self) { day in
                VStack(alignment: .leading, spacing: 4) {
                    Text(TimerEvent.weekdayNames[day - 1].prefix(3).capitalized).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(timer.events.filter { $0.weekday == day }.sorted { $0.minuteOfDay < $1.minuteOfDay }.enumerated()), id: \.offset) { _, event in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(event.timeText).font(.caption.monospacedDigit().weight(.medium))
                            Text(event.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background((event.power == false ? Color.gray : (event.mode?.tint ?? .orange)).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}
