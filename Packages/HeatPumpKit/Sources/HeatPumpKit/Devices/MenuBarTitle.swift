import Foundation

/// One thing the menu bar title can show. The raw values are stored (the user's layout), so
/// they never change.
public enum MenuBarItem: String, Sendable, CaseIterable, Codable {
    case modeIcon, indoor, target, outdoor, power, todayCost, priceNow, health
    /// An air quality sensor's readings (its temperature is `indoor`).
    case radon, co2, humidity
}

/// The symbol at the start of the title: the heat pump's mode, a heat pump that is off, an
/// energy meter or an air quality sensor.
public enum MenuBarSymbol: Sendable, Equatable {
    case mode(OperationMode)
    case off
    case meter
    case sensor
}

/// What the shown device and the shared context have right now; nil is unknown (not shown).
public struct MenuBarValues: Sendable, Equatable {
    public var symbol: MenuBarSymbol?
    public var indoor: Double?
    public var target: Double?
    public var outdoor: Double?
    public var powerW: Double?
    public var todayCostNok: Double?
    public var priceNowOre: Double?
    public var priceLevel: PriceLevel?
    public var health: HealthSeverity?
    /// Radon in Bq/m³ (the short-term average, else the long-term one).
    public var radon: Double?
    /// CO₂ in ppm.
    public var co2: Double?
    /// Relative humidity in %.
    public var humidity: Double?

    public init(
        symbol: MenuBarSymbol? = nil, indoor: Double? = nil, target: Double? = nil, outdoor: Double? = nil, powerW: Double? = nil,
        todayCostNok: Double? = nil, priceNowOre: Double? = nil, priceLevel: PriceLevel? = nil, radon: Double? = nil,
        co2: Double? = nil, humidity: Double? = nil, health: HealthSeverity? = nil
    ) {
        self.symbol = symbol
        self.indoor = indoor
        self.target = target
        self.outdoor = outdoor
        self.powerW = powerW
        self.todayCostNok = todayCostNok
        self.priceNowOre = priceNowOre
        self.priceLevel = priceLevel
        self.health = health
        self.radon = radon
        self.co2 = co2
        self.humidity = humidity
    }
}

/// One shown part of the title, in the layout's order; the app formats it.
public enum MenuBarSegment: Sendable, Equatable {
    case symbol(MenuBarSymbol)
    case indoor(Double)
    case target(Double)
    case outdoor(Double)
    case power(Double)
    case todayCost(Double)
    case priceNow(ore: Double, level: PriceLevel?)
    case health(HealthSeverity)
    case radon(Double)
    case co2(Double)
    case humidity(Double)
}

/// The menu bar title the user designed (Settings → General → Menu bar): which items, in which
/// order. Kept here so the rules (missing values hidden, health only as a warning, the icon when
/// nothing is left) can be tested without the UI.
public struct MenuBarLayout: Sendable, Equatable {
    public var items: [MenuBarItem]

    /// Mode icon, indoor temperature and power.
    public static let `default` = MenuBarLayout(items: [.modeIcon, .indoor, .power])

    public init(items: [MenuBarItem]) {
        var seen: Set<MenuBarItem> = []
        self.items = items.filter { seen.insert($0).inserted }
    }

    /// The stored form ("modeIcon,indoor,power"); nil (never saved) is the default, and unknown
    /// or repeated items are dropped.
    public init(storedValue: String?) {
        guard let storedValue else {
            self = .default
            return
        }
        self.init(items: storedValue.split(separator: ",").compactMap { MenuBarItem(rawValue: String($0)) })
    }

    public var storedValue: String { items.map(\.rawValue).joined(separator: ",") }

    /// The items not in the title, in their natural order (to add).
    public var available: [MenuBarItem] { MenuBarItem.allCases.filter { !items.contains($0) } }

    /// The parts to show: an item without a value is left out (never a dash), and health only
    /// when there is a warning or worse.
    public func segments(for values: MenuBarValues) -> [MenuBarSegment] {
        items.compactMap { item in
            switch item {
            case .modeIcon: values.symbol.map { .symbol($0) }
            case .indoor: values.indoor.map { .indoor($0) }
            case .target: values.target.map { .target($0) }
            case .outdoor: values.outdoor.map { .outdoor($0) }
            case .power: values.powerW.map { .power($0) }
            case .todayCost: values.todayCostNok.map { .todayCost($0) }
            case .priceNow: values.priceNowOre.map { .priceNow(ore: $0, level: values.priceLevel) }
            case .health: values.health.flatMap { $0 >= .warning ? .health($0) : nil }
            case .radon: values.radon.map { .radon($0) }
            case .co2: values.co2.map { .co2($0) }
            case .humidity: values.humidity.map { .humidity($0) }
            }
        }
    }

    /// True when nothing is chosen or nothing chosen has a value: the title is the app's icon.
    public func isIconOnly(for values: MenuBarValues) -> Bool { segments(for: values).isEmpty }

    /// Moves `item` one place (`offset` −1 earlier, +1 later); nothing at the ends.
    public mutating func move(_ item: MenuBarItem, by offset: Int) {
        guard let index = items.firstIndex(of: item) else { return }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        items.swapAt(index, target)
    }

    public mutating func add(_ item: MenuBarItem) {
        if !items.contains(item) { items.append(item) }
    }

    public mutating func remove(_ item: MenuBarItem) {
        items.removeAll { $0 == item }
    }

    /// The device the title shows: the one last chosen in the panel while it is enabled, else the
    /// primary (first) device.
    public static func shownDevice(chosen: DeviceKey?, devices: [DeviceKey]) -> DeviceKey? {
        if let chosen, devices.contains(chosen) { return chosen }
        return devices.first
    }
}
