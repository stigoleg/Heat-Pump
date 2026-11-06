import Charts
import HeatPumpKit
import SwiftUI

/// Thermostat-centred overview: dial, key numbers, last 24 hours, and the most important hint.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var history = HistoryData()
    @State private var selected: Date?
    @State private var selectedForecast: Date?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                StatusBanner()
                if let state = model.state {
                    hero(state)
                    last24(state)
                    weather.id("weather")
                    insight
                } else if model.startupError == nil {
                    ContentUnavailableView(
                        "No status yet", systemImage: "thermometer.medium",
                        description: Text("Fetching status from the heat pump…"))
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .devScrollTarget(proxy)
        }
        .task(id: model.revision) { history = await model.history(range: .day) }
    }

    // MARK: Hero

    private func hero(_ state: DeviceState) -> some View {
        let shown = model.debouncer?.displayed ?? ControlSettings(state)
        let mode = model.debouncer?.displayedMode ?? state.mode
        let range = state.limits.range(for: mode ?? .heat)
        return CardSurface(padding: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                // In the layout (not an overlay) so a long status never covers the dial or facts.
                if let debouncer = model.debouncer, debouncer.status != .idle || (debouncer.remainingThisHour ?? .max) < 4 {
                    StatusChip(status: debouncer.status, remaining: debouncer.remainingThisHour)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                let dial = ThermostatDial(
                    room: model.newerLocalSample?.roomTemperature ?? state.roomTemperature, setpoint: shown.setTemperature, range: range,
                    step: state.temperatureIncrement, mode: mode, isOn: shown.power
                ) { value, commit in
                    model.debouncer?.edit(.temperature(value), commit: commit)
                }
                // Full size when there is room; shrinks with the card in narrow windows.
                .frame(idealWidth: 290, maxWidth: 290, idealHeight: 290, maxHeight: 290)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    // The room value in the dial is local only when a newer local reading has one.
                    if let local = model.newerLocalSample, local.roomTemperature != nil {
                        localAge(local.timestamp, indoor: true).font(.caption).foregroundStyle(.secondary)
                    }
                }
                let dialColumn = VStack(spacing: Theme.Space.s) {
                    dial
                    phaseLine
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: Theme.Space.xxl) {
                        dialColumn
                        facts(state)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        dialColumn.frame(maxWidth: .infinity)
                        facts(state)
                    }
                }
                // Chips wrap to more lines when the window is narrow.
                FlowLayout(spacing: Theme.Space.s) {
                    SettingChip(
                        title: mode.map { .verbatim($0.displayName) } ?? "Mode unknown – choose a mode",
                        systemImage: mode?.systemImage ?? "questionmark.circle", tint: mode?.tint ?? Theme.Status.caution
                    ) {
                        model.selection = .control
                    }
                    SettingChip(title: shown.power ? "On" : "Off", systemImage: "power", tint: shown.power ? Theme.Status.good : .secondary) {
                        model.selection = .control
                    }
                    SettingChip(
                        title: shown.fanSpeed == 0 ? "Fan auto" : "Fan \(shown.fanSpeed)", systemImage: "fan",
                        tint: Theme.Data.blue
                    ) { model.selection = .control }
                    SettingChip(
                        title: state.offline ? "Disconnected" : "Connected",
                        systemImage: state.offline ? "wifi.slash" : "wifi",
                        tint: state.offline ? Theme.Status.caution : Theme.Status.good
                    ) { model.selection = .control }
                    priceChip
                }
            }
        }
    }

    @ViewBuilder private var priceChip: some View {
        if let level = model.currentPriceLevel {
            SettingChip(title: .verbatim(level.nowText), systemImage: "bolt.horizontal.fill", tint: level.color) {
                model.initialHistoryTab = "energy"
                model.selection = .history
            }
            .help("Price level this hour compared with the last few days")
        }
    }

    /// What the unit is doing now (local reading), in plain words: "Defrosting – …", "Resting …", "Heating".
    @ViewBuilder private var phaseLine: some View {
        if let sample = model.liveSample, let phase = sample.phase, phase != .off {
            Label {
                Text(sample.statusLine ?? phase.statusLine).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: phase.systemImage).foregroundStyle(phase.tint)
            }
            .font(.callout.weight(.medium))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 290)
            .help(phase.explanation)
            .accessibilityHint(phase.explanation)
        }
    }

    private func facts(_ state: DeviceState) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            // Per value: the outdoor temperature is local only when the local reading has one
            // (the unit reports none while it is off), otherwise it comes from MELCloud.
            let local = model.newerLocalSample.flatMap { $0.outdoorTemperature == nil ? nil : $0 }
            fact("Outdoor", systemImage: "cloud.sun.fill", tint: Theme.Data.outside) {
                Text(Format.degrees(local?.outdoorTemperature ?? state.outdoorTemperature))
            } detail: {
                if let local { localAge(local.timestamp, indoor: false) }
            }
            fact("Power", systemImage: "bolt.fill", tint: .yellow) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    if let watts = model.liveSample?.powerW {
                        Text(Format.watts(Double(watts)))
                        powerSparkline
                    } else if let watts = model.estimatedPowerW {
                        Text("≈ " + Format.watts(watts))
                        sparkline
                    } else {
                        Text(verbatim: "—")
                    }
                }
            } detail: {
                if let sample = model.liveSample {
                    compressorIndicator(sample)
                } else {
                    model.estimatedPowerW == nil ? Text("Comes with a local connection") : Text("Estimate from the pump’s power meter")
                }
            }
            fact("Today", systemImage: "chart.bar.fill", tint: Theme.Data.energy) {
                Text(todayText)
            } detail: {
                if model.today?.isEstimate == true { Text("The cost is an estimate") }
            }
            fact("Price now", systemImage: "bolt.horizontal.fill", tint: Theme.Data.electricity) {
                Text(currentPriceText)
            } detail: {
                Text(model.priceSettings.agreement.displayName)
            }
            if let report = model.health {
                fact("Health", systemImage: report.overall.systemImage, tint: report.overall.color) {
                    Text(report.overall == .ok ? String(localized: "All OK") : report.overall.displayName)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact<Value: View, Detail: View>(
        _ label: LocalizedStringKey, systemImage: String, tint: Color, @ViewBuilder value: () -> Value,
        @ViewBuilder detail: () -> Detail = { EmptyView() }
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Image(systemName: systemImage).foregroundStyle(tint).frame(width: 20)
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                value().font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                detail().font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var todayText: String {
        guard let today = model.today else { return "—" }
        let kr = today.costNok.map { " · " + Format.kroner($0) } ?? ""
        return Format.kWh(today.totalKWh) + kr
    }

    private var currentPriceText: String {
        let hour = Calendar.current.dateInterval(of: .hour, for: Date())?.start
        guard let price = model.todayPrices.first(where: { $0.hour == hour }) else { return "—" }
        return String(localized: "\(Display.format("%.2f", price.totalOre / 100)) NOK/kWh")
    }

    /// "Measured locally 12 s ago", ticking every second.
    private func localAge(_ date: Date, indoor: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(date)))
            let minutes = seconds / 60
            Group {
                switch (indoor, seconds < 90) {
                case (true, true): Text("Indoor measured locally \(seconds) s ago")
                case (true, false): Text("Indoor measured locally \(minutes) min ago")
                case (false, true): Text("Measured locally \(seconds) s ago")
                case (false, false): Text("Measured locally \(minutes) min ago")
                }
            }
            .monospacedDigit()
        }
    }

    private func compressorIndicator(_ sample: LocalSample) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(sample.isRunning ? Theme.Status.good : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            if sample.isRunning, let hz = sample.compressorHz {
                Text("Compressor running · \(hz) Hz")
            } else if sample.isRunning {
                Text("Compressor running")
            } else {
                Text("Compressor stopped")
            }
        }
    }

    /// Power over the last 60 minutes from local readings.
    @ViewBuilder private var powerSparkline: some View {
        let points = model.recentLocal.compactMap { s in s.powerW.map { (date: s.timestamp, watts: Double($0)) } }
        if points.count >= 2 {
            Chart(points, id: \.date) { p in
                AreaMark(x: .value("Time", p.date), y: .value("W", p.watts))
                    .foregroundStyle(ChartKit.areaGradient(.yellow))
                    .interpolationMethod(.stepEnd)
                LineMark(x: .value("Time", p.date), y: .value("W", p.watts))
                    .foregroundStyle(Color.yellow)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .interpolationMethod(.stepEnd)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(100, points.map(\.watts).max() ?? 100))
            .frame(width: 70, height: 18)
            .accessibilityLabel("Power, last hour")
        }
    }

    /// Tiny bar sparkline of the last hours' use.
    @ViewBuilder private var sparkline: some View {
        let recent = Array(model.todayHourly.suffix(8))
        if recent.count >= 2 {
            Chart(recent, id: \.hour) { h in
                BarMark(x: .value("Hour", h.hour, unit: .hour), y: .value("kWh", h.kWh))
                    .foregroundStyle(Color.yellow.opacity(0.8))
                    .cornerRadius(1.5)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(width: 60, height: 18)
            .accessibilityHidden(true)
        }
    }

    // MARK: Last 24 hours

    @ViewBuilder private func last24(_ state: DeviceState) -> some View {
        let now = Date()
        let start = now.addingTimeInterval(-86_400)
        let temps = history.temperatures.filter { $0.timestamp >= start }
        let bars = costBars(from: start)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Last 24 h", hint: history.fromMELCloud ? nil : "Builds up while the app is open") {
                FlowLayout {
                    LegendDot(label: "Indoor", color: Theme.Data.inside)
                    LegendDot(label: "Outdoor", color: Theme.Data.outside, dashed: true)
                    LegendDot(label: bars.isCost ? "NOK/hour" : "NOK/kWh", color: Theme.Data.purple)
                }
            }
            CardSurface {
                if temps.isEmpty && bars.values.isEmpty {
                    EmptyChart(
                        title: "No data yet",
                        message: "Temperatures are shown once the app has fetched the status a few times, and from MELCloud when the log is available.")
                } else {
                    VStack(spacing: Theme.Space.s) {
                        temperatureChart(temps, domain: start...now)
                            .frame(height: 170)
                        barChart(bars, domain: start...now)
                            .frame(height: 64)
                    }
                }
            }
        }
    }

    private func temperatureChart(_ points: [TemperaturePoint], domain: ClosedRange<Date>) -> some View {
        let values = points.flatMap { [$0.room, $0.outdoor].compactMap { $0 } }
        let low = (values.min() ?? 0).rounded(.down) - 1
        let high = (values.max() ?? 25).rounded(.up) + 1
        // The indoor area starts just below the lowest indoor value, not at the outdoor minimum.
        let areaBase = (points.compactMap(\.room).min() ?? low) - 1.5
        return Chart {
            ForEach(points, id: \.timestamp) { p in
                if let room = p.room {
                    AreaMark(x: .value("Time", p.timestamp), yStart: .value("°C", areaBase), yEnd: .value("°C", room), series: .value("Series", "indoor"))
                        .foregroundStyle(ChartKit.areaGradient(Theme.Data.inside))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.timestamp), y: .value("°C", room), series: .value("Series", "indoor"))
                        .foregroundStyle(Theme.Data.inside)
                        .interpolationMethod(.monotone)
                }
                if let outdoor = p.outdoor {
                    LineMark(x: .value("Time", p.timestamp), y: .value("°C", outdoor), series: .value("Series", "outdoor"))
                        .foregroundStyle(Theme.Data.outside)
                        .lineStyle(ChartKit.previousStroke)
                        .interpolationMethod(.monotone)
                }
            }
            if let p = nearest(points, to: selected, by: \.timestamp) {
                RuleMark(x: .value("Selected", p.timestamp))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ChartTooltip(
                            title: Format.hour(p.timestamp),
                            rows: [
                                ("Indoor", Format.temperature(p.room), Theme.Data.inside),
                                ("Outdoor", Format.temperature(p.outdoor), Theme.Data.outside),
                            ])
                    }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: low...high)
        .calmYAxis { Display.format("%.0f°", $0) }
        .chartXAxis(.hidden)
        .chartXSelection(value: $selected)
    }

    private struct Bars {
        var values: [(hour: Date, value: Double)]
        var isCost: Bool
    }

    private func costBars(from start: Date) -> Bars {
        let cost = model.todayHourly.compactMap { h in h.cost.map { (h.hour, $0.totalNok) } }.filter { $0.0 >= start }
        if !cost.isEmpty { return Bars(values: cost, isCost: true) }
        let prices = (model.todayPrices + model.tomorrowPrices).filter { $0.hour >= start && $0.hour <= Date() }
        return Bars(values: prices.map { ($0.hour, $0.totalOre / 100) }, isCost: false)
    }

    private func barChart(_ bars: Bars, domain: ClosedRange<Date>) -> some View {
        Chart {
            ForEach(bars.values, id: \.hour) { bar in
                BarMark(x: .value("Hour", bar.hour, unit: .hour), y: .value("NOK", bar.value))
                    .foregroundStyle(Theme.Data.purple.opacity(0.75))
                    .cornerRadius(2)
            }
            if let bar = nearest(bars.values, to: selected, by: \.hour) {
                RuleMark(x: .value("Selected", bar.hour))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        Text(bars.isCost ? Format.kroner(bar.value) : String(localized: "\(Display.format("%.2f", bar.value)) NOK/kWh"))
                            .font(.caption2).monospacedDigit()
                            .padding(4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
            }
        }
        .chartXScale(domain: domain)
        .calmYAxis { Display.format("%.1f", $0) }
        .calmXAxis(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)), count: 8)
        .chartXSelection(value: $selected)
    }

    // MARK: Weather

    @ViewBuilder private var weather: some View {
        let hours = model.forecast
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Weather next 48 h", hint: model.weatherLocation.map { .verbatim($0.displayName) }) {
                Text(WeatherForecast.attribution).font(.caption).foregroundStyle(.secondary)
            }
            CardSurface {
                if hours.count < 2 {
                    EmptyChart(
                        title: "No weather forecast yet",
                        message: model.weatherMessage.map { .verbatim($0) } ?? "The weather forecast is fetched from MET Norway at most once an hour.",
                        systemImage: "cloud.sun")
                } else {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        forecastStrip(hours).frame(height: 90)
                        // Range and tomorrow's estimate side by side, or stacked when narrow.
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.l) {
                                forecastRange(hours)
                                Spacer()
                                tomorrowEstimate(alignment: .trailing)
                            }
                            VStack(alignment: .leading, spacing: Theme.Space.s) {
                                forecastRange(hours)
                                tomorrowEstimate(alignment: .leading)
                            }
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    @ViewBuilder private func forecastRange(_ hours: [ForecastHour]) -> some View {
        if let low = hours.min(by: { $0.temperature < $1.temperature }),
            let high = hours.max(by: { $0.temperature < $1.temperature })
        {
            Label(
                "Coldest \(Display.format("%.0f°", low.temperature)) \(Format.weekdayHour(low.time)) · warmest \(Display.format("%.0f°", high.temperature)) \(Format.weekdayHour(high.time))",
                systemImage: "thermometer.medium"
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func tomorrowEstimate(alignment: HorizontalAlignment) -> some View {
        if let tomorrow = model.tomorrow {
            VStack(alignment: alignment, spacing: 2) {
                Text(tomorrow.shortText).font(.callout.weight(.semibold)).monospacedDigit()
                Text(tomorrowDetail(tomorrow)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .help("Rough estimate: consumption against how cold it has been over the last \(tomorrow.basisDays) days, tomorrow’s forecast and electricity prices.")
        }
    }

    private func tomorrowDetail(_ t: TomorrowEstimate) -> String {
        var parts: [String] = []
        if t.kWhLow.rounded() == t.kWhHigh.rounded() {
            parts.append(String(localized: "Rough estimate from \(t.basisDays) days of own measurements"))
        } else {
            parts.append(String(localized: "Uncertain: about \(Display.format("%.0f–%.0f", t.kWhLow, t.kWhHigh)) kWh"))
            if let low = t.costLowNok, let high = t.costHighNok {
                parts.append(String(localized: "\(Display.format("%.0f–%.0f", low, high)) NOK"))
            }
        }
        if t.pricesFromToday { parts.append(String(localized: "today’s prices used")) }
        return parts.joined(separator: " · ")
    }

    private func forecastStrip(_ hours: [ForecastHour]) -> some View {
        let temps = hours.map(\.temperature)
        let low = (temps.min() ?? 0).rounded(.down) - 1
        let high = (temps.max() ?? 10).rounded(.up) + 1
        return Chart {
            ForEach(hours, id: \.time) { h in
                AreaMark(x: .value("Time", h.time), yStart: .value("°C", low), yEnd: .value("°C", h.temperature))
                    .foregroundStyle(ChartKit.areaGradient(Theme.Data.outside))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", h.time), y: .value("°C", h.temperature))
                    .foregroundStyle(Theme.Data.outside)
                    .lineStyle(ChartKit.previousStroke)
                    .interpolationMethod(.monotone)
            }
            RuleMark(y: .value("Freezing point", 0)).foregroundStyle(Color.secondary.opacity(0.25))
            if let h = nearest(hours, to: selectedForecast, by: \.time) {
                RuleMark(x: .value("Selected", h.time))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ChartTooltip(
                            title: Format.weekdayHour(h.time),
                            rows: [
                                ("Outdoor", Format.temperature(h.temperature), Theme.Data.outside),
                                ("Wind", h.windSpeed.map { Display.format("%.0f m/s", $0) } ?? "–", .secondary),
                            ])
                    }
            }
        }
        .chartYScale(domain: low...high)
        .calmYAxis { Display.format("%.0f°", $0) }
        .calmXAxis(Date.FormatStyle().weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)), count: 6)
        .chartXSelection(value: $selectedForecast)
        .accessibilityLabel("Outdoor temperature, next 48 hours")
    }

    // MARK: Insight

    @ViewBuilder private var insight: some View {
        if let finding = model.health?.findings.first(where: { $0.severity != .ok }) {
            InsightCard(
                title: .verbatim(finding.title), detail: .verbatim(finding.recommendation), systemImage: finding.severity.systemImage,
                tint: finding.severity.color
            ) { model.selection = .health }
        } else if let message = model.priceMessage {
            InsightCard(title: "Electricity price", detail: .verbatim(message), systemImage: "exclamationmark.triangle.fill", tint: Theme.Status.caution)
        }
    }
}
