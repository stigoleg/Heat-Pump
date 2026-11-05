import AppKit
import HeatPumpKit
import SwiftUI

/// Quits when the last window closes (normal window app, no background polling) and stops
/// the poll task on the way out.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dev only (screenshots): VARMEPUMPE_APPEARANCE=dark|light.
        switch ProcessInfo.processInfo.environment["VARMEPUMPE_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

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
        .defaultSize(width: 1180, height: 860)
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
