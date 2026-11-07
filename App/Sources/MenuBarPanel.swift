import AppKit
import HeatPumpKit
import SwiftUI

// MARK: - Title

/// The menu bar item's title: the items the user chose for the shown device (Settings → General
/// → Menu bar). Drawn into a template image, so the menu bar tints it in light, dark and when
/// highlighted; a menu bar label shows only one image and one text otherwise.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Label {
            Text("Heat Pump")
        } icon: {
            Image(nsImage: Self.image(segments: model.menuBarSegments))
        }
    }

    static func image(segments: [MenuBarSegment]) -> NSImage {
        let renderer = ImageRenderer(content: MenuBarTitleView(segments: segments).foregroundStyle(.black))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

/// The title's parts in a row, compact, with tabular digits; the app's icon when nothing is left.
struct MenuBarTitleView: View {
    let segments: [MenuBarSegment]

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if segments.isEmpty {
                Image(systemName: "thermometer.medium")
            } else {
                ForEach(segments.indices, id: \.self) { index in
                    segment(segments[index])
                }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder private func segment(_ segment: MenuBarSegment) -> some View {
        switch segment {
        case .symbol(let symbol): Image(systemName: symbol.systemImage)
        case .indoor(let value): Text(verbatim: Format.degrees(value))
        case .target(let value):
            HStack(spacing: 1) {
                Image(systemName: "arrow.right").imageScale(.small)
                Text(verbatim: Format.degrees(value))
            }
        case .outdoor(let value):
            HStack(spacing: 2) {
                Image(systemName: "cloud.sun").imageScale(.small)
                Text(verbatim: Format.degrees(value))
            }
        case .power(let watts): Text(verbatim: Format.watts(watts))
        case .todayCost(let nok): Text(verbatim: Format.kroner(nok))
        case .priceNow(let ore, _): Text(verbatim: Format.ore(ore))
        case .health(let severity): Image(systemName: severity.systemImage)
        }
    }
}

extension MenuBarSymbol {
    var systemImage: String {
        switch self {
        case .mode(let mode): mode.systemImage
        case .off: "power"
        case .meter: DeviceKind.energyMeter.systemImage
        }
    }
}

// MARK: - Panel

/// The panel under the menu bar item: the shown device's status, insight and controls, price
/// control while it is on, and the app's commands. Edits go through the device's debouncer, as on
/// Control (validation, change budget, change log and rate limits in the kit).
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let device = app.menuBarDevice
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let pump = device as? HeatPumpDeviceModel {
                HeatPumpPanel(device: pump, showWindow: showWindow)
            } else if let meter = device as? EnergyMeterDeviceModel {
                MeterPanel(device: meter)
            }
            if app.priceControl.enabled {
                Divider()
                priceControl
            }
            Divider()
            footer
        }
        .padding(Theme.Space.l)
        .frame(width: 360)
    }

    // MARK: Price control

    private var priceControl: some View {
        let runner = app.priceControl
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: runner.status?.kind.systemImage ?? "bolt.badge.clock")
                .foregroundStyle(runner.status?.kind.tint ?? .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Price control: \(runner.status?.text ?? String(localized: "starting…"))")
                    .fixedSize(horizontal: false, vertical: true)
                if let next = runner.status?.nextStep {
                    Text("Next: \(next.summary(now: Date(), timeZone: .current))")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.s)
            Button("Turn Off") { Task { await runner.setEnabled(false) } }
                .controlSize(.small)
                .disabled(runner.isBusy)
                .help("Turn Off Price Control")
        }
        .font(.callout)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            Button("Open Heat Pump") { showWindow() }
                .keyboardShortcut("o")
            Spacer(minLength: 0)
            Button("Refresh") { Task { await app.refresh(force: true) } }
                .keyboardShortcut("r")
                .disabled(app.isRefreshing)
            Button("Settings…") {
                openSettings()
                NSApp.activate()
            }
            .keyboardShortcut(",")
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    /// Brings the main window forward (opens it when closed); the Dock icon comes back with it.
    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate()
    }
}

