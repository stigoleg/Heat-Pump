import Foundation

public struct ErrorLogEntry: Codable, Sendable, Equatable {
    public var deviceId: Int
    public var start: Date
    public var end: Date?
    public var message: String
    public var code: String?
    /// Where the entry came from, e.g. `melcloud` or `state` (derived from an active error flag).
    public var source: String

    public init(deviceId: Int, start: Date, end: Date? = nil, message: String, code: String? = nil, source: String = "melcloud") {
        self.deviceId = deviceId
        self.start = start
        self.end = end
        self.message = message
        self.code = code
        self.source = source
    }
}

public struct TemperaturePoint: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var room: Double?
    public var set: Double?
    public var outdoor: Double?

    public init(timestamp: Date, room: Double? = nil, set: Double? = nil, outdoor: Double? = nil) {
        self.timestamp = timestamp
        self.room = room
        self.set = set
        self.outdoor = outdoor
    }
}

public struct EnergyDay: Codable, Sendable, Equatable {
    /// Local calendar day, `yyyy-MM-dd`.
    public var day: String
    public var totalKWh: Double
    public var heatingKWh: Double?
    public var coolingKWh: Double?

    public init(day: String, totalKWh: Double, heatingKWh: Double? = nil, coolingKWh: Double? = nil) {
        self.day = day
        self.totalKWh = totalKWh
        self.heatingKWh = heatingKWh
        self.coolingKWh = coolingKWh
    }
}

public enum MaintenanceKind: String, Codable, Sendable, CaseIterable {
    case airFilter
    case deodorizingFilter
    case vBlockingFilter
    case professionalService
    case other

    public var displayName: String {
        switch self {
        case .airFilter: "Luftfilter"
        case .deodorizingFilter: "Luktfilter/luftrenser"
        case .vBlockingFilter: "V-blokkerende filter (grønt)"
        case .professionalService: "Service hos forhandler"
        case .other: "Annet"
        }
    }

    /// Recommended interval in days per the MSZ-RW owner manual (nil = no fixed interval).
    public var recommendedIntervalDays: Int? {
        switch self {
        case .airFilter: 14
        case .deodorizingFilter: 90
        case .vBlockingFilter: 90
        case .professionalService, .other: nil
        }
    }
}

public struct MaintenanceRecord: Codable, Sendable, Equatable {
    public var id: Int64?
    public var kind: MaintenanceKind
    public var timestamp: Date
    public var note: String?

    public init(id: Int64? = nil, kind: MaintenanceKind, timestamp: Date, note: String? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.note = note
    }
}

public enum ChangeSource: String, Codable, Sendable, CaseIterable {
    case app
    case claude
}

public enum ChangeResult: String, Codable, Sendable {
    /// Reserved against the change budget; send in progress (or the process died mid-send).
    case pending
    case ok
    case failed
    case rejected
}

public struct ChangeRecord: Codable, Sendable, Equatable {
    public var id: Int64?
    public var timestamp: Date
    public var source: ChangeSource
    public var field: String
    public var oldValue: String?
    public var newValue: String?
    public var reason: String?
    public var result: ChangeResult
    public var error: String?

    public init(
        id: Int64? = nil, timestamp: Date, source: ChangeSource, field: String, oldValue: String?,
        newValue: String?, reason: String?, result: ChangeResult, error: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.reason = reason
        self.result = result
        self.error = error
    }
}

public enum HealthSeverity: String, Codable, Sendable, Comparable, CaseIterable {
    case ok
    case info
    case warning
    case critical

    private var rank: Int {
        switch self {
        case .ok: 0
        case .info: 1
        case .warning: 2
        case .critical: 3
        }
    }

    public static func < (lhs: HealthSeverity, rhs: HealthSeverity) -> Bool { lhs.rank < rhs.rank }

    public var displayName: String {
        switch self {
        case .ok: "OK"
        case .info: "Til info"
        case .warning: "Advarsel"
        case .critical: "Kritisk"
        }
    }
}

/// One health observation. `title`, `detail` and `recommendation` are Norwegian display text;
/// `code` is stable and machine-readable.
public struct HealthFinding: Codable, Sendable, Equatable, Identifiable {
    public var id: String { code }
    public var code: String
    public var severity: HealthSeverity
    public var title: String
    public var detail: String
    public var recommendation: String

    public init(code: String, severity: HealthSeverity, title: String, detail: String, recommendation: String) {
        self.code = code
        self.severity = severity
        self.title = title
        self.detail = detail
        self.recommendation = recommendation
    }
}

public struct HealthReport: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var overall: HealthSeverity
    public var findings: [HealthFinding]

    public init(generatedAt: Date, findings: [HealthFinding]) {
        self.generatedAt = generatedAt
        self.findings = findings.sorted { $0.severity > $1.severity }
        self.overall = findings.map(\.severity).max() ?? .ok
    }
}
