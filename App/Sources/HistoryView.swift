import Charts
import HeatPumpKit
import SwiftUI

enum HistoryTab: String, CaseIterable, Identifiable {
    case temperature, energy, operation, power
    var id: String { rawValue }
    var title: String {
        switch self {
        case .temperature: String(localized: "Temperature")
        case .energy: String(localized: "Energy and cost")
        case .operation: String(localized: "Operation")
        case .power: String(localized: "Power")
        }
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: HistoryTab = .temperature
    @State private var range: HistoryRange = .week
    @State private var data = HistoryData()
    @State private var previous = HistoryData()
    @State private var energy = EnergyData()
    @State private var localPower = LocalPowerData()
    @State private var forecast: [ForecastHour] = []
    @State private var houseShare: HouseShareSummary?
    @State private var phaseSpans: [LocalPhaseSpan] = []
    @State private var defrostSpans: [LocalPhaseSpan] = []
    @State private var showCost = false
    @State private var selected: Date?
    @State private var selectedPrice: Date?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        tabPicker
                        Spacer()
                        rangePicker
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        tabPicker
                        rangePicker
                    }
                    // Narrowest: the tabs become a pop-up menu.
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        tabMenu
                        rangePicker
                    }
                }
                switch tab {
                case .temperature: temperatureTab
                case .energy: energyTab
                case .operation: operationTab
                case .power: powerTab
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .devScrollTarget(proxy)
        }
        .task(id: "\(range.rawValue)-\(model.revision)") {
            let now = Date()
            let start = range.start(now: now)
            data = await model.history(from: start, to: now)
            previous = await model.history(from: range.shifted(start, by: -1), to: start)
            energy = await model.energy(range: range)
            forecast = forecastHours > 0 ? await model.forecast(until: now.addingTimeInterval(forecastHours * 3600)) : []
            houseShare = await model.houseShare(range: range)
        }
        // Power data only while that tab is shown (aggregated in SQL off the main thread).
        .task(id: "\(range.rawValue)-\(model.revision)-\(tab == .power)") {
            guard tab == .power else { return }
            localPower = await model.localPower(range: range)
        }
        // Local phases (running, rest, defrost) for Operation and Power.
        .task(id: "\(range.rawValue)-\(model.revision)-\(tab == .power || tab == .operation)") {
            guard tab == .power || tab == .operation else { return }
            if tab == .operation { phaseSpans = await model.phaseSpans(range: range) }
            if tab == .power { defrostSpans = await model.defrostSpans(range: range) }
        }
        .onChange(of: tab) { selected = nil }
        .onAppear {
            if model.initialHistoryTab == "energy-kr" {
                tab = .energy
                showCost = true
            } else if let initial = model.initialHistoryTab.flatMap(HistoryTab.init(rawValue:)) {
                tab = initial
            }
            if let days = ProcessInfo.processInfo.environment["VARMEPUMPE_HISTORY_RANGE"].flatMap(HistoryRange.init(rawValue:)) {
                range = days
            }
        }
    }

    private var periodStart: Date { range.start(now: Date()) }

    /// Hours of forecast shown after "now" in the temperature chart (24 h and 7 d only).
    private var forecastHours: Double {
        switch range {
        case .day: 24
        case .week: 48
        case .month, .year: 0
        }
    }

    private var temperatureEnd: Date {
        forecast.isEmpty ? Date() : max(Date(), forecast.last?.time ?? Date())
    }

    private var tabPicker: some View {
        Picker("View", selection: $tab) {
            ForEach(HistoryTab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var tabMenu: some View {
        Picker("View", selection: $tab) {
            ForEach(HistoryTab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    private var rangePicker: some View {
        Picker("Period", selection: $range) {
            ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: Temperature

    private var temperatureTab: some View {
        let points = Downsample.temperatures(data.temperatures, maxCount: 600)
        let inside = data.temperatures.compactMap(\.room)
        let outside = data.temperatures.compactMap(\.outdoor)
        let prevInside = previous.temperatures.compactMap(\.room)
        let prevOutside = previous.temperatures.compactMap(\.outdoor)
        return VStack(alignment: .leading, spacing: Theme.Space.xl) {
            KPIRow {
                KPITile(
                    label: "Average indoor", value: Format.temperature(inside.average),
                    delta: Delta.between(inside.average, prevInside.average, higherIsGood: true), systemImage: "house.fill",
                    tint: Theme.Data.inside)
                KPITile(
                    label: "Lowest / highest indoor",
                    value: inside.isEmpty ? "–" : Display.format("%.1f / %.1f°", inside.min() ?? 0, inside.max() ?? 0),
                    detail: "in the period", systemImage: "arrow.up.arrow.down", tint: Theme.Data.inside)
                KPITile(
                    label: "Average outdoor", value: Format.temperature(outside.average),
                    detail: prevOutside.average.map { "Previous period: \(Format.temperature($0))" }, systemImage: "cloud.sun.fill",
                    tint: Theme.Data.outside)
                KPITile(
                    label: "Cost in the period", value: Format.kroner(energy.totalCost),
                    detail: energy.isEstimate ? "Partly estimated" : nil, systemImage: "creditcard.fill", tint: Theme.Data.purple)
            }
            TrendCard(title: "Temperature", value: inside.last.map { String(localized: "Indoors now \(Format.degrees($0))") }) {
                FlowLayout {
                    LegendDot(label: "Indoor", color: Theme.Data.inside)
                    LegendDot(label: "Outdoor", color: Theme.Data.outside)
                    LegendDot(label: "Target", color: Theme.Data.setpoint, dashed: true)
                    if !forecast.isEmpty { LegendDot(label: "Forecast outdoor", color: Theme.Data.outside.opacity(0.7), dashed: true) }
                }
            } chart: {
                if points.isEmpty {
                    EmptyChart(
                        title: "No temperature data yet",
                        message: "The history builds up while the app is open, and older data is fetched from \(model.serviceName) (at most once an hour).")
                } else {
                    temperatureChart(points).frame(height: 300)
                }
            }
            if !forecast.isEmpty {
                Text("The dashed line after “now” is the outdoor weather forecast. \(WeatherForecast.attribution).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !data.fromService && !points.isEmpty {
                Label(
                    "The temperature log from \(model.serviceName) is not available. The chart shows the readings the app has fetched itself, and builds up while the app is open.",
                    systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func temperatureChart(_ points: [TemperaturePoint]) -> some View {
        let values = points.flatMap { [$0.room, $0.outdoor, $0.set].compactMap { $0 } } + forecast.map(\.temperature)
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
                        .interpolationMethod(.monotone)
                }
                if let set = p.set {
                    LineMark(x: .value("Time", p.timestamp), y: .value("°C", set), series: .value("Series", "target"))
                        .foregroundStyle(Theme.Data.setpoint)
                        .lineStyle(ChartKit.setpointStroke)
                        .interpolationMethod(.stepEnd)
                }
            }
            ForEach(forecast, id: \.time) { h in
                LineMark(x: .value("Time", h.time), y: .value("°C", h.temperature), series: .value("Series", "forecast"))
                    .foregroundStyle(Theme.Data.outside.opacity(0.7))
                    .lineStyle(ChartKit.previousStroke)
                    .interpolationMethod(.monotone)
            }
            if !forecast.isEmpty {
                RuleMark(x: .value("Now", Date()))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        Text("now").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
            }
            if let selected, selected > Date(), let h = nearest(forecast, to: selected, by: \.time) {
                RuleMark(x: .value("Selected", h.time))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ChartTooltip(
                            title: String(localized: "\(Display.dateTime(h.time)) (forecast)"),
                            rows: [("Outdoor", Format.temperature(h.temperature), Theme.Data.outside)])
                    }
            } else if let p = nearest(points, to: selected, by: \.timestamp) {
                RuleMark(x: .value("Selected", p.timestamp))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ChartTooltip(
                            title: Display.dateTime(p.timestamp),
                            rows: [
                                ("Indoor", Format.temperature(p.room), Theme.Data.inside),
                                ("Outdoor", Format.temperature(p.outdoor), Theme.Data.outside),
                                ("Target", Format.temperature(p.set), Theme.Data.setpoint),
                            ])
                    }
            }
        }
        .chartXScale(domain: periodStart...temperatureEnd)
        .padding(.top, forecast.isEmpty ? 0 : Theme.Space.m)
        .chartYScale(domain: low...high)
        .calmYAxis { Display.format("%.0f°", $0) }
        .calmXAxis(range.axisFormat)
        .chartXSelection(value: $selected)
    }

    // MARK: Energy and cost

    private var energyTab: some View {
        let bars = energyBars
        let previousBars = previousEnergyBars
        let totalKWh = bars.reduce(0) { $0 + $1.kWh }
        let previousKWh = previousBars.reduce(0) { $0 + $1.kWh }
        let support = energy.buckets.compactMap(\.cost?.supportNok).reduce(0, +)
        let days = max(1, Date().timeIntervalSince(periodStart) / 86_400)
        return VStack(alignment: .leading, spacing: Theme.Space.xl) {
            KPIRow {
                KPITile(
                    label: "Electricity use", value: Format.kWh(totalKWh),
                    delta: Delta.between(totalKWh, previousKWh, higherIsGood: false), systemImage: "bolt.fill", tint: Theme.Data.energy)
                KPITile(
                    label: "Cost", value: Format.kroner(energy.totalCost),
                    delta: Delta.between(energy.totalCost, energy.previousTotalCost, higherIsGood: false),
                    systemImage: "creditcard.fill", tint: Theme.Data.purple)
                KPITile(
                    label: "Average per day", value: Format.kWh(totalKWh / days),
                    detail: energy.totalCost.map { "\(Format.kroner($0 / days)) per day" }, systemImage: "calendar",
                    tint: Theme.Data.energy)
                KPITile(
                    label: "Electricity subsidy", value: Format.kroner(abs(support)),
                    detail: model.priceSettings.agreement == .norgespris ? "Not with Norgespris" : "deducted",
                    systemImage: "gift.fill", tint: Theme.Data.support)
            }
            TrendCard(
                title: showCost ? "Cost" : "Electricity use",
                value: showCost ? Format.kroner(energy.totalCost) : Format.kWh(totalKWh),
                delta: showCost
                    ? Delta.between(energy.totalCost, energy.previousTotalCost, higherIsGood: false)
                    : Delta.between(totalKWh, previousKWh, higherIsGood: false)
            ) {
                FlowLayout {
                    if showCost {
                        LegendDot(label: "Electricity after subsidy", color: Theme.Data.electricity)
                        LegendDot(label: "Grid tariff", color: Theme.Data.gridTariff)
                        LegendDot(label: "Subsidy (deducted)", color: Theme.Data.support.opacity(0.35))
                    } else {
                        LegendDot(label: "kWh", color: Theme.Data.energy)
                    }
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
                    EmptyChart(
                        title: "No energy data yet",
                        message: range == .day
                            ? "Consumption per hour is calculated from the pump’s power meter while the app is open."
                            : "\(model.serviceName) updates energy figures with a delay of a few hours.")
                } else {
                    energyChart(bars, previous: previousBars).frame(height: 260)
                }
            }
            if energy.isEstimate {
                Label(
                    "Cost marked as estimated: for hours without measured consumption, the day’s kWh is priced at the day’s average price. The capacity charge in the grid tariff is not included, because it depends on the whole household’s highest consumption.",
                    systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
            }
            modeSplit.id("modes")
            houseSection.id("house")
            priceSection.id("prices")
        }
    }

    // MARK: Mode split and the house

    @ViewBuilder private var modeSplit: some View {
        let split = energy.buckets.compactMap(\.modes).reduce(into: EnergyModeSplit()) { total, m in
            total.heatingKWh += m.heatingKWh
            total.coolingKWh += m.coolingKWh
            total.autoKWh += m.autoKWh
            total.dryKWh += m.dryKWh
            total.fanKWh += m.fanKWh
            total.otherKWh += m.otherKWh
        }
        let shares = split.shares
        if !shares.isEmpty {
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack {
                        Text("Breakdown by mode").font(.headline)
                        Spacer()
                        Text("From \(model.serviceName)").font(.caption).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(shares, id: \.name) { share in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(share.mode?.tint ?? .gray)
                                    .frame(width: max(2, (geo.size.width - CGFloat(shares.count) * 2) * share.share))
                            }
                        }
                    }
                    .frame(height: 10)
                    FlowLayout(spacing: Theme.Space.l) {
                        ForEach(shares, id: \.name) { share in
                            LegendDot(
                                label: .verbatim("\(share.name) \(Format.percentShare(share.share)) · \(Format.kWh(share.kWh))"),
                                color: share.mode?.tint ?? .gray)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var houseSection: some View {
        if let house = houseShare {
            let perHour = range == .day
            let items = houseBars(house, perHour: perHour)
            TrendCard(title: "The heat pump’s share of household electricity", value: house.yesterday?.share.map {
                String(localized: "The heat pump used \(Format.percentShare($0)) of the electricity yesterday")
            }) {
                FlowLayout {
                    LegendDot(label: "Heat pump", color: Theme.Data.energy)
                    LegendDot(label: "Rest of the house", color: Color.gray.opacity(0.45))
                }
            } chart: {
                if items.isEmpty {
                    EmptyChart(title: "No figures for the period", message: "Tibber updates the household consumption with a delay of a few hours.")
                } else {
                    Chart {
                        ForEach(items, id: \.date) { item in
                            BarMark(x: .value("Time", item.date, unit: perHour ? .hour : .day), yStart: .value("kWh", 0), yEnd: .value("kWh", item.pump))
                                .foregroundStyle(Theme.Data.energy.opacity(item.measured ? 0.9 : 0.55))
                            BarMark(x: .value("Time", item.date, unit: perHour ? .hour : .day), yStart: .value("kWh", item.pump), yEnd: .value("kWh", max(item.pump, item.house)))
                                .foregroundStyle(Color.gray.opacity(0.45))
                        }
                        if let item = nearest(items, to: selected, by: \.date) {
                            RuleMark(x: .value("Selected", item.date, unit: perHour ? .hour : .day))
                                .foregroundStyle(Color.secondary.opacity(0.25))
                                .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                    ChartTooltip(
                                        title: perHour ? Display.dateTime(item.date) : Display.date(item.date),
                                        rows: [
                                            ("House", Format.kWh(item.house), .secondary),
                                            (item.measured ? "Heat pump" : "Heat pump (estimated)", Format.kWh(item.pump), Theme.Data.energy),
                                            ("Share", item.house > 0 ? Format.percentShare(item.pump / item.house) : "–", .primary),
                                        ])
                                }
                        }
                    }
                    // Day bars reach to the end of today (and hour bars to the end of this hour).
                    .chartXScale(domain: periodStart...houseDomainEnd(perHour: perHour))
                    .calmYAxis { Display.format("%.0f", $0) }
                    .calmXAxis(perHour ? Date.FormatStyle().hour(.twoDigits(amPM: .abbreviated)) : range.axisFormat)
                    .chartXSelection(value: $selected)
                    .frame(height: 200)
                }
            }
            let days = house.days.filter { $0.start >= Calendar.current.startOfDay(for: periodStart) }
            let tibberCost = days.compactMap(\.houseCostNok).reduce(0, +)
            (tibberCost > 0
                ? Text("The household consumption comes from Tibber (a few hours’ delay). The heat pump’s part is measured locally where possible (dark), otherwise estimated from \(model.serviceName) (light). The house cost \(Format.kroner(tibberCost)) in the period according to Tibber (electricity, without grid tariff).")
                : Text("The household consumption comes from Tibber (a few hours’ delay). The heat pump’s part is measured locally where possible (dark), otherwise estimated from \(model.serviceName) (light)."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func houseDomainEnd(perHour: Bool) -> Date {
        let calendar = Calendar.current
        let now = Date()
        return (perHour ? calendar.dateInterval(of: .hour, for: now)?.end : calendar.dateInterval(of: .day, for: now)?.end) ?? now
    }

    private struct HouseBar {
        var date: Date
        var house: Double
        var pump: Double
        var measured: Bool
    }

    private func houseBars(_ house: HouseShareSummary, perHour: Bool) -> [HouseBar] {
        if perHour {
            return house.hours.filter { $0.hour >= periodStart }.map {
                HouseBar(date: $0.hour, house: $0.houseKWh, pump: $0.heatPumpKWh ?? 0, measured: $0.heatPumpMeasured)
            }
        }
        return house.days.filter { $0.start >= Calendar.current.startOfDay(for: periodStart) }.map {
            HouseBar(date: $0.start, house: $0.houseKWh, pump: $0.heatPumpKWh, measured: $0.heatPumpMeasured)
        }
    }

    struct EnergyBar: Identifiable {
        var date: Date
        var unit: Calendar.Component
        var kWh: Double
        var cost: CostSplit?
        var isEstimate: Bool
        var id: Date { date }
    }

    private var energyBars: [EnergyBar] { bars(buckets: energy.buckets, hourly: energy.hourly) }
    private var previousEnergyBars: [EnergyBar] { bars(buckets: energy.previous, hourly: energy.previousHourly) }

    private func bars(buckets: [EnergyBucket], hourly: [HourCost]) -> [EnergyBar] {
        if range == .day {
            return hourly.map { EnergyBar(date: $0.hour, unit: .hour, kWh: $0.kWh, cost: $0.cost, isEstimate: false) }
        }
        let unit: Calendar.Component = range == .year ? .month : .day
        return buckets.compactMap { b in
            let text = unit == .month ? b.period + "-01" : b.period
            guard let date = WireDate.parse(text, timeZone: .current) else { return nil }
            return EnergyBar(date: date, unit: unit, kWh: b.totalKWh, cost: b.cost, isEstimate: b.isEstimate)
        }
    }

    private func energyChart(_ bars: [EnergyBar], previous: [EnergyBar]) -> some View {
        // Previous period drawn on the current period's dates (same position in the period).
        let shifted = previous.map { bar -> EnergyBar in
            var moved = bar
            moved.date = range.shifted(bar.date, by: 1)
            return moved
        }
        let unit = bars.first?.unit ?? .day
        return Chart {
            ForEach(bars) { bar in
                if showCost, let cost = bar.cost {
                    // The solid bar is what you pay: electricity after support + grid tariff.
                    // The pale cap on top is the support that was deducted.
                    let electricity = max(0, cost.energyNok + cost.supportNok)
                    let net = electricity + cost.gridNok
                    BarMark(
                        x: .value("Time", bar.date, unit: unit), yStart: .value("NOK", 0), yEnd: .value("NOK", electricity))
                        .foregroundStyle(by: .value("Part", CostPart.electricity.title))
                    BarMark(
                        x: .value("Time", bar.date, unit: unit), yStart: .value("NOK", electricity), yEnd: .value("NOK", net))
                        .foregroundStyle(by: .value("Part", CostPart.grid.title))
                    if cost.supportNok < 0 {
                        BarMark(
                            x: .value("Time", bar.date, unit: unit), yStart: .value("NOK", net),
                            yEnd: .value("NOK", net - cost.supportNok))
                            .foregroundStyle(by: .value("Part", CostPart.support.title))
                    }
                } else if !showCost {
                    BarMark(x: .value("Time", bar.date, unit: unit), y: .value("kWh", bar.kWh))
                        .foregroundStyle(Theme.Data.energy.opacity(bar.isEstimate && showCost ? 0.5 : 0.85))
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
                        ChartTooltip(title: title(for: bar), rows: tooltipRows(bar))
                    }
            }
        }
        .chartForegroundStyleScale([
            CostPart.electricity.title: Theme.Data.electricity, CostPart.grid.title: Theme.Data.gridTariff,
            CostPart.support.title: Theme.Data.support.opacity(0.3),
        ])
        .chartLegend(.hidden)
        .calmYAxis { showCost ? String(localized: "\(Display.format("%.0f", $0)) NOK") : Display.format("%.0f", $0) }
        .calmXAxis(range.axisFormat)
        .chartXSelection(value: $selected)
    }

    private func title(for bar: EnergyBar) -> String {
        switch bar.unit {
        case .hour: Display.dateTime(bar.date)
        case .month: bar.date.formatted(Date.FormatStyle().month(.wide).year().locale(Display.locale))
        default: Display.date(bar.date)
        }
    }

    private func tooltipRows(_ bar: EnergyBar) -> [(label: LocalizedStringKey, value: String, color: Color)] {
        var rows: [(label: LocalizedStringKey, value: String, color: Color)] = [("Consumption", Format.kWh(bar.kWh), Theme.Data.energy)]
        if let cost = bar.cost {
            rows.append(("Electricity", Format.kroner(cost.energyNok), Theme.Data.electricity))
            rows.append(("Grid tariff", Format.kroner(cost.gridNok), Theme.Data.gridTariff))
            if cost.supportNok < 0 { rows.append(("Subsidy", Format.kroner(cost.supportNok), Theme.Data.support)) }
            rows.append((bar.isEstimate ? "To pay (estimated)" : "To pay", Format.kroner(cost.totalNok), .primary))
        }
        return rows
    }

    private var priceSection: some View {
        let today = model.todayPrices
        let tomorrow = model.tomorrowPrices
        let all = today + tomorrow
        let now = Date()
        return TrendCard(
            title: "Electricity price per hour",
            value: all.first { $0.hour <= now && now < $0.hour.addingTimeInterval(3600) }.map {
                String(localized: "Now \(Display.format("%.2f", $0.totalOre / 100)) NOK/kWh")
            }
        ) {
            FlowLayout {
                if all.contains(where: { $0.level != nil }) {
                    ForEach([PriceLevel.veryCheap, .cheap, .normal, .expensive, .veryExpensive], id: \.self) {
                        LegendDot(label: .verbatim($0.displayName), color: $0.color)
                    }
                } else {
                    LegendDot(label: "Today", color: Theme.Data.purple)
                }
                LegendDot(label: tomorrow.isEmpty ? "Tomorrow (from about 13:00)" : "Tomorrow (lighter)", color: Theme.Data.purple.opacity(0.4))
            }
        } chart: {
            if all.isEmpty {
                EmptyChart(
                    title: "No prices yet", message: model.priceMessage.map { .verbatim($0) } ?? "Choose an electricity contract under Settings → Electricity price.",
                    systemImage: "bolt.horizontal")
            } else {
                Chart {
                    ForEach(all, id: \.hour) { p in
                        BarMark(x: .value("Hour", p.hour, unit: .hour), y: .value("NOK/kWh", p.totalOre / 100))
                            .foregroundStyle((p.level?.color ?? Theme.Data.purple).opacity(Calendar.current.isDateInToday(p.hour) ? 0.85 : 0.4))
                            .cornerRadius(2)
                    }
                    RuleMark(x: .value("Now", now))
                        .foregroundStyle(Theme.Status.caution)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            Text("now").font(.caption2.weight(.semibold)).foregroundStyle(Theme.Status.caution)
                        }
                    if let p = nearest(all, to: selectedPrice, by: \.hour) {
                        RuleMark(x: .value("Selected", p.hour, unit: .hour))
                            .foregroundStyle(Color.secondary.opacity(0.25))
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                ChartTooltip(
                                    title: Display.dateTime(p.hour),
                                    rows: [
                                        ("Electricity", Display.format("%.0f øre", p.energyOre), Theme.Data.electricity),
                                        ("Grid tariff", Display.format("%.0f øre", p.gridOre), Theme.Data.gridTariff),
                                        ("Subsidy", Display.format("%.0f øre", p.supportOre), Theme.Data.support),
                                        ("Total", Format.kroner(p.totalOre / 100), .primary),
                                        ("Level", p.level.map { $0.displayName + (p.levelFromTibber ? " (Tibber)" : "") } ?? "–", p.level?.color ?? .secondary),
                                    ])
                            }
                    }
                }
                .calmYAxis { Display.format("%.1f", $0) }
                .calmXAxis(Date.FormatStyle().hour(.twoDigits(amPM: .abbreviated)), count: 8)
                .chartXSelection(value: $selectedPrice)
                .padding(.top, Theme.Space.l)
                .frame(height: 196)
            }
        }
    }

    // MARK: Operation

    private var operationTab: some View {
        let bands = OperationBands.make(power: data.power, modes: data.modes, end: Date()) + OperationBands.local(phaseSpans)
        let onSeconds = bands.filter { $0.row == .power && $0.isOn }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let covered = bands.filter { $0.row == .power }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let modeSeconds = Dictionary(grouping: bands.filter { $0.row == .mode }, by: \.label)
            .mapValues { $0.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } }
        let mainMode = modeSeconds.max { $0.value < $1.value }?.key
        return VStack(alignment: .leading, spacing: Theme.Space.xl) {
            KPIRow {
                KPITile(
                    label: "Share on", value: covered > 0 ? Display.format("%.0f %%", onSeconds / covered * 100) : "–",
                    detail: "of the time with data", systemImage: "power", tint: Theme.Status.good)
                KPITile(label: "Most used mode", value: mainMode ?? "–", systemImage: "dial.medium", tint: Theme.Data.orange)
                KPITile(
                    label: "Changes", value: "\(model.changes.filter { $0.timestamp >= periodStart && $0.result == .ok }.count)",
                    detail: "sent from the app and Claude", systemImage: "slider.horizontal.3", tint: Theme.Data.purple)
                KPITile(
                    label: "Cost in the period", value: Format.kroner(energy.totalCost), detail: energy.isEstimate ? "Partly estimated" : nil,
                    systemImage: "creditcard.fill", tint: Theme.Data.purple)
            }
            TrendCard(title: "Operation") {
                FlowLayout {
                    ForEach([OperationMode.heat, .cool, .dry, .fan, .auto], id: \.self) {
                        LegendDot(label: .verbatim($0.displayName), color: $0.tint)
                    }
                    if !phaseSpans.isEmpty {
                        ForEach([LocalPhaseSpan.Kind.running, .rest, .defrost], id: \.self) {
                            LegendDot(label: .verbatim($0.displayName), color: $0.color)
                        }
                    }
                }
            } chart: {
                if bands.isEmpty {
                    EmptyChart(title: "No operation data yet", message: "Operation is recorded every time the app or Claude fetches the status.")
                } else {
                    Chart(bands) { band in
                        RectangleMark(
                            xStart: .value("From", band.start), xEnd: .value("To", band.end), y: .value("Row", band.row.title), height: 22)
                        .foregroundStyle(band.color)
                        .cornerRadius(3)
                    }
                    .chartXScale(domain: periodStart...Date())
                    .chartYAxis {
                        AxisMarks { value in
                            AxisValueLabel { if let row = value.as(String.self) { Text(row).font(.caption) } }
                        }
                    }
                    .calmXAxis(range.axisFormat)
                    .frame(height: phaseSpans.isEmpty ? 110 : 150)
                }
            }
            Group {
                if phaseSpans.isEmpty {
                    Text("The top row shows whether the heat pump was on (green) or off (gray). The next row shows the mode.")
                } else if range == .day {
                    Text("The top row shows whether the heat pump was on (green) or off (gray). The next row shows the mode. The “Local” row comes from the Wi-Fi adapter: indigo when the compressor is running, gray when it is resting, yellow at start-up and pink when the outdoor unit is defrosting. Defrosting is normal in damp cold.")
                } else {
                    Text("The top row shows whether the heat pump was on (green) or off (gray). The next row shows the mode. The “Local” row comes from the Wi-Fi adapter: indigo when the compressor is running, gray when it is resting, yellow at start-up and pink when the outdoor unit is defrosting. Defrosting is normal in damp cold. For longer periods, what dominated each interval is shown.")
                }
            }
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Power

    @Environment(\.openSettings) private var openSettings

    @ViewBuilder private var powerTab: some View {
        if !model.localSettings.enabled && localPower.buckets.isEmpty {
            CardSurface {
                VStack(spacing: Theme.Space.m) {
                    EmptyChart(
                        title: "Power requires a local connection",
                        message: "Turn on the local connection, and the app reads power in watts and the compressor’s activity directly from the Wi-Fi adapter on the home network (read only).",
                        systemImage: "bolt.badge.clock")
                    Button("Open Local Connection") {
                        model.settingsTab = "lokal"
                        openSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            localPowerContent
        }
    }

    private var localPowerContent: some View {
        let buckets = localPower.buckets
        let totals = localPower.totals
        let perDay = localPower.startsUnit == .day
        return VStack(alignment: .leading, spacing: Theme.Space.xl) {
            KPIRow(minimum: 125) {
                KPITile(
                    label: "Average power", value: Format.watts(totals?.averageW), detail: "measured locally", systemImage: "bolt.fill",
                    tint: .yellow)
                KPITile(label: "Highest power", value: Format.watts(totals?.maxW), systemImage: "arrow.up.to.line", tint: .yellow)
                KPITile(
                    label: "Starts last 24 h", value: "\(localPower.startsLast24h)",
                    detail: "times the compressor started", systemImage: "arrow.clockwise", tint: Theme.Data.orange)
                KPITile(
                    label: "Runtime", value: durationText(totals?.runningSeconds ?? 0),
                    detail: (totals?.observedSeconds ?? 0) > 0
                        ? "\(Format.percentShare((totals?.runningSeconds ?? 0) / (totals?.observedSeconds ?? 1))) of the time" : nil,
                    systemImage: "timer", tint: Theme.Data.orange)
            }
            TrendCard(title: "Power", value: model.liveSample?.powerW.map { String(localized: "Now \(Format.watts(Double($0)))") }) {
                FlowLayout {
                    LegendDot(label: "Average incl. stops (W)", color: .yellow)
                    if let totals, totals.phaseCount > 0 {
                        LegendDot(label: "Defrosting (\(totals.defrosts) in the period)", color: LocalPhaseSpan.Kind.defrost.color)
                    }
                }
            } chart: {
                if buckets.count < 2 {
                    EmptyChart(
                        title: "No local readings yet",
                        message: "The app reads the Wi-Fi adapter every minute while it is open. The chart fills in over time.",
                        systemImage: "bolt.badge.clock")
                } else {
                    powerChart(buckets).frame(height: 220)
                }
            }
            TrendCard(title: "Compressor", value: model.liveSample.map { $0.isRunning ? String(localized: "Now \($0.compressorHz ?? 0) Hz") : String(localized: "Stopped now") }) {
                LegendDot(label: "Frequency when running (Hz)", color: Theme.Data.orange)
            } chart: {
                if buckets.count < 2 {
                    EmptyChart(title: "No compressor data yet", message: "Shown once the app has read the adapter for a while.")
                } else {
                    hzChart(buckets).frame(height: 140)
                }
            }
            TrendCard(title: perDay ? "Starts per day" : "Starts per hour") {
                LegendDot(label: perDay ? "Starts per day" : "Four or more in the hour", color: perDay ? Theme.Data.purple : Theme.Status.caution)
            } chart: {
                if localPower.starts.isEmpty {
                    EmptyChart(title: "No starts recorded yet", message: "Starts are counted when the readings are close together.")
                } else {
                    startsChart(localPower.starts, perDay: perDay).frame(height: 110)
                }
            }
            Text(
                "Measured directly from the Wi-Fi adapter on the home network. Starts are only counted when the readings are close together (at least every 5 minutes), that is, while the app is open. One to three starts an hour is normal; four or more over several hours is called short cycling."
            )
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var powerAxis: Date.FormatStyle { range == .day ? Date.FormatStyle().hour(.twoDigits(amPM: .abbreviated)) : range.axisFormat }

    private func powerChart(_ buckets: [LocalPowerBucket]) -> some View {
        Chart {
            ForEach(Array(defrostSpans.enumerated()), id: \.offset) { _, span in
                RectangleMark(xStart: .value("From", span.start), xEnd: .value("To", max(span.end, span.start.addingTimeInterval(range == .day ? 120 : 600))))
                    .foregroundStyle(LocalPhaseSpan.Kind.defrost.color.opacity(0.25))
            }
            ForEach(buckets, id: \.start) { b in
                AreaMark(x: .value("Time", b.start), y: .value("W", b.averageW ?? 0))
                    .foregroundStyle(ChartKit.areaGradient(.yellow))
                    .interpolationMethod(.stepEnd)
                LineMark(x: .value("Time", b.start), y: .value("W", b.averageW ?? 0))
                    .foregroundStyle(.yellow)
                    .interpolationMethod(.stepEnd)
            }
            if let b = nearest(buckets, to: selected, by: \.start) {
                RuleMark(x: .value("Selected", b.start))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ChartTooltip(
                            title: Display.dateTime(b.start),
                            rows: [
                                ("Average", Format.watts(b.averageW), .yellow), ("Max", Format.watts(b.maxW), .yellow),
                                ("Compressor on", Format.percentShare(b.runningShare), Theme.Data.orange),
                            ])
                    }
            }
        }
        .chartXScale(domain: periodStart...Date())
        .calmYAxis { Display.format("%.0f W", $0) }
        .calmXAxis(powerAxis)
        .chartXSelection(value: $selected)
    }

    private func hzChart(_ buckets: [LocalPowerBucket]) -> some View {
        Chart {
            ForEach(buckets.filter { $0.averageRunningHz != nil }, id: \.start) { b in
                LineMark(x: .value("Time", b.start), y: .value("Hz", b.averageRunningHz ?? 0))
                    .foregroundStyle(Theme.Data.orange)
                    .interpolationMethod(.stepEnd)
            }
            if let b = nearest(buckets, to: selected, by: \.start) {
                RuleMark(x: .value("Selected", b.start))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ChartTooltip(
                            title: Display.dateTime(b.start),
                            rows: [
                                ("Average when running", b.averageRunningHz.map { Display.format("%.0f Hz", $0) } ?? String(localized: "stopped"), Theme.Data.orange),
                                ("Max", Display.format("%.0f Hz", b.maxHz ?? 0), Theme.Data.orange),
                                ("Running", Format.percentShare(b.runningShare), Theme.Data.orange),
                            ])
                    }
            }
        }
        .chartXScale(domain: periodStart...Date())
        .chartYScale(domain: 0...max(60, (buckets.compactMap(\.maxHz).max() ?? 60) + 5))
        .calmYAxis { Display.format("%.0f Hz", $0) }
        .calmXAxis(powerAxis)
        .chartXSelection(value: $selected)
    }

    private func startsChart(_ starts: [LocalPowerBucket], perDay: Bool) -> some View {
        Chart {
            ForEach(starts, id: \.start) { h in
                BarMark(x: .value("Time", h.start, unit: perDay ? .day : .hour), y: .value("Starts", h.starts))
                    .foregroundStyle(!perDay && h.starts >= 4 ? Theme.Status.caution : Theme.Data.purple.opacity(0.75))
                    .cornerRadius(1.5)
            }
            if let h = nearest(starts, to: selected, by: \.start) {
                RuleMark(x: .value("Selected", h.start))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        Text("\(h.starts) starts · \(perDay ? Format.dayMonth(h.start) : Format.hour(h.start))")
                            .font(.caption2).monospacedDigit()
                            .padding(4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
            }
        }
        .chartXScale(domain: periodStart...Date())
        .calmYAxis { Display.format("%.0f", $0) }
        .calmXAxis(powerAxis)
        .chartXSelection(value: $selected)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return String(localized: "\(minutes) min") }
        return String(localized: "\(minutes / 60) h \(minutes % 60) min")
    }
}

// MARK: Helpers

extension HistoryRange {
    var axisFormat: Date.FormatStyle {
        switch self {
        case .day: Date.FormatStyle().hour(.twoDigits(amPM: .abbreviated))
        case .week: Date.FormatStyle().weekday(.abbreviated).day()
        case .month: Date.FormatStyle().day().month(.abbreviated)
        case .year: Date.FormatStyle().month(.abbreviated)
        }
    }
}

extension EnergyData {
    var totalCost: Double? {
        let costs = buckets.compactMap(\.costNok)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    var previousTotalCost: Double? {
        let costs = previous.compactMap(\.costNok)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    var isEstimate: Bool { buckets.contains { $0.isEstimate } }
}

extension Array where Element == Double {
    var average: Double? { isEmpty ? nil : reduce(0, +) / Double(count) }
}

enum Downsample {
    /// Averages points into at most `maxCount` time buckets.
    static func temperatures(_ points: [TemperaturePoint], maxCount: Int) -> [TemperaturePoint] {
        guard points.count > maxCount, let first = points.first?.timestamp, let last = points.last?.timestamp else { return points }
        let width = last.timeIntervalSince(first) / Double(maxCount)
        guard width > 0 else { return points }
        let groups = Dictionary(grouping: points) { Int($0.timestamp.timeIntervalSince(first) / width) }
        return groups.keys.sorted().compactMap { key in
            guard let group = groups[key], let ts = group.first?.timestamp else { return nil }
            return TemperaturePoint(
                timestamp: ts, room: group.compactMap(\.room).average, set: group.compactMap(\.set).last,
                outdoor: group.compactMap(\.outdoor).average)
        }
    }
}

struct OperationBand: Identifiable {
    /// Chart row. Logic keys on this, never on the displayed text.
    enum Row {
        case power, mode, local

        var title: String {
            switch self {
            case .power: String(localized: "On/off")
            case .mode: String(localized: "Mode")
            case .local: String(localized: "Local")
            }
        }
    }

    let id = UUID()
    let row: Row
    let label: String
    /// Power row: the unit was on.
    var isOn = false
    let start: Date
    let end: Date
    let color: Color
}

/// Stacked cost bar parts. Series values and the colour scale both use `title`.
enum CostPart {
    case electricity, grid, support

    var title: String {
        switch self {
        case .electricity: String(localized: "Electricity after subsidy")
        case .grid: String(localized: "Grid tariff")
        case .support: String(localized: "Subsidy (deducted)")
        }
    }
}

enum OperationBands {
    /// Third row from local readings: running, rest, defrost, start-up and off.
    static func local(_ spans: [LocalPhaseSpan]) -> [OperationBand] {
        spans.filter { $0.kind != .unknown && $0.end > $0.start }.map {
            OperationBand(row: .local, label: $0.kind.displayName, start: $0.start, end: $0.end, color: $0.kind.color)
        }
    }

    /// Bands between consecutive readings; a gap over 2 h ends a band.
    static func make(power: [HistoryPoint], modes: [HistoryPoint], end: Date) -> [OperationBand] {
        func bands(_ points: [HistoryPoint], row: OperationBand.Row, label: (HistoryPoint) -> (String, Color)) -> [OperationBand] {
            let sorted = points.sorted { $0.timestamp < $1.timestamp }
            var result: [OperationBand] = []
            for (index, point) in sorted.enumerated() {
                let next = index + 1 < sorted.count ? sorted[index + 1].timestamp : min(end, point.timestamp.addingTimeInterval(600))
                let stop = min(next, point.timestamp.addingTimeInterval(2 * 3600))
                guard stop > point.timestamp else { continue }
                let (text, color) = label(point)
                if let last = result.last, last.label == text, last.end == point.timestamp {
                    result[result.count - 1] = OperationBand(row: row, label: text, isOn: last.isOn, start: last.start, end: stop, color: color)
                } else {
                    result.append(OperationBand(row: row, label: text, isOn: row == .power && point.value == 1, start: point.timestamp, end: stop, color: color))
                }
            }
            return result
        }
        let powerBands = bands(power, row: .power) { p in
            (p.value == 1 ? String(localized: "On") : String(localized: "Off"), p.value == 1 ? Theme.Status.good.opacity(0.75) : Color.gray.opacity(0.35))
        }
        let modeBands = bands(modes, row: .mode) { p in
            let mode = p.text.flatMap(OperationMode.init(key:))
            return (mode?.displayName ?? String(localized: "Unknown"), mode?.tint.opacity(0.8) ?? Color.gray.opacity(0.35))
        }
        return powerBands + modeBands
    }
}
