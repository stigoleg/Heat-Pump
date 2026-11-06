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
                    "No status yet", systemImage: "slider.horizontal.3",
                    description: Text("The controls become available once the status has been fetched."))
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
                        (model.weeklyTimer?.enabled == true
                            ? Text("Changes are sent automatically a few seconds after you set them. The weekly schedule in \(model.serviceName) is on, so the heat pump can also change by itself.")
                            : Text("Changes are sent automatically a few seconds after you set them."))
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: Theme.Space.s)
                        StatusChip(status: debouncer.status, remaining: debouncer.remainingThisHour)
                    }
                }
                if mode == nil {
                    InsightCard(
                        title: "Mode unknown – choose a mode",
                        detail: "The heat pump reports no valid mode. Choose Heat under Mode, for example, before you change the temperature.",
                        systemImage: "questionmark.circle.fill", tint: Theme.Status.caution)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.l) {
                        powerCard(shown, debouncer).frame(idealWidth: 220, maxWidth: 240)
                        temperatureCard(shown, mode: mode, state: state, debouncer: debouncer).frame(idealWidth: 380, maxWidth: .infinity)
                    }
                    VStack(spacing: Theme.Space.l) {
                        powerCard(shown, debouncer)
                        temperatureCard(shown, mode: mode, state: state, debouncer: debouncer)
                    }
                }
                modeSection(mode, debouncer)
                fanSection(shown, state: state, debouncer: debouncer)
                vaneSection(shown, debouncer)
                WeeklyTimerStatus().id("timer")
                Text(
                    "It can take a couple of minutes before the heat pump confirms. At most \(ChangeBudget.maxChangesPerHour) sends per hour, in total for the app and Claude; several changes in a row are combined into one send."
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
                .accessibilityLabel(shown.power ? Text("Turn off the heat pump") : Text("Turn on the heat pump"))
                (shown.power ? Text("The heat pump is on") : Text("The heat pump is off"))
                    .font(.headline)
                (shown.power ? Text("Click to turn it off.") : Text("Click to turn it on.")).font(.caption).foregroundStyle(.secondary)
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
                    Label("Target temperature", systemImage: "thermometer.medium").foregroundStyle(.secondary)
                    Spacer()
                    Text("Indoors now \(Format.temperature(state.roomTemperature))").font(.callout).foregroundStyle(.secondary)
                }
                HStack(alignment: .center, spacing: Theme.Space.l) {
                    Text(Format.temperature(shown.setTemperature))
                        .font(.system(size: 52, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                    Spacer()
                    Stepper("Target temperature", value: Binding(get: { shown.setTemperature }, set: { debouncer.edit(.temperature($0)) }), in: range, step: step)
                        .labelsHidden()
                }
                Slider(value: binding, in: range, step: step) {
                    Text("Target temperature")
                } minimumValueLabel: {
                    Text(Display.format("%.0f°", range.lowerBound)).font(.caption)
                } maximumValueLabel: {
                    Text(Display.format("%.0f°", range.upperBound)).font(.caption)
                } onEditingChanged: { editing in
                    sliderEditing = editing
                    if !editing { debouncer.commit() }
                }
                .labelsHidden()
                .tint(tint)
                Text(
                    "Allowed in \((mode ?? .heat).sentenceName) mode: \(Display.format("%.0f–%.0f °C", range.lowerBound, range.upperBound)). Small adjustments (1–2 degrees) are enough."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Mode

    private func modeSection(_ current: OperationMode?, _ debouncer: ChangeDebouncer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Mode", hint: "Heat is the right choice in winter")
            let modes: [OperationMode] = [.heat, .cool, .dry, .fan, .auto]
            // Spread over the full width when there is room; wrap to more lines when narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.m) {
                    ForEach(modes, id: \.self) { modeButton($0, current: current, debouncer) }
                }
                FlowLayout(spacing: Theme.Space.m, lineSpacing: 0) {
                    ForEach(modes, id: \.self) { modeButton($0, current: current, debouncer) }
                }
            }
            Text(current.map(modeHelp) ?? String(localized: "Mode unknown – choose a mode.")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func modeButton(_ mode: OperationMode, current: OperationMode?, _ debouncer: ChangeDebouncer) -> some View {
        let selected = current == mode
        // Only the active mode has colour; the others are neutral, so the choice reads at a glance.
        return Button {
            debouncer.edit(.mode(mode))
        } label: {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 56, height: 56)
                    .background(
                        selected ? AnyShapeStyle(mode.tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.05)),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(selected ? Color.clear : Theme.hairline)
                    }
                    .shadow(color: selected ? mode.tint.opacity(0.35) : .clear, radius: 6, y: 2)
                Text(mode.displayName)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(mode.tint) : AnyShapeStyle(.secondary))
            }
            .frame(minWidth: 72, maxWidth: .infinity)
            .padding(.vertical, Theme.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func modeHelp(_ mode: OperationMode) -> String {
        switch mode {
        case .heat: String(localized: "Heat: warms the room to the target temperature.")
        case .cool: String(localized: "Cool: cools the room in summer.")
        case .dry: String(localized: "Dry: takes moisture out of the air, with a little cooling.")
        case .fan: String(localized: "Fan: circulates the air without heating or cooling.")
        case .auto: String(localized: "Auto: chooses between heating and cooling by itself.")
        }
    }

    // MARK: Fan

    private func fanSection(_ shown: ControlSettings, state: DeviceState, debouncer: ChangeDebouncer) -> some View {
        let speeds = (state.hasAutomaticFanSpeed ? [0] : []) + Array(1...max(state.numberOfFanSpeeds, 1))
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Fan speed", hint: "Auto is the quietest and almost always fits")
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
                                Text(verbatim: "\(speed)").font(.caption)
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
                    .accessibilityLabel(speed == 0 ? Text("Fan auto") : Text("Fan speed \(speed)"))
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
            SectionHeader("Airflow direction", hint: "When heating: the lowest position or Auto, so the heat reaches the floor")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Theme.Space.l, alignment: .top)], spacing: Theme.Space.l) {
                CardSurface {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("Up/down").font(.callout).foregroundStyle(.secondary)
                        FlowLayout(spacing: Theme.Space.s, lineSpacing: Theme.Space.s) {
                            ForEach(VaneVertical.allCases, id: \.self) { vane in
                                VaneButton(
                                    selected: shown.vaneVertical == vane, title: vane.shortTitle,
                                    accessibility: String(localized: "Up/down: \(vane.displayName)")
                                ) {
                                    VaneGlyph(kind: vane.glyph(vertical: true))
                                } action: { debouncer.edit(.vaneVertical(vane)) }
                            }
                        }
                    }
                }
                CardSurface {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("Left/right").font(.callout).foregroundStyle(.secondary)
                        FlowLayout(spacing: Theme.Space.s, lineSpacing: Theme.Space.s) {
                            ForEach(VaneHorizontal.allCases, id: \.self) { vane in
                                VaneButton(
                                    selected: shown.vaneHorizontal == vane, title: vane.shortTitle,
                                    accessibility: String(localized: "Left/right: \(vane.displayName)")
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
        case .auto: String(localized: "Auto")
        case .swing: String(localized: "Swing")
        default: "\(position ?? 0)"
        }
    }

    func glyph(vertical: Bool) -> VaneGlyphKind {
        switch self {
        case .auto: .auto
        case .swing: .swing(vertical: true)
        // 1 = top (nearly horizontal) … 5 = bottom (pointing down).
        default: .direction(Double((position ?? 1) - 1) * 17 - 5, vertical: true)
        }
    }
}

extension VaneHorizontal {
    var shortTitle: String {
        switch self {
        case .auto: String(localized: "Auto")
        case .swing: String(localized: "Swing")
        case .split: String(localized: "Split")
        default: "\(position ?? 0)"
        }
    }

    var glyph: VaneGlyphKind {
        switch self {
        case .auto: .auto
        case .swing: .swing(vertical: false)
        case .split: .split
        // 1 = left … 5 = right.
        default: .direction(Double((position ?? 3) - 3) * 25, vertical: false)
        }
    }
}

/// Compact status of MELCloud's weekly timer with a link to the Weekly schedule page.
struct WeeklyTimerStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        CardSurface {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.m) {
                    label
                    Spacer(minLength: Theme.Space.s)
                    button
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    label
                    button
                }
            }
        }
    }

    private var label: some View {
        let timer = model.weeklyTimer
        return Label(text(timer), systemImage: timer?.enabled == true ? "calendar.badge.clock" : "calendar")
            .foregroundStyle(timer?.enabled == true ? Theme.Status.info : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var button: some View {
        Button("Open Weekly Schedule") { model.selection = .schedule }
    }

    private func text(_ timer: WeeklyTimer?) -> String {
        guard let timer else { return String(localized: "Fetching the weekly schedule from \(model.serviceName)…") }
        guard timer.enabled == true else { return timer.enabled == false ? String(localized: "Weekly schedule off") : String(localized: "Unknown whether the weekly schedule is on") }
        guard let next = timer.nextEvent(after: Date(), timeZone: .current) else { return String(localized: "Weekly schedule on") }
        let day = TimerEvent.shortWeekdayNames[next.event.weekday - 1]
        return String(localized: "Weekly schedule on · Next: \(day) \(next.event.timeText) \(next.event.summary)")
    }
}
