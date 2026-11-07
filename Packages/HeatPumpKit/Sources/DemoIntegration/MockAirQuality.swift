import AirthingsIntegration
import Foundation
import HeatPumpKit

/// Demo: a simulated Airthings Wave Plus (`VARMEPUMPE_DEMO_DEVICES=…,airthings`). Its own
/// integration, so texts and documents are Airthings' while the simulated heat pumps keep naming
/// MELCloud.
public struct DemoAirQualityIntegration: Integration {
    public init() {}

    private var simulated: AirthingsIntegration { AirthingsIntegration() }

    /// `Integration.id`; the integration part of the simulated sensor's `DeviceKey`. Persisted.
    public static let id = "demo-airquality"

    public var id: String { Self.id }
    public var displayName: String { simulated.displayName }
    public var vendorName: String { "Simulated" }
    public var brandName: String { simulated.brandName }
    public var unitDescription: String { simulated.unitDescription }
    public var credentialFields: [CredentialField] { [] }
    public var rateLimitPolicy: RateLimitPolicy { simulated.rateLimitPolicy }
    public var errorCodes: any ErrorCodeExplaining { simulated.errorCodes }
    public var knowledge: KnowledgeSource { simulated.knowledge }

    public func makeConnection(_ context: IntegrationContext) throws -> any DeviceConnection {
        MockAirQualitySensor(now: context.now)
    }
}

/// The simulated Wave Plus in the basement: radon between about 60 and 140 Bq/m³ with a long-term
/// average just above the action level, CO2 that rises at night, and humidity, temperature, VOC and
/// air pressure that follow the day and the weather. A pure function of time; never touches the
/// network.
public actor MockAirQualitySensor: AirQualityDriver, AirQualityLogReporting, AirQualityDemoSeeding {
    public nonisolated let identifier = "mock-airquality"
    public static let device = DeviceKey(integration: DemoAirQualityIntegration.id, nativeId: "2930000001")

    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// The simulated sensor as it is listed.
    public static var listing: [DeviceSummary] {
        [DeviceSummary(key: device, name: L10n.tr("Basement (simulated)"), kind: .airQualitySensor, metadata: ["type": "WAVE_PLUS"])]
    }

    public nonisolated var capabilities: Set<Capability> { [.airQuality, .airQualityLog] }
    public nonisolated var maxAirQualityLogDays: Int { 200 }

    public func login() async throws {}
    public func listDevices() async throws -> [DeviceSummary] { Self.listing }

    public func fetchLatest(devices: [DeviceKey]) async throws -> [AirQualityReading] {
        let t = now()
        // The sensor reported at the last 5-minute mark.
        let recorded = Date(timeIntervalSince1970: (t.timeIntervalSince1970 / 300).rounded(.down) * 300)
        return devices.filter { $0 == Self.device }.map {
            var values = Self.values(at: recorded)
            values[.battery] = 78
            return AirQualityReading(device: $0, recorded: recorded, values: values)
        }
    }

    public func fetchHourly(device: DeviceKey, range: DateInterval) async throws -> [AirQualityHour] {
        demoHours(device: device, from: range.start, to: min(range.end, now()))
    }

    public func fetchThresholds(device: DeviceKey) async throws -> AirQualityThresholds? { nil }

    public nonisolated func demoHours(device: DeviceKey, from: Date, to: Date) -> [AirQualityHour] {
        guard device == Self.device else { return [] }
        var hours: [AirQualityHour] = []
        var hour = Date(timeIntervalSince1970: (from.timeIntervalSince1970 / 3600).rounded(.up) * 3600)
        while hour < to {
            hours.append(AirQualityHour(hour: hour, values: Self.values(at: hour.addingTimeInterval(1800))))
            hour = hour.addingTimeInterval(3600)
        }
        return hours
    }

    /// The simulated values at `date`.
    static func values(at date: Date) -> [AirQualityMetric: Double] {
        let t = date.timeIntervalSince1970
        let day = 86_400.0
        let hourOfDay = Calendar.current.component(.hour, from: date)
        // Radon: weather fronts every few days on top of a winter high.
        let season = cos(2 * .pi * (t / (365.25 * day) - 0.03))  // 1 in January, −1 in July
        let radon = 92 + 22 * season + 30 * sin(2 * .pi * t / (4.7 * day)) + 9 * sin(2 * .pi * t / (0.9 * day))
        let longTerm = 104 + 8 * sin(2 * .pi * t / (40 * day))
        // CO2: climbs through the night with the bedroom door shut, aired out in the morning.
        let night = hourOfDay >= 22 || hourOfDay < 7
        let hoursIntoNight = Double((hourOfDay + 2) % 24)
        let co2 = night ? 620 + 60 * hoursIntoNight : 560 + 40 * sin(2 * .pi * Double(hourOfDay) / 24)
        let humidity = 36 + 6 * sin(2 * .pi * t / day) - 5 * season
        let temperature = 20.4 + 0.9 * sin(2 * .pi * (t / day - 0.3))
        let pressure = 1009 + 11 * sin(2 * .pi * t / (4.7 * day))
        let voc = 140 + 70 * max(0, sin(2 * .pi * (t / day - 0.7)))
        return [
            .radonShortTerm: max(20, radon).rounded(), .radonLongTerm: longTerm.rounded(), .co2: co2.rounded(),
            .voc: voc.rounded(), .humidity: humidity.rounded(), .temperature: (temperature * 10).rounded() / 10,
            .pressure: (pressure * 10).rounded() / 10,
        ]
    }
}
