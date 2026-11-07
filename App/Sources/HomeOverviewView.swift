import HeatPumpKit
import SwiftUI

/// Home with two or more devices: the shared price and weather now, and a card per device that
/// opens the device's overview.
struct HomeOverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                StatusBanner(showsDevice: false)
                nowSection
                devicesSection
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Now

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Now", hint: model.weatherLocation.map { .verbatim($0.displayName(serviceName: model.serviceName)) })
            CardSurface {
                KPIRow {
                    KPITile(
                        label: "Price now", value: priceNow, detail: .verbatim(model.priceSettings.agreement.displayName),
                        systemImage: "bolt.horizontal.fill", tint: model.currentPriceLevel?.color ?? Theme.Data.electricity)
                    KPITile(
                        label: "Outdoor", value: Format.degrees(outdoorNow?.temperature), detail: outdoorDetail,
                        systemImage: "cloud.sun.fill", tint: Theme.Data.outside)
                    KPITile(
                        label: "Today", value: todayEnergy, detail: todayCost.map { .verbatim($0) },
                        systemImage: "chart.bar.fill", tint: Theme.Data.energy)
                }
            }
        }
    }

    private var priceNow: String {
        let now = Date()
        guard let price = model.todayPrices.first(where: { $0.hour <= now && now < $0.hour.addingTimeInterval(3600) }) else { return "—" }
        return String(localized: "\(Display.format("%.2f", price.totalOre / 100)) NOK/kWh")
    }

    private var outdoorNow: ForecastHour? {
        model.forecast.first
    }

    private var outdoorDetail: LocalizedStringKey? {
        let next = model.forecast.prefix(24).map(\.temperature)
        guard let low = next.min(), let high = next.max() else { return nil }
        return "Next 24 h: \(Format.degrees(low)) to \(Format.degrees(high))"
    }

    /// Every heat pump's use today, together.
    private var todayEnergy: String {
        let buckets = model.heatPumps.compactMap(\.today)
        guard !buckets.isEmpty else { return "—" }
        return Format.kWh(buckets.map(\.totalKWh).reduce(0, +))
    }

    private var todayCost: String? {
        let costs = model.heatPumps.compactMap(\.today?.costNok)
        guard !costs.isEmpty else { return nil }
        return Format.kroner(costs.reduce(0, +))
    }

    // MARK: Devices

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Devices", hint: "Click a device to open it")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: Theme.Space.l, alignment: .top)], alignment: .leading,
                spacing: Theme.Space.l
            ) {
                ForEach(model.devices.indices, id: \.self) { index in
                    DeviceUIRegistry.homeCard(for: model.devices[index])
                }
            }
        }
    }
}

/// A heat pump on Home: name, mode, indoor and target temperature, power, connection, and
/// today's use and cost.
struct HeatPumpHomeCard: View {
    @Environment(AppModel.self) private var app
    let device: HeatPumpDeviceModel

    var body: some View {
        Button {
            app.route = .device(device.key, .overview)
        } label: {
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    header
                    if let state = device.state {
                        temperatures(state)
                        Divider()
                        figures
                    } else {
                        Text("No status yet").foregroundStyle(.secondary)
                    }
                    if let problem = device.dataProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.Status.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .help("Open \(device.displayName)")
        .accessibilityElement(children: .combine)
    }

    private var mode: OperationMode? { device.effectiveState?.mode ?? device.state?.mode }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            IconBadge(systemImage: mode?.systemImage ?? "fan.fill", color: device.state?.power == false ? .gray : (mode?.tint ?? .gray), size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.headline)
                Text(modeText).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let state = device.state {
                Label(state.offline ? "Offline" : "Online", systemImage: state.offline ? "wifi.slash" : "wifi")
                    .font(.callout)
                    .foregroundStyle(state.offline ? Theme.Status.caution : Theme.Status.good)
            }
        }
    }

    private var modeText: String {
        guard let state = device.state else { return device.serviceName }
        guard state.power else { return String(localized: "Off") }
        return mode?.displayName ?? String(localized: "Mode unknown")
    }

    private func temperatures(_ state: DeviceState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(Format.temperature(device.newerLocalSample?.roomTemperature ?? state.roomTemperature))
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text("Target \(Format.temperature(device.effectiveState?.setTemperature ?? state.setTemperature))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var figures: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            figure("Power", systemImage: "bolt.fill", tint: .yellow, value: power)
            figure("Today", systemImage: "chart.bar.fill", tint: Theme.Data.energy, value: today)
        }
    }

    private func figure(_ label: LocalizedStringKey, systemImage: String, tint: Color, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(label).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            .font(.callout)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var power: String {
        if let watts = device.liveSample?.powerW { return Format.watts(Double(watts)) }
        if let watts = device.estimatedPowerW { return "≈ " + Format.watts(watts) }
        return "—"
    }

    private var today: String {
        guard let today = device.today else { return "—" }
        let kr = today.costNok.map { " · " + Format.kroner($0) } ?? ""
        return Format.kWh(today.totalKWh) + kr
    }
}

