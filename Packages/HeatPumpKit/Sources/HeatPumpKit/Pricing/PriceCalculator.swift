import Foundation

/// Pure price and cost arithmetic.
public enum PriceCalculator {
    /// Grid day rate applies on weekdays 06–22 that are not public holidays.
    public static func isGridDayRate(_ hour: Date, timeZone: TimeZone) -> Bool {
        let calendar = WireDate.calendar(timeZone)
        let h = calendar.component(.hour, from: hour)
        guard (6..<22).contains(h), !calendar.isDateInWeekend(hour) else { return false }
        return !NorwegianHolidays.isHoliday(hour, timeZone: timeZone)
    }

    /// Price of one kWh in `hour`. `spot` is required for spot agreements; returns nil without it.
    public static func breakdown(
        hour: Date, settings: PriceSettings, spot: HourPrice?, timeZone: TimeZone
    ) -> PriceBreakdown? {
        let day = isGridDayRate(hour, timeZone: timeZone)
        let grid = day ? settings.grid.dayOre : settings.grid.nightOre
        switch settings.agreement {
        case .norgespris:
            return PriceBreakdown(hour: hour, energyOre: settings.norgesprisOre, gridOre: grid, supportOre: 0, isDayRate: day)
        case .tibber, .spot:
            guard let spot else { return nil }
            let vat = vatFactor(spot, settings: settings)
            let markup = settings.agreement == .spot ? settings.markupOre : 0
            return PriceBreakdown(
                hour: hour, energyOre: spot.totalOre + markup, gridOre: grid,
                supportOre: -Stromstotte.support(spotOreExVat: spot.spotOre, vatFactor: vat), isDayRate: day)
        }
    }

    /// VAT factor of a stored price: from the area for hvakosterstrommen, otherwise from
    /// total/spot (Tibber's `tax` is VAT plus certificates, so the ratio is capped at 1.25).
    static func vatFactor(_ price: HourPrice, settings: PriceSettings) -> Double {
        if let area = PriceArea(rawValue: price.area) { return area.vatFactor }
        guard price.spotOre > 1 else { return 1.25 }
        return min(1.25, max(1, price.totalOre / price.spotOre))
    }

    /// Cost of one day: hours with measured kWh use their own hour price; the rest of the day's
    /// kWh (`dayKWh` minus measured) uses the day's average price. `isEstimate` when more than
    /// 10 % of the kWh had to be priced at the average.
    public static func dayCost(
        dayKWh: Double, hourly: [HourCost], prices: [PriceBreakdown]
    ) -> (cost: CostSplit, isEstimate: Bool)? {
        guard !prices.isEmpty else { return nil }
        var cost = CostSplit()
        var measured = 0.0
        let byHour = Dictionary(prices.map { ($0.hour, $0) }, uniquingKeysWith: { a, _ in a })
        for h in hourly {
            guard let price = byHour[h.hour] else { continue }
            cost = cost + CostSplit(kWh: h.kWh, price: price)
            measured += h.kWh
        }
        let rest = max(0, dayKWh - measured)
        if rest > 0 {
            let n = Double(prices.count)
            let average = PriceBreakdown(
                hour: prices[0].hour,
                energyOre: prices.map(\.energyOre).reduce(0, +) / n,
                gridOre: prices.map(\.gridOre).reduce(0, +) / n,
                supportOre: prices.map(\.supportOre).reduce(0, +) / n, isDayRate: false)
            cost = cost + CostSplit(kWh: rest, price: average)
        }
        let total = max(dayKWh, measured)
        return (cost, total > 0 ? rest / total > 0.1 : false)
    }
}

/// Turns the lifetime energy counter in snapshots into kWh per hour.
public enum CounterSampler {
    /// Longest gap between two counter readings that is still split over the hours between them.
    public static let maxGap: TimeInterval = 3 * 3600

    /// kWh per hour start. Increases between two readings are spread evenly over the time
    /// between them; decreases (counter reset) and long gaps are skipped.
    public static func hourly(_ samples: [(at: Date, kWh: Double)], timeZone: TimeZone) -> [Date: Double] {
        let sorted = samples.sorted { $0.at < $1.at }
        var result: [Date: Double] = [:]
        let calendar = WireDate.calendar(timeZone)
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let span = b.at.timeIntervalSince(a.at)
            let delta = b.kWh - a.kWh
            guard span > 0, span <= maxGap, delta >= 0 else { continue }
            var cursor = a.at
            while cursor < b.at {
                guard let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start else { break }
                let hourEnd = hourStart.addingTimeInterval(3600)
                let end = min(hourEnd, b.at)
                result[hourStart, default: 0] += delta * end.timeIntervalSince(cursor) / span
                cursor = end
            }
        }
        return result
    }

    /// Average power in W over the last readings spanning at least `minSpan`, or nil.
    public static func averagePowerW(
        _ samples: [(at: Date, kWh: Double)], now: Date, window: TimeInterval = 90 * 60, minSpan: TimeInterval = 20 * 60
    ) -> Double? {
        let recent = samples.filter { now.timeIntervalSince($0.at) <= window }.sorted { $0.at < $1.at }
        guard let first = recent.first, let last = recent.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        let delta = last.kWh - first.kWh
        guard span >= minSpan, delta >= 0 else { return nil }
        return delta * 1000 / (span / 3600)
    }
}
