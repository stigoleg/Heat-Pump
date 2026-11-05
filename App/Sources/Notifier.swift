import Foundation
import HeatPumpKit
import UserNotifications

/// Delivers local notifications while the app is open; remembers what was already sent.
@MainActor
final class Notifier {
    private let defaults = UserDefaults.standard
    private let memoryKey = "notificationMemory"
    private let askedKey = "askedNotificationPermission"

    var memory: NotificationMemory {
        get {
            guard let data = defaults.data(forKey: memoryKey),
                let memory = try? JSONDecoder().decode(NotificationMemory.self, from: data)
            else { return NotificationMemory() }
            return memory
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: memoryKey) }
        }
    }

    /// Asks for permission on first launch only.
    func requestPermissionOnce() async {
        guard !defaults.bool(forKey: askedKey) else { return }
        defaults.set(true, forKey: askedKey)
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func deliver(_ notification: PlannedNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
