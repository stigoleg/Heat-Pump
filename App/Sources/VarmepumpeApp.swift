import HeatPumpKit
import SwiftUI

@main
struct VarmepumpeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Varmepumpe", id: "main") {
            RootView()
                .environment(model)
                .environment(\.locale, Norwegian.locale)
                .frame(minWidth: 860, minHeight: 580)
                .task { model.start() }
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