// MARK: - Heat pump

/// A heat pump in the panel: name and status, the numbers that matter now, health, and the
/// controls the device has.
private struct HeatPumpPanel: View {
    @Environment(AppModel.self) private var app
    let device: HeatPumpDeviceModel
    let showWindow: () -> Void

    private var capabilities: Set<Capability>? { device.descriptor?.capabilities }

    /// Unknown device (before the first sign-in): every control, as Control shows them.
    private func has(_ capability: Capability) -> Bool { capabilities?.contains(capability) ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            if let problem = device.dataProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.Status.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let state = device.state {
                insight(state)
                health
                if has(.thermostat), let debouncer = device.debouncer {
                    Divider()
                    controls(state: state, debouncer: debouncer)
                }
            } else {
                Text("No status yet").foregroundStyle(.secondary)
            }
        }
    }

    private var mode: OperationMode? { device.debouncer?.displayedMode ?? device.state?.mode }

    private var isOn: Bool { device.debouncer?.displayed?.power ?? device.state?.power ?? false }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            IconBadge(
                systemImage: mode?.systemImage ?? DeviceKind.airToAirHeatPump.systemImage,
                color: isOn ? (mode?.tint ?? .gray) : .gray, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                DeviceTitle(name: device.displayName)
                statusLine.font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Space.s)
            if let state = device.state {
                Label(state.offline ? "Offline" : "Online", systemImage: state.offline ? "wifi.slash" : "wifi")
                    .font(.caption)
                    .foregroundStyle(state.offline ? Theme.Status.caution : Theme.Status.good)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The mode, and what the unit is doing when a local reading says so ("Defrosting – …").
    @ViewBuilder private var statusLine: some View {
        if let sample = device.liveSample, let phase = sample.phase, phase != .off {
            Label {
                Text(sample.statusLine ?? phase.statusLine).lineLimit(2)
            } icon: {
                Image(systemName: phase.systemImage).foregroundStyle(phase.tint)
            }
            .help(phase.explanation)
        } else if device.state != nil {
            if !isOn {
                Text("Off")
            } else if let mode {
                Text(mode.displayName)
            } else {
                Text("Mode unknown")
            }
        } else {
            Text(device.serviceName)
        }
    }

    // MARK: Insight

    private func insight(_ state: DeviceState) -> some View {
        let local = device.newerLocalSample
        let shown = device.debouncer?.displayed ?? ControlSettings(state)
        return CardSurface(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    figure("Indoor", systemImage: "thermometer.medium", tint: Theme.Data.inside) {
                        Text(Format.temperature(local?.roomTemperature ?? state.roomTemperature))
                    }
                    figure("Target", systemImage: "scope", tint: mode?.tint ?? Theme.Data.setpoint) {
                        Text(state.setTemperature == nil ? "—" : Format.temperature(shown.setTemperature))
                    }
                    figure("Outdoor", systemImage: "cloud.sun.fill", tint: Theme.Data.outside) {
                        Text(Format.temperature(local?.outdoorTemperature ?? state.outdoorTemperature ?? app.forecast.first?.temperature))
                    }
                }
                Divider()
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    figure("Power", systemImage: "bolt.fill", tint: .yellow) {
                        Text(power)
                    }
                    figure("Today", systemImage: "chart.bar.fill", tint: Theme.Data.energy, detail: device.today?.costNok.map(Format.kroner)) {
                        Text(device.today.map { Format.kWh($0.totalKWh) } ?? "—")
                    }
                    PriceNowFigure()
                }
            }
        }
    }

    private var power: String {
        if let watts = device.liveSample?.powerW { return Format.watts(Double(watts)) }
        if let watts = device.estimatedPowerW { return "≈ " + Format.watts(watts) }
        return "—"
    }

    // MARK: Health

    @ViewBuilder private var health: some View {
        if let report = device.health {
            Button {
                app.route = .device(device.key, .health)
                showWindow()
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: report.overall.systemImage).foregroundStyle(report.overall.color)
                    if report.overall == .ok {
                        Text("All OK")
                    } else if let finding = report.findings.first(where: { $0.severity != .ok }) {
                        Text(finding.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(report.overall.displayName)
                    }
                    Spacer(minLength: Theme.Space.s)
                    Text("Open Health").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Health")
        }
    }

    // MARK: Controls

    private func controls(state: DeviceState, debouncer: ChangeDebouncer) -> some View {
        let shown = debouncer.displayed ?? ControlSettings(state)
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Text("Control").font(.headline)
                Spacer()
                Toggle(isOn: Binding(get: { shown.power }, set: { debouncer.edit(.power($0)) })) {
                    Text(shown.power ? "On" : "Off").font(.callout).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(shown.power ? Text("Turn off the heat pump") : Text("Turn on the heat pump"))
            }
            if debouncer.status != .idle || (debouncer.remainingThisHour ?? .max) < 4 {
                StatusChip(status: debouncer.status, remaining: debouncer.remainingThisHour)
            }
            modes(debouncer)
            temperature(shown, state: state, debouncer: debouncer)
            if has(.fanSpeed) { fan(shown, state: state, debouncer: debouncer) }
            if has(.airflow) { airflow(shown, debouncer: debouncer) }
        }
    }

    private func modes(_ debouncer: ChangeDebouncer) -> some View {
        HStack(spacing: Theme.Space.s) {
            ForEach([OperationMode.heat, .cool, .dry, .fan, .auto], id: \.self) { mode in
                modeButton(mode, selected: debouncer.displayedMode == mode) { debouncer.edit(.mode(mode)) }
            }
        }
    }

    /// Control's mode button, smaller: only the active mode has colour.
    private func modeButton(_ mode: OperationMode, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.xs) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 40, height: 40)
                    .background(
                        selected ? AnyShapeStyle(mode.tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.05)),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .strokeBorder(selected ? Color.clear : Theme.hairline)
                    }
                    .shadow(color: selected ? mode.tint.opacity(0.35) : .clear, radius: 4, y: 1)
                Text(mode.displayName)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(mode.tint) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func temperature(_ shown: ControlSettings, state: DeviceState, debouncer: ChangeDebouncer) -> some View {
        let range = state.limits.range(for: debouncer.displayedMode ?? .heat)
        let step = state.temperatureIncrement > 0 ? state.temperatureIncrement : 0.5
        return HStack(alignment: .center, spacing: Theme.Space.m) {
            Label("Target temperature", systemImage: "thermometer.medium").foregroundStyle(.secondary)
            Spacer()
            Text(Format.temperature(shown.setTemperature))
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(debouncer.displayedMode?.tint ?? .secondary)
                .contentTransition(.numericText())
            Stepper(
                "Target temperature", value: Binding(get: { shown.setTemperature }, set: { debouncer.edit(.temperature($0)) }), in: range,
                step: step
            )
            .labelsHidden()
        }
        .font(.callout)
    }

    private func fan(_ shown: ControlSettings, state: DeviceState, debouncer: ChangeDebouncer) -> some View {
        let speeds = (state.hasAutomaticFanSpeed ? [0] : []) + Array(1...max(state.numberOfFanSpeeds, 1))
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Label("Fan speed", systemImage: "fan").foregroundStyle(.secondary).font(.callout)
            Picker("Fan speed", selection: Binding(get: { shown.fanSpeed }, set: { debouncer.edit(.fanSpeed($0)) })) {
                ForEach(speeds, id: \.self) { speed in
                    if speed == 0 { Text("Auto").tag(0) } else { Text(verbatim: "\(speed)").tag(speed) }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func airflow(_ shown: ControlSettings, debouncer: ChangeDebouncer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Label("Airflow direction", systemImage: "wind").foregroundStyle(.secondary).font(.callout)
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.xs) {
                GridRow {
                    Text("Up/down").font(.callout)
                    Picker("Up/down", selection: Binding(get: { shown.vaneVertical }, set: { debouncer.edit(.vaneVertical($0)) })) {
                        ForEach(VaneVertical.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Left/right").font(.callout)
                    Picker("Left/right", selection: Binding(get: { shown.vaneHorizontal }, set: { debouncer.edit(.vaneHorizontal($0)) })) {
                        ForEach(VaneHorizontal.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
            }
        }
    }
}

// MARK: - Energy meter

/// An energy meter in the panel: power now, today's use and cost and the price now; no controls.
private struct MeterPanel: View {
    let device: EnergyMeterDeviceModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                IconBadge(systemImage: DeviceKind.energyMeter.systemImage, color: .yellow, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    DeviceTitle(name: device.displayName)
                    Text(DeviceKind.energyMeter.title).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Space.s)
                if device.powerNowW != nil {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(Theme.Status.good)
                }
            }
            .accessibilityElement(children: .combine)
            if let problem = device.syncProblem ?? device.liveProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.Status.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CardSurface(padding: Theme.Space.m) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    figure("Power now", systemImage: "bolt.fill", tint: .yellow) {
                        Text(Format.watts(device.powerNowW))
                    }
                    figure(
                        "Today", systemImage: "chart.bar.fill", tint: Theme.Data.energy,
                        detail: device.status?.today.cost.map { Format.kroner($0.totalNok) }
                    ) {
                        Text(device.status.map { Format.kWh($0.today.kWh) } ?? "—")
                    }
                    PriceNowFigure(fallbackOre: device.status?.priceNowOre)
                }
            }
        }
    }
}