extension HeatPumpDeviceModel {
    /// Why the device's data may be old: a sign-in problem, a block or a failed fetch (Home's
    /// card and the menu bar panel).
    var dataProblem: String? {
        guard let result = stateResult else { return nil }
        if result.needsLogin { return result.blockMessage ?? result.error ?? String(localized: "Log in to \(serviceName) in Settings.") }
        if let until = result.blockedUntil, until > Date() {
            return result.blockMessage ?? BlockReason.rateLimited.message(until: until, serviceName: serviceName)
        }
        return result.error
    }
}

/// An energy meter on Home: power now, today's use and cost, and any problem.
struct MeterHomeCard: View {
    @Environment(AppModel.self) private var app
    let device: EnergyMeterDeviceModel

    var body: some View {
        Button {
            app.route = .device(device.key, .overview)
        } label: {
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(spacing: Theme.Space.s) {
                        IconBadge(systemImage: DeviceKind.energyMeter.systemImage, color: .yellow, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.displayName).font(.headline)
                            Text(DeviceKind.energyMeter.title).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if device.powerNowW != nil {
                            Label("Live", systemImage: "dot.radiowaves.left.and.right")
                                .font(.callout)
                                .foregroundStyle(Theme.Status.good)
                        }
                    }
                    Text(Format.watts(device.powerNowW))
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text("Today").foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "chart.bar.fill").foregroundStyle(Theme.Data.energy)
                        }
                        .font(.callout)
                        Text(today)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                    }
                    if let problem = device.syncProblem ?? device.liveProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.Status.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .help("Open \(device.displayName)")
        .accessibilityElement(children: .combine)
    }

    private var today: String {
        guard let today = device.status?.today else { return "—" }
        let kr = today.cost.map { " · " + Format.kroner($0.totalNok) } ?? ""
        return Format.kWh(today.kWh) + kr
    }
}

/// An air quality sensor on Home: radon, CO2 and temperature with the worst level, and any problem.
struct AirQualityHomeCard: View {
    @Environment(AppModel.self) private var app
    let device: AirQualityDeviceModel

    var body: some View {
        Button {
            app.route = .device(device.key, .overview)
        } label: {
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(spacing: Theme.Space.s) {
                        IconBadge(systemImage: DeviceKind.airQualitySensor.systemImage, color: .teal, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.displayName).font(.headline)
                            Text(DeviceKind.airQualitySensor.title).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let level = device.status?.worstLevel {
                            Label(level.title, systemImage: level.systemImage)
                                .font(.callout)
                                .foregroundStyle(level.color)
                        }
                    }
                    if let status = device.status {
                        if let radon = status.value(.radonShortTerm) ?? status.value(.radonLongTerm) {
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                                Text(Display.format("%.0f", radon.value))
                                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                                    .monospacedDigit()
                                Text("Bq/m³ radon").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        HStack(alignment: .top, spacing: Theme.Space.l) {
                            figure(status.value(.co2))
                            figure(status.value(.temperature))
                            figure(status.value(.humidity))
                        }
                    } else {
                        Text("No readings yet").foregroundStyle(.secondary)
                    }
                    if let problem = device.syncProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.Status.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .help("Open \(device.displayName)")
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func figure(_ value: AirQualityValue?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(value.metric.title).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: value.metric.systemImage).foregroundStyle(value.level?.color ?? value.metric.tint)
                }
                .font(.callout)
                .lineLimit(1)
                Text(value.metric.formatted(value.value))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
