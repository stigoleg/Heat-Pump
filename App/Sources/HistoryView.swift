import Charts
import HeatPumpKit
import SwiftUI

enum HistoryTab: String, CaseIterable, Identifiable {
    case temperature, energy, operation, power
    var id: String { rawValue }
    var title: String {
        switch self {
        case .temperature: "Temperatur"
        case .energy: "Energi og kostnad"
        case .operation: "Drift"
        case .power: "Effekt"
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
    @State private var showCost = false
    @State private var selected: Date?
    @State private var selectedPrice: Date?

    var body: some View {
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
        .task(id: "\(range.rawValue)-\(model.revision)") {
            let now = Date()
            let start = range.start(now: now)
            data = await model.history(from: start, to: now)
            previous = await model.history(from: range.shifted(start, by: -1), to: start)
            energy = await model.energy(range: range)
        }
        // Effekt data only while that tab is shown (aggregated in SQL off the main thread).
        .task(id: "\(range.rawValue)-\(model.revision)-\(tab == .power)") {
            guard tab == .power else { return }
            localPower = await model.localPower(range: range)
        }
        .onChange(of: tab) { selected = nil }
        .onAppear {
            if model.initialHistoryTab == "energy-kr" {
                tab = .energy
                showCost = true
            } else if let initial = model.initialHistoryTab.flatMap(HistoryTab.init(rawValue:)) {
                tab = initial
            }
        }
    }

    private var periodStart: Date { range.start(now: Date()) }

    private var tabPicker: some View {
        Picker("Visning", selection: $tab) {
            ForEach(HistoryTab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var rangePicker: some View {
        Picker("Periode", selection: $range) {
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
                    label: "Snitt inne", value: Format.temperature(inside.average),
                    delta: Delta.between(inside.average, prevInside.average, higherIsGood: true), systemImage: "house.fill",
                    tint: Theme.Data.inside)
                KPITile(
                    label: "Lavest / høyest inne",
                    value: inside.isEmpty ? "–" : Norwegian.format("%.1f / %.1f°", inside.min() ?? 0, inside.max() ?? 0),
                    detail: "i perioden", systemImage: "arrow.up.arrow.down", tint: Theme.Data.inside)
                KPITile(
                    label: "Snitt ute", value: Format.temperature(outside.average),
                    detail: prevOutside.average.map { "Forrige periode: \(Format.temperature($0))" }, systemImage: "cloud.sun.fill",
                    tint: Theme.Data.outside)
                KPITile(
                    label: "Kostnad i perioden", value: Format.kroner(energy.totalCost),
                    detail: energy.isEstimate ? "Delvis anslag" : nil, systemImage: "creditcard.fill", tint: Theme.Data.purple)
            }
            TrendCard(title: "Temperatur", value: inside.last.map { "Inne nå " + Format.degrees($0) }) {
                HStack(spacing: Theme.Space.m) {
                    LegendDot(label: "Inne", color: Theme.Data.inside)
                    LegendDot(label: "Ute", color: Theme.Data.outside)
                    LegendDot(label: "Ønsket", color: Theme.Data.setpoint, dashed: true)
                }
            } chart: {
                if points.isEmpty {
                    EmptyChart(
                        title: "Ingen temperaturdata ennå",
                        message: "Historikken bygges opp mens appen er åpen, og eldre data hentes fra MELCloud (høyst én gang i timen).")
                } else {
                    temperatureChart(points).frame(height: 300)
                }
            }
            if !data.fromMELCloud && !points.isEmpty {
                Label(
                    "Temperaturloggen fra MELCloud er ikke tilgjengelig. Grafen viser målingene appen selv har hentet, og bygges opp mens appen er åpen.",
                    systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func temperatureChart(_ points: [TemperaturePoint]) -> some View {
        let values = points.flatMap { [$0.room, $0.outdoor, $0.set].compactMap { $0 } }
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
                        .interpolationMethod(.monotone)
                }
                if let set = p.set {
                    LineMark(x: .value("Tid", p.timestamp), y: .value("°C", set), series: .value("S", "ønsket"))
                        .foregroundStyle(Theme.Data.setpoint)
                        .lineStyle(ChartKit.setpointStroke)
                        .interpolationMethod(.stepEnd)
                }
            }
            if let p = nearest(points, to: selected, by: \.timestamp) {
                RuleMark(x: .value("Valgt", p.timestamp))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ChartTooltip(
                            title: Norwegian.dateTime(p.timestamp),
                            rows: [
                                ("Inne", Format.temperature(p.room), Theme.Data.inside),
                                ("Ute", Format.temperature(p.outdoor), Theme.Data.outside),
                                ("Ønsket", Format.temperature(p.set), Theme.Data.setpoint),
                            ])
                    }
            }
        }
        .chartXScale(domain: periodStart...Date())
        .chartYScale(domain: low...high)
        .calmYAxis { Norwegian.format("%.0f°", $0) }
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
                    label: "Strømforbruk", value: Format.kWh(totalKWh),
                    delta: Delta.between(totalKWh, previousKWh, higherIsGood: false), systemImage: "bolt.fill", tint: Theme.Data.energy)
                KPITile(
                    label: "Kostnad", value: Format.kroner(energy.totalCost),
                    delta: Delta.between(energy.totalCost, energy.previousTotalCost, higherIsGood: false),
                    systemImage: "creditcard.fill", tint: Theme.Data.purple)
                KPITile(
                    label: "Snitt per døgn", value: Format.kWh(totalKWh / days),
                    detail: energy.totalCost.map { Format.kroner($0 / days) + " per døgn" }, systemImage: "calendar",
                    tint: Theme.Data.energy)
                KPITile(
                    label: "Strømstøtte", value: Format.kroner(abs(support)),
                    detail: model.priceSettings.agreement == .norgespris ? "Ikke med Norgespris" : "trukket fra",
                    systemImage: "gift.fill", tint: Theme.Data.support)
            }
            TrendCard(
                title: showCost ? "Kostnad" : "Strømforbruk",
                value: showCost ? Format.kroner(energy.totalCost) : Format.kWh(totalKWh),
                delta: showCost
                    ? Delta.between(energy.totalCost, energy.previousTotalCost, higherIsGood: false)
                    : Delta.between(totalKWh, previousKWh, higherIsGood: false)
            ) {
                HStack(spacing: Theme.Space.m) {
                    if showCost {
                        LegendDot(label: "Strøm etter støtte", color: Theme.Data.electricity)
                        LegendDot(label: "Nettleie", color: Theme.Data.gridTariff)
                        LegendDot(label: "Støtte (trukket fra)", color: Theme.Data.support.opacity(0.35))
                    } else {
                        LegendDot(label: "kWh", color: Theme.Data.energy)
                    }
                    LegendDot(label: "Forrige periode", color: Theme.Data.previous, dashed: true)
                    Picker("Enhet", selection: $showCost) {
                        Text("kWh").tag(false)
                        Text("kr").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            } chart: {
                if bars.isEmpty {
                    EmptyChart(
                        title: "Ingen energidata ennå",
                        message: range == .day
                            ? "Forbruk per time beregnes fra strømmåleren i pumpen mens appen er åpen."
                            : "MELCloud oppdaterer energitall med noen timers forsinkelse.")
                } else {
                    energyChart(bars, previous: previousBars).frame(height: 260)
                }
            }
            if energy.isEstimate {
                Label(
                    "Kostnad merket som anslag: for timer uten målt forbruk er døgnets kWh priset med døgnets snittpris. Kapasitetsleddet i nettleien er ikke med, fordi det avhenger av hele husets høyeste forbruk.",
                    systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
            }
            priceSection
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
                        x: .value("Tid", bar.date, unit: unit), yStart: .value("kr", 0), yEnd: .value("kr", electricity))
                        .foregroundStyle(by: .value("Del", "Strøm etter støtte"))
                    BarMark(
                        x: .value("Tid", bar.date, unit: unit), yStart: .value("kr", electricity), yEnd: .value("kr", net))
                        .foregroundStyle(by: .value("Del", "Nettleie"))
                    if cost.supportNok < 0 {
                        BarMark(
                            x: .value("Tid", bar.date, unit: unit), yStart: .value("kr", net),
                            yEnd: .value("kr", net - cost.supportNok))
                            .foregroundStyle(by: .value("Del", "Støtte (trukket fra)"))
                    }
                } else if !showCost {
                    BarMark(x: .value("Tid", bar.date, unit: unit), y: .value("kWh", bar.kWh))
                        .foregroundStyle(Theme.Data.energy.opacity(bar.isEstimate && showCost ? 0.5 : 0.85))
                        .cornerRadius(3)
                }
            }
            ForEach(shifted) { bar in
                if let value = showCost ? bar.cost?.totalNok : bar.kWh {
                    LineMark(x: .value("Tid", bar.date, unit: unit), y: .value("Forrige", value), series: .value("S", "forrige"))
                        .foregroundStyle(Theme.Data.previous)
                        .lineStyle(ChartKit.previousStroke)
                        .interpolationMethod(.monotone)
                }
            }
            if let bar = nearest(bars, to: selected, by: \.date) {
                RuleMark(x: .value("Valgt", bar.date, unit: unit))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ChartTooltip(title: title(for: bar), rows: tooltipRows(bar))
                    }
            }
        }
        .chartForegroundStyleScale([
            "Strøm etter støtte": Theme.Data.electricity, "Nettleie": Theme.Data.gridTariff,
            "Støtte (trukket fra)": Theme.Data.support.opacity(0.3),
        ])
        .chartLegend(.hidden)
        .calmYAxis { Norwegian.format(showCost ? "%.0f kr" : "%.0f", $0) }
        .calmXAxis(range.axisFormat)
        .chartXSelection(value: $selected)
    }

    private func title(for bar: EnergyBar) -> String {
        switch bar.unit {
        case .hour: Norwegian.dateTime(bar.date)
        case .month: bar.date.formatted(Date.FormatStyle().month(.wide).year().locale(Norwegian.locale))
        default: Norwegian.date(bar.date)
        }
    }

    private func tooltipRows(_ bar: EnergyBar) -> [(label: String, value: String, color: Color)] {
        var rows: [(label: String, value: String, color: Color)] = [("Forbruk", Format.kWh(bar.kWh), Theme.Data.energy)]
        if let cost = bar.cost {
            rows.append(("Strøm", Format.kroner(cost.energyNok), Theme.Data.electricity))
            rows.append(("Nettleie", Format.kroner(cost.gridNok), Theme.Data.gridTariff))
            if cost.supportNok < 0 { rows.append(("Støtte", Format.kroner(cost.supportNok), Theme.Data.support)) }
            rows.append(("Å betale" + (bar.isEstimate ? " (anslag)" : ""), Format.kroner(cost.totalNok), .primary))
        }
        return rows
    }

    private var priceSection: some View {
        let today = model.todayPrices
        let tomorrow = model.tomorrowPrices
        let all = today + tomorrow
        let now = Date()
        return TrendCard(
            title: "Strømpris per time",
            value: all.first { $0.hour <= now && now < $0.hour.addingTimeInterval(3600) }.map {
                Norwegian.format("Nå %.2f kr/kWh", $0.totalOre / 100)
            }
        ) {
            HStack(spacing: Theme.Space.m) {
                LegendDot(label: "I dag", color: Theme.Data.purple)
                LegendDot(label: tomorrow.isEmpty ? "I morgen (fra ca. kl. 13)" : "I morgen", color: Theme.Data.purple.opacity(0.4))
            }
        } chart: {
            if all.isEmpty {
                EmptyChart(
                    title: "Ingen priser ennå", message: model.priceMessage ?? "Velg strømavtale under Innstillinger → Strømpris.",
                    systemImage: "bolt.horizontal")
            } else {
                Chart {
                    ForEach(all, id: \.hour) { p in
                        BarMark(x: .value("Time", p.hour, unit: .hour), y: .value("kr/kWh", p.totalOre / 100))
                            .foregroundStyle(Theme.Data.purple.opacity(Calendar.current.isDateInToday(p.hour) ? 0.8 : 0.4))
                            .cornerRadius(2)
                    }
                    RuleMark(x: .value("Nå", now))
                        .foregroundStyle(Theme.Status.caution)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            Text("nå").font(.caption2.weight(.semibold)).foregroundStyle(Theme.Status.caution)
                        }
                    if let p = nearest(all, to: selectedPrice, by: \.hour) {
                        RuleMark(x: .value("Valgt", p.hour, unit: .hour))
                            .foregroundStyle(Color.secondary.opacity(0.25))
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                ChartTooltip(
                                    title: Norwegian.dateTime(p.hour),
                                    rows: [
                                        ("Strøm", Norwegian.format("%.0f øre", p.energyOre), Theme.Data.electricity),
                                        ("Nettleie", Norwegian.format("%.0f øre", p.gridOre), Theme.Data.gridTariff),
                                        ("Støtte", Norwegian.format("%.0f øre", p.supportOre), Theme.Data.support),
                                        ("Totalt", Norwegian.format("%.2f kr", p.totalOre / 100), .primary),
                                    ])
                            }
                    }
                }
                .calmYAxis { Norwegian.format("%.1f", $0) }
                .calmXAxis(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)), count: 8)
                .chartXSelection(value: $selectedPrice)
                .padding(.top, Theme.Space.l)
                .frame(height: 196)
            }
        }
    }

    // MARK: Operation

    private var operationTab: some View {
        let bands = OperationBands.make(power: data.power, modes: data.modes, end: Date())
        let onSeconds = bands.filter { $0.row == "Av/på" && $0.label == "På" }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let covered = bands.filter { $0.row == "Av/på" }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let modeSeconds = Dictionary(grouping: bands.filter { $0.row == "Modus" }, by: \.label)
            .mapValues { $0.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } }
        let mainMode = modeSeconds.max { $0.value < $1.value }?.key
        return VStack(alignment: .leading, spacing: Theme.Space.xl) {
            KPIRow {
                KPITile(
                    label: "Andel på", value: covered > 0 ? Norwegian.format("%.0f %%", onSeconds / covered * 100) : "–",
                    detail: "av tiden med data", systemImage: "power", tint: Theme.Status.good)
                KPITile(label: "Mest brukt modus", value: mainMode ?? "–", systemImage: "dial.medium", tint: Theme.Data.orange)
                KPITile(
                    label: "Endringer", value: "\(model.changes.filter { $0.timestamp >= periodStart && $0.result == .ok }.count)",
                    detail: "sendt fra appen og Claude", systemImage: "slider.horizontal.3", tint: Theme.Data.purple)
                KPITile(
                    label: "Kostnad i perioden", value: Format.kroner(energy.totalCost), detail: energy.isEstimate ? "Delvis anslag" : nil,
                    systemImage: "creditcard.fill", tint: Theme.Data.purple)
            }
            TrendCard(title: "Drift") {
                HStack(spacing: Theme.Space.m) {
                    ForEach([OperationMode.heat, .cool, .dry, .fan, .auto], id: \.self) {
                        LegendDot(label: $0.displayName, color: $0.tint)
                    }
                }
            } chart: {
                if bands.isEmpty {
                    EmptyChart(title: "Ingen driftsdata ennå", message: "Driften registreres hver gang appen eller Claude henter status.")
                } else {
                    Chart(bands) { band in
                        RectangleMark(
                            xStart: .value("Fra", band.start), xEnd: .value("Til", band.end), y: .value("Rad", band.row), height: 22)
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
                    .frame(height: 110)
                }
            }
            Text("Øverste rad viser om varmepumpen var på (grønn) eller av (grå). Nederste rad viser modus.")
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
                        title: "Effekt krever lokal tilkobling",
                        message: "Slå på lokal tilkobling, så leser appen effekt i watt og kompressorens aktivitet direkte fra Wi-Fi-modulen på hjemmenettet (bare lesing).",
                        systemImage: "bolt.badge.clock")
                    Button("Åpne Lokal tilkobling") {
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
                    label: "Snitteffekt", value: Format.watts(totals?.averageW), detail: "målt lokalt", systemImage: "bolt.fill",
                    tint: .yellow)
                KPITile(label: "Høyeste effekt", value: Format.watts(totals?.maxW), systemImage: "arrow.up.to.line", tint: .yellow)
                KPITile(
                    label: "Starter siste 24 t", value: "\(localPower.startsLast24h)",
                    detail: "kompressoren startet", systemImage: "arrow.clockwise", tint: Theme.Data.orange)
                KPITile(
                    label: "Driftstid", value: durationText(totals?.runningSeconds ?? 0),
                    detail: (totals?.observedSeconds ?? 0) > 0
                        ? Norwegian.format("%.0f %% av tiden", (totals?.runningSeconds ?? 0) / (totals?.observedSeconds ?? 1) * 100) : nil,
                    systemImage: "timer", tint: Theme.Data.orange)
            }
            TrendCard(title: "Effekt", value: model.liveSample?.powerW.map { "Nå " + Format.watts(Double($0)) }) {
                LegendDot(label: "Snitt inkl. stopp (W)", color: .yellow)
            } chart: {
                if buckets.count < 2 {
                    EmptyChart(
                        title: "Ingen lokale målinger ennå",
                        message: "Appen leser Wi-Fi-modulen hvert minutt mens den er åpen. Grafen fylles etter hvert.",
                        systemImage: "bolt.badge.clock")
                } else {
                    powerChart(buckets).frame(height: 220)
                }
            }
            TrendCard(title: "Kompressor", value: model.liveSample.map { $0.isRunning ? "Nå \($0.compressorHz ?? 0) Hz" : "Står nå" }) {
                LegendDot(label: "Frekvens når den går (Hz)", color: Theme.Data.orange)
            } chart: {
                if buckets.count < 2 {
                    EmptyChart(title: "Ingen kompressordata ennå", message: "Vises når appen har lest modulen en stund.")
                } else {
                    hzChart(buckets).frame(height: 140)
                }
            }
            TrendCard(title: perDay ? "Starter per døgn" : "Starter per time") {
                LegendDot(label: perDay ? "Starter per døgn" : "Fire eller flere i timen", color: perDay ? Theme.Data.purple : Theme.Status.caution)
            } chart: {
                if localPower.starts.isEmpty {
                    EmptyChart(title: "Ingen starter registrert ennå", message: "Starter telles når målingene ligger tett.")
                } else {
                    startsChart(localPower.starts, perDay: perDay).frame(height: 110)
                }
            }
            Text(
                "Målt direkte fra Wi-Fi-modulen på hjemmenettet. Starter telles bare når målingene ligger tett (minst hvert 5. minutt), altså mens appen er åpen. Én til tre starter i timen er vanlig; fire eller flere over flere timer kalles korte sykluser."
            )
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var powerAxis: Date.FormatStyle { range == .day ? Date.FormatStyle().hour(.twoDigits(amPM: .omitted)) : range.axisFormat }

    private func powerChart(_ buckets: [LocalPowerBucket]) -> some View {
        Chart {
            ForEach(buckets, id: \.start) { b in
                AreaMark(x: .value("Tid", b.start), y: .value("W", b.averageW ?? 0))
                    .foregroundStyle(ChartKit.areaGradient(.yellow))
                    .interpolationMethod(.stepEnd)
                LineMark(x: .value("Tid", b.start), y: .value("W", b.averageW ?? 0))
                    .foregroundStyle(.yellow)
                    .interpolationMethod(.stepEnd)
            }
            if let b = nearest(buckets, to: selected, by: \.start) {
                RuleMark(x: .value("Valgt", b.start))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ChartTooltip(
                            title: Norwegian.dateTime(b.start),
                            rows: [
                                ("Snitt", Format.watts(b.averageW), .yellow), ("Maks", Format.watts(b.maxW), .yellow),
                                ("Kompressor på", Format.percentShare(b.runningShare), Theme.Data.orange),
                            ])
                    }
            }
        }
        .chartXScale(domain: periodStart...Date())
        .calmYAxis { Norwegian.format("%.0f W", $0) }
        .calmXAxis(powerAxis)
        .chartXSelection(value: $selected)
    }

    private func hzChart(_ buckets: [LocalPowerBucket]) -> some View {
        Chart {
            ForEach(buckets.filter { $0.averageRunningHz != nil }, id: \.start) { b in
                LineMark(x: .value("Tid", b.start), y: .value("Hz", b.averageRunningHz ?? 0))
                    .foregroundStyle(Theme.Data.orange)
                    .interpolationMethod(.stepEnd)
            }
            if let b = nearest(buckets, to: selected, by: \.start) {
                RuleMark(x: .value("Valgt", b.start))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ChartTooltip(
                            title: Norwegian.dateTime(b.start),
                            rows: [
                                ("Snitt når den går", b.averageRunningHz.map { Norwegian.format("%.0f Hz", $0) } ?? "står", Theme.Data.orange),
                                ("Maks", Norwegian.format("%.0f Hz", b.maxHz ?? 0), Theme.Data.orange),
                                ("Går", Format.percentShare(b.runningShare), Theme.Data.orange),
                            ])
                    }
            }
        }
        .chartXScale(domain: periodStart...Date())
        .chartYScale(domain: 0...max(60, (buckets.compactMap(\.maxHz).max() ?? 60) + 5))
        .calmYAxis { Norwegian.format("%.0f Hz", $0) }
        .calmXAxis(powerAxis)
        .chartXSelection(value: $selected)
    }

    private func startsChart(_ starts: [LocalPowerBucket], perDay: Bool) -> some View {
        Chart {
            ForEach(starts, id: \.start) { h in
                BarMark(x: .value("Tid", h.start, unit: perDay ? .day : .hour), y: .value("Starter", h.starts))
                    .foregroundStyle(!perDay && h.starts >= 4 ? Theme.Status.caution : Theme.Data.purple.opacity(0.75))
                    .cornerRadius(1.5)
            }
            if let h = nearest(starts, to: selected, by: \.start) {
                RuleMark(x: .value("Valgt", h.start))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        Text("\(h.starts) starter · \(perDay ? Format.dayMonth(h.start) : Format.hour(h.start))")
                            .font(.caption2).monospacedDigit()
                            .padding(4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
            }
        }
        .chartXScale(domain: periodStart...Date())
        .calmYAxis { Norwegian.format("%.0f", $0) }
        .calmXAxis(powerAxis)
        .chartXSelection(value: $selected)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) t \(minutes % 60) min"
    }
}

