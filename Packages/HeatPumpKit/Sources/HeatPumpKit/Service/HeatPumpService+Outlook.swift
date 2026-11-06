import Foundation

/// Estimated price per kWh for one hour (øre/kWh incl. VAT, same basis as `PriceBreakdown.totalOre`:
/// electricity + grid tariff − electricity subsidy). An estimate, not a published price.
public struct EstimatedPrice: Codable, Sendable, Equatable {
    public var hour: Date
    public var totalOre: Double
    /// 25th and 75th percentile.
    public var lowOre: Double
    public var highOre: Double
}

/// Prices from now on: the published ones and, for spot agreements, an estimate for the days after.
public struct PriceOutlook: Codable, Sendable, Equatable {
    public var agreement: PriceAgreementKind
    /// Published prices (Norgespris: every hour).
    public var known: [PriceBreakdown]
    /// Hours after the last published price; empty for Norgespris and with too little history.
    public var estimate: [EstimatedPrice]
    /// Complete days of prices behind the estimate.
    public var basisDays: Int?
    public var temperatureAdjusted: Bool
    /// End of the period covered (exclusive).
    public var end: Date
    /// Why there is no estimate (spot agreements only), or nil.
    public var estimateMissing: String?

    /// One sentence on how the estimate is made.
    public static let methodText =
        L10n.tr("The estimate is based on how the price has varied through the day over the last four weeks and the level over the last week, adjusted for the weather forecast when the price has followed the temperature; actual prices for tomorrow arrive around 13:00.")
}

/// Expected use and cost of one forecast day (an estimate).
public struct DayOutlook: Codable, Sendable, Equatable {
    /// Local start of the day.
    public var date: Date
    /// `yyyy-MM-dd`
    public var day: String
    public var meanOutdoor: Double
    public var minOutdoor: Double
    public var maxOutdoor: Double
    public var kWh: Double
    public var kWhLow: Double
    public var kWhHigh: Double
    public var costNok: Double?
    /// Hours priced with a published price and with the estimate.
    public var knownPriceHours: Int
    public var estimatedPriceHours: Int

    public var usesEstimatedPrices: Bool { estimatedPriceHours > 0 }
}

extension HeatPumpService {
    /// Days of prices ahead shown on Prognose (from today).
    public static let outlookDays = 7

    /// Published prices from the current hour to the end of day `outlookDays` after today, and an
    /// estimate for the hours after the last published one (spot agreements only).
    public func priceOutlook() throws -> PriceOutlook {
        let settings = try priceSettings()
        let calendar = WireDate.calendar(timeZone)
        let t = now()
        let hourStart = calendar.dateInterval(of: .hour, for: t)?.start ?? t
        let end = calendar.date(byAdding: .day, value: Self.outlookDays + 1, to: calendar.startOfDay(for: t)) ?? t
        let known = try priceBreakdowns(from: hourStart, to: end)
        var outlook = PriceOutlook(
            agreement: settings.agreement, known: known, estimate: [], basisDays: nil, temperatureAdjusted: false, end: end)
        guard let key = priceKey(settings) else { return outlook }
        let from = known.last.map { $0.hour.addingTimeInterval(3600) } ?? hourStart
        guard from < end else { return outlook }
        let historyStart = calendar.date(byAdding: .day, value: -(Self.priceBackfillDays + 1), to: calendar.startOfDay(for: t)) ?? t
        let history = try store.prices(source: key.source, area: key.area, from: historyStart, to: from)
        guard
            let result = PriceEstimator.estimate(
                history: history, dayTemperatures: try dayTemperatures(from: historyStart, to: end), from: from, to: end,
                timeZone: timeZone)
        else {
            outlook.estimateMissing = L10n.format("The estimate needs at least %lld days of stored prices.", PriceEstimator.minDays)
            return outlook
        }
        // Spot excl. VAT → the full price per kWh, like the published hours.
        let vat = history.last.map { PriceCalculator.vatFactor($0, settings: settings) } ?? settings.area.vatFactor
        func total(_ hour: Date, _ spot: Double) -> Double? {
            let price = HourPrice(hour: hour, area: key.area, source: key.source, spotOre: spot, totalOre: spot * vat)
            return PriceCalculator.breakdown(hour: hour, settings: settings, spot: price, timeZone: timeZone)?.totalOre
        }
        outlook.estimate = result.hours.compactMap { h in
            guard let median = total(h.hour, h.median), let low = total(h.hour, h.low), let high = total(h.hour, h.high) else {
                return nil
            }
            return EstimatedPrice(hour: h.hour, totalOre: median, lowOre: min(low, median), highOre: max(high, median))
        }
        outlook.basisDays = result.basisDays
        outlook.temperatureAdjusted = result.temperatureSlope != nil
        return outlook
    }

