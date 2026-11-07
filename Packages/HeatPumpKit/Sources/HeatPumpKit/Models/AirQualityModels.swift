import Foundation

/// What an air quality sensor measures, in display order. Values are always metric (`unit`); a
/// driver converts or asks its vendor for metric units.
public enum AirQualityMetric: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    /// Radon, the sensor's short-term value (a rolling average of about a day), Bq/m³.
    case radonShortTerm
    /// Radon, the sensor's long-term average (since it was set up, up to a year), Bq/m³.
    case radonLongTerm
    case co2
    case voc
    case pm25
    case pm1
    case humidity
    case temperature
    case pressure
    /// Battery charge, %.
    case battery

    /// The unit symbol (not translated).
    public var unit: String {
        switch self {
        case .radonShortTerm, .radonLongTerm: "Bq/m³"
        case .co2: "ppm"
        case .voc: "ppb"
        case .pm25, .pm1: "µg/m³"
        case .humidity, .battery: "%"
        case .temperature: "°C"
        case .pressure: "hPa"
        }
    }

    public var title: String {
        switch self {
        case .radonShortTerm: L10n.tr("Radon (short-term average)")
        case .radonLongTerm: L10n.tr("Radon (long-term average)")
        case .co2: L10n.tr("CO₂")
        case .voc: L10n.tr("VOC")
        case .pm25: L10n.tr("PM2.5")
        case .pm1: L10n.tr("PM1")
        case .humidity: L10n.tr("Humidity")
        case .temperature: L10n.tr("Temperature")
        case .pressure: L10n.tr("Air pressure")
        case .battery: L10n.tr("Battery")
        }
    }

    /// Decimals worth showing.
    public var fractionDigits: Int { self == .temperature ? 1 : 0 }

    /// `value` with its unit, e.g. "84 Bq/m³" (locale-aware).
    public func formatted(_ value: Double) -> String {
        Display.format(fractionDigits == 1 ? "%.1f" : "%.0f", value) + " " + unit
    }

    /// The radon values: the same thresholds and advice apply to both.
    public var isRadon: Bool { self == .radonShortTerm || self == .radonLongTerm }
}

/// How a value rates against its thresholds.
public enum AirQualityLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case good
    case fair
    case poor

    private var rank: Int {
        switch self {
        case .good: 0
        case .fair: 1
        case .poor: 2
        }
    }

    public static func < (lhs: AirQualityLevel, rhs: AirQualityLevel) -> Bool { lhs.rank < rhs.rank }

    public var title: String {
        switch self {
        case .good: L10n.tr("Good")
        case .fair: L10n.tr("Fair")
        case .poor: L10n.tr("Poor")
        }
    }
}

/// Values with `from <= value < to` rate as `level`; a nil bound is open.
public struct AirQualityRange: Codable, Sendable, Equatable {
    public var from: Double?
    public var to: Double?
    public var level: AirQualityLevel

    public init(from: Double?, to: Double?, level: AirQualityLevel) {
        self.from = from
        self.to = to
        self.level = level
    }

    public func contains(_ value: Double) -> Bool {
        (from.map { value >= $0 } ?? true) && (to.map { value < $0 } ?? true)
    }
}

/// The ranges a sensor's values are rated by. A metric without its own ranges uses
/// `standard`'s; the long-term radon average uses the short-term value's.
public struct AirQualityThresholds: Codable, Sendable, Equatable {
    public var ranges: [AirQualityMetric: [AirQualityRange]]
    /// How long the vendor allows the thresholds to be cached (its `Cache-Control`), if it said.
    public var maxAge: TimeInterval?

    public init(ranges: [AirQualityMetric: [AirQualityRange]], maxAge: TimeInterval? = nil) {
        self.ranges = ranges
        self.maxAge = maxAge
    }

    /// The defaults common consumer monitors use (radon 100/150 Bq/m³, CO2 800/1000 ppm, VOC
    /// 250/2000 ppb, PM 10/25 µg/m³, humidity 30–60 % good and 25–70 % fair, temperature 18–25 °C
    /// good). Pressure and battery are not rated.
    public static let standard = AirQualityThresholds(ranges: [
        .radonShortTerm: rising(100, 150),
        .co2: rising(800, 1000),
        .voc: rising(250, 2000),
        .pm25: rising(10, 25),
        .pm1: rising(10, 25),
        .humidity: [
            AirQualityRange(from: nil, to: 25, level: .poor), AirQualityRange(from: 25, to: 30, level: .fair),
            AirQualityRange(from: 30, to: 60, level: .good), AirQualityRange(from: 60, to: 70, level: .fair),
            AirQualityRange(from: 70, to: nil, level: .poor),
        ],
        .temperature: [
            AirQualityRange(from: nil, to: 18, level: .fair), AirQualityRange(from: 18, to: 25, level: .good),
            AirQualityRange(from: 25, to: nil, level: .fair),
        ],
    ])

