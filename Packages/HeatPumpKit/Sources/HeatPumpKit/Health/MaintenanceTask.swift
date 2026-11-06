import Foundation

/// A maintenance task a unit has, with the intervals its manual gives. Supplied by the
/// integration (`Integration.maintenanceTasks`); the core only tracks when it was last done.
public struct MaintenanceTask: Sendable, Equatable {
    public var kind: MaintenanceKind
    /// Recommended interval in days (nil = no fixed interval).
    public var intervalDays: Int?
    /// Past this many days the status is `overdue` rather than `due` (nil = never overdue).
    public var overdueAfterDays: Int?

    public init(kind: MaintenanceKind, intervalDays: Int? = nil, overdueAfterDays: Int? = nil) {
        self.kind = kind
        self.intervalDays = intervalDays
        self.overdueAfterDays = overdueAfterDays
    }
}
