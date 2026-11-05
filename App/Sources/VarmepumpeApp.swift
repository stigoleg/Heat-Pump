import AppKit
import HeatPumpKit
import SwiftUI

/// Quits when the last window closes (normal window app, no background polling) and stops
/// the poll task on the way out.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model.stop() }
    }
}

@main
struct VarmepumpeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        WindowGroup("Varmepumpe", id: "main") {
            RootView()
                .environment(model)
                .environment(\.locale, Norwegian.locale)
                .frame(minWidth: 860, minHeight: 580)
                .task { model.start() }
                .onDisappear { model.stop() }
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Oppdater nå") {
                    Task { await model.refresh(force: true) }
                }
                .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(\.locale, Norwegian.locale)
        }
    }
}
