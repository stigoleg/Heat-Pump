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
}

public struct HistoryPoint: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var value: Double?
    public var text: String?
    /// `snapshot` (polled state) or `log` (MELCloud temperature log).
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
