import Foundation
import HeatPumpKit
import TibberIntegration

/// Demo: a simulated Tibber home with a real-time reader (`VARMEPUMPE_DEMO_DEVICES=…,meter`). Its
/// own integration, so texts name Tibber while the simulated heat pumps keep naming MELCloud.
public struct DemoMeterIntegration: Integration {
    public init() {}

    private var simulated: TibberIntegration { TibberIntegration() }

    /// `Integration.id`; the integration part of the simulated home's `DeviceKey`. Persisted.
    public static let id = "demo-meter"

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
        MockMeter(now: context.now)
    }
}

/// The simulated home: hours from `MockHouseConsumptionProvider`, and live power around the
/// current hour's use every 5 seconds. Never touches the network.
public actor MockMeter: EnergyMeterDriver, LivePowerDriver, MeterDemoSeeding {
    public nonisolated let identifier = "mock-meter"
    public static let device = DeviceKey(integration: DemoMeterIntegration.id, nativeId: "home")
    /// Seconds between simulated live readings.
    static let interval: TimeInterval = 5

    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// The simulated home as it is listed.
    public static var listing: [DeviceSummary] {
        [DeviceSummary(key: device, name: L10n.tr("Home (simulated)"), kind: .energyMeter, metadata: ["realTime": "true"])]
    }

    public nonisolated var capabilities: Set<Capability> { [.energyLog, .livePower] }

    public func login() async throws {}
    public func listDevices() async throws -> [DeviceSummary] { Self.listing }

    public func fetchHours(device: DeviceKey, lastHours: Int) async throws -> [HouseHour] {
        try await MockHouseConsumptionProvider(now: now).fetchConsumption(lastHours: lastHours)
    }

    /// Power at `date`: the hour's average with a slow wave and some flicker.
    static func powerW(at date: Date) -> Double {
        let hour = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        let average = MockHouseConsumptionProvider.hour(starting: hour).kWh * 1000
        let t = date.timeIntervalSince1970
        return max(150, average * (1 + 0.18 * sin(t / 420) + 0.06 * sin(t / 37)))
    }

    /// kWh since local midnight at `date`: the finished hours plus the share of the current one.
    static func consumptionToday(at date: Date) -> Double {
        let calendar = Calendar.current
        var hour = calendar.startOfDay(for: date)
        var total = 0.0
        while hour.addingTimeInterval(3600) <= date {
            total += MockHouseConsumptionProvider.hour(starting: hour).kWh
            hour = hour.addingTimeInterval(3600)
        }
        total += MockHouseConsumptionProvider.hour(starting: hour).kWh * date.timeIntervalSince(hour) / 3600
        return (total * 1000).rounded() / 1000
    }

    static func reading(at date: Date) -> LivePowerReading {
        LivePowerReading(at: date, powerW: (powerW(at: date)).rounded(), consumptionTodayKWh: consumptionToday(at: date), currency: "NOK")
    }

    public nonisolated func liveReadings(device: DeviceKey) -> AsyncStream<LivePowerEvent> {
        let now = now
        return AsyncStream { continuation in
            let task = Task {
                continuation.yield(.state(.live))
                while !Task.isCancelled {
                    continuation.yield(.reading(Self.reading(at: now())))
                    try? await Task.sleep(for: .seconds(Self.interval))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public nonisolated func demoLiveMinutes(device: DeviceKey, from: Date, to: Date) -> [LiveMinute] {
        var minutes: [LiveMinute] = []
        var minute = Date(timeIntervalSince1970: (from.timeIntervalSince1970 / 60).rounded(.down) * 60)
        while minute.addingTimeInterval(60) <= to {
            let samples = stride(from: 0.0, to: 60, by: Self.interval).map { Self.powerW(at: minute.addingTimeInterval($0)) }
            let last = minute.addingTimeInterval(55)
            minutes.append(
                LiveMinute(
                    minute: minute, powerW: (samples.reduce(0, +) / Double(samples.count)).rounded(), maxPowerW: samples.max() ?? 0,
                    consumptionTodayKWh: Self.consumptionToday(at: last), lastReading: last))
            minute = minute.addingTimeInterval(60)
        }
        return minutes
    }
}
