import Foundation
import Testing
@testable import HeatPumpKit

@Suite("Menu bar title")
struct MenuBarTitleTests {
    let living = DeviceKey(integration: "demo", nativeId: "100001")
    let bedroom = DeviceKey(integration: "demo", nativeId: "100002")
    let meter = DeviceKey(integration: "demo-meter", nativeId: "home")

    func values(
        symbol: MenuBarSymbol? = .mode(.heat), indoor: Double? = 21, target: Double? = 22, outdoor: Double? = -3,
        powerW: Double? = 780, todayCostNok: Double? = 12.4, priceNowOre: Double? = 123, priceLevel: PriceLevel? = .cheap,
        health: HealthSeverity? = .ok
    ) -> MenuBarValues {
        MenuBarValues(
            symbol: symbol, indoor: indoor, target: target, outdoor: outdoor, powerW: powerW, todayCostNok: todayCostNok,
            priceNowOre: priceNowOre, priceLevel: priceLevel, health: health)
    }

    @Test func defaultIsModeIndoorAndPower() {
        #expect(MenuBarLayout.default.items == [.modeIcon, .indoor, .power])
        #expect(MenuBarLayout.default.segments(for: values()) == [.symbol(.mode(.heat)), .indoor(21), .power(780)])
    }

    @Test func followsTheChosenOrder() {
        let layout = MenuBarLayout(items: [.priceNow, .outdoor, .modeIcon, .todayCost, .target])
        #expect(
            layout.segments(for: values())
                == [.priceNow(ore: 123, level: .cheap), .outdoor(-3), .symbol(.mode(.heat)), .todayCost(12.4), .target(22)])
    }

    @Test func missingValuesAreHidden() {
        let layout = MenuBarLayout(items: MenuBarItem.allCases)
        let segments = layout.segments(for: values(symbol: nil, indoor: nil, outdoor: nil, todayCostNok: nil, priceNowOre: nil))
        #expect(segments == [.target(22), .power(780)])
    }

    @Test func healthShowsOnlyAWarning() {
        let layout = MenuBarLayout(items: [.indoor, .health])
        #expect(layout.segments(for: values(health: .ok)) == [.indoor(21)])
        #expect(layout.segments(for: values(health: .info)) == [.indoor(21)])
        #expect(layout.segments(for: values(health: .warning)) == [.indoor(21), .health(.warning)])
        #expect(layout.segments(for: values(health: .critical)) == [.indoor(21), .health(.critical)])
        #expect(layout.segments(for: values(health: nil)) == [.indoor(21)])
    }

    @Test func nothingToShowFallsBackToTheIcon() {
        #expect(MenuBarLayout(items: []).segments(for: values()).isEmpty)
        #expect(MenuBarLayout(items: []).isIconOnly(for: values()))
        let empty = values(symbol: nil, indoor: nil, target: nil, outdoor: nil, powerW: nil)
        #expect(MenuBarLayout.default.isIconOnly(for: empty))
        #expect(!MenuBarLayout.default.isIconOnly(for: values()))
    }

    @Test func storedFormRoundTripsAndDropsUnknownAndRepeatedItems() {
        let layout = MenuBarLayout(items: [.power, .modeIcon, .health])
        #expect(layout.storedValue == "power,modeIcon,health")
        #expect(MenuBarLayout(storedValue: layout.storedValue) == layout)
        #expect(MenuBarLayout(storedValue: "indoor,bogus,indoor,power").items == [.indoor, .power])
        #expect(MenuBarLayout(storedValue: "").items == [])
        #expect(MenuBarLayout(storedValue: nil) == .default)
    }

    @Test func availableItemsAreTheOnesNotChosen() {
        #expect(MenuBarLayout.default.available == [.target, .outdoor, .todayCost, .priceNow, .health])
        #expect(MenuBarLayout(items: MenuBarItem.allCases).available.isEmpty)
    }

    @Test func movingAndRemovingItems() {
        var layout = MenuBarLayout.default
        layout.move(.power, by: -1)
        #expect(layout.items == [.modeIcon, .power, .indoor])
        layout.move(.modeIcon, by: -1)
        #expect(layout.items == [.modeIcon, .power, .indoor])
        layout.move(.indoor, by: 1)
        #expect(layout.items == [.modeIcon, .power, .indoor])
        layout.add(.health)
        layout.add(.health)
        #expect(layout.items == [.modeIcon, .power, .indoor, .health])
        layout.remove(.power)
        #expect(layout.items == [.modeIcon, .indoor, .health])
    }

    @Test func shownDeviceIsTheChosenOneWhenItIsEnabled() {
        #expect(MenuBarLayout.shownDevice(chosen: bedroom, devices: [living, bedroom]) == bedroom)
        #expect(MenuBarLayout.shownDevice(chosen: nil, devices: [living, bedroom]) == living)
        #expect(MenuBarLayout.shownDevice(chosen: meter, devices: [living, bedroom]) == living)
        #expect(MenuBarLayout.shownDevice(chosen: bedroom, devices: []) == nil)
    }
}
