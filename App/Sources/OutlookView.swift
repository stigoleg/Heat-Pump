import Charts
import HeatPumpKit
import SwiftUI

/// Prognose: the weather ahead, published and estimated electricity prices, expected use and
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
            SectionHeader("Vær", hint: model.weatherLocation?.displayName)
            TrendCard(title: "Neste 48 timer") {
                FlowLayout {
                    LegendDot(label: "Temperatur", color: Theme.Data.outside)
                    LegendDot(label: "Nedbør (mm)", color: Theme.Data.blue.opacity(0.35))
                }
            } chart: {
                if hours.isEmpty {
                    EmptyChart(
                        title: "Ingen værvarsel ennå", message: model.weatherMessage ?? "Varselet hentes fra MET Norway.",
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
                        x: .value("Tid", h.time, unit: .hour), yStart: .value("mm", low), yEnd: .value("mm", low + min(mm, 6) * mmScale)
                    )
                    .foregroundStyle(Theme.Data.blue.opacity(0.35))
                }
                LineMark(x: .value("Tid", h.time), y: .value("°C", h.temperature))
                    .foregroundStyle(Theme.Data.outside)
                    .interpolationMethod(.monotone)
            }
            if low < 0, high > 0 { RuleMark(y: .value("0", 0)).foregroundStyle(Color.secondary.opacity(0.25)) }
            if let h = nearest(hours, to: selectedWeather, by: \.time) {
                RuleMark(x: .value("Valgt", h.time))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        ChartTooltip(
                            title: Format.weekdayHour(h.time),
                            rows: [
                                ("Ute", Format.temperature(h.temperature), Theme.Data.outside),
                                ("Nedbør", h.precipitation.map { Norwegian.format("%.1f mm", $0) } ?? "–", Theme.Data.blue),
                                ("Vind", h.windSpeed.map { Norwegian.format("%.0f m/s", $0) } ?? "–", .secondary),
                            ])
                    }
            }
        }
        .chartYScale(domain: low...high)
        .calmYAxis { Norwegian.format("%.0f°", $0) }
        .calmXAxis(Date.FormatStyle().weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)), count: 6)
        .chartXSelection(value: $selectedWeather)
        .accessibilityLabel("Temperatur og nedbør neste 48 timer")
    }

    // MARK: Prices

    private var priceSection: some View {
        let outlook = model.priceOutlook
        let known = outlook?.known ?? []
        let estimate = outlook?.estimate ?? []
        let now = Date()
        let current = known.first { $0.hour <= now && now < $0.hour.addingTimeInterval(3600) }
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Strømpris", hint: outlook.map { $0.agreement == .norgespris ? "Norgespris" : $0.agreement.displayName })
            TrendCard(
                title: "Neste 7 dager",
                value: current.map { Norwegian.format("Nå %.2f kr/kWh", $0.totalOre / 100) }
            ) {
                FlowLayout {
                    if known.contains(where: { $0.level != nil }) {
                        ForEach([PriceLevel.veryCheap, .cheap, .normal, .expensive, .veryExpensive], id: \.self) {
                            LegendDot(label: $0.displayName, color: $0.color)
                        }
                    } else {
                        LegendDot(label: "Kjent pris", color: Theme.Data.purple)
                    }
                    if !estimate.isEmpty { LegendDot(label: "Anslag (usikkert)", color: .secondary, dashed: true) }
                }
            } chart: {
                if known.isEmpty && estimate.isEmpty {
                    EmptyChart(
                        title: "Ingen priser ennå", message: model.priceMessage ?? "Velg strømavtale under Innstillinger → Strømpris.",
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
            return Norwegian.format("Norgespris er %.0f øre/kWh hele døgnet; søylene viser den pluss nettleien, som er lavere om natten og i helgene. Ingen anslag trengs.", model.priceSettings.norgesprisOre)
        }
        var text = "Søylene er publiserte priser (strøm, nettleie og strømstøtte). "
        if !outlook.estimate.isEmpty {
            text += "Det stiplede er et anslag med usikkerhetsområde, ikke en pris: " + PriceOutlook.methodText.prefix(1).lowercased()
                + PriceOutlook.methodText.dropFirst()
        } else if let missing = outlook.estimateMissing {
            text += missing + " Virkelige priser for i morgen kommer rundt kl. 13."
        } else {
            text += "Virkelige priser for i morgen kommer rundt kl. 13."
        }
        return text
    }

    private func priceChart(known: [PriceBreakdown], estimate: [EstimatedPrice]) -> some View {
        let now = Date()
        return Chart {
            ForEach(known, id: \.hour) { p in
                BarMark(x: .value("Time", p.hour, unit: .hour), y: .value("kr/kWh", p.totalOre / 100))
                    .foregroundStyle((p.level?.color ?? Theme.Data.purple).opacity(0.85))
            }
            ForEach(estimate, id: \.hour) { e in
                AreaMark(
                    x: .value("Time", e.hour), yStart: .value("Lav", e.lowOre / 100), yEnd: .value("Høy", e.highOre / 100),
                    series: .value("Serie", "band")
                )
                .foregroundStyle(Color.secondary.opacity(0.16))
                .interpolationMethod(.monotone)
                LineMark(x: .value("Time", e.hour), y: .value("kr/kWh", e.totalOre / 100), series: .value("Serie", "anslag"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(ChartKit.previousStroke)
                    .interpolationMethod(.monotone)
            }
            RuleMark(x: .value("Nå", now))
                .foregroundStyle(Theme.Status.caution)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    Text("nå").font(.caption2.weight(.semibold)).foregroundStyle(Theme.Status.caution)
                }
            if let first = estimate.first {
                RuleMark(x: .value("Anslag", first.hour))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("anslag →").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let selectedPrice {
                if let p = known.first(where: { $0.hour <= selectedPrice && selectedPrice < $0.hour.addingTimeInterval(3600) }) {
                    RuleMark(x: .value("Valgt", p.hour, unit: .hour))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            ChartTooltip(
                                title: Norwegian.dateTime(p.hour),
                                rows: [
                                    ("Totalt", Norwegian.format("%.2f kr", p.totalOre / 100), .primary),
                                    ("Nivå", p.level?.displayName ?? "–", p.level?.color ?? .secondary),
                                ])
                        }
                } else if let e = nearest(estimate, to: selectedPrice, by: \.hour) {
                    RuleMark(x: .value("Valgt", e.hour))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            ChartTooltip(
                                title: Norwegian.dateTime(e.hour),
                                rows: [
                                    ("Anslag", Norwegian.format("%.2f kr", e.totalOre / 100), .secondary),
                                    ("Trolig", Norwegian.format("%.2f–%.2f kr", e.lowOre / 100, e.highOre / 100), .secondary),
                                ])
                        }
                }
            }
        }
        .calmYAxis { Norwegian.format("%.1f", $0) }
        .calmXAxis(Date.FormatStyle().weekday(.abbreviated).day(), count: 8)
        .chartXSelection(value: $selectedPrice)
        .accessibilityLabel("Strømpris neste 7 dager, kjente priser og anslag")
    }

    // MARK: Use and cost

    @ViewBuilder private var useSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Forventet forbruk og kostnad", hint: "Anslag per døgn")
            if model.dailyOutlook.isEmpty {
                InsightCard(
                    title: "Ikke nok data ennå",
                    detail: "Anslaget trenger minst \(DegreeDayModel.minDays) dager med forbruk og utetemperatur, og et værvarsel.",
                    systemImage: "chart.bar.doc.horizontal", tint: .secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.m, alignment: .top)], alignment: .leading,
                    spacing: Theme.Space.m
                ) {
                    ForEach(model.dailyOutlook, id: \.day) { DayOutlookCard(day: $0) }
                }
                Text(
                    "Grovt anslag: forbruket mot hvor kaldt det har vært de siste ukene, værvarselet og prisene. Dager merket «prisanslag» bruker anslåtte priser for timene uten publisert pris."
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
                Text(Norwegian.format("%.0f° / %.0f°", day.maxTemperature.rounded() + 0, day.minTemperature.rounded() + 0))
                    .font(.body.weight(.medium)).monospacedDigit()
                Text(day.precipitation.map { Norwegian.format("%.1f mm", $0) } ?? "– mm")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Text(day.maxWind.map { Norwegian.format("%.0f m/s", $0) } ?? "– m/s")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if Calendar.current.isDateInToday(day.date) { return "I dag" }
        return day.date.formatted(Date.FormatStyle().weekday(.abbreviated).day().locale(Norwegian.locale))
    }
}

