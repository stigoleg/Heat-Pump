import AppKit
import HeatPumpKit
import SwiftUI

/// Quits when the last window closes (normal window app, no background polling) and stops
/// the poll task on the way out.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Saved choice (Visning → Utseende); dev VARMEPUMPE_APPEARANCE=dark|light overrides it.
        MainActor.assumeIsolated { model.applyAppearance() }
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
                .frame(minWidth: 620, minHeight: 580)
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
                Menu("Utseende") {
                    Picker("Utseende", selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                    Button("Bytt utseende") { model.cycleAppearance() }
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(\.locale, Norwegian.locale)
        }
        .defaultSize(width: 700, height: 600)
        .windowResizability(.contentMinSize)
    }
}
