import Foundation

/// What has already been notified, persisted by the app between launches.
public struct NotificationMemory: Codable, Sendable, Equatable {
    /// Newest error-log start already seen (nil before the first run).
    public var lastErrorEventStart: Date?
    /// Whether the current active error has been notified.
    public var activeErrorNotified: Bool
    public var lastFilterReminder: Date?
    /// An air quality sensor's last notification of a high long-term radon average (nil while it
    /// is below the action level).
    public var lastRadonAlert: Date?

    public init(
        lastErrorEventStart: Date? = nil, activeErrorNotified: Bool = false, lastFilterReminder: Date? = nil, lastRadonAlert: Date? = nil
    ) {
        self.lastErrorEventStart = lastErrorEventStart
        self.activeErrorNotified = activeErrorNotified
        self.lastFilterReminder = lastFilterReminder
        self.lastRadonAlert = lastRadonAlert
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

    /// `serviceName` names the service in the active-error text; `noErrorCodes` are the
    /// integration's "no error" codes. `device` is set when more than one device is enabled: the
    /// titles start with its name and the identifiers end with its key, so each device notifies
    /// on its own (its `memory` is its own too).
    public static func plan(
        state: DeviceState?, errorEvents: [ErrorLogEntry], maintenance: [MaintenanceStatus],
        memory: NotificationMemory, now: Date, serviceName: String, noErrorCodes: Set<Int>,
        device: (key: DeviceKey, name: String)? = nil
    ) -> (notifications: [PlannedNotification], memory: NotificationMemory) {
        let planned = planned(
            state: state, errorEvents: errorEvents, maintenance: maintenance, memory: memory, now: now, serviceName: serviceName,
            noErrorCodes: noErrorCodes)
        guard let device else { return planned }
        let named = planned.notifications.map {
            PlannedNotification(id: "\($0.id)@\(device.key.rawValue)", title: L10n.format("%1$@: %2$@", device.name, $0.title), body: $0.body)
        }
        return (named, planned.memory)
    }

    private static func planned(
        state: DeviceState?, errorEvents: [ErrorLogEntry], maintenance: [MaintenanceStatus],
        memory: NotificationMemory, now: Date, serviceName: String, noErrorCodes: Set<Int>
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
        if let state, state.hasActiveError(noErrorCodes: noErrorCodes) {
            if !memory.activeErrorNotified {
                let body =
                    state.errorCode.flatMap {
                        noErrorCodes.contains($0)
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

extension NotificationPlanner {
    /// How often a long-term radon average at or above the action level is notified while it lasts.
    public static let radonAlertInterval: TimeInterval = 7 * 86_400

    /// An air quality sensor's notification: its long-term radon average at or above the action
    /// level (`AirQualityHealth.radonActionLevel`), when the user turned it on, at most weekly
    /// while it lasts. The average moves slowly, so more often would only nag.
    public static func planAirQuality(
        status: AirQualityStatus?, enabled: Bool, memory: NotificationMemory, now: Date, device: (key: DeviceKey, name: String)
    ) -> (notifications: [PlannedNotification], memory: NotificationMemory) {
        var memory = memory
        guard let radon = status?.value(.radonLongTerm)?.value else { return ([], memory) }
        guard radon >= AirQualityHealth.radonActionLevel else {
            memory.lastRadonAlert = nil
            return ([], memory)
        }
        guard enabled, memory.lastRadonAlert.map({ now.timeIntervalSince($0) >= radonAlertInterval }) ?? true else { return ([], memory) }
        memory.lastRadonAlert = now
        let body =
            radon >= AirQualityHealth.radonLimit
            ? L10n.format(
                "The long-term radon average is %@, above the limit value of 200 Bq/m³. See the sensor in the app for what to do.",
                AirQualityMetric.radonLongTerm.formatted(radon))
            : L10n.format(
                "The long-term radon average is %@. Measures are recommended from 100 Bq/m³. See the sensor in the app for what to do.",
                AirQualityMetric.radonLongTerm.formatted(radon))
        return (
            [
                PlannedNotification(
                    id: "radon-high@\(device.key.rawValue)", title: L10n.format("%1$@: %2$@", device.name, L10n.tr("High radon level")), body: body)
            ], memory
        )
    }
}