struct DayOutlookCard: View {
    let day: DayOutlook

    var body: some View {
        CardSurface(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(day.date.formatted(Date.FormatStyle().weekday(.wide).day().month(.abbreviated).locale(Norwegian.locale)))
                    .font(.callout.weight(.semibold))
                Text("~" + Norwegian.format("%.0f kWh", day.kWh))
                    .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                if day.kWhLow.rounded() != day.kWhHigh.rounded() {
                    Text(Norwegian.format("ca. %.0f–%.0f kWh", day.kWhLow, day.kWhHigh)).font(.caption).foregroundStyle(.secondary)
                }
                Text(day.costNok.map { "~" + Norwegian.format("%.0f kr", $0) } ?? "kostnad ukjent")
                    .font(.body.weight(.medium)).monospacedDigit()
                Text(Norwegian.format("%.0f° i snitt · ", day.meanOutdoor) + (day.usesEstimatedPrices ? "prisanslag" : "kjente priser"))
                    .font(.caption).foregroundStyle(day.usesEstimatedPrices ? .secondary : .primary)
            }
        }
        .help("Anslag ut fra værvarselet og egne målinger. \(day.knownPriceHours) timer med publisert pris, \(day.estimatedPriceHours) med anslått pris.")
    }
}

// MARK: - Price control