// MARK: Helpers

extension HistoryRange {
    var axisFormat: Date.FormatStyle {
        switch self {
        case .day: Date.FormatStyle().hour(.twoDigits(amPM: .omitted))
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
    let id = UUID()
    let row: String
    let label: String
    let start: Date
    let end: Date
    let color: Color
}

enum OperationBands {
    /// Bands between consecutive readings; a gap over 2 h ends a band.
    static func make(power: [HistoryPoint], modes: [HistoryPoint], end: Date) -> [OperationBand] {
        func bands(_ points: [HistoryPoint], row: String, label: (HistoryPoint) -> (String, Color)) -> [OperationBand] {
            let sorted = points.sorted { $0.timestamp < $1.timestamp }
            var result: [OperationBand] = []
            for (index, point) in sorted.enumerated() {
                let next = index + 1 < sorted.count ? sorted[index + 1].timestamp : min(end, point.timestamp.addingTimeInterval(600))
                let stop = min(next, point.timestamp.addingTimeInterval(2 * 3600))
                guard stop > point.timestamp else { continue }
                let (text, color) = label(point)
                if let last = result.last, last.label == text, last.end == point.timestamp {
                    result[result.count - 1] = OperationBand(row: row, label: text, start: last.start, end: stop, color: color)
                } else {
                    result.append(OperationBand(row: row, label: text, start: point.timestamp, end: stop, color: color))
                }
            }
            return result
        }
        let powerBands = bands(power, row: "Av/på") { p in
            (p.value == 1 ? "På" : "Av", p.value == 1 ? Theme.Status.good.opacity(0.75) : Color.gray.opacity(0.35))
        }
        let modeBands = bands(modes, row: "Modus") { p in
            let mode = p.text.flatMap(OperationMode.init(key:))
            return (mode?.displayName ?? "Ukjent", mode?.tint.opacity(0.8) ?? Color.gray.opacity(0.35))
        }
        return powerBands + modeBands
    }
}
