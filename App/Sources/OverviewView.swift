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
                        "Ingen status ennå", systemImage: "thermometer.medium",
                        description: Text("Henter status fra varmepumpen …"))
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
                        localAge(local.timestamp, prefix: "Inne målt lokalt").font(.caption).foregroundStyle(.secondary)
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
                        title: mode?.displayName ?? "Modus ukjent – velg modus",
                        systemImage: mode?.systemImage ?? "questionmark.circle", tint: mode?.tint ?? Theme.Status.caution
                    ) {
                        model.selection = .control
                    }
                    SettingChip(title: shown.power ? "På" : "Av", systemImage: "power", tint: shown.power ? Theme.Status.good : .secondary) {
                        model.selection = .control
                    }
                    SettingChip(
                        title: shown.fanSpeed == 0 ? "Vifte auto" : "Vifte \(shown.fanSpeed)", systemImage: "fan",
                        tint: Theme.Data.blue
                    ) { model.selection = .control }
                    SettingChip(
                        title: state.offline ? "Frakoblet" : "Tilkoblet",
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
            SettingChip(title: level.nowText, systemImage: "bolt.horizontal.fill", tint: level.color) {
                model.initialHistoryTab = "energy"
                model.selection = .history
            }
            .help("Prisnivå denne timen sammenlignet med de siste dagene")
        }
    }

    /// What the unit is doing now (local reading), in plain words: "Avriser – …", "Hviler …", "Varmer".
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
            fact("Ute", systemImage: "cloud.sun.fill", tint: Theme.Data.outside) {
                Text(Format.degrees(local?.outdoorTemperature ?? state.outdoorTemperature))
            } detail: {
                if let local { localAge(local.timestamp, prefix: "Målt lokalt") }
            }
            fact("Effekt", systemImage: "bolt.fill", tint: .yellow) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    if let watts = model.liveSample?.powerW {
                        Text(Format.watts(Double(watts)))
                        powerSparkline
                    } else if let watts = model.estimatedPowerW {
                        Text("≈ " + Format.watts(watts))
                        sparkline
                    } else {
                        Text("—")
                    }
                }
            } detail: {
                if let sample = model.liveSample {
                    compressorIndicator(sample)
                } else {
                    Text(model.estimatedPowerW == nil ? "Kommer med lokal tilkobling" : "Anslag fra strømmåleren i pumpen")
                }
            }
            fact("I dag", systemImage: "chart.bar.fill", tint: Theme.Data.energy) {
                Text(todayText)
            } detail: {
                if model.today?.isEstimate == true { Text("Kostnad er et anslag") }
            }
            fact("Strøm nå", systemImage: "bolt.horizontal.fill", tint: Theme.Data.electricity) {
                Text(currentPriceText)
            } detail: {
                Text(model.priceSettings.agreement.displayName)
            }
            if let report = model.health {
                fact("Helse", systemImage: report.overall.systemImage, tint: report.overall.color) {
                    Text(report.overall == .ok ? "Alt OK" : report.overall.displayName)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact<Value: View, Detail: View>(
        _ label: String, systemImage: String, tint: Color, @ViewBuilder value: () -> Value,
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
        return Norwegian.format("%.2f kr/kWh", price.totalOre / 100)
    }

    /// "Målt lokalt for 12 s siden", ticking every second.
    private func localAge(_ date: Date, prefix: String) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(date)))
            Text(seconds < 90 ? "\(prefix) for \(seconds) s siden" : "\(prefix) for \(seconds / 60) min siden")
                .monospacedDigit()
        }
    }

    private func compressorIndicator(_ sample: LocalSample) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(sample.isRunning ? Theme.Status.good : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            if sample.isRunning {
                Text("Kompressor går" + (sample.compressorHz.map { " · \($0) Hz" } ?? ""))
            } else {
                Text("Kompressor står")
            }
        }
    }

    /// Power over the last 60 minutes from local readings.
    @ViewBuilder private var powerSparkline: some View {
        let points = model.recentLocal.compactMap { s in s.powerW.map { (date: s.timestamp, watts: Double($0)) } }
        if points.count >= 2 {
            Chart(points, id: \.date) { p in
                AreaMark(x: .value("Tid", p.date), y: .value("W", p.watts))
                    .foregroundStyle(ChartKit.areaGradient(.yellow))
                    .interpolationMethod(.stepEnd)
                LineMark(x: .value("Tid", p.date), y: .value("W", p.watts))
                    .foregroundStyle(Color.yellow)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .interpolationMethod(.stepEnd)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(100, points.map(\.watts).max() ?? 100))
            .frame(width: 70, height: 18)
            .accessibilityLabel("Effekt siste time")
        }
    }

    /// Tiny bar sparkline of the last hours' use.
    @ViewBuilder private var sparkline: some View {
        let recent = Array(model.todayHourly.suffix(8))
        if recent.count >= 2 {
            Chart(recent, id: \.hour) { h in
                BarMark(x: .value("Time", h.hour, unit: .hour), y: .value("kWh", h.kWh))
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
            SectionHeader(title: "Siste 24 t", hint: history.fromMELCloud ? nil : "Bygges opp mens appen er åpen") {
                FlowLayout {
                    LegendDot(label: "Inne", color: Theme.Data.inside)
                    LegendDot(label: "Ute", color: Theme.Data.outside, dashed: true)
                    LegendDot(label: bars.isCost ? "kr/time" : "kr/kWh", color: Theme.Data.purple)
                }
            }
            CardSurface {
                if temps.isEmpty && bars.values.isEmpty {
                    EmptyChart(
                        title: "Ingen data ennå",
                        message: "Temperaturer vises når appen har hentet status noen ganger, og fra MELCloud når loggen er tilgjengelig.")
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
                    AreaMark(x: .value("Tid", p.timestamp), yStart: .value("°C", areaBase), yEnd: .value("°C", room), series: .value("S", "inne"))
                        .foregroundStyle(ChartKit.areaGradient(Theme.Data.inside))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Tid", p.timestamp), y: .value("°C", room), series: .value("S", "inne"))
                        .foregroundStyle(Theme.Data.inside)
                        .interpolationMethod(.monotone)
                }
                if let outdoor = p.outdoor {
                    LineMark(x: .value("Tid", p.timestamp), y: .value("°C", outdoor), series: .value("S", "ute"))
                        .foregroundStyle(Theme.Data.outside)
                        .lineStyle(ChartKit.previousStroke)
                        .interpolationMethod(.monotone)
                }
            }
            if let p = nearest(points, to: selected, by: \.timestamp) {
                RuleMark(x: .value("Valgt", p.timestamp))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ChartTooltip(
                            title: Format.hour(p.timestamp),
                            rows: [
                                ("Inne", Format.temperature(p.room), Theme.Data.inside),
                                ("Ute", Format.temperature(p.outdoor), Theme.Data.outside),
                            ])
                    }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: low...high)
        .calmYAxis { Norwegian.format("%.0f°", $0) }
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
                BarMark(x: .value("Time", bar.hour, unit: .hour), y: .value("kr", bar.value))
                    .foregroundStyle(Theme.Data.purple.opacity(0.75))
                    .cornerRadius(2)
            }
            if let bar = nearest(bars.values, to: selected, by: \.hour) {
                RuleMark(x: .value("Valgt", bar.hour))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        Text(Norwegian.format(bars.isCost ? "%.2f kr" : "%.2f kr/kWh", bar.value))
                            .font(.caption2).monospacedDigit()
                            .padding(4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
            }
        }
        .chartXScale(domain: domain)
        .calmYAxis { Norwegian.format("%.1f", $0) }
        .calmXAxis(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)), count: 8)
        .chartXSelection(value: $selected)
    }

    // MARK: Weather

    @ViewBuilder private var weather: some View {
        let hours = model.forecast
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Vær neste 48 t", hint: model.weatherLocation?.displayName) {
                Text(WeatherForecast.attribution).font(.caption).foregroundStyle(.secondary)
            }
            CardSurface {
                if hours.count < 2 {
                    EmptyChart(
                        title: "Ingen værvarsel ennå",
                        message: model.weatherMessage ?? "Værvarselet hentes fra MET Norway høyst én gang i timen.",
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
                Norwegian.format("Kaldest %.0f° %@ · varmest %.0f° %@", low.temperature, Format.weekdayHour(low.time), high.temperature, Format.weekdayHour(high.time)),
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
            .help("Grovt anslag: forbruket mot hvor kaldt det har vært de siste \(tomorrow.basisDays) dagene, morgendagens varsel og strømpriser.")
        }
    }

    private func tomorrowDetail(_ t: TomorrowEstimate) -> String {
        var text: String
        if t.kWhLow.rounded() == t.kWhHigh.rounded() {
            text = "Grovt anslag fra \(t.basisDays) dager med egne målinger"
        } else {
            text = Norwegian.format("Usikkert: ca. %.0f–%.0f kWh", t.kWhLow, t.kWhHigh)
            if let low = t.costLowNok, let high = t.costHighNok { text += Norwegian.format(" · %.0f–%.0f kr", low, high) }
        }
        if t.pricesFromToday { text += " · dagens priser brukt" }
        return text
    }

    private func forecastStrip(_ hours: [ForecastHour]) -> some View {
        let temps = hours.map(\.temperature)
        let low = (temps.min() ?? 0).rounded(.down) - 1
        let high = (temps.max() ?? 10).rounded(.up) + 1
        return Chart {
            ForEach(hours, id: \.time) { h in
                AreaMark(x: .value("Tid", h.time), yStart: .value("°C", low), yEnd: .value("°C", h.temperature))
                    .foregroundStyle(ChartKit.areaGradient(Theme.Data.outside))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Tid", h.time), y: .value("°C", h.temperature))
                    .foregroundStyle(Theme.Data.outside)
                    .lineStyle(ChartKit.previousStroke)
                    .interpolationMethod(.monotone)
            }
            RuleMark(y: .value("0", 0)).foregroundStyle(Color.secondary.opacity(0.25))
            if let h = nearest(hours, to: selectedForecast, by: \.time) {
                RuleMark(x: .value("Valgt", h.time))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ChartTooltip(
                            title: Format.weekdayHour(h.time),
                            rows: [
                                ("Ute", Format.temperature(h.temperature), Theme.Data.outside),
                                ("Vind", h.windSpeed.map { Norwegian.format("%.0f m/s", $0) } ?? "–", .secondary),
                            ])
                    }
            }
        }
        .chartYScale(domain: low...high)
        .calmYAxis { Norwegian.format("%.0f°", $0) }
        .calmXAxis(Date.FormatStyle().weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)), count: 6)
        .chartXSelection(value: $selectedForecast)
        .accessibilityLabel("Temperatur ute neste 48 timer")
    }

    // MARK: Insight

    @ViewBuilder private var insight: some View {
        if let finding = model.health?.findings.first(where: { $0.severity != .ok }) {
            InsightCard(
                title: finding.title, detail: finding.recommendation, systemImage: finding.severity.systemImage,
                tint: finding.severity.color
            ) { model.selection = .health }
        } else if let message = model.priceMessage {
            InsightCard(title: "Strømpris", detail: message, systemImage: "exclamationmark.triangle.fill", tint: Theme.Status.caution)
        }
    }
}
