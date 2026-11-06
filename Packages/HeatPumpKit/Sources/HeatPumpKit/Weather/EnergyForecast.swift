import Foundation

/// Daily kWh explained by heating degree-days (base 17 °C, as in `HealthEngine`):
/// kWh = intercept + slope × degree-days, fitted by least squares.
public struct DegreeDayModel: Codable, Sendable, Equatable {
    public var intercept: Double
    public var slope: Double
    /// Standard deviation of the residuals (kWh); used for the "ca. a–b" range.
    public var residualStd: Double
    public var days: Int

    /// Fewest days with both kWh and outdoor temperature before an estimate is shown.
    public static let minDays = 10

    public func predict(degreeDays: Double) -> Double { max(0, intercept + slope * degreeDays) }

    /// Least-squares line through (degree-days, kWh), or nil with fewer than `minDays` days or
    /// without spread in the temperatures.
    public static func fit(_ points: [(degreeDays: Double, kWh: Double)]) -> DegreeDayModel? {
        guard points.count >= minDays else { return nil }
        let n = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.degreeDays } / n
        let meanY = points.reduce(0) { $0 + $1.kWh } / n
        let sxx = points.reduce(0) { $0 + pow($1.degreeDays - meanX, 2) }
        guard sxx > 1e-6 else { return nil }
        let sxy = points.reduce(0) { $0 + ($1.degreeDays - meanX) * ($1.kWh - meanY) }
        let slope = sxy / sxx
        let intercept = meanY - slope * meanX
        let sse = points.reduce(0) { $0 + pow($1.kWh - (intercept + slope * $1.degreeDays), 2) }
        let std = points.count > 2 ? sqrt(sse / (n - 2)) : 0
        return DegreeDayModel(intercept: intercept, slope: slope, residualStd: std, days: points.count)
    }

    /// Heating degree-days of a day with mean outdoor temperature `mean`.
    public static func degreeDays(mean: Double) -> Double { max(0, HealthEngine.Threshold.degreeDayBase - mean) }
}

/// Expected use and cost tomorrow.
public struct TomorrowEstimate: Codable, Sendable, Equatable {
    /// `yyyy-MM-dd`
    public var day: String
    public var kWh: Double
    public var kWhLow: Double
    public var kWhHigh: Double
    public var costNok: Double?
    public var costLowNok: Double?
    public var costHighNok: Double?
    public var meanOutdoor: Double
    public var minOutdoor: Double
    /// Days the model was fitted on.
    public var basisDays: Int
    /// True when tomorrow's spot prices are not out yet and today's hourly prices were used instead.
    public var pricesFromToday: Bool

    /// "Anslag i morgen: ~12 kWh · ~14 kr"
    public var shortText: String {
        "Anslag i morgen: ~" + Display.format("%.0f kWh", kWh) + (costNok.map { Display.format(" · ~%.0f kr", $0) } ?? "")
    }
}

public enum EnergyForecast {
    /// Weight of each hour of a day when its kWh are spread out: degrees below 17 °C, with a small
    /// floor so mild hours are not free.
    static func hourWeights(_ temperatures: [Double]) -> [Double] {
        temperatures.map { max(0.5, HealthEngine.Threshold.degreeDayBase - $0) }
    }

    /// Cost of `kWh` spread over `hours` (temperature, price øre/kWh) by `hourWeights`.
    static func cost(kWh: Double, hours: [(temperature: Double, priceOre: Double)]) -> Double? {
        guard !hours.isEmpty else { return nil }
        let weights = hourWeights(hours.map(\.temperature))
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }
        return zip(weights, hours).reduce(0) { $0 + kWh * $1.0 / total * $1.1.priceOre / 100 }
    }
}
