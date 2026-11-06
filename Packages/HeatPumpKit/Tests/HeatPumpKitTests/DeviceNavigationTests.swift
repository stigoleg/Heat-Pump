import Foundation
import Testing
@testable import DemoIntegration
@testable import HeatPumpKit

@Suite("Device navigation")
struct DeviceNavigationTests {
    let living = DemoUnit.unit(0).key
    let bedroom = DemoUnit.unit(1).key

    func device(_ key: DeviceKey, _ capabilities: Set<Capability>? = nil) -> DeviceDescriptor {
        DeviceDescriptor(
            key: key, name: key.rawValue, kind: .airToAirHeatPump, capabilities: capabilities ?? MockBackend(units: [.unit(0)]).capabilities)
    }

    @Test func heatPumpScreensFollowTheCapabilities() {
        #expect(DeviceNavigation.screens(for: device(living)) == DeviceScreen.allCases)
        #expect(DeviceNavigation.screens(for: nil) == DeviceScreen.allCases)
        #expect(DeviceNavigation.screens(kind: .airToAirHeatPump, capabilities: [.thermostat]) == [.overview, .control, .history, .health])
        #expect(DeviceNavigation.screens(kind: .airToAirHeatPump, capabilities: []) == [.overview, .history, .health])
        #expect(DeviceNavigation.screens(kind: .energyMeter, capabilities: [.energyLog]).isEmpty)
    }

    @Test func groupsStartAtTwoDevices() {
        #expect(!DeviceNavigation.isGrouped(deviceCount: 0))
        #expect(!DeviceNavigation.isGrouped(deviceCount: 1))
        #expect(DeviceNavigation.isGrouped(deviceCount: 2))
    }

    @Test func oneDeviceRoutesAreThePrimarys() {
        let one = [device(living)]
        #expect(DeviceNavigation.normalized(.device(bedroom, .control), devices: one) == .device(nil, .control))
        #expect(DeviceNavigation.normalized(.home(.overview), devices: one) == .device(nil, .overview))
        #expect(DeviceNavigation.normalized(.home(.forecast), devices: one) == .home(.forecast))
        #expect(DeviceNavigation.normalized(.device(nil, .away), devices: []) == .device(nil, .away))
        let basic = [device(living, [.thermostat])]
        #expect(DeviceNavigation.normalized(.device(nil, .away), devices: basic) == .device(nil, .overview))
    }

    @Test func twoDeviceRoutesNameTheDevice() {
        let two = [device(living), device(bedroom, [.thermostat])]
        #expect(DeviceNavigation.normalized(.device(nil, .control), devices: two) == .device(living, .control))
        #expect(DeviceNavigation.normalized(.device(bedroom, .control), devices: two) == .device(bedroom, .control))
        #expect(DeviceNavigation.normalized(.device(bedroom, .schedule), devices: two) == .device(bedroom, .overview))
        let gone = DeviceKey(integration: "demo", nativeId: "999")
        #expect(DeviceNavigation.normalized(.device(gone, .health), devices: two) == .device(living, .health))
        #expect(DeviceNavigation.normalized(.home(.overview), devices: two) == .home(.overview))
    }

    @Test func devScreenValues() {
        #expect(DeviceNavigation.route(devScreen: "overview") == .device(nil, .overview))
        #expect(DeviceNavigation.route(devScreen: "schedule") == .device(nil, .schedule))
        #expect(DeviceNavigation.route(devScreen: "outlook") == .home(.forecast))
        #expect(DeviceNavigation.route(devScreen: "activity") == .home(.activity))
        #expect(DeviceNavigation.route(devScreen: "home") == .home(.overview))
        #expect(DeviceNavigation.route(devScreen: "home/forecast") == .home(.forecast))
        #expect(DeviceNavigation.route(devScreen: "home/activity") == .home(.activity))
        #expect(DeviceNavigation.route(devScreen: "demo:100002/control") == .device(bedroom, .control))
        #expect(DeviceNavigation.route(devScreen: "demo:100002/outlook") == nil)
        #expect(DeviceNavigation.route(devScreen: "nonsense") == nil)
    }
}
