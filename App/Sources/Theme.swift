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

enum Format {
    static func temperature(_ value: Double?) -> String {
        guard let value else { return "–" }
        return Norwegian.format("%.1f °C", value)
    }

    static func degrees(_ value: Double?) -> String {
        guard let value else { return "–" }
        return Norwegian.format("%.1f°", value)
    }

    static func kWh(_ value: Double) -> String { Norwegian.format("%.1f kWh", value) }

    static func kroner(_ value: Double?) -> String {
        guard let value else { return "–" }
        return Norwegian.format("%.2f kr", value)
    }

    static func ore(_ value: Double?) -> String {
        guard let value else { return "–" }
        return Norwegian.format("%.0f øre", value)
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return "—" }
        return Norwegian.format("%.0f W", value)
    }

    static func percent(_ value: Double) -> String {
        Norwegian.format("%+.0f %%", value)
    }

    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "ukjent" }
        if abs(now.timeIntervalSince(date)) < 45 { return "akkurat nå" }
        return date.formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide).locale(Norwegian.locale))
    }

    static func countdown(to date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds >= 3600 { return "\(seconds / 3600) t \(seconds % 3600 / 60) min" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func hour(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute().locale(Norwegian.locale))
    }

    static func dayMonth(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().day().month(.abbreviated).locale(Norwegian.locale))
    }
}
