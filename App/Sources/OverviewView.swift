import Charts
import HeatPumpKit
import SwiftUI

/// Thermostat-centred overview: dial, key numbers, last 24 hours, and the most important hint.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var history = HistoryData()
    @State private var selected: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                StatusBanner()
                if let state = model.state {
                    hero(state)
                    last24(state)
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
        .task(id: model.revision) { history = await model.history(range: .day) }
    }

    // MARK: Hero

    private func hero(_ state: DeviceState) -> some View {
        let shown = model.debouncer?.displayed ?? ControlSettings(state)
        let range = state.limits.range(for: shown.mode)
        return CardSurface(padding: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                let dial = ThermostatDial(
                    room: state.roomTemperature, setpoint: shown.setTemperature, range: range,
                    step: state.temperatureIncrement, mode: shown.mode, isOn: shown.power
                ) { value, commit in
                    model.debouncer?.edit(.temperature(value), commit: commit)
                }
                .frame(width: 290, height: 290)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: Theme.Space.xxl) {
                        dial
                        facts(state)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        dial.frame(maxWidth: .infinity)
                        facts(state)
                    }
                }
                HStack(spacing: Theme.Space.s) {
                    SettingChip(title: shown.mode.displayName, systemImage: shown.mode.systemImage, tint: shown.mode.tint) {
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
                    Spacer()
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let debouncer = model.debouncer {
                StatusChip(status: debouncer.status, remaining: debouncer.remainingThisHour)
                    .fixedSize()
                    .padding(Theme.Space.m)
            }
        }
    }

    private func facts(_ state: DeviceState) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            fact("Ute", systemImage: "cloud.sun.fill", tint: Theme.Data.outside) {
                Text(Format.degrees(state.outdoorTemperature))
            }
            fact("Effekt", systemImage: "bolt.fill", tint: .yellow) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    if let watts = model.estimatedPowerW {
                        Text("≈ " + Format.watts(watts))
                    } else {
                        Text("—")
                    }
                    sparkline
                }
            } detail: {
                Text(model.estimatedPowerW == nil ? "Kommer med lokal tilkobling" : "Anslag fra strømmåleren i pumpen")
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
        .frame(minWidth: 250, maxWidth: .infinity, alignment: .leading)
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
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                detail().font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
                HStack(spacing: Theme.Space.m) {
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
        return Chart {
            ForEach(points, id: \.timestamp) { p in
                if let room = p.room {
                    AreaMark(x: .value("Tid", p.timestamp), yStart: .value("°C", low), yEnd: .value("°C", room), series: .value("S", "inne"))
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
