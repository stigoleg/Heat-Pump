import Charts
import HeatPumpKit
import SwiftUI

/// An air quality sensor's history: a chart per value (hourly averages for 24 h, 7 d and 30 d,
/// daily averages for a year) with the fair and poor ranges as quiet bands behind the line.
struct AirQualityHistoryView: View {
    @Environment(AirQualityDeviceModel.self) private var model
    @State private var range: HistoryRange = .week
    @State private var series: [Series] = []
    @State private var thresholds = AirQualityThresholds.standard
    @State private var loaded = false

    struct Point: Identifiable {
        var date: Date
        var value: Double
        var id: Date { date }
    }

    struct Series: Identifiable {
        var metric: AirQualityMetric
        var points: [Point]
        var id: AirQualityMetric { metric }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                HStack {
                    Spacer()
                    Picker("Period", selection: $range) {
                        ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if loaded, series.isEmpty {
                    CardSurface {
                        EmptyChart(
                            title: "No history yet", message: "\(model.serviceName) is asked for the hourly averages at most once an hour.",
                            systemImage: DeviceKind.airQualitySensor.systemImage)
                    }
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 420), spacing: Theme.Space.l, alignment: .top)], alignment: .leading,
                    spacing: Theme.Space.l
                ) {
                    ForEach(series) { series in
                        SensorChart(series: series, ranges: thresholds.ranges(for: series.metric), range: range, perDay: perDay)
                    }
                }
                Text(perDay ? "Daily averages of the hourly values. Shaded bands mark the fair and poor ranges." : "Hourly averages. Shaded bands mark the fair and poor ranges.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(range.rawValue)-\(model.revision)") { await load() }
        .onAppear {
            if let value = ProcessInfo.processInfo.environment["VARMEPUMPE_HISTORY_RANGE"], let dev = HistoryRange(rawValue: value) {
                range = dev
            }
        }
    }

    /// A year is shown per day; the shorter periods per hour.
    private var perDay: Bool { range == .year }

    private func load() async {
        let now = Date()
        let hours = await model.hours(from: range.start(now: now), to: now)
        thresholds = await model.thresholds()
        let calendar = Calendar.current
        series = AirQualityMetric.allCases.filter { $0 != .battery }.compactMap { metric in
            let values = hours.compactMap { hour in hour.values[metric].map { (hour.hour, $0) } }
            guard !values.isEmpty else { return nil }
            guard perDay else { return Series(metric: metric, points: values.map { Point(date: $0.0, value: $0.1) }) }
            let days = Dictionary(grouping: values) { calendar.startOfDay(for: $0.0) }
            return Series(
                metric: metric,
                points: days.keys.sorted().map { day in
                    let dayValues = days[day, default: []].map(\.1)
                    return Point(date: day, value: dayValues.reduce(0, +) / Double(dayValues.count))
                })
        }
        loaded = true
    }
}

/// One value's chart: the line, the fair and poor bands, and a tooltip on hover.
private struct SensorChart: View {
    let series: AirQualityHistoryView.Series
    let ranges: [AirQualityRange]
    let range: HistoryRange
    let perDay: Bool
    @State private var selected: Date?

    private var metric: AirQualityMetric { series.metric }

    /// The data's span with some room, so a band never squeezes the line.
    private var domain: ClosedRange<Double> {
        let values = series.points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let pad = max((high - low) * 0.15, metric == .temperature ? 0.5 : 1)
        let floor = metric == .temperature || metric == .pressure ? low - pad : max(0, low - pad)
        return floor...(high + pad)
    }

    /// The bands that are not good, clipped to the chart.
    private var bands: [(start: Double, end: Double, level: AirQualityLevel)] {
        let domain = domain
        return ranges.filter { $0.level != .good }.compactMap { range in
            let start = max(domain.lowerBound, range.from ?? domain.lowerBound)
            let end = min(domain.upperBound, range.to ?? domain.upperBound)
            return start < end ? (start, end, range.level) : nil
        }
    }

    var body: some View {
        let latest = series.points.last
        TrendCard(title: .verbatim(metric.title), value: latest.map { metric.formatted($0.value) }) {
            FlowLayout {
                LegendDot(label: perDay ? "Daily average" : "Hourly average", color: metric.tint)
                if bands.contains(where: { $0.level == .fair }) { LegendDot(label: .verbatim(AirQualityLevel.fair.title), color: AirQualityLevel.fair.color) }
                if bands.contains(where: { $0.level == .poor }) { LegendDot(label: .verbatim(AirQualityLevel.poor.title), color: AirQualityLevel.poor.color) }
            }
        } chart: {
            Chart {
                ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                    RectangleMark(yStart: .value("From", band.start), yEnd: .value("To", band.end))
                        .foregroundStyle(band.level.color.opacity(0.07))
                }
                ForEach(series.points) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Value", point.value), series: .value("Series", metric.rawValue))
                        .foregroundStyle(metric.tint)
                        .interpolationMethod(.monotone)
                }
                if let point = nearest(series.points, to: selected, by: \.date) {
                    RuleMark(x: .value("Selected", point.date))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            ChartTooltip(
                                title: perDay ? Display.date(point.date) : Display.dateTime(point.date),
                                rows: [(.verbatim(metric.title), metric.formatted(point.value), metric.tint)])
                        }
                }
            }
            .chartYScale(domain: domain)
            .calmYAxis { Display.format(metric.fractionDigits == 1 ? "%.1f" : "%.0f", $0) }
            .calmXAxis(range.axisFormat)
            .chartXSelection(value: $selected)
            .frame(height: 180)
            .accessibilityLabel(Text(verbatim: metric.title))
        }
    }
}
