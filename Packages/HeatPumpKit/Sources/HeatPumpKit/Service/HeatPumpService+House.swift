import Foundation

/// Result of a house-consumption update.
public struct HouseSync: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// No Tibber token.
        case notConfigured
        case fetched
        case skipped
        case failed
    }

    public var status: Status
    public var count: Int = 0
    public var message: String?
    public var nextAllowed: Date?
}

/// The whole house's electricity use from Tibber, and the heat pump's share of it.
extension HeatPumpService {
    public static let houseFetchKey = "house.tibber"
    /// Tibber's consumption is not real time; one request an hour is plenty.
    public static let houseInterval: TimeInterval = 3600

    /// Backfills up to 744 hours the first time, then fetches only the hours since the newest
    /// stored one (plus two, which Tibber may complete late). At most once an hour.
    public func syncHouseConsumption() async throws -> HouseSync {
        let t = now()
        switch try store.reserveFetch(key: Self.houseFetchKey, minInterval: Self.houseInterval, now: t, melcloud: false) {
        case .throttled(let next):
            return HouseSync(status: .skipped, nextAllowed: next)
        case .blocked, .credentialsRejected:
            return HouseSync(status: .skipped)
        case .allowed:
            guard let provider = houseProvider() else { return HouseSync(status: .notConfigured) }
            let last: Int
            if let latest = try store.latestHouseHour() {
                last = min(744, max(3, Int((t.timeIntervalSince(latest) / 3600).rounded(.up)) + 2))
            } else {
                last = 744
            }
            do {
                let hours = try await provider.fetchConsumption(lastHours: last)
                try store.upsertHouseHours(hours)
                try store.recordFetchSuccess(key: Self.houseFetchKey, now: t)
                return HouseSync(status: .fetched, count: hours.count)
            } catch {
                return HouseSync(status: .failed, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    public func houseHours(from: Date, to: Date) throws -> [HouseHour] {
        try store.houseHours(from: from, to: to)
    }

    /// House and heat pump per hour and per day. The heat pump's hours come from its exact local
    /// counter where it covers them, otherwise from MELCloud's counter (an estimate).
    public func houseShare(from: Date, to: Date) throws -> HouseShareSummary {
        let house = Dictionary(try store.houseHours(from: from, to: to).map { ($0.hour, $0) }, uniquingKeysWith: { a, _ in a })
        let pump = Dictionary(try hourlyConsumption(from: from, to: to).map { ($0.hour, $0) }, uniquingKeysWith: { a, _ in a })
        let calendar = WireDate.calendar(timeZone)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now()))
        return HouseShare.summarize(
            house: house, heatPump: pump, timeZone: timeZone, yesterday: yesterday.map { WireDate.day($0, timeZone: timeZone) })
    }
}
