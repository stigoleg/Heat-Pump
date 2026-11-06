import Foundation

public struct ErrorLogEntry: Codable, Sendable, Equatable {
    public var device: DeviceKey
    public var start: Date
    public var end: Date?
    public var message: String
    public var code: String?
    /// Where the entry came from, e.g. `melcloud` or `state` (derived from an active error flag).
    public var source: String

    /// `source` is the producing integration's `sourceTag`.
    public init(device: DeviceKey, start: Date, end: Date? = nil, message: String, code: String? = nil, source: String) {
        self.device = device
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
    /// The other modes of MELCloud's `EnergyCost/Report` (nil when not reported).
    public var autoKWh: Double?
    public var dryKWh: Double?
    public var fanKWh: Double?
    public var otherKWh: Double?

    public init(
        day: String, totalKWh: Double, heatingKWh: Double? = nil, coolingKWh: Double? = nil, autoKWh: Double? = nil,
        dryKWh: Double? = nil, fanKWh: Double? = nil, otherKWh: Double? = nil
    ) {
        self.day = day
        self.totalKWh = totalKWh
        self.heatingKWh = heatingKWh
        self.coolingKWh = coolingKWh
        self.autoKWh = autoKWh
        self.dryKWh = dryKWh
        self.fanKWh = fanKWh
        self.otherKWh = otherKWh
    }
}

/// kWh per operation mode as MELCloud's `EnergyCost/Report` splits it.
public struct EnergyModeSplit: Codable, Sendable, Equatable {
    public var heatingKWh: Double = 0
    public var coolingKWh: Double = 0
    public var autoKWh: Double = 0
    public var dryKWh: Double = 0
    public var fanKWh: Double = 0
    public var otherKWh: Double = 0

    public init() {}

    public var totalKWh: Double { heatingKWh + coolingKWh + autoKWh + dryKWh + fanKWh + otherKWh }

    mutating func add(_ day: EnergyDay) {
        heatingKWh += day.heatingKWh ?? 0
        coolingKWh += day.coolingKWh ?? 0
        autoKWh += day.autoKWh ?? 0
        dryKWh += day.dryKWh ?? 0
        fanKWh += day.fanKWh ?? 0
        otherKWh += day.otherKWh ?? 0
    }

    func rounded() -> EnergyModeSplit {
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        var out = EnergyModeSplit()
        (out.heatingKWh, out.coolingKWh, out.autoKWh) = (r(heatingKWh), r(coolingKWh), r(autoKWh))
        (out.dryKWh, out.fanKWh, out.otherKWh) = (r(dryKWh), r(fanKWh), r(otherKWh))
        return out
    }

    /// Modes with use, largest first. `mode` is nil for "other".
    public var shares: [EnergyModeShare] {
        let total = totalKWh
        guard total > 0 else { return [] }
        let parts: [(OperationMode?, String, Double)] = [
            (.heat, OperationMode.heat.displayName, heatingKWh), (.cool, OperationMode.cool.displayName, coolingKWh),
            (.auto, OperationMode.auto.displayName, autoKWh), (.dry, OperationMode.dry.displayName, dryKWh),
            (.fan, OperationMode.fan.displayName, fanKWh), (nil, "Annet", otherKWh),
        ]
        return parts.filter { $0.2 > 0 }.sorted { $0.2 > $1.2 }.map {
            EnergyModeShare(mode: $0.0, name: $0.1, kWh: $0.2, share: $0.2 / total)
        }
    }
}

public struct EnergyModeShare: Codable, Sendable, Equatable {
    public var mode: OperationMode?
    public var name: String
    public var kWh: Double
    public var share: Double
}

public enum MaintenanceKind: String, Codable, Sendable, CaseIterable {
    case airFilter
    case deodorizingFilter
    case vBlockingFilter
    case professionalService
    case other

    public var displayName: String {
        switch self {
        case .airFilter: L10n.tr("Air filter")
        case .deodorizingFilter: L10n.tr("Deodorizing/air purifying filter")
        case .vBlockingFilter: L10n.tr("V-blocking filter (green)")
        case .professionalService: L10n.tr("Service by the dealer")
        case .other: L10n.tr("Other")
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
    /// The app's price control (Prognose → Prisstyring).
    case automation
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
        case .ok: L10n.tr("OK")
        case .info: L10n.tr("For information")
        case .warning: L10n.tr("Warning")
        case .critical: L10n.tr("Critical")
        }
    }
}

/// One health observation. `title`, `detail` and `recommendation` are display text;
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
