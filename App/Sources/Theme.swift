import HeatPumpKit
import SwiftUI

/// Design tokens, defined once. Inspired by Astryx: calm spacing, grouping by whitespace,
/// status by leading icons (never tinted surfaces), four categorical data colours.
enum Theme {
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 8
        static let card: CGFloat = 14
        static let large: CGFloat = 20
    }

    /// Categorical data colours (system colours adapt to light and dark mode).
    enum Data {
        static let blue = Color.blue
        static let green = Color.green
        static let orange = Color.orange
        static let purple = Color.purple
        /// Inside temperature, cost.
        static let inside = orange
        static let outside = blue
        static let setpoint = Color.secondary
        static let energy = Color.teal
        static let gridTariff = purple
        static let electricity = blue
        static let support = green
        static let previous = Color.gray.opacity(0.7)
    }

    /// Semantic status colours.
    enum Status {
        static let good = Color.green
        static let caution = Color.orange
        static let bad = Color.red
        static let info = Color.blue
        static let neutral = Color.secondary
    }

    /// Card surface: neutral, never tinted by status.
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.primary.opacity(0.08)
}

extension OperationMode {
    var systemImage: String {
        switch self {
        case .heat: "flame.fill"
        case .cool: "snowflake"
        case .dry: "humidity.fill"
        case .fan: "fan.fill"
        case .auto: "a.circle.fill"
        }
    }

    /// Mode tint for the dial and charts.
    var tint: Color {
        switch self {
        case .heat: .orange
        case .cool: .blue
        case .dry: .teal
        case .fan: .gray
        case .auto: .purple
        }
    }

    /// Gradient along the dial arc.
    var gradient: [Color] {
        switch self {
        case .heat: [.orange, .red]
        case .cool: [.cyan, .blue]
        case .dry: [.mint, .teal]
        case .fan: [.gray.opacity(0.6), .gray]
        case .auto: [.indigo, .purple]
        }
    }
}

extension LocalPhase {
    var tint: Color {
        switch self {
        case .defrost: .cyan
        case .preheat, .warmup: .yellow
        case .standby, .resting, .off: .secondary
        case .heating: .orange
        case .cooling: .blue
        case .drying: .teal
        case .fan: .gray
        case .running: .purple
        }
    }
}

extension LocalPhaseSpan.Kind {
    var color: Color {
        switch self {
        // Distinct from the mode colours (orange heat, teal dry, blue cool, purple auto).
        case .running: Color.indigo.opacity(0.75)
        case .rest: Color.gray.opacity(0.35)
        case .defrost: Color.pink.opacity(0.85)
        case .startup: Color.yellow.opacity(0.8)
        case .off: Color.gray.opacity(0.15)
        case .unknown: Color.gray.opacity(0.1)
        }
    }
}

extension PriceLevel {
    var color: Color {
        switch self {
        case .veryCheap: .green
        case .cheap: .mint
        case .normal: Theme.Data.purple
        case .expensive: .orange
        case .veryExpensive: .red
        }
    }
}

extension HealthSeverity {
    var color: Color {
        switch self {
        case .ok: Theme.Status.good
        case .info: Theme.Status.info
        case .warning: Theme.Status.caution
        case .critical: Theme.Status.bad
        }
    }

    var systemImage: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
}

extension AirQualityLevel {
    var color: Color {
        switch self {
        case .good: Theme.Status.good
        case .fair: Theme.Status.caution
        case .poor: Theme.Status.bad
        }
    }

    var systemImage: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .fair: "exclamationmark.circle.fill"
        case .poor: "exclamationmark.triangle.fill"
        }
    }
}

extension AirQualityMetric {
    var systemImage: String {
        switch self {
        case .radonShortTerm, .radonLongTerm: "atom"
        case .co2: "carbon.dioxide.cloud.fill"
        case .voc: "aqi.medium"
        case .pm25, .pm1: "aqi.low"
        case .humidity: "humidity.fill"
        case .temperature: "thermometer.medium"
        case .pressure: "gauge.with.dots.needle.50percent"
        case .battery: "battery.75percent"
        }
    }

    /// The chart colour; temperature keeps the indoor colour.
    var tint: Color {
        switch self {
        case .radonShortTerm, .radonLongTerm: Theme.Data.purple
        case .co2: Theme.Data.energy
        case .voc, .pm25, .pm1: Theme.Data.green
        case .humidity: Theme.Data.blue
        case .temperature: Theme.Data.inside
        case .pressure, .battery: .secondary
        }
    }
}

enum Format {
    static func temperature(_ value: Double?) -> String {
        guard let value else { return "–" }
        return Display.format("%.1f °C", value)
    }

    static func degrees(_ value: Double?) -> String {
        guard let value else { return "–" }
        return Display.format("%.1f°", value)
    }

    static func kWh(_ value: Double) -> String { Display.format("%.1f kWh", value) }

    static func kroner(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(localized: "\(Display.format("%.2f", value)) NOK")
    }

    static func ore(_ value: Double?) -> String {
        guard let value else { return "–" }
        return Display.format("%.0f øre", value)
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return "—" }
        return Display.format("%.0f W", value)
    }

    /// 0…1 as "42 %".
    static func percentShare(_ value: Double) -> String {
        Display.format("%.0f %%", value * 100)
    }

    static func percent(_ value: Double) -> String {
        Display.format("%+.0f %%", value)
    }

    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return String(localized: "unknown") }
        if abs(now.timeIntervalSince(date)) < 45 { return String(localized: "just now") }
        return date.formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide).locale(Display.locale))
    }

    static func countdown(to date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds >= 3600 { return String(localized: "\(seconds / 3600) h \(seconds % 3600 / 60) min") }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func hour(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().hour(.twoDigits(amPM: .abbreviated)).minute().locale(Display.locale))
    }

    /// "tor. 14" (weekday and hour).
    static func weekdayHour(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().weekday(.abbreviated).hour(.twoDigits(amPM: .abbreviated)).locale(Display.locale))
    }

    static func dayMonth(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().day().month(.abbreviated).locale(Display.locale))
    }
}
