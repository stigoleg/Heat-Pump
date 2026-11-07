import HeatPumpKit
import SwiftUI

/// What the app shows for each kind of device: its screens (which ones follow from the kind and
/// capabilities, `DeviceNavigation`), the views behind them with the device's model in the
/// environment, its card on Home and the Settings it brings. A new kind adds its model
/// (`DeviceModel`) and one case in each function here.
@MainActor
enum DeviceUIRegistry {
    /// The device's screens in sidebar order.
    static func screens(for device: any DeviceModel) -> [DeviceScreen] {
        DeviceNavigation.screens(for: device.descriptor)
    }

    /// One of the device's screens, with its model in the environment.
    @ViewBuilder static func screen(_ screen: DeviceScreen, of device: any DeviceModel) -> some View {
        if let heatPump = device as? HeatPumpDeviceModel {
            heatPumpScreen(screen).environment(heatPump)
        } else if let meter = device as? EnergyMeterDeviceModel {
            meterScreen(screen).environment(meter)
        } else if let sensor = device as? AirQualityDeviceModel {
            sensorScreen(screen).environment(sensor)
        }
    }

    /// A sensor has Overview and History (`DeviceNavigation`); any other screen shows its overview.
    @ViewBuilder private static func sensorScreen(_ screen: DeviceScreen) -> some View {
        switch screen {
        case .history: AirQualityHistoryView()
        default: AirQualityOverviewView()
        }
    }

    /// A meter has Overview and History (`DeviceNavigation`); any other screen shows its overview.
    @ViewBuilder private static func meterScreen(_ screen: DeviceScreen) -> some View {
        switch screen {
        case .history: MeterHistoryView()
        default: MeterOverviewView()
        }
    }

    @ViewBuilder private static func heatPumpScreen(_ screen: DeviceScreen) -> some View {
        switch screen {
        case .overview: OverviewView()
        case .control: ControlView()
        case .schedule: ScheduleView()
        case .history: HistoryView()
        case .away: AwayView()
        case .health: HealthView()
        }
    }

    /// The device's card on Home (two or more devices).
    @ViewBuilder static func homeCard(for device: any DeviceModel) -> some View {
        if let heatPump = device as? HeatPumpDeviceModel {
            HeatPumpHomeCard(device: heatPump)
        } else if let meter = device as? EnergyMeterDeviceModel {
            MeterHomeCard(device: meter)
        } else if let sensor = device as? AirQualityDeviceModel {
            AirQualityHomeCard(device: sensor)
        }
    }

    /// The devices Settings → Local connection is for: heat pumps their integration reads on the
    /// home network (and the primary one before its device is known).
    static func localConnectionDevices(_ devices: [any DeviceModel]) -> [HeatPumpDeviceModel] {
        devices.compactMap { $0 as? HeatPumpDeviceModel }.filter {
            $0.descriptor.map { $0.capabilities.contains(.localTelemetry) } ?? true
        }
    }
}

extension DeviceScreen {
    /// The sidebar screen with today's title, icon and colour.
    var screen: Screen { Screen(.device(nil, self)) ?? .overview }
}

extension HomeScreen {
    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .forecast: Screen.outlook.title
        case .activity: Screen.activity.title
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .forecast: Screen.outlook.systemImage
        case .activity: Screen.activity.systemImage
        }
    }

    var color: Color {
        switch self {
        case .overview: .blue
        case .forecast: Screen.outlook.color
        case .activity: Screen.activity.color
        }
    }
}