/// Prisstyring: switch with the warning, settings, status now and the plan.
struct PriceControlSection: View {
    @Environment(AppModel.self) private var model
    @State private var draft = PriceControlSettings.default
    @State private var saveError: String?

    private var runner: PriceControlRunner { model.priceControl }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Prisstyring", hint: "Senker temperaturen når strømmen er dyr")
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
                Text("Prisstyring").font(.headline)
                Text(baseText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if runner.isBusy { ProgressView().controlSize(.small) }
            Toggle(
                "Prisstyring",
                isOn: Binding(get: { runner.enabled }, set: { on in Task { await runner.setEnabled(on) } })
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(runner.isBusy || model.service == nil)
        }
    }

    private var baseText: String {
        switch runner.plan?.baseSource ?? .unknown {
        case .schedule: return "Senker fra temperaturen i ukeplanen."
        case .comfort:
            return "Senker fra din vanlige temperatur, " + (runner.settings.comfortTemperature.map(TimerEventText.temperature) ?? "–")
                + " (den du sist stilte inn selv)."
        case .unknown: return "Senker fra temperaturen varmepumpen står på når du slår den på."
        }
    }

    private var warning: some View {
        Label {
            Text(
                "Prisstyringen virker bare mens appen kjører og Macen er på og våken. Når du lukker vinduet, fortsetter appen i menylinjen. Når Macen skal sove eller appen avsluttes, settes temperaturen tilbake først. Skjer ikke det (strømbrudd, krasj), blir temperaturen stående – men aldri lavere enn "
                    + TimerEventText.temperature(draft.minimumTemperature) + "."
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
                Text("Senk i dyre timer: ") + Text(Norwegian.format("%.1f °C", draft.reduceExpensive)).monospacedDigit()
            }
            Stepper(value: binding(\.reduceVeryExpensive), in: PriceControlSettings.reductionRange, step: 0.5) {
                Text("Senk i svært dyre timer: ") + Text(Norwegian.format("%.1f °C", draft.reduceVeryExpensive)).monospacedDigit()
            }
            Stepper(value: binding(\.minimumTemperature), in: PriceControlSettings.minimumRange, step: 0.5) {
                Text("Aldri lavere enn: ") + Text(Norwegian.format("%.1f °C", draft.minimumTemperature)).monospacedDigit()
            }
            Stepper(value: binding(\.maxReducedHoursPerDay), in: PriceControlSettings.reducedHoursRange) {
                Text("Senk høyst \(Text(String(draft.maxReducedHoursPerDay)).monospacedDigit()) \(draft.maxReducedHoursPerDay == 1 ? "time" : "timer") per døgn")
            }
            Toggle(isOn: binding(\.preheat)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Forvarm litt før dyre timer")
                    Text("+1 °C i opptil to av de billigste timene de fire timene før.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Bare i varmemodus. Av/på og modus endres aldri. Prisstyringen står over feriemodus og hendelser i ukeplanen, og tar pause til neste skifte når du endrer temperaturen selv.")
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
                        Text("Nå: " + status.text).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        if let problem = status.problem {
                            Text(problem).font(.caption).foregroundStyle(Theme.Status.caution).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } icon: {
                    Image(systemName: status.kind.systemImage).foregroundStyle(status.kind.tint)
                }
            }
            if let message = runner.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            Text(runner.enabled ? "Plan de neste 36 timene" : "Slik ville planen sett ut de neste 36 timene")
                .font(.callout.weight(.semibold)).padding(.top, Theme.Space.xs)
            let changes = plan?.changes ?? []
            if let note = plan?.note {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if changes.isEmpty {
                Text("Ingen dyre timer i de publiserte prisene, så temperaturen står som den er.")
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
                Text(
                    "\(over) dyre " + (over == 1 ? "time" : "timer") + " senkes ikke, fordi høyst \(runner.settings.maxReducedHoursPerDay) "
                        + (runner.settings.maxReducedHoursPerDay == 1 ? "time" : "timer") + " senkes per døgn."
                )
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Høyst \(runner.settings.maxReducedHoursPerDay) " + (runner.settings.maxReducedHoursPerDay == 1 ? "time" : "timer") + " senkes per døgn, de dyreste først. Planen bruker bare publiserte priser, ikke anslaget. Endringene vises under Claude-aktivitet med kilden «Prisstyring».")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Temperature text as in the weekly plan ("21 °C", "20,5 °C").
enum TimerEventText {
    static func temperature(_ value: Double) -> String {
        value == value.rounded() ? Norwegian.format("%.0f °C", value) : Norwegian.format("%.1f °C", value)
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
        Text(
            current.map { Norwegian.format("Strøm nå: %.2f kr/kWh", $0.totalOre / 100) + ($0.level.map { " · " + $0.displayName } ?? "") }
                ?? "Strøm nå: –")
        if let state = model.state {
            Text("Inne " + Format.temperature(state.roomTemperature) + " · ønsket " + Format.temperature(state.setTemperature))
        }
        Text("Prisstyring: " + (model.priceControl.status?.text ?? "starter …"))
        if let next = model.priceControl.status?.nextStep {
            Text("Neste: " + next.summary(now: now, timeZone: .current))
        }
        Divider()
        Button("Åpne Varmepumpe") { showWindow() }
        Button("Slå av prisstyring") {
            Task {
                await model.priceControl.setEnabled(false)
                // Back to the normal app: without a window open it quits, as when the last window closes.
                if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { NSApp.terminate(nil) }
            }
        }
        .disabled(model.priceControl.isBusy)
        Divider()
        Button("Avslutt Varmepumpe") { NSApp.terminate(nil) }
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
