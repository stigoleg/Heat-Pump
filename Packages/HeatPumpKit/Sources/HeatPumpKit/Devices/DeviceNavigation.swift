import Foundation

/// A screen about one device.
public enum DeviceScreen: String, Sendable, Hashable, CaseIterable {
    case overview, control, schedule, history, away, health
}

/// A screen about the home as a whole.
public enum HomeScreen: String, Sendable, Hashable, CaseIterable {
    /// Every device at a glance (only with two or more devices).
    case overview
    case forecast
    case activity
}

/// Where the app's main window is. `device(nil, …)` is the primary device: with one device the
/// app never names it, so its routes stay valid while the device is still unknown (first sign-in).
public enum AppRoute: Sendable, Hashable {
    case home(HomeScreen)
    case device(DeviceKey?, DeviceScreen)
}

/// The app's navigation rules, kept here so they can be tested without the UI.
///
/// With one enabled device (or none yet) the sidebar is today's flat list and every route is
/// about the primary device. With two or more it is grouped: Home, then one group per device.
public enum DeviceNavigation {
    /// Whether the sidebar shows groups (Home and one per device).
    public static func isGrouped(deviceCount: Int) -> Bool { deviceCount >= 2 }

    /// The Home screens the sidebar lists in grouped mode.
    public static let homeScreens: [HomeScreen] = [.overview, .forecast, .activity]

    /// The screens a device has, in sidebar order: each only when its capability exists.
    /// Unknown device (nil, before the first sign-in): every heat pump screen, as before devices.
    public static func screens(for device: DeviceDescriptor?) -> [DeviceScreen] {
        guard let device else { return DeviceScreen.allCases }
        return screens(kind: device.kind, capabilities: device.capabilities)
    }

    public static func screens(kind: DeviceKind, capabilities: Set<Capability>) -> [DeviceScreen] {
        switch kind {
        case .airToAirHeatPump:
            return DeviceScreen.allCases.filter { screen in
                switch screen {
                case .overview, .history, .health: true
                case .control: capabilities.contains(.thermostat)
                case .schedule: capabilities.contains(.weeklySchedule)
                case .away: capabilities.contains(.awayModes)
                }
            }
        case .energyMeter:
            // The meter's screens come with its integration.
            return []
        }
    }

    /// The route the app shows for `route` with these enabled devices (registry order): with one
    /// device every device route is the primary's (nil) and Home's overview is the device's; with
    /// two or more a missing or unknown device becomes the first one, and a screen the device does
    /// not have becomes its overview.
    public static func normalized(_ route: AppRoute, devices: [DeviceDescriptor]) -> AppRoute {
        guard isGrouped(deviceCount: devices.count) else {
            switch route {
            case .home(.overview): return .device(nil, .overview)
            case .home: return route
            case .device(_, let screen):
                return screens(for: devices.first).contains(screen) ? .device(nil, screen) : .device(nil, .overview)
            }
        }
        switch route {
        case .home: return route
        case .device(let key, let screen):
            let device = devices.first { $0.key == key } ?? devices[0]
            return .device(device.key, screens(for: device).contains(screen) ? screen : .overview)
        }
    }

    /// Parses the developer hook `VARMEPUMPE_SCREEN`: today's values (`overview`, `control`, …,
    /// `outlook`, `activity`), `home`, `home/<screen>` and `<device key>/<screen>`.
    public static func route(devScreen value: String) -> AppRoute? {
        switch value {
        case "outlook": return .home(.forecast)
        case "activity": return .home(.activity)
        case "home": return .home(.overview)
        default: break
        }
        if let screen = DeviceScreen(rawValue: value) { return .device(nil, screen) }
        guard let slash = value.lastIndex(of: "/") else { return nil }
        let head = String(value[..<slash])
        let tail = String(value[value.index(after: slash)...])
        if head == "home" {
            if tail == "outlook" { return .home(.forecast) }
            return HomeScreen(rawValue: tail).map(AppRoute.home)
        }
        guard let key = DeviceKey(head), let screen = DeviceScreen(rawValue: tail) else { return nil }
        return .device(key, screen)
    }
}