    /// Good below `fair`, fair below `poor`, poor from there.
    static func rising(_ fair: Double, _ poor: Double) -> [AirQualityRange] {
        [
            AirQualityRange(from: nil, to: fair, level: .good), AirQualityRange(from: fair, to: poor, level: .fair),
            AirQualityRange(from: poor, to: nil, level: .poor),
        ]
    }

    /// The ranges `metric` is rated by: its own, else the standard ones.
    public func ranges(for metric: AirQualityMetric) -> [AirQualityRange] {
        Self.own(ranges, metric) ?? Self.own(Self.standard.ranges, metric) ?? []
    }

    private static func own(_ ranges: [AirQualityMetric: [AirQualityRange]], _ metric: AirQualityMetric) -> [AirQualityRange]? {
        let found = ranges[metric] ?? (metric == .radonLongTerm ? ranges[.radonShortTerm] : nil)
        return found?.isEmpty == false ? found : nil
    }

    /// How `value` of `metric` rates; nil when no range covers it (pressure, battery).
    public func level(_ metric: AirQualityMetric, _ value: Double) -> AirQualityLevel? {
        ranges(for: metric).first { $0.contains(value) }?.level
    }
}

/// A sensor's newest values as the service reported them.
public struct AirQualityReading: Codable, Sendable, Equatable {
    public var device: DeviceKey
    /// When the sensor took the values (nil when the service did not say).
    public var recorded: Date?
    public var values: [AirQualityMetric: Double]

    public init(device: DeviceKey, recorded: Date?, values: [AirQualityMetric: Double]) {
        self.device = device
        self.recorded = recorded
        self.values = values
    }
}

/// A sensor's averages over one hour.
public struct AirQualityHour: Codable, Sendable, Equatable {
    /// Start of the hour.
    public var hour: Date
    public var values: [AirQualityMetric: Double]

    public init(hour: Date, values: [AirQualityMetric: Double]) {
        self.hour = hour
        self.values = values
    }
}

/// One value with its level.
public struct AirQualityValue: Codable, Sendable, Equatable, Identifiable {
    public var metric: AirQualityMetric
    public var value: Double
    /// Nil for values that are not rated (pressure, battery).
    public var level: AirQualityLevel?
    public var id: AirQualityMetric { metric }

    public init(metric: AirQualityMetric, value: Double, level: AirQualityLevel?) {
        self.metric = metric
        self.value = value
        self.level = level
    }
}

/// A sensor at a glance (stored data only): the newest values with their levels and what to do
/// about them.
public struct AirQualityStatus: Codable, Sendable, Equatable {
    public var device: DeviceKey
    /// When the sensor took the values.
    public var recorded: Date?
    /// When they were fetched from the service.
    public var fetchedAt: Date?
    /// In `AirQualityMetric` order, battery included.
    public var values: [AirQualityValue]
    /// The worst level among the rated values (nil without any).
    public var worstLevel: AirQualityLevel?
    public var findings: [HealthFinding]
    /// Whether the levels come from the sensor's own thresholds (the user's settings in the
    /// vendor's app) rather than the standard ones.
    public var thresholdsFromDevice: Bool

    public init(
        device: DeviceKey, recorded: Date?, fetchedAt: Date?, values: [AirQualityValue], findings: [HealthFinding],
        thresholdsFromDevice: Bool
    ) {
        self.device = device
        self.recorded = recorded
        self.fetchedAt = fetchedAt
        self.values = values
        worstLevel = values.compactMap(\.level).max()
        self.findings = findings
        self.thresholdsFromDevice = thresholdsFromDevice
    }

    public func value(_ metric: AirQualityMetric) -> AirQualityValue? { values.first { $0.metric == metric } }

    /// Battery charge in %, when the sensor reports it.
    public var batteryPercent: Int? { value(.battery).map { Int($0.value.rounded()) } }
}
