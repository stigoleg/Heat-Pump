import Foundation

/// What has already been notified, persisted by the app between launches.
public struct NotificationMemory: Codable, Sendable, Equatable {
    /// Newest error-log start already seen (nil before the first run).
    public var lastErrorEventStart: Date?
    /// Whether the current active error has been notified.
    public var activeErrorNotified: Bool
    public var lastFilterReminder: Date?

    public init(lastErrorEventStart: Date? = nil, activeErrorNotified: Bool = false, lastFilterReminder: Date? = nil) {
        self.lastErrorEventStart = lastErrorEventStart
        self.activeErrorNotified = activeErrorNotified
        self.lastFilterReminder = lastFilterReminder
    }
}

public struct PlannedNotification: Sendable, Equatable {
    public var id: String
    public var title: String
    public var body: String
}

/// Decides which local notifications to show. Pure; the app delivers them.
public enum NotificationPlanner {
    public static let filterReminderInterval: TimeInterval = 86_400

    public static func plan(
        state: DeviceState?, errorEvents: [ErrorLogEntry], maintenance: [MaintenanceStatus],
        memory: NotificationMemory, now: Date
    ) -> (notifications: [PlannedNotification], memory: NotificationMemory) {
        var memory = memory
        var notifications: [PlannedNotification] = []

        // New error-log entries. The first run only records a baseline, so old entries do not spam.
        if let newest = errorEvents.max(by: { $0.start < $1.start }) {
            if let seen = memory.lastErrorEventStart {
                let fresh = errorEvents.filter { $0.start > seen }
                if !fresh.isEmpty {
                    notifications.append(
                        PlannedNotification(
                            id: "error-log-\(Int(newest.start.timeIntervalSince1970))",
                            title: "Ny feil i feilloggen",
                            body: fresh.count == 1
                                ? "«\(newest.message)». Se Helse i appen for hva det betyr."
                                : "\(fresh.count) nye feil, siste: «\(newest.message)». Se Helse i appen."))
                }
            }
            if memory.lastErrorEventStart.map({ newest.start > $0 }) ?? true {
                memory.lastErrorEventStart = newest.start
            }
        }

        // Active error: once per occurrence.
        if let state, state.hasActiveError {
            if !memory.activeErrorNotified {
                let code = state.errorCode.flatMap { DeviceState.noErrorCodes.contains($0) ? nil : " (kode \($0))" } ?? ""
                notifications.append(
                    PlannedNotification(
                        id: "active-error", title: "Varmepumpen melder feil",
                        body: "MELCloud melder en feil nå\(code). Åpne Helse i appen for råd."))
                memory.activeErrorNotified = true
            }
        } else if state != nil {
            memory.activeErrorNotified = false
        }

        // Overdue air filter: at most once per day.
        if maintenance.contains(where: { $0.kind == .airFilter && $0.status == "overdue" }),
            memory.lastFilterReminder.map({ now.timeIntervalSince($0) >= filterReminderInterval }) ?? true
        {
            notifications.append(
                PlannedNotification(
                    id: "filter-overdue", title: "Tid for å rengjøre luftfilteret",
                    body: "Det er over 30 dager siden luftfilteret ble rengjort. Registrer det i appen når det er gjort."))
            memory.lastFilterReminder = now
        }
        return (notifications, memory)
    }
}
