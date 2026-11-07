import Foundation

/// What an air quality sensor's newest values call for. Pure; the service builds the findings
/// from stored data, and the app and the MCP helper show them.
///
/// Radon is judged by the long-term average against the Norwegian Radiation and Nuclear Safety
/// Authority's (DSA) values for the annual average: action level 100 Bq/m³, limit 200 Bq/m³.
/// Short-term values swing with weather and ventilation and are never a verdict on their own.
public enum AirQualityHealth {
    /// DSA's action level for the annual average radon concentration, Bq/m³.
    public static let radonActionLevel = 100.0
    /// DSA's limit value for the annual average radon concentration, Bq/m³.
    public static let radonLimit = 200.0
    /// Battery at or below this (%) is worth a reminder.
    public static let lowBattery = 10
    /// Readings older than this mean the sensor has stopped reporting.
    public static let staleAfter: TimeInterval = 6 * 3600

    /// Findings for a sensor's newest values, taken at `recorded`; `serviceName` names its service.
    public static func findings(
        values: [AirQualityValue], recorded: Date?, now: Date, serviceName: String
    ) -> [HealthFinding] {
        var findings: [HealthFinding] = []
        func value(_ metric: AirQualityMetric) -> AirQualityValue? { values.first { $0.metric == metric } }

        let longTerm = value(.radonLongTerm)?.value
        if let longTerm, longTerm >= radonLimit {
            findings.append(
                HealthFinding(
                    code: "air_radon_limit", severity: .critical, title: L10n.tr("Radon above the limit value"),
                    detail: L10n.format(
                        "The long-term radon average is %@. The limit value for the annual average is 200 Bq/m³.",
                        AirQualityMetric.radonLongTerm.formatted(longTerm)),
                    recommendation: L10n.tr(
                        "Measure for at least two months in the winter half-year to find the annual average, and plan radon measures (better ventilation, sealing, a radon sump). See the air quality document.")
                ))
        } else if let longTerm, longTerm >= radonActionLevel {
            findings.append(
                HealthFinding(
                    code: "air_radon_action", severity: .warning, title: L10n.tr("Radon above the action level"),
                    detail: L10n.format(
                        "The long-term radon average is %@. Measures are recommended when the annual average is 100 Bq/m³ or more.",
                        AirQualityMetric.radonLongTerm.formatted(longTerm)),
                    recommendation: L10n.tr(
                        "Keep measuring through the winter half-year (at least two months) to find the annual average, and consider simple measures such as better ventilation. See the air quality document.")
                ))
        } else if let short = value(.radonShortTerm), short.level == .poor {
            findings.append(
                HealthFinding(
                    code: "air_radon_short", severity: .info, title: L10n.tr("Short-term radon is high"),
                    detail: L10n.format(
                        "The short-term radon value is %@. It swings with weather and ventilation; the long-term average is what counts.",
                        AirQualityMetric.radonShortTerm.formatted(short.value)),
                    recommendation: L10n.tr("Air out and keep an eye on the long-term average over the coming weeks.")))
        }

        if let co2 = value(.co2), co2.level == .poor {
            findings.append(
                HealthFinding(
                    code: "air_co2_high", severity: .warning, title: L10n.tr("High CO₂"),
                    detail: L10n.format("CO₂ is %@: the air is stale, which can make you tired and give headaches.", AirQualityMetric.co2.formatted(co2.value)),
                    recommendation: L10n.tr("Air out, open a vent or turn up the ventilation, especially in bedrooms at night.")))
        }

        if let humidity = value(.humidity), humidity.level == .poor {
            // Poor is far below or far above the good range.
            let dry = humidity.value < 45
            findings.append(
                HealthFinding(
                    code: dry ? "air_humidity_low" : "air_humidity_high", severity: .warning,
                    title: dry ? L10n.tr("Very dry air") : L10n.tr("Very humid air"),
                    detail: dry
                        ? L10n.format("Humidity is %@. Very dry air can irritate eyes, skin and airways.", AirQualityMetric.humidity.formatted(humidity.value))
                        : L10n.format("Humidity is %@. Humid air over time gives a risk of mould and dust mites.", AirQualityMetric.humidity.formatted(humidity.value)),
                    recommendation: dry
                        ? L10n.tr("Lower the indoor temperature a little and avoid airing out for long in frost.")
                        : L10n.tr("Ventilate more, use the extractor fan when cooking and showering, and dry clothes outdoors.")))
        }

        for metric in [AirQualityMetric.voc, .pm25, .pm1] {
            guard let found = value(metric), found.level == .poor else { continue }
            findings.append(
                HealthFinding(
                    code: "air_\(metric.rawValue)_high", severity: .warning, title: L10n.format("High %@", metric.title),
                    detail: L10n.format("%@ is %@, which the sensor rates as poor.", metric.title, metric.formatted(found.value)),
                    recommendation: metric == .voc
                        ? L10n.tr("Air out and look for sources such as new furniture, paint, cleaning products or cooking.")
                        : L10n.tr("Air out when the outdoor air is clean, and look for sources such as candles, a wood stove or cooking.")))
        }

        if let battery = value(.battery), Int(battery.value.rounded()) <= lowBattery {
            findings.append(
                HealthFinding(
                    code: "air_battery_low", severity: .info, title: L10n.tr("Sensor battery low"),
                    detail: L10n.format("The battery is at %@.", AirQualityMetric.battery.formatted(battery.value)),
                    recommendation: L10n.tr("Change the batteries soon, or the sensor stops measuring.")))
        }

        if let recorded, now.timeIntervalSince(recorded) > staleAfter {
            findings.append(
                HealthFinding(
                    code: "air_stale", severity: .info, title: L10n.tr("No new readings"),
                    detail: L10n.format("The newest values are from %@.", Display.dateTime(recorded)),
                    recommendation: L10n.format(
                        "Check the sensor's batteries and its connection to %@ (through a hub, or by syncing it with the phone app).",
                        serviceName)))
        }
        return findings
    }
}
