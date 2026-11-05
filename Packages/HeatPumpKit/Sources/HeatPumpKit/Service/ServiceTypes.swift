import Foundation

/// Current state plus freshness metadata. Never hides that data may be old.
public struct StateResult: Codable, Sendable, Equatable {
    public var state: DeviceState?
    public var fetchedAt: Date?
    public var dataAgeSeconds: Int?
    /// True when this call actually reached the backend.
    public var refreshed: Bool
    /// True when the returned data is older than requested or invalidated by a change.
    public var stale: Bool
    /// Set while MELCloud has blocked us; no network calls happen until then.
    public var blockedUntil: Date?
    /// Set when a refresh was skipped because another refresh happened < 60 s ago.
    public var nextRefreshAllowed: Date?
    /// Norwegian error text from the last refresh attempt, if it failed.
    public var error: String?
    /// True when credentials are missing or MELCloud refused them; show the login screen.
    public var needsLogin: Bool = false
    /// Why requests are blocked (set together with `blockedUntil`).
    public var blockReason: BlockReason?
    /// Norwegian text for the block or credential stop, chosen from the reason.
    public var blockMessage: String?
}

public struct ChangeOutcome: Codable, Sendable, Equatable {
    public var result: ChangeResult
    /// Norwegian summary for display.
    public var message: String
    public var field: String
    public var oldValue: String?
    public var newValue: String?
    public var nextAllowed: Date?
    public var blockedUntil: Date?
}

public enum ReportKind: String, Codable, Sendable, CaseIterable {
    case errorLog
    case temperatureLog
    case energy
}

public struct ReportSync: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case fetched, skipped, blocked, failed
    }

    public var kind: ReportKind
    public var status: Status
    public var count: Int
    public var message: String?
    public var nextAllowed: Date?
}

public enum HistoryMetric: String, Codable, Sendable, CaseIterable {
    case roomTemperature = "room_temperature"
    case outdoorTemperature = "outdoor_temperature"
    case setTemperature = "set_temperature"
    case mode
    case power
    /// Electrical power in W from the local adapter.
    case powerW = "power_w"
    /// Compressor frequency in Hz from the local adapter.
    case compressorHz = "compressor_hz"
    /// Minutes of defrost per hour from the local adapter (`text` gives the number of defrosts).
    case defrost

    /// Metrics that come from local adapter readings instead of MELCloud.
    public var isLocal: Bool { self == .powerW || self == .compressorHz || self == .defrost }
}

public struct HistoryPoint: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var value: Double?
    public var text: String?
    /// `snapshot` (polled state), `log` (MELCloud temperature log) or `local` (Wi-Fi adapter on
    /// the home network; averaged per bucket when there are many readings).
    public var source: String
}

public enum EnergyPeriod: String, Codable, Sendable, CaseIterable {
    case day, week, month
}

public struct EnergyBucket: Codable, Sendable, Equatable {
    /// `yyyy-MM-dd` (day), first day of ISO week (week) or `yyyy-MM` (month).
    public var period: String
    public var totalKWh: Double
    public var heatingKWh: Double
    public var days: Int
    /// Total cost in NOK (nil when no prices are known for the period).
    public var costNok: Double?
    /// True when part of the cost uses a day's average price instead of hourly use × hourly price,
    /// or some days in the period lack prices.
    public var isEstimate: Bool = false
    /// Cost split into electricity, grid tariff and support.
    public var cost: CostSplit?
    /// kWh per mode as MELCloud reports it (nil for days MELCloud has no report for). Days the
    /// local counter measured keep MELCloud's split, so the sum may differ slightly from `totalKWh`.
    public var modes: EnergyModeSplit?
}

public struct MaintenanceStatus: Codable, Sendable, Equatable {
    public var kind: MaintenanceKind
    public var displayName: String
    public var lastDone: Date?
    public var daysSince: Int?
    public var recommendedIntervalDays: Int?
    /// `ok`, `due`, `overdue`, `unknown` or `not_applicable`.
    public var status: String
    public var note: String?
    /// Last done + recommended interval (nil when unknown or no fixed interval).
    public var nextDue: Date?
    public init(
        kind: MaintenanceKind, displayName: String, lastDone: Date? = nil, daysSince: Int? = nil,
        recommendedIntervalDays: Int? = nil, status: String, note: String? = nil, nextDue: Date? = nil
    ) {
        self.kind = kind
        self.displayName = displayName
        self.lastDone = lastDone
        self.daysSince = daysSince
        self.recommendedIntervalDays = recommendedIntervalDays
        self.status = status
        self.note = note
        self.nextDue = nextDue
    }
}

/// Temperature points for charts and where they come from.
public struct TemperatureHistory: Sendable, Equatable {
    public var points: [TemperaturePoint]
    /// False when MELCloud's temperature log had nothing and the points are the app's own snapshots.
    public var fromMELCloud: Bool

    public init(points: [TemperaturePoint], fromMELCloud: Bool) {
        self.points = points
        self.fromMELCloud = fromMELCloud
    }
}

/// How many writes are left in the rolling hour and when the next one may go out.
public struct WriteBudget: Codable, Sendable, Equatable {
    public var remaining: Int
    /// Set when a write now would be refused (spacing or budget); nil when one may go out now.
    public var nextAllowed: Date?

    public init(remaining: Int, nextAllowed: Date? = nil) {
        self.remaining = remaining
        self.nextAllowed = nextAllowed
    }
}
