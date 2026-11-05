import Foundation

/// Estimated spot price for one hour (øre/kWh excl. VAT): the point estimate and the middle half
/// (25th–75th percentile) of what the method's own past errors suggest.
public struct SpotEstimate: Sendable, Equatable {
    public var hour: Date
    public var median: Double
    public var low: Double
    public var high: Double
}

/// The estimate for the hours after the last known price.
public struct SpotEstimateResult: Sendable, Equatable {
    public var hours: [SpotEstimate]
    /// Complete days of prices the estimate is built on.
    public var basisDays: Int
    /// Øre per °C applied to the daily level; nil when the temperature effect was not used.
    public var temperatureSlope: Double?
    /// Correlation between daily mean price and daily mean temperature (nil with too few days).
    public var correlation: Double?
}

/// Rough spot-price estimate for the days after the published prices. Pure and deterministic.
///
/// Method: the shape of a day is the median, per hour of day and for weekdays and weekends /
/// public holidays separately, of each hour's price relative to its day's mean over the last
/// 28 days. The level is the mean of the last 7 days. When the daily mean price over the last
/// 30 days follows the outdoor temperature (|r| ≥ 0.4, at least 14 days), the level is moved by
/// the regression slope times the forecast's difference from the last 7 days' mean temperature.
/// The band is the 25th–75th percentile of the method's errors when it is replayed on the past
/// days (each predicted from the 7 days before it).
public enum PriceEstimator {
    /// Fewest complete days of prices before an estimate is made.
    public static let minDays = 14
    static let profileDays = 28
    static let levelDays = 7
    static let regressionDays = 30
    static let minCorrelation = 0.4
    /// Days whose mean is this low (øre) are left out of the shape (ratios would explode).
    static let ratioFloor = 5.0

    /// Estimates every hour with `from <= hour < to` from `history` (stored spot prices) and daily
    /// mean outdoor temperatures keyed by local start of day (past days and forecast days).
    /// Nil with fewer than `minDays` complete days of prices before `from`.
    public static func estimate(
        history: [HourPrice], dayTemperatures: [Date: Double], from: Date, to: Date, timeZone: TimeZone
    ) -> SpotEstimateResult? {
        let calendar = WireDate.calendar(timeZone)
        let firstDay = calendar.startOfDay(for: from)
        // Complete days (≥ 20 hours) before the first estimated day.
        let byDay = Dictionary(grouping: history.filter { $0.hour < firstDay }) { calendar.startOfDay(for: $0.hour) }
            .filter { $0.value.count >= 20 }
        let days = byDay.keys.sorted().suffix(regressionDays)
        guard days.count >= minDays else { return nil }
        let means = Dictionary(uniqueKeysWithValues: days.map { day in
            (day, byDay[day]!.reduce(0) { $0 + $1.spotOre } / Double(byDay[day]!.count))
        })

        func isWeekend(_ date: Date) -> Bool {
            calendar.isDateInWeekend(date) || NorwegianHolidays.isHoliday(date, timeZone: timeZone)
        }
        struct Key: Hashable {
            var weekend: Bool
            var hour: Int
        }

        // Shape: median ratio to the day's mean per (weekday/weekend, hour of day).
        var ratios: [Key: [Double]] = [:]
        var anyDay: [Int: [Double]] = [:]
        for day in days.suffix(profileDays) {
            guard let mean = means[day], mean > ratioFloor else { continue }
            for price in byDay[day]! {
                let hour = calendar.component(.hour, from: price.hour)
                ratios[Key(weekend: isWeekend(day), hour: hour), default: []].append(price.spotOre / mean)
                anyDay[hour, default: []].append(price.spotOre / mean)
            }
        }
        let profile = ratios.mapValues { quantile($0, 0.5) }
        let anyProfile = anyDay.mapValues { quantile($0, 0.5) }
        func ratio(_ date: Date) -> Double {
            let hour = calendar.component(.hour, from: date)
            return profile[Key(weekend: isWeekend(date), hour: hour)] ?? anyProfile[hour] ?? 1
        }

        // Temperature effect on the daily level.
        let pairs = days.compactMap { day in dayTemperatures[day].map { (t: $0, p: means[day]!) } }
        var slope: Double?
        var correlation: Double?
        if pairs.count >= minDays {
            let n = Double(pairs.count)
            let mt = pairs.reduce(0) { $0 + $1.t } / n
            let mp = pairs.reduce(0) { $0 + $1.p } / n
            let stt = pairs.reduce(0) { $0 + pow($1.t - mt, 2) }
            let spp = pairs.reduce(0) { $0 + pow($1.p - mp, 2) }
            let stp = pairs.reduce(0) { $0 + ($1.t - mt) * ($1.p - mp) }
            if stt > 1e-9, spp > 1e-9 {
                let r = stp / sqrt(stt * spp)
                correlation = r
                if abs(r) >= minCorrelation { slope = stp / stt }
            }
        }

        /// Level of `day` from the `levelDays` complete days before it (in `days`).
        func level(for day: Date, before: [Date]) -> Double? {
            let basis = Array(before.suffix(levelDays))
            guard !basis.isEmpty else { return nil }
            let mean = basis.reduce(0) { $0 + means[$1]! } / Double(basis.count)
            guard let slope, let target = dayTemperatures[day] else { return mean }
            let temps = basis.compactMap { dayTemperatures[$0] }
            guard !temps.isEmpty else { return mean }
            return mean + slope * (target - temps.reduce(0, +) / Double(temps.count))
        }

        // Replay on the past: each day after the first 7 predicted from the 7 days before it.
        var residuals: [Double] = []
        let ordered = Array(days)
        for index in ordered.indices where index >= levelDays {
            let day = ordered[index]
            guard let level = level(for: day, before: Array(ordered[..<index])) else { continue }
            for price in byDay[day]! { residuals.append(price.spotOre - level * ratio(price.hour)) }
        }
        let lowOffset = residuals.isEmpty ? 0 : quantile(residuals, 0.25)
        let highOffset = residuals.isEmpty ? 0 : quantile(residuals, 0.75)

        var hours: [SpotEstimate] = []
        guard var hour = calendar.dateInterval(of: .hour, for: from)?.start else { return nil }
        var levels: [Date: Double] = [:]
        while hour < to {
            let day = calendar.startOfDay(for: hour)
            if levels[day] == nil { levels[day] = level(for: day, before: ordered) }
            if let level = levels[day] {
                let median = level * ratio(hour)
                hours.append(
                    SpotEstimate(hour: hour, median: median, low: min(median, median + lowOffset), high: max(median, median + highOffset)))
            }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { break }
            hour = next
        }
        return SpotEstimateResult(hours: hours, basisDays: days.count, temperatureSlope: slope, correlation: correlation)
    }

    /// Linearly interpolated quantile `q` (0…1) of `values` (not empty).
    static func quantile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}
