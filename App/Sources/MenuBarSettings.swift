import AppKit
import HeatPumpKit
import Observation
import SwiftUI

/// The menu bar item's preferences (Settings → General → Menu bar): on or off, the title's
/// items and the device last chosen in the panel. App-only, so they live in UserDefaults.
/// Dev: `VARMEPUMPE_MENU_BAR=on|open|off` overrides the switch without saving (`open` also
/// opens the panel, for screenshots).
@MainActor
@Observable
final class MenuBarPreferences {
    static let enabledKey = "menuBarEnabled"
    static let itemsKey = "menuBarItems"
    static let deviceKey = "menuBarDevice"

    private(set) var enabled: Bool
    private(set) var layout: MenuBarLayout
    /// The device last chosen in the panel (nil: the primary device).
    private(set) var chosenDevice: DeviceKey?
    /// Dev only: open the panel once the item is in the menu bar.
    let opensPanelAtLaunch: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let override: Bool?
    /// Keeps App Nap from stretching the poll while the item is shown (the Mac may still sleep).
    @ObservationIgnored private var activity: NSObjectProtocol?

    init(environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let dev = environment["VARMEPUMPE_MENU_BAR"]
        override = dev.map { $0 != "off" }
        opensPanelAtLaunch = dev == "open"
        enabled = override ?? defaults.bool(forKey: Self.enabledKey)
        layout = MenuBarLayout(storedValue: defaults.string(forKey: Self.itemsKey))
        chosenDevice = defaults.string(forKey: Self.deviceKey).flatMap(DeviceKey.init)
        updateActivity()
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if override == nil { defaults.set(on, forKey: Self.enabledKey) }
        updateActivity()
    }

    func setLayout(_ new: MenuBarLayout) {
        layout = new
        defaults.set(new.storedValue, forKey: Self.itemsKey)
    }

    func resetLayout() {
        layout = .default
        defaults.removeObject(forKey: Self.itemsKey)
    }

    func choose(_ key: DeviceKey?) {
        chosenDevice = key
        defaults.set(key?.rawValue, forKey: Self.deviceKey)
    }

    private func updateActivity() {
        if enabled, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "The menu bar shows the heat pump")
        } else if !enabled, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}

extension MenuBarItem {
    var title: String {
        switch self {
        case .modeIcon: String(localized: "Mode icon")
        case .indoor: String(localized: "Indoor temperature")
        case .target: String(localized: "Target temperature")
        case .outdoor: String(localized: "Outdoor temperature")
        case .power: String(localized: "Power")
        case .todayCost: String(localized: "Today's cost")
        case .priceNow: String(localized: "Price now")
        case .health: String(localized: "Health warning")
        case .radon: String(localized: "Radon")
        case .co2: AirQualityMetric.co2.title
        case .humidity: AirQualityMetric.humidity.title
        }
    }

    var systemImage: String {
        switch self {
        case .modeIcon: "flame.fill"
        case .indoor: "thermometer.medium"
        case .target: "arrow.right.circle"
        case .outdoor: "cloud.sun.fill"
        case .power: "bolt.fill"
        case .todayCost: "chart.bar.fill"
        case .priceNow: "bolt.horizontal.fill"
        case .health: "exclamationmark.triangle.fill"
        case .radon: AirQualityMetric.radonShortTerm.systemImage
        case .co2: AirQualityMetric.co2.systemImage
        case .humidity: AirQualityMetric.humidity.systemImage
        }
    }

    var tint: Color {
        switch self {
        case .modeIcon: OperationMode.heat.tint
        case .indoor: Theme.Data.inside
        case .target: Theme.Data.setpoint
        case .outdoor: Theme.Data.outside
        case .power: .yellow
        case .todayCost: Theme.Data.energy
        case .priceNow: Theme.Data.electricity
        case .health: Theme.Status.caution
        case .radon: AirQualityMetric.radonShortTerm.tint
        case .co2: AirQualityMetric.co2.tint
        case .humidity: AirQualityMetric.humidity.tint
        }
    }

    /// When the item is left out even though it is chosen.
    var note: String? {
        switch self {
        case .health: String(localized: "Only when there is a warning")
        case .radon, .co2, .humidity: String(localized: "From an air quality sensor")
        default: nil
        }
    }
}

/// Settings → General → Menu bar: the switch, a live preview of the title, and the title's items
/// in order (move, remove, add, reset).
struct MenuBarSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let menuBar = model.menuBar
        Section {
            Toggle(isOn: Binding(get: { menuBar.enabled }, set: { model.setMenuBarEnabled($0) })) {
                Label { Text("Show in the menu bar") } icon: {
                    IconBadge(systemImage: "menubar.rectangle", color: .blue)
                }
            }
            if menuBar.enabled {
                LabeledContent("Preview") {
                    MenuBarTitlePreview()
                }
                ForEach(menuBar.layout.items, id: \.self) { item in
                    row(item, layout: menuBar.layout)
                }
                HStack {
                    Menu("Add Item") {
                        ForEach(menuBar.layout.available, id: \.self) { item in
                            Button(item.title) {
                                var layout = menuBar.layout
                                layout.add(item)
                                menuBar.setLayout(layout)
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(menuBar.layout.available.isEmpty)
                    Spacer()
                    Button("Reset to Default") { menuBar.resetLayout() }
                        .disabled(menuBar.layout == .default)
                }
            }
        } header: {
            Text("Menu bar")
        } footer: {
            Text(
                "Shows the heat pump in the menu bar; click it for status and controls. While it is on, the app keeps running when you close the window. Values that are not known yet are left out."
            )
        }
    }

    private func row(_ item: MenuBarItem, layout: MenuBarLayout) -> some View {
        let index = layout.items.firstIndex(of: item) ?? 0
        return HStack(spacing: Theme.Space.s) {
            Image(systemName: item.systemImage).foregroundStyle(item.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                if let note = item.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button { move(item, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .help("Move Up")
            Button { move(item, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == layout.items.count - 1)
                .help("Move Down")
            Button { remove(item) } label: { Image(systemName: "minus.circle") }
                .help("Remove")
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title)
    }

    private func move(_ item: MenuBarItem, by offset: Int) {
        var layout = model.menuBar.layout
        layout.move(item, by: offset)
        model.menuBar.setLayout(layout)
    }

    private func remove(_ item: MenuBarItem) {
        var layout = model.menuBar.layout
        layout.remove(item)
        model.menuBar.setLayout(layout)
    }
}

/// The title as the menu bar shows it, on a strip that looks like the menu bar.
private struct MenuBarTitlePreview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MenuBarTitleView(segments: model.menuBarSegments)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            .background(.bar, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Theme.hairline))
            .accessibilityLabel("Preview of the menu bar title")
    }
}
