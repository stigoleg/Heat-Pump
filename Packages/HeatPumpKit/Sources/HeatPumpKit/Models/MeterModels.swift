import Foundation

/// One reading of a meter's live power stream (`LivePowerDriver`). Frames may leave fields out.
public struct LivePowerReading: Codable, Sendable, Equatable {
    public var at: Date
    /// Power drawn from the grid now, in W.
    public var powerW: Double
    /// kWh used since local midnight (the meter's own counter), when the frame has it.
    public var consumptionTodayKWh: Double?
    /// What the service says today's use cost so far (needs a power deal with it); nil otherwise.
    public var costToday: Double?
    public var currency: String?
    /// Power fed into the grid now (solar), in W.
    public var productionW: Double?

    public init(
        at: Date, powerW: Double, consumptionTodayKWh: Double? = nil, costToday: Double? = nil, currency: String? = nil,
        productionW: Double? = nil
    ) {
        self.at = at
        self.powerW = powerW
        self.consumptionTodayKWh = consumptionTodayKWh
        self.costToday = costToday
        self.currency = currency
        self.productionW = productionW
    }
}

/// Why a live stream stopped for good (it is not retried until the app starts it again).
public enum LivePowerStop: String, Codable, Sendable, Equatable {
    /// The service refused the sign-in values.
    case unauthorized
    /// The service does not know the meter (anymore).
    case notFound
    /// The meter has no live data (no real-time device paired).
    case notAvailable

    /// Display text naming the meter's service.
    public func message(serviceName: String) -> String {
        switch self {
        case .unauthorized: L10n.format("%@ did not accept the token, so live power is off. Check the token in Settings.", serviceName)
        case .notFound: L10n.format("%@ no longer knows this home, so live power is off.", serviceName)
        case .notAvailable: L10n.format("%@ has no live power for this home. It needs a real-time meter reader.", serviceName)
        }
    }
}

/// The state of a live power stream.
public enum LivePowerState: Sendable, Equatable {
    case connecting
    /// Connected; readings arrive.
    case live
    /// Waiting before the next attempt (after a dropped connection or a silence).
    case waiting(until: Date)
    case stopped(LivePowerStop)
}

/// What a live power stream delivers.
public enum LivePowerEvent: Sendable, Equatable {
    case reading(LivePowerReading)
    case state(LivePowerState)
}

/// One minute of live power as stored (`meter_live`, kept for 48 hours), so the trend survives
/// a restart and the MCP helper can answer without a connection of its own.
public struct LiveMinute: Codable, Sendable, Equatable {
    /// Start of the minute.
    public var minute: Date
    /// Average of the minute's readings, in W.
    public var powerW: Double
    public var maxPowerW: Double
    /// The meter's kWh since midnight at the minute's last reading, when known.
    public var consumptionTodayKWh: Double?
    /// When the minute's last reading was taken.
    public var lastReading: Date

    public init(minute: Date, powerW: Double, maxPowerW: Double, consumptionTodayKWh: Double?, lastReading: Date) {
        self.minute = minute
        self.powerW = powerW
        self.maxPowerW = maxPowerW
        self.consumptionTodayKWh = consumptionTodayKWh
        self.lastReading = lastReading
    }
}

/// A meter's use and cost today: finished hours from the hourly data, the rest of the day from
/// the live counter where there is one.
public struct MeterToday: Codable, Sendable, Equatable {
    public var kWh: Double
    /// Priced like everything else in the app (agreement, grid tariff, subsidy); nil without prices.
    public var cost: CostSplit?
    /// Per hour, oldest first.
    public var hours: [HourCost]
    /// Hours of today counted (finished or live).
    public var hoursCovered: Int
    /// True when part of today came from the live counter (hourly data arrives late).
    public var includesLive: Bool
}

/// A meter at a glance (the MCP `get_meter_status` tool and the app).
public struct MeterStatus: Codable, Sendable, Equatable {
    public var device: DeviceKey
    /// The newest stored live minute (nil without live data).
    public var live: LiveMinute?
    public var today: MeterToday
    /// The price of the current hour (øre/kWh incl. grid tariff and subsidy).
    public var priceNowOre: Double?
    /// The newest finished hour the service reported.
    public var latestHour: Date?
    public var hasLivePower: Bool
}
