import Charts
import HeatPumpKit
import SwiftUI

/// An energy meter's history: use and cost per hour (24 h) or per day (7 d, 30 d), priced like
/// the rest of the app, with the previous period for comparison.
struct MeterHistoryView: View {
    @Environment(EnergyMeterDeviceModel.self) private var model
    @Environment(AppModel.self) private var app
    @State private var range: HistoryRange = .week
    @State private var bars: [Bar] = []
    @State private var previous: [Bar] = []
    @State private var showCost = false
    @State private var selected: Date?

    /// The meter keeps about a month of hours (Tibber gives 744 on the first fetch).
    private static let ranges: [HistoryRange] = [.day, .week, .month]

    struct Bar: Identifiable {
        var date: Date
        var kWh: Double
        var cost: CostSplit?
        var id: Date { date }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                HStack {
                    Spacer()
                    Picker("Period", selection: $range) {
                        ForEach(Self.ranges) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                kpis
                chartCard
                Text("Cost is your electricity contract, the grid tariff's energy charge and the electricity subsidy for each hour, as elsewhere in the app. \(model.serviceName)'s own cost does not include the grid tariff.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(range.rawValue)-\(model.revision)") { await load() }
    }

    private var perHour: Bool { range == .day }

    private func load() async {
        let now = Date()
        let start = range.start(now: now)
        let previousStart = range.shifted(start, by: -1)
        if perHour {
            bars = await model.hourly(from: start, to: now).map { Bar(date: $0.hour, kWh: $0.kWh, cost: $0.cost) }
            previous = await model.hourly(from: previousStart, to: start).map { Bar(date: $0.hour, kWh: $0.kWh, cost: $0.cost) }
        } else {
            bars = await model.daily(from: start, to: now).map { Bar(date: $0.start, kWh: $0.kWh, cost: $0.cost) }
            previous = await model.daily(from: previousStart, to: start).map { Bar(date: $0.start, kWh: $0.kWh, cost: $0.cost) }
        }
    }

    // MARK: KPIs

    private func total(_ bars: [Bar]) -> Double { bars.reduce(0) { $0 + $1.kWh } }

    private func cost(_ bars: [Bar]) -> Double? {
        let costs = bars.compactMap(\.cost)
        return costs.isEmpty ? nil : costs.reduce(0) { $0 + $1.totalNok }
    }

    private var kpis: some View {
        let kWh = total(bars)
        let days = max(1, Date().timeIntervalSince(range.start(now: Date())) / 86_400)
        return KPIRow {
            KPITile(
                label: "Electricity use", value: Format.kWh(kWh), delta: Delta.between(kWh, total(previous), higherIsGood: false),
                systemImage: "bolt.fill", tint: Theme.Data.energy)
            KPITile(
                label: "Cost", value: Format.kroner(cost(bars)), delta: Delta.between(cost(bars), cost(previous), higherIsGood: false),
                systemImage: "creditcard.fill", tint: Theme.Data.purple)
            KPITile(
                label: "Average per day", value: Format.kWh(kWh / days),
                detail: cost(bars).map { "\(Format.kroner($0 / days)) per day" }, systemImage: "calendar", tint: Theme.Data.energy)
        }
    }

    // MARK: Chart

    private var chartCard: some View {
        TrendCard(
            title: showCost ? "Cost" : "Electricity use", value: showCost ? Format.kroner(cost(bars)) : Format.kWh(total(bars))
        ) {
            FlowLayout {
                LegendDot(label: showCost ? "NOK" : "kWh", color: showCost ? Theme.Data.purple : Theme.Data.energy)
                LegendDot(label: "Previous period", color: Theme.Data.previous, dashed: true)
                Picker("Unit", selection: $showCost) {
                    Text("kWh").tag(false)
                    Text("NOK").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        } chart: {
            if bars.isEmpty {
                EmptyChart(title: "No energy data yet", message: "\(model.serviceName) reports each hour a little after it ends.")
            } else {
                chart.frame(height: 260)
            }
        }
    }

    private var chart: some View {
        let unit: Calendar.Component = perHour ? .hour : .day
        let shifted = previous.map { Bar(date: range.shifted($0.date, by: 1), kWh: $0.kWh, cost: $0.cost) }
        let color = showCost ? Theme.Data.purple : Theme.Data.energy
        return Chart {
            ForEach(bars) { bar in
                if let value = showCost ? bar.cost?.totalNok : bar.kWh {
                    BarMark(x: .value("Time", bar.date, unit: unit), y: .value("Value", value))
                        .foregroundStyle(color.opacity(0.85))
                        .cornerRadius(3)
                }
            }
            ForEach(shifted) { bar in
                if let value = showCost ? bar.cost?.totalNok : bar.kWh {
                    LineMark(x: .value("Time", bar.date, unit: unit), y: .value("Previous", value), series: .value("Series", "previous"))
                        .foregroundStyle(Theme.Data.previous)
                        .lineStyle(ChartKit.previousStroke)
                        .interpolationMethod(.monotone)
                }
            }
            if let bar = nearest(bars, to: selected, by: \.date) {
                RuleMark(x: .value("Selected", bar.date, unit: unit))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ChartTooltip(title: perHour ? Display.dateTime(bar.date) : Display.date(bar.date), rows: rows(bar))
                    }
            }
        }
        .calmYAxis { showCost ? String(localized: "\(Display.format("%.0f", $0)) NOK") : Display.format("%.0f", $0) }
        .calmXAxis(range.axisFormat)
        .chartXSelection(value: $selected)
        .accessibilityLabel("Electricity use of the house per period")
    }

    private func rows(_ bar: Bar) -> [(label: LocalizedStringKey, value: String, color: Color)] {
        var rows: [(label: LocalizedStringKey, value: String, color: Color)] = [("Consumption", Format.kWh(bar.kWh), Theme.Data.energy)]
        if let cost = bar.cost {
            rows.append(("Electricity", Format.kroner(cost.energyNok), Theme.Data.electricity))
            rows.append(("Grid tariff", Format.kroner(cost.gridNok), Theme.Data.gridTariff))
            if cost.supportNok < 0 { rows.append(("Subsidy", Format.kroner(cost.supportNok), Theme.Data.support)) }
            rows.append(("To pay", Format.kroner(cost.totalNok), .primary))
        }
        return rows
    }
}
