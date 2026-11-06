import Charts
import HeatPumpKit
import SwiftUI

/// Forecast: the weather ahead, published and estimated electricity prices, expected use and
/// cost per day, and price control.
struct OutlookView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedWeather: Date?
    @State private var selectedPrice: Date?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    StatusBanner()
                    weatherSection
                    priceSection.id("prices")
                    useSection.id("use")
                    PriceControlSection().id("pricecontrol")
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .devScrollTarget(proxy)
        }
    }

    // MARK: Weather

    private var weatherSection: some View {
        let hours = Array(model.longForecast.prefix { $0.time < Date().addingTimeInterval(48 * 3600) })
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Weather", hint: (model.weatherLocation?.displayName).map(LocalizedStringKey.verbatim))
            TrendCard(title: "Next 48 hours") {
                FlowLayout {
                    LegendDot(label: "Temperature", color: Theme.Data.outside)
                    LegendDot(label: "Precipitation (mm)", color: Theme.Data.blue.opacity(0.35))
                }
            } chart: {
                if hours.isEmpty {
                    EmptyChart(
                        title: "No weather forecast yet", message: model.weatherMessage.map { .verbatim($0) } ?? "The forecast is fetched from MET Norway.",
                        systemImage: "cloud.sun")
                } else {
                    weatherChart(hours).frame(height: 200)
                }
            }
            let days = WeatherDay.days(from: model.longForecast)
            if !days.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 104), spacing: Theme.Space.m, alignment: .top)], alignment: .leading,
                    spacing: Theme.Space.m
                ) {
                    ForEach(days, id: \.date) { WeatherDayCard(day: $0) }
                }
            }
            Text(WeatherForecast.attribution).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func weatherChart(_ hours: [ForecastHour]) -> some View {
        let temps = hours.map(\.temperature)
        let low = (temps.min() ?? 0).rounded(.down) - 1
        let high = (temps.max() ?? 10).rounded(.up) + 1
        // Precipitation drawn from the bottom on the temperature scale: 1 mm = a sixth of the range.
        let mmScale = (high - low) / 6
        return Chart {
            ForEach(hours, id: \.time) { h in
                if let mm = h.precipitation, mm > 0 {
                    BarMark(
                        x: .value("Time", h.time, unit: .hour), yStart: .value("mm", low), yEnd: .value("mm", low + min(mm, 6) * mmScale)
                    )
                    .foregroundStyle(Theme.Data.blue.opacity(0.35))
                }
                LineMark(x: .value("Time", h.time), y: .value("°C", h.temperature))
                    .foregroundStyle(Theme.Data.outside)
                    .interpolationMethod(.monotone)
            }
            if low < 0, high > 0 { RuleMark(y: .value("Freezing point", 0)).foregroundStyle(Color.secondary.opacity(0.25)) }
            if let h = nearest(hours, to: selectedWeather, by: \.time) {
                RuleMark(x: .value("Selected", h.time))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ChartTooltip(
                            title: Format.weekdayHour(h.time),
                            rows: [
                                ("Outdoor", Format.temperature(h.temperature), Theme.Data.outside),
                                ("Precipitation", h.precipitation.map { Display.format("%.1f mm", $0) } ?? "–", Theme.Data.blue),
                                ("Wind", h.windSpeed.map { Display.format("%.0f m/s", $0) } ?? "–", .secondary),
                            ])
                    }
            }
        }
        .chartYScale(domain: low...high)
        .calmYAxis { Display.format("%.0f°", $0) }
        .calmXAxis(Date.FormatStyle().weekday(.abbreviated).hour(.twoDigits(amPM: .abbreviated)), count: 6)
        .chartXSelection(value: $selectedWeather)
        .accessibilityLabel("Temperature and precipitation, next 48 hours")
    }

    // MARK: Prices

    private var priceSection: some View {
        let outlook = model.priceOutlook
        let known = outlook?.known ?? []
        let estimate = outlook?.estimate ?? []
        let now = Date()
        let current = known.first { $0.hour <= now && now < $0.hour.addingTimeInterval(3600) }
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Electricity price", hint: outlook.map { .verbatim($0.agreement.displayName) })
            TrendCard(
                title: "Next 7 days",
                value: current.map { String(localized: "Now \(Display.format("%.2f", $0.totalOre / 100)) NOK/kWh") }
            ) {
                FlowLayout {
                    if known.contains(where: { $0.level != nil }) {
                        ForEach([PriceLevel.veryCheap, .cheap, .normal, .expensive, .veryExpensive], id: \.self) {
                            LegendDot(label: .verbatim($0.displayName), color: $0.color)
                        }
                    } else {
                        LegendDot(label: "Known price", color: Theme.Data.purple)
                    }
                    if !estimate.isEmpty { LegendDot(label: "Estimate (uncertain)", color: .secondary, dashed: true) }
                }
            } chart: {
                if known.isEmpty && estimate.isEmpty {
                    EmptyChart(
                        title: "No prices yet", message: model.priceMessage.map { .verbatim($0) } ?? "Choose an electricity contract under Settings → Electricity price.",
                        systemImage: "bolt.horizontal")
                } else {
                    priceChart(known: known, estimate: estimate).frame(height: 220)
                }
            }
            Text(priceExplanation(outlook)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func priceExplanation(_ outlook: PriceOutlook?) -> String {
        guard let outlook else { return "" }
        if outlook.agreement == .norgespris {
            return String(
                localized: "Norgespris is \(Display.format("%.0f", model.priceSettings.norgesprisOre)) øre/kWh around the clock; the bars show it plus the grid tariff, which is lower at night and on weekends. No estimate is needed.")
        }
        if !outlook.estimate.isEmpty {
            let method = PriceOutlook.methodText.prefix(1).lowercased() + PriceOutlook.methodText.dropFirst()
            return String(
                localized: "The bars are published prices (electricity, grid tariff and electricity subsidy). The dashed line is an estimate with a range of uncertainty, not a price: \(method)")
        } else if let missing = outlook.estimateMissing {
            return String(
                localized: "The bars are published prices (electricity, grid tariff and electricity subsidy). \(missing) Real prices for tomorrow come around 13:00.")
        } else {
            return String(
                localized: "The bars are published prices (electricity, grid tariff and electricity subsidy). Real prices for tomorrow come around 13:00.")
        }
    }

    private func priceChart(known: [PriceBreakdown], estimate: [EstimatedPrice]) -> some View {
        let now = Date()
        return Chart {
            ForEach(known, id: \.hour) { p in
                BarMark(x: .value("Hour", p.hour, unit: .hour), y: .value("NOK/kWh", p.totalOre / 100))
                    .foregroundStyle((p.level?.color ?? Theme.Data.purple).opacity(0.85))
            }
            ForEach(estimate, id: \.hour) { e in
                AreaMark(
                    x: .value("Hour", e.hour), yStart: .value("Low", e.lowOre / 100), yEnd: .value("High", e.highOre / 100),
                    series: .value("Series", "band")
                )
                .foregroundStyle(Color.secondary.opacity(0.16))
                .interpolationMethod(.monotone)
                LineMark(x: .value("Hour", e.hour), y: .value("NOK/kWh", e.totalOre / 100), series: .value("Series", "estimate"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(ChartKit.previousStroke)
                    .interpolationMethod(.monotone)
            }
            RuleMark(x: .value("Now", now))
                .foregroundStyle(Theme.Status.caution)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    Text("now").font(.caption2.weight(.semibold)).foregroundStyle(Theme.Status.caution)
                }
            if let first = estimate.first {
                RuleMark(x: .value("Estimate", first.hour))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("estimate →").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let selectedPrice {
                if let p = known.first(where: { $0.hour <= selectedPrice && selectedPrice < $0.hour.addingTimeInterval(3600) }) {
                    RuleMark(x: .value("Selected", p.hour, unit: .hour))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            ChartTooltip(
                                title: Display.dateTime(p.hour),
                                rows: [
                                    ("Total", Format.kroner(p.totalOre / 100), .primary),
                                    ("Level", p.level?.displayName ?? "–", p.level?.color ?? .secondary),
                                ])
                        }
                } else if let e = nearest(estimate, to: selectedPrice, by: \.hour) {
                    RuleMark(x: .value("Selected", e.hour))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            ChartTooltip(
                                title: Display.dateTime(e.hour),
                                rows: [
                                    ("Estimate", Format.kroner(e.totalOre / 100), .secondary),
                                    ("Likely", String(localized: "\(Display.format("%.2f–%.2f", e.lowOre / 100, e.highOre / 100)) NOK"), .secondary),
                                ])
                        }
                }
            }
        }
        .calmYAxis { Display.format("%.1f", $0) }
        .calmXAxis(Date.FormatStyle().weekday(.abbreviated).day(), count: 8)
        .chartXSelection(value: $selectedPrice)
        .accessibilityLabel("Electricity price, next 7 days, known prices and estimate")
    }

    // MARK: Use and cost

    @ViewBuilder private var useSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Expected consumption and cost", hint: "Estimate per day")
            if model.dailyOutlook.isEmpty {
                InsightCard(
                    title: "Not enough data yet",
                    detail: "The estimate needs at least \(DegreeDayModel.minDays) days of consumption and outdoor temperature, and a weather forecast.",
                    systemImage: "chart.bar.doc.horizontal", tint: .secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.m, alignment: .top)], alignment: .leading,
                    spacing: Theme.Space.m
                ) {
                    ForEach(model.dailyOutlook, id: \.day) { DayOutlookCard(day: $0) }
                }
                Text(
                    "Rough estimate: consumption against how cold it has been over the last few weeks, the weather forecast and the prices. Days marked “price estimate” use estimated prices for the hours without a published price."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One forecast day for the weather cards.
struct WeatherDay {
    var date: Date
    var minTemperature: Double
    var maxTemperature: Double
    /// mm; nil when MET gave no amounts.
    var precipitation: Double?
    var maxWind: Double?
    var symbol: String?

    /// Days from the forecast (today first, at most nine).
    static func days(from hours: [ForecastHour], calendar: Calendar = .current) -> [WeatherDay] {
        Dictionary(grouping: hours) { calendar.startOfDay(for: $0.time) }
            .sorted { $0.key < $1.key }
            .prefix(9)
            .map { date, entries in
                let temps = entries.map(\.temperature)
                // Hourly amounts where MET has them, its 6-hour amounts beyond that.
                let amounts = entries.compactMap { $0.precipitation ?? $0.precipitation6h }
                let noon = entries.min { abs(calendar.component(.hour, from: $0.time) - 12) < abs(calendar.component(.hour, from: $1.time) - 12) }
                return WeatherDay(
                    date: date, minTemperature: temps.min() ?? 0, maxTemperature: temps.max() ?? 0,
                    precipitation: amounts.isEmpty ? nil : amounts.reduce(0, +), maxWind: entries.compactMap(\.windSpeed).max(),
                    symbol: noon?.symbol ?? entries.first?.symbol)
            }
    }
}

/// MET symbol codes (`partlycloudy_day`, `lightrainshowers_night` …) as SF Symbols.
enum WeatherSymbol {
    static func systemImage(_ code: String?) -> String {
        guard let code else { return "cloud" }
        let night = code.hasSuffix("_night") || code.hasSuffix("_polartwilight")
        if code.contains("thunder") { return "cloud.bolt.rain.fill" }
        if code.contains("sleet") { return "cloud.sleet.fill" }
        if code.contains("snow") { return "cloud.snow.fill" }
        if code.contains("heavyrain") { return "cloud.heavyrain.fill" }
        if code.contains("rainshowers") { return night ? "cloud.moon.rain.fill" : "cloud.sun.rain.fill" }
        if code.contains("rain") { return "cloud.rain.fill" }
        if code.hasPrefix("fog") { return "cloud.fog.fill" }
        if code.hasPrefix("cloudy") { return "cloud.fill" }
        if code.hasPrefix("partlycloudy") || code.hasPrefix("fair") { return night ? "cloud.moon.fill" : "cloud.sun.fill" }
        if code.hasPrefix("clearsky") { return night ? "moon.stars.fill" : "sun.max.fill" }
        return "cloud"
    }

    /// Readable on light and dark cards: sun yellow, night indigo, rain and snow blue, clouds grey.
    static func tint(_ code: String?) -> Color {
        let image = systemImage(code)
        if image.contains("rain") || image.contains("snow") || image.contains("sleet") || image.contains("bolt") { return .blue }
        if image.contains("moon") { return .indigo }
        if image.contains("sun") { return .orange }
        return .secondary
    }
}

struct WeatherDayCard: View {
    let day: WeatherDay

    var body: some View {
        CardSurface(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title).font(.callout.weight(.semibold))
                Image(systemName: WeatherSymbol.systemImage(day.symbol))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(WeatherSymbol.tint(day.symbol))
                    .font(.title2)
                    .frame(height: 30)
                    .help(day.symbol ?? "")
                // Rounded first so −0,3 shows as 0°, not −0°.
                Text(Display.format("%.0f° / %.0f°", day.maxTemperature.rounded() + 0, day.minTemperature.rounded() + 0))
                    .font(.body.weight(.medium)).monospacedDigit()
                Text(day.precipitation.map { Display.format("%.1f mm", $0) } ?? "– mm")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Text(day.maxWind.map { Display.format("%.0f m/s", $0) } ?? "– m/s")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if Calendar.current.isDateInToday(day.date) { return String(localized: "Today") }
        return day.date.formatted(Date.FormatStyle().weekday(.abbreviated).day().locale(Display.locale))
    }
}

struct DayOutlookCard: View {
    let day: DayOutlook

    var body: some View {
        CardSurface(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(day.date.formatted(Date.FormatStyle().weekday(.wide).day().month(.abbreviated).locale(Display.locale)))
                    .font(.callout.weight(.semibold))
                Text("~" + Display.format("%.0f kWh", day.kWh))
                    .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                if day.kWhLow.rounded() != day.kWhHigh.rounded() {
                    Text(String(localized: "about \(Display.format("%.0f–%.0f", day.kWhLow, day.kWhHigh)) kWh")).font(.caption).foregroundStyle(.secondary)
                }
                Text(day.costNok.map { String(localized: "~\(Display.format("%.0f", $0)) NOK") } ?? String(localized: "cost unknown"))
                    .font(.body.weight(.medium)).monospacedDigit()
                (day.usesEstimatedPrices
                    ? Text("\(Display.format("%.0f°", day.meanOutdoor)) average · price estimate")
                    : Text("\(Display.format("%.0f°", day.meanOutdoor)) average · known prices"))
                    .font(.caption).foregroundStyle(day.usesEstimatedPrices ? .secondary : .primary)
            }
        }
        .help("Estimate based on the weather forecast and own measurements. \(day.knownPriceHours) hours with a published price, \(day.estimatedPriceHours) with an estimated price.")
    }
}

// MARK: - Price control

/// Price control: switch with the warning, settings, status now and the plan.
struct PriceControlSection: View {
    @Environment(AppModel.self) private var model
    @State private var draft = PriceControlSettings.default
    @State private var saveError: String?

    private var runner: PriceControlRunner { model.priceControl }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Price control", hint: "Lowers the temperature when electricity is expensive")
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    toggleRow
                    warning
                    Divider()
                    settings
                    Divider()
                    statusAndPlan
                }
            }
        }
        .task(id: runner.settings) { draft = runner.settings }
    }

    private var toggleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Price control").font(.headline)
                Text(baseText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if runner.isBusy { ProgressView().controlSize(.small) }
            Toggle(
                "Price control",
                isOn: Binding(get: { runner.enabled }, set: { on in Task { await runner.setEnabled(on) } })
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(runner.isBusy || model.service == nil)
        }
    }

    private var baseText: String {
        switch runner.plan?.baseSource ?? .unknown {
        case .schedule: return String(localized: "Lowers from the temperature in the weekly schedule.")
        case .comfort:
            let comfort = runner.settings.comfortTemperature.map(TimerEventText.temperature) ?? "–"
            return String(localized: "Lowers from your usual temperature, \(comfort) (the one you last set yourself).")
        case .unknown: return String(localized: "Lowers from the temperature the heat pump is set to when you turn it on.")
        }
    }

    private var warning: some View {
        Label {
            Text(
                "Price control only works while the app is running and the Mac is on and awake. When you close the window, the app keeps running in the menu bar. When the Mac goes to sleep or the app quits, the temperature is restored first. If that does not happen (power cut, crash), the temperature stays where it is – but never lower than \(TimerEventText.temperature(draft.minimumTemperature))."
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.caution)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Stepper(value: binding(\.reduceExpensive), in: PriceControlSettings.reductionRange, step: 0.5) {
                Text("Lower in expensive hours: \(Text(Display.format("%.1f °C", draft.reduceExpensive)).monospacedDigit())")
            }
            Stepper(value: binding(\.reduceVeryExpensive), in: PriceControlSettings.reductionRange, step: 0.5) {
                Text("Lower in very expensive hours: \(Text(Display.format("%.1f °C", draft.reduceVeryExpensive)).monospacedDigit())")
            }
            Stepper(value: binding(\.minimumTemperature), in: PriceControlSettings.minimumRange, step: 0.5) {
                Text("Never lower than: \(Text(Display.format("%.1f °C", draft.minimumTemperature)).monospacedDigit())")
            }
            Stepper(value: binding(\.maxReducedHoursPerDay), in: PriceControlSettings.reducedHoursRange) {
                Text("Lower at most \(draft.maxReducedHoursPerDay) hours per day").monospacedDigit()
            }
            Toggle(isOn: binding(\.preheat)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preheat a little before expensive hours")
                    Text("+1 °C in up to two of the cheapest of the four hours before.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Heat mode only. On/off and mode are never changed. Price control overrides holiday mode and events in the weekly schedule, and pauses until the next change when you change the temperature yourself.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let saveError { Text(saveError).font(.caption).foregroundStyle(Theme.Status.bad) }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PriceControlSettings, Value>) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in
                draft[keyPath: keyPath] = value
                let new = draft
                Task { saveError = await runner.save(new) }
            })
    }

    @ViewBuilder private var statusAndPlan: some View {
        let plan = runner.plan
        let now = Date()
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if runner.enabled, let status = runner.status {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Now: \(status.text)").font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        if let problem = status.problem {
                            Text(problem).font(.caption).foregroundStyle(Theme.Status.caution).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } icon: {
                    Image(systemName: status.kind.systemImage).foregroundStyle(status.kind.tint)
                }
            }
            if let message = runner.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            (runner.enabled ? Text("Plan for the next 36 hours") : Text("What the plan would look like for the next 36 hours"))
                .font(.callout.weight(.semibold)).padding(.top, Theme.Space.xs)
            let changes = plan?.changes ?? []
            if let note = plan?.note {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if changes.isEmpty {
                Text("No expensive hours in the published prices, so the temperature stays as it is.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(changes, id: \.start) { step in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Image(systemName: step.kind == .reduce ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                            .foregroundStyle(step.level?.color ?? .secondary)
                        Text(step.summary(now: now, timeZone: .current)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
            if let over = plan?.overDailyLimit, over > 0 {
                Text("Expensive hours not lowered: \(over) (the limit is \(runner.settings.maxReducedHoursPerDay) per day).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("At most \(runner.settings.maxReducedHoursPerDay) hours are lowered per day, the most expensive first. The plan only uses published prices, not the estimate. The changes are shown under Claude activity with the source “Price control”.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Temperature text as in the weekly plan ("21 °C", "20,5 °C").
enum TimerEventText {
    static func temperature(_ value: Double) -> String {
        value == value.rounded() ? Display.format("%.0f °C", value) : Display.format("%.1f °C", value)
    }
}

extension PriceControlStatus.Kind {
    var systemImage: String {
        switch self {
        case .off: "power"
        case .normal: "checkmark.circle.fill"
        case .lowered: "arrow.down.circle.fill"
        case .raised: "arrow.up.circle.fill"
        case .paused: "pause.circle.fill"
        case .waiting: "hourglass"
        case .skipped: "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .off, .waiting: .secondary
        case .normal: Theme.Status.good
        case .lowered, .raised: Theme.Status.info
        case .paused, .skipped: Theme.Status.caution
        }
    }
}

// MARK: - Menu bar

/// The menu-bar item's menu while price control is on.
struct PriceControlMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let now = Date()
        let current = model.todayPrices.first { $0.hour <= now && now < $0.hour.addingTimeInterval(3600) }
        if let current {
            let price = Display.format("%.2f", current.totalOre / 100)
            if let level = current.level {
                Text("Electricity now: \(price) NOK/kWh · \(level.displayName)")
            } else {
                Text("Electricity now: \(price) NOK/kWh")
            }
        } else {
            Text("Electricity now: –")
        }
        if let state = model.state {
            Text("Indoor \(Format.temperature(state.roomTemperature)) · target \(Format.temperature(state.setTemperature))")
        }
        Text("Price control: \(model.priceControl.status?.text ?? String(localized: "starting…"))")
        if let next = model.priceControl.status?.nextStep {
            Text("Next: \(next.summary(now: now, timeZone: .current))")
        }
        Divider()
        Button("Open Heat Pump") { showWindow() }
        Button("Turn Off Price Control") {
            Task {
                await model.priceControl.setEnabled(false)
                // Back to the normal app: without a window open it quits, as when the last window closes.
                if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { NSApp.terminate(nil) }
            }
        }
        .disabled(model.priceControl.isBusy)
        Divider()
        Button("Quit Heat Pump") { NSApp.terminate(nil) }
    }

    private func showWindow() {
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate()
    }
}
