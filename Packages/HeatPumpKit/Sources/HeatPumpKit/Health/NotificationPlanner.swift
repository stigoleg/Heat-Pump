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

    /// `serviceName` names the service in the active-error text.
    public static func plan(
        state: DeviceState?, errorEvents: [ErrorLogEntry], maintenance: [MaintenanceStatus],
        memory: NotificationMemory, now: Date, serviceName: String
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
                            title: L10n.tr("New error in the error log"),
                            body: fresh.count == 1
                                ? L10n.format("“%@”. See Health in the app for what it means.", newest.message)
                                : L10n.format("%lld new errors, latest: “%@”. See Health in the app.", fresh.count, newest.message)))
                }
            }
            if memory.lastErrorEventStart.map({ newest.start > $0 }) ?? true {
                memory.lastErrorEventStart = newest.start
            }
        }

        // Active error: once per occurrence.
        if let state, state.hasActiveError {
            if !memory.activeErrorNotified {
                let body =
                    state.errorCode.flatMap {
                        DeviceState.noErrorCodes.contains($0)
                            ? nil
                            : L10n.format("%@ is reporting an error now (code %@). Open Health in the app for advice.", serviceName, String($0))
                    }
                    ?? L10n.format("%@ is reporting an error now. Open Health in the app for advice.", serviceName)
                notifications.append(
                    PlannedNotification(id: "active-error", title: L10n.tr("The heat pump is reporting an error"), body: body))
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
                    id: "filter-overdue", title: L10n.tr("Time to clean the air filter"),
                    body: L10n.tr("It has been over 30 days since the air filter was cleaned. Record it in the app when it is done.")))
            memory.lastFilterReminder = now
        }
        return (notifications, memory)
    }
}