// MARK: - Shared

/// The device's name; with two or more devices a menu that chooses the one the panel and the
/// title show (remembered).
private struct DeviceTitle: View {
    @Environment(AppModel.self) private var app
    let name: String

    var body: some View {
        if app.devices.count >= 2 {
            Menu {
                ForEach(app.devices.indices, id: \.self) { index in
                    let device = app.devices[index]
                    Button {
                        app.menuBar.choose(device.key)
                    } label: {
                        Label(device.displayName, systemImage: device.kind.systemImage)
                    }
                }
            } label: {
                Text(name).font(.headline)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose Device")
        } else {
            Text(name).font(.headline).lineLimit(1)
        }
    }
}

/// One number in the panel's insight card: a small label with its glyph, the value, a detail.
private func figure<Value: View>(
    _ label: LocalizedStringKey, systemImage: String, tint: Color, detail: String? = nil, @ViewBuilder value: () -> Value
) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Label {
            Text(label).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.caption)
        value()
            .font(.system(.body, design: .rounded).weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        if let detail {
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
}

/// The price of this hour with its level in the level's colour.
private struct PriceNowFigure: View {
    private func priceText(_ ore: Double?) -> String {
        guard let ore else { return "—" }
        return String(localized: "\(Display.format("%.2f", ore / 100)) NOK/kWh")
    }

    @Environment(AppModel.self) private var app
    var fallbackOre: Double?

    var body: some View {
        let price = app.currentPrice
        let level = price?.level
        figure("Price now", systemImage: "bolt.horizontal.fill", tint: level?.color ?? Theme.Data.electricity, detail: level?.displayName) {
            Text(priceText(price?.totalOre ?? fallbackOre))
        }
    }
}

// MARK: - Dev

enum MenuBarDev {
    /// Dev only (`VARMEPUMPE_MENU_BAR=open`, screenshots): opens the panel by clicking the item.
    @MainActor static func openPanel() {
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
            if let button = statusButton(in: window.contentView) {
                button.performClick(nil)
                break
            }
        }
        // A full menu bar hides the item and puts the panel off screen; move it on screen.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard let screen = NSScreen.main else { return }
            for window in NSApp.windows where window.isVisible && window.level.rawValue > 0 && window.frame.width >= 300 {
                if !screen.visibleFrame.contains(window.frame) {
                    window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - window.frame.width - 80, y: screen.visibleFrame.maxY))
                }
            }
        }
    }

    @MainActor private static func statusButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        for subview in view.subviews {
            if let button = statusButton(in: subview) { return button }
        }
        return nil
    }
}
