import Foundation

/// Parses and formats the timezone-less timestamps MELCloud Classic uses
/// (`2026-11-05T10:15:30`, `2026-11-05T10:15:30.123`, `2026-11-05`).
///
/// `LastCommunication`/`NextCommunication` are UTC; report and error-log
/// timestamps are building-local wall clock. The caller picks the zone.
public enum WireDate {
    public static func parse(_ text: String?, timeZone: TimeZone) -> Date? {
        guard var text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        // Explicit offsets are honoured when present.
        if text.hasSuffix("Z") || text.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil {
            if let date = try? Date(text, strategy: .iso8601) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            text = String(text.dropLast(text.hasSuffix("Z") ? 1 : 6))
        }
        let parts = text.split(separator: "T", maxSplits: 1).map(String.init)
        let dateParts = parts[0].split(separator: "-").compactMap { Int($0) }
        guard dateParts.count == 3 else { return nil }
        // Year-1 sentinel means "never set".
        if dateParts[0] <= 1 { return nil }
        var components = DateComponents()
        components.year = dateParts[0]
        components.month = dateParts[1]
        components.day = dateParts[2]
        components.hour = 0
        components.minute = 0
        components.second = 0
        if parts.count == 2 {
            let timeAndFraction = parts[1].split(separator: ".", maxSplits: 1).map(String.init)
            let timeParts = timeAndFraction[0].split(separator: ":").compactMap { Int($0) }
            guard timeParts.count >= 2 else { return nil }
            components.hour = timeParts[0]
            components.minute = timeParts[1]
            components.second = timeParts.count > 2 ? timeParts[2] : 0
            if timeAndFraction.count == 2, let fraction = Double("0." + timeAndFraction[1]) {
                components.nanosecond = Int(fraction * 1_000_000_000)
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)
    }

    /// `yyyy-MM-dd` in the given zone.
    public static func day(_ date: Date, timeZone: TimeZone) -> String {
        let c = calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `yyyy-MM-ddTHH:mm:ss` in the given zone.
    public static func localTimestamp(_ date: Date, timeZone: TimeZone) -> String {
        let c = calendar(timeZone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    public static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

extension Date {
    /// ISO 8601 with offset, suitable for JSON output.
    public var iso8601: String {
        formatted(Date.ISO8601FormatStyle(timeZone: .current))
    }
}

/// Norwegian (bokmål) display formatting for user-facing text.
public enum Norwegian {
    public static let locale = Locale(identifier: "nb_NO")

    public static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    public static func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }

    public static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    /// `String(format:)` with Norwegian decimal comma.
    public static func format(_ format: String, _ arguments: any CVarArg...) -> String {
        String(format: format, locale: locale, arguments: arguments)
    }
}
