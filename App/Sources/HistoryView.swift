import Charts
import HeatPumpKit
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var range: HistoryRange = .week
    @State private var period: EnergyPeriod = .day
    @State private var data = HistoryData()
    @State private var energy: [EnergyBucket] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                temperatureSection
                energySection
                timelineSection
            }
            .padding(24)
        }
        .task(id: "\(range.rawValue)-\(model.revision)") { data = await model.history(range: range) }
        .task(id: "\(period.rawValue)-\(model.revision)") { energy = await model.energy(period: period) }
    }

    private var temperatureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Temperatur").font(.title2.weight(.semibold))
                Spacer()
                Picker("Periode", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if data.temperatures.isEmpty {
                empty("Ingen temperaturdata ennå")
            } else {
                Chart(data.temperatures) { point in
                    LineMark(
                        x: .value("Tid", point.date),
                        y: .value("°C", point.value))
                    .foregroundStyle(by: .value("Serie", point.series))
                    .interpolationMethod(point.series == "Ønsket" ? .stepEnd : .monotone)
                }
                .chartForegroundStyleScale(["Inne": Color.orange, "Ute": Color.blue, "Ønsket": Color.gray])
                .chartYScale(domain: temperatureDomain)
                .chartYAxisLabel("°C")
                .frame(height: 260)
                Text("Inne er romtemperaturen ved innedelen, Ute er målt av utedelen, Ønsket er temperaturen varmepumpen styrer mot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var energySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Strømforbruk").font(.title2.weight(.semibold))
                Spacer()
                Picker("Gruppering", selection: $period) {
                    Text("Dag").tag(EnergyPeriod.day)
                    Text("Uke").tag(EnergyPeriod.week)
                    Text("Måned").tag(EnergyPeriod.month)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if energy.isEmpty {
                empty("Ingen energidata ennå")
            } else {
                Chart(energy, id: \.period) { bucket in
                    BarMark(
                        x: .value("Periode", date(for: bucket), unit: unit),
                        y: .value("kWh", bucket.totalKWh))
                    .foregroundStyle(.teal)
                }
                .chartYAxisLabel("kWh")
                .frame(height: 220)
                Text("Totalt \(Format.kWh(energy.reduce(0) { $0 + $1.totalKWh })) i perioden. MELCloud oppdaterer energitall med noen timers forsinkelse.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drift").font(.title2.weight(.semibold))
            if data.power.isEmpty {
                empty("Ingen driftsdata ennå")
            } else {
                Chart {
                    ForEach(Array(data.power.enumerated()), id: \.offset) { _, point in
                        LineMark(x: .value("Tid", point.timestamp), y: .value("Av/på", point.value ?? 0))
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(.green)
                        PointMark(x: .value("Tid", point.timestamp), y: .value("Av/på", point.value ?? 0))
                            .foregroundStyle(.green)
                            .symbolSize(12)
                    }
                    ForEach(Array(data.modes.enumerated()), id: \.offset) { _, point in
                        PointMark(x: .value("Tid", point.timestamp), y: .value("Av/på", 1.15))
                            .foregroundStyle(by: .value("Modus", modeName(point.text)))
                            .symbolSize(18)
                    }
                }
                .chartYScale(domain: -0.1...1.3)
                .chartYAxis {
                    AxisMarks(values: [0, 1]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text(value.as(Double.self) == 1 ? "På" : "Av") }
                    }
                }
                .frame(height: 140)
                Text("Linjen viser om varmepumpen var på. Prikkene viser modus ved hver statushenting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func empty(_ title: String) -> some View {
        ContentUnavailableView(
            title, systemImage: "chart.line.uptrend.xyaxis",
            description: Text("Historikken bygges opp mens appen er i bruk, og eldre data hentes fra MELCloud (høyst én gang i timen)."))
        .frame(height: 180)
    }

    private func modeName(_ key: String?) -> String {
        key.flatMap(OperationMode.init(key:))?.displayName ?? "Ukjent"
    }

    private var unit: Calendar.Component {
        switch period {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    private func date(for bucket: EnergyBucket) -> Date {
        let text = period == .month ? bucket.period + "-01" : bucket.period
        return WireDate.parse(text, timeZone: .current) ?? .distantPast
    }

    /// Y range that fits the data with a little air, instead of always reaching 40 °C.
    private var temperatureDomain: ClosedRange<Double> {
        let values = data.temperatures.map(\.value)
        guard let low = values.min(), let high = values.max() else { return 0...30 }
        return (low.rounded(.down) - 2)...(high.rounded(.up) + 2)
    }
}