    /// Daily mean outdoor temperature keyed by local start of day: measured days, then the forecast.
    func dayTemperatures(from: Date, to: Date) throws -> [Date: Double] {
        var result: [Date: Double] = [:]
        for (day, mean) in try dailyOutdoorMeans(from: from, to: now()) {
            if let date = WireDate.parse(day, timeZone: timeZone) { result[date] = mean }
        }
        for day in try forecastDays(from: now(), to: to) { result[day.date] = day.mean }
        return result
    }

    /// Forecast entries grouped per local day (days with at least 4 entries: MET's longer range
    /// has one entry per 6 hours).
    func forecastDays(from: Date, to: Date) throws -> [(date: Date, mean: Double, hours: [ForecastHour])] {
        let calendar = WireDate.calendar(timeZone)
        let start = calendar.startOfDay(for: from)
        let hours = try store.forecast(from: start, to: to)
        return Dictionary(grouping: hours) { calendar.startOfDay(for: $0.time) }
            .filter { $0.value.count >= 4 }
            .map { (date: $0.key, mean: $0.value.reduce(0) { $0 + $1.temperature } / Double($0.value.count), hours: $0.value) }
            .sorted { $0.date < $1.date }
    }

    /// Expected use and cost for each forecast day from tomorrow (at most `outlookDays`), from the
    /// degree-day model, the forecast and published prices where they exist, else the estimate.
    /// Empty without enough history for the model.
    public func dailyOutlook() throws -> [DayOutlook] {
        guard let model = try degreeDayModel() else { return [] }
        let calendar = WireDate.calendar(timeZone)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now())),
            let end = calendar.date(byAdding: .day, value: Self.outlookDays, to: tomorrow)
        else { return [] }
        let outlook = try priceOutlook()
        let known = Dictionary(outlook.known.map { ($0.hour, $0.totalOre) }, uniquingKeysWith: { a, _ in a })
        let estimated = Dictionary(outlook.estimate.map { ($0.hour, $0.totalOre) }, uniquingKeysWith: { a, _ in a })
        func r(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        return try forecastDays(from: tomorrow, to: end).compactMap { day in
            let temps = day.hours.map(\.temperature)
            let kWh = model.predict(degreeDays: DegreeDayModel.degreeDays(mean: day.mean))
            // Hourly temperatures between the forecast's entries, to weight the hours.
            var priced: [(temperature: Double, priceOre: Double)] = []
            var knownHours = 0
            var estimatedHours = 0
            var hour = day.date
            let next = calendar.date(byAdding: .day, value: 1, to: day.date) ?? day.date.addingTimeInterval(86_400)
            while hour < next {
                let temperature = Self.interpolated(day.hours, at: hour)
                if let price = known[hour] {
                    priced.append((temperature, price))
                    knownHours += 1
                } else if let price = estimated[hour] {
                    priced.append((temperature, price))
                    estimatedHours += 1
                }
                hour = hour.addingTimeInterval(3600)
            }
            let cost = priced.count >= 20 ? EnergyForecast.cost(kWh: kWh, hours: priced).map(r) : nil
            return DayOutlook(
                date: day.date, day: WireDate.day(day.date, timeZone: timeZone), meanOutdoor: r(day.mean),
                minOutdoor: temps.min() ?? day.mean, maxOutdoor: temps.max() ?? day.mean, kWh: r(kWh),
                kWhLow: r(max(0, kWh - model.residualStd)), kWhHigh: r(kWh + model.residualStd), costNok: cost,
                knownPriceHours: knownHours, estimatedPriceHours: estimatedHours)
        }
    }

    /// Temperature at `date` from sorted forecast entries (linear between entries, flat at the ends).
    static func interpolated(_ hours: [ForecastHour], at date: Date) -> Double {
        let sorted = hours.sorted { $0.time < $1.time }
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        if date <= first.time { return first.temperature }
        if date >= last.time { return last.temperature }
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.time <= date && date <= b.time {
            let span = b.time.timeIntervalSince(a.time)
            guard span > 0 else { return a.temperature }
            return a.temperature + (b.temperature - a.temperature) * date.timeIntervalSince(a.time) / span
        }
        return last.temperature
    }
}
