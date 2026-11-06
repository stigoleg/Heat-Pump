import Charts
import HeatPumpKit
import SwiftUI

/// An energy meter's overview: power now with the last hour's trend, today's use and cost, the
/// price now and, with a heat pump in the app, its share of the house today.
struct MeterOverviewView: View {
    @Environment(EnergyMeterDeviceModel.self) private var model
    @Environment(AppModel.self) private var app
    @State private var selected: Date?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    StatusBanner(showsDevice: false)
                    if let problem { problemCard(problem) }
                    nowSection
                    trendSection.id("trend")
                    todaySection.id("today")
                    Text("Hourly figures from \(model.serviceName) arrive 2–3 hours late; until then today's use comes from the live meter reader.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .devScrollTarget(proxy)
        }
    }

    // MARK: Problems

    private var problem: String? {
        if !model.hasCredentials { return String(localized: "Add the \(model.serviceName) token under Settings → Account.") }
        return model.syncProblem ?? model.liveProblem
    }

    private func problemCard(_ text: String) -> some View {
        InsightCard(
            title: "Some data could not be fetched", detail: .verbatim(text), systemImage: "exclamationmark.triangle.fill",
            tint: Theme.Status.caution)
    }

    // MARK: Now

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Now", hint: .verbatim(model.displayName))
            CardSurface {
                KPIRow {
                    KPITile(
                        label: "Power now", value: Format.watts(model.powerNowW), detail: powerDetail, systemImage: "bolt.fill",
                        tint: .yellow)
                    KPITile(
                        label: "Today", value: model.status.map { Format.kWh($0.today.kWh) } ?? "—",
                        detail: model.status?.today.cost.map { .verbatim(Format.kroner($0.totalNok)) }, systemImage: "chart.bar.fill",
                        tint: Theme.Data.energy)
                    KPITile(
                        label: "Price now", value: priceNow, detail: .verbatim(app.priceSettings.agreement.displayName),
                        systemImage: "bolt.horizontal.fill", tint: app.currentPriceLevel?.color ?? Theme.Data.electricity)
                    if let share = heatPumpShare {
                        KPITile(
                            label: "Heat pump share", value: Format.percentShare(share), detail: "Of the house's use today",
                            systemImage: "fan.fill", tint: Theme.Data.inside)
                    }
                }
            }
        }
    }

    private var powerDetail: LocalizedStringKey {
        guard model.hasLivePower else { return "No live meter reader" }
        switch model.liveState {
        case .connecting: return "Connecting…"
        case .waiting(let until): return "Reconnecting at \(Format.hour(until))"
        case .stopped: return "Live power is off"
        case .live, nil: return model.powerNowW == nil ? "Waiting for a reading" : "Live from \(model.serviceName)"
        }
    }

    private var priceNow: String {
        let now = Date()
        guard let price = app.todayPrices.first(where: { $0.hour <= now && now < $0.hour.addingTimeInterval(3600) }) else { return "—" }
        return String(localized: "\(Display.format("%.2f", price.totalOre / 100)) NOK/kWh")
    }

    /// Every heat pump's use today against the house's (nil without a heat pump or house data).
    private var heatPumpShare: Double? {
        let pumps = app.heatPumps.compactMap(\.today)
        guard !pumps.isEmpty, let house = model.status?.today.kWh, house > 0.1 else { return nil }
        return min(1, pumps.map(\.totalKWh).reduce(0, +) / house)
    }

    // MARK: Trend

    private struct Point: Identifiable {
        var date: Date
        var watts: Double
        var id: Date { date }
    }

    /// The stored minutes of the last hour, and this run's newest reading.
    private var points: [Point] {
        var points = model.recentMinutes.map { Point(date: $0.minute.addingTimeInterval(30), watts: $0.powerW) }
        if let reading = model.currentReading, reading.at > (points.last?.date ?? .distantPast) {
            points.append(Point(date: reading.at, watts: reading.powerW))
        }
        return points
    }

    private var trendSection: some View {
        let points = points
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            TrendCard(title: "Power, last hour", value: points.isEmpty ? nil : Format.watts(points.map(\.watts).max()) + " max") {
                LegendDot(label: "W", color: Theme.Data.energy)
            } chart: {
                if points.count < 2 {
                    EmptyChart(
                        title: "No live power yet",
                        message: model.hasLivePower
                            ? "The trend fills in while the app is open."
                            : "Live power needs a real-time meter reader paired with the home in the \(model.serviceName) app.",
                        systemImage: "bolt.slash")
                } else {
                    Chart {
                        ForEach(points) { point in
                            AreaMark(x: .value("Time", point.date), y: .value("W", point.watts))
                                .foregroundStyle(ChartKit.areaGradient(Theme.Data.energy))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("Time", point.date), y: .value("W", point.watts), series: .value("Series", "power"))
                                .foregroundStyle(Theme.Data.energy)
                                .interpolationMethod(.monotone)
                        }
                        if let point = nearest(points, to: selected, by: \.date) {
                            RuleMark(x: .value("Selected", point.date))
                                .foregroundStyle(Color.secondary.opacity(0.25))
                                .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                    ChartTooltip(title: Display.time(point.date), rows: [("Power", Format.watts(point.watts), Theme.Data.energy)])
                                }
                        }
                    }
                    .chartXScale(domain: Date().addingTimeInterval(-3600)...Date())
                    .calmYAxis()
                    .calmXAxis(Date.FormatStyle().hour().minute(), count: 6)
                    .chartXSelection(value: $selected)
                    .frame(height: 160)
                    .accessibilityLabel("Power over the last hour")
                }
            }
        }
    }

    // MARK: Today

    private var dayStart: Date { Calendar.current.startOfDay(for: Date()) }

    private var todaySection: some View {
        let hours = model.status?.today.hours ?? []
        return TrendCard(title: "Today per hour", value: model.status.map { Format.kWh($0.today.kWh) }) {
            if model.status?.today.includesLive == true {
                Text("Includes live readings").font(.caption).foregroundStyle(.secondary)
            }
        } chart: {
            if hours.isEmpty {
                EmptyChart(
                    title: "No hours yet today", message: "\(model.serviceName) reports each hour a little after it ends.",
                    systemImage: "chart.bar")
            } else {
                Chart {
                    ForEach(hours, id: \.hour) { hour in
                        BarMark(x: .value("Hour", hour.hour, unit: .hour), y: .value("kWh", hour.kWh))
                            .foregroundStyle(Theme.Data.energy.opacity(0.85))
                            .cornerRadius(3)
                    }
                }
                .chartXScale(domain: dayStart...dayStart.addingTimeInterval(86_400))
                .calmYAxis { Display.format(hours.map(\.kWh).max() ?? 0 < 2 ? "%.2f" : "%.1f", $0) }
                .calmXAxis(Date.FormatStyle().hour(), count: 8)
                .frame(height: 180)
                .accessibilityLabel("Electricity use per hour today")
            }
        }
    }
}
