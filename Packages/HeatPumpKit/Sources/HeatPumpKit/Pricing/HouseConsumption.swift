import Foundation

/// One hour of a meter's electricity use (the whole house's) as its service reports it.
public struct HouseHour: Codable, Sendable, Equatable {
    public var hour: Date
    public var kWh: Double
    /// What the service says the hour cost (NOK); a cross-check, not used for the app's own cost.
    public var costNok: Double?
    /// The service's unit price in øre/kWh.
    public var unitPriceOre: Double?

    public init(hour: Date, kWh: Double, costNok: Double?, unitPriceOre: Double?) {
        self.hour = hour
        self.kWh = kWh
        self.costNok = costNok
        self.unitPriceOre = unitPriceOre
    }
}

/// A source of the house's hourly consumption.
public protocol HouseConsumptionProviding: Sendable {
    /// The last `lastHours` finished hours (Tibber caps it at 744).
    func fetchConsumption(lastHours: Int) async throws -> [HouseHour]
}

/// One hour: the house and the heat pump.
public struct HouseShareHour: Codable, Sendable, Equatable {
    public var hour: Date
    public var houseKWh: Double
    public var heatPumpKWh: Double?
    /// True when the heat pump's kWh come from its exact local counter (else an estimate).
    public var heatPumpMeasured: Bool
    public var houseCostNok: Double?

    /// Heat pump ÷ house, or nil without both.
    public var share: Double? {
        guard let heatPumpKWh, houseKWh > 0 else { return nil }
        return heatPumpKWh / houseKWh
    }
}

/// One local day.
public struct HouseShareDay: Codable, Sendable, Equatable {
    /// `yyyy-MM-dd`
    public var day: String
    public var start: Date
    public var houseKWh: Double
    /// Heat-pump kWh over the hours where both are known.
    public var heatPumpKWh: Double
    /// Hours with both house and heat-pump data.
    public var hoursWithBoth: Int
    /// Heat pump ÷ house over the hours with both; nil with fewer than 20 such hours.
    public var share: Double?
    /// True when every heat-pump hour came from the local counter.
    public var heatPumpMeasured: Bool
    /// Tibber's own cost for the whole house that day.
    public var houseCostNok: Double?
}

public struct HouseShareSummary: Codable, Sendable, Equatable {
    public var hours: [HouseShareHour]
    public var days: [HouseShareDay]
    /// Yesterday, when it is in the range.
    public var yesterday: HouseShareDay?
}

public enum HouseShare {
    /// Hours with both values a day needs before a share is given.
    public static let minHoursPerDay = 20

    public static func summarize(
        house: [Date: HouseHour], heatPump: [Date: HourCost], timeZone: TimeZone, yesterday: String? = nil
    ) -> HouseShareSummary {
        let hours = house.keys.sorted().compactMap { hour -> HouseShareHour? in
            guard let h = house[hour] else { return nil }
            let pump = heatPump[hour]
            return HouseShareHour(
                hour: hour, houseKWh: h.kWh, heatPumpKWh: pump?.kWh, heatPumpMeasured: pump?.measuredLocally ?? false,
                houseCostNok: h.costNok)
        }
        let calendar = WireDate.calendar(timeZone)
        let grouped = Dictionary(grouping: hours) { calendar.startOfDay(for: $0.hour) }
        let days = grouped.keys.sorted().map { start -> HouseShareDay in
            let list = grouped[start] ?? []
            let both = list.filter { $0.heatPumpKWh != nil }
            let houseBoth = both.reduce(0) { $0 + $1.houseKWh }
            let pump = both.reduce(0) { $0 + ($1.heatPumpKWh ?? 0) }
            let costs = list.compactMap(\.houseCostNok)
            func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
            return HouseShareDay(
                day: WireDate.day(start, timeZone: timeZone), start: start, houseKWh: r(list.reduce(0) { $0 + $1.houseKWh }),
                heatPumpKWh: r(pump), hoursWithBoth: both.count,
                share: both.count >= minHoursPerDay && houseBoth > 0 ? pump / houseBoth : nil,
                heatPumpMeasured: !both.isEmpty && both.allSatisfy(\.heatPumpMeasured),
                houseCostNok: costs.isEmpty ? nil : r(costs.reduce(0, +)))
        }
        return HouseShareSummary(hours: hours, days: days, yesterday: days.first { $0.day == yesterday })
    }
}
