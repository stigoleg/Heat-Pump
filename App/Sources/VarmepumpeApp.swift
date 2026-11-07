import AppKit
import HeatPumpKit
import SwiftUI

/// Quits when the last window closes (normal window app, polling only while open) and stops
/// the poll task on the way out. While price control or the menu bar item is on, the app keeps
/// running with a menu-bar item and keeps polling; price control sets the temperature back before
/// quitting. With the menu bar item on, the Dock icon is shown only while a window is open.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !model.keepsRunningInBackground }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Saved choice (View → Appearance); dev VARMEPUMPE_APPEARANCE=dark|light overrides it.
        MainActor.assumeIsolated {
            model.applyAppearance()
            // Polling belongs to the app, so it can outlive the window while price control is on.
            model.start()
            model.updater.start()
            // Dev only (screenshots): open the panel once the item is in the menu bar.
            if model.menuBar.opensPanelAtLaunch {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    MenuBarDev.openPanel()
                }
            }
        }
    }

    /// With price control on, the base temperature is set back first (at most 5 s). Before its
    /// settings are read, the app cannot know, so it reads them first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard model.keepsRunningInBackground || !model.priceControl.loaded else { return .terminateNow }
            Task { @MainActor in
                await model.priceControl.restoreBeforeQuit()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            model.stop()
            // A downloaded update replaces the app now (automatic mode), after any price-control restore.
            model.updater.finishOnQuit()
        }
    }
}

@main
struct VarmepumpeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var model: AppModel { appDelegate.model }

    init() {
        // Before any localized string is looked up (dev VARMEPUMPE_LANGUAGE=en|nb).
        AppLanguage.applyEnvironmentOverride()
    }

    var body: some Scene {
        WindowGroup("Heat Pump", id: "main") {
            RootView()
                .environment(model)
                .environment(\.locale, L10n.locale)
                .frame(minWidth: 620, minHeight: 580)
                .task { model.start() }
                .onDisappear { if !model.keepsRunningInBackground { model.stop() } }
        }
        .defaultSize(width: 1180, height: 860)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(model: model)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh Now") {
                    Task { await model.refresh(force: true) }
                }
                .keyboardShortcut("r")
                Menu("Appearance") {
                    Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                    Button("Toggle Appearance") { model.cycleAppearance() }
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(\.locale, L10n.locale)
        }
        .defaultSize(width: 700, height: 600)
        .windowResizability(.contentMinSize)

        // The menu bar item (Settings → General → Menu bar): status, insight and controls, and
        // price control while it is on.
        MenuBarExtra(isInserted: Binding(get: { model.menuBar.enabled }, set: { _ in })) {
            MenuBarPanel()
                .environment(model)
                .environment(\.locale, L10n.locale)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        // Without the menu bar item, only while price control is on.
        MenuBarExtra(isInserted: Binding(get: { !model.menuBar.enabled && model.priceControl.enabled }, set: { _ in })) {
            PriceControlMenu()
                .environment(model)
                .environment(\.locale, L10n.locale)
        } label: {
            Label("Heat Pump – price control", systemImage: "bolt.badge.clock")
        }
    }
}
