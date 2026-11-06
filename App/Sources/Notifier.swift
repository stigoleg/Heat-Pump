import Foundation
import HeatPumpKit
import UserNotifications

/// Delivers local notifications while the app is open; remembers what was already sent.
@MainActor
final class Notifier {
    private let defaults = UserDefaults.standard
    private let memoryKey = "notificationMemory"
    private let askedKey = "askedNotificationPermission"

    /// What was already sent for a device: nil is the first device (the memory from before
    /// devices), any other device has its own.
    func memory(for device: DeviceKey?) -> NotificationMemory {
        guard let data = defaults.data(forKey: key(device)),
            let memory = try? JSONDecoder().decode(NotificationMemory.self, from: data)
        else { return NotificationMemory() }
        return memory
    }

    func setMemory(_ memory: NotificationMemory, for device: DeviceKey?) {
        if let data = try? JSONEncoder().encode(memory) { defaults.set(data, forKey: key(device)) }
    }

    private func key(_ device: DeviceKey?) -> String {
        device.map { "\(memoryKey)@\($0.rawValue)" } ?? memoryKey
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
