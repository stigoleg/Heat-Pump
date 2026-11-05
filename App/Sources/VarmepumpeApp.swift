import AppKit
import HeatPumpKit
import SwiftUI

/// Quits when the last window closes (normal window app, polling only while open) and stops
/// the poll task on the way out. While price control is on, the app keeps running with a
/// menu-bar item and keeps polling, and it sets the temperature back before quitting.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !model.keepsRunningInBackground }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Saved choice (Visning → Utseende); dev VARMEPUMPE_APPEARANCE=dark|light overrides it.
        MainActor.assumeIsolated {
            model.applyAppearance()
            // Polling belongs to the app, so it can outlive the window while price control is on.
            model.start()
        }
    }

    /// With price control on, the base temperature is set back first (at most 5 s).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard model.keepsRunningInBackground else { return .terminateNow }
            Task { @MainActor in
                await model.priceControl.restoreBeforeQuit()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
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
                .frame(minWidth: 620, minHeight: 580)
                .task { model.start() }
                .onDisappear { if !model.keepsRunningInBackground { model.stop() } }
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

        // Only while price control is on.
        MenuBarExtra(isInserted: Binding(get: { model.priceControl.enabled }, set: { _ in })) {
            PriceControlMenu()
                .environment(model)
                .environment(\.locale, Norwegian.locale)
        } label: {
            Label("Varmepumpe – prisstyring", systemImage: "bolt.badge.clock")
        }
    }
}
