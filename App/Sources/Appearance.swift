import AppKit
import SwiftUI

/// App-wide light/dark choice. Applied through `NSApp.appearance`, so the main window,
/// Settings, alerts and menus all follow it.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let defaultsKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// nil follows the system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// System → Light → Dark → System (⌘⇧L).
    var next: AppAppearance {
        switch self {
        case .system: .light
        case .light: .dark
        case .dark: .system
        }
    }
}

/// Toolbar button: one click opens the three choices.
struct AppearanceMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            AppearancePicker()
        } label: {
            Label("Appearance", systemImage: model.appearance.systemImage)
        }
        .help("Appearance: \(model.appearance.title). Choose System, Light or Dark (⌘⇧L toggles).")
    }
}

/// The three choices with a checkmark (menus) or as a segmented control (Settings).
struct AppearancePicker: View {
    @Environment(AppModel.self) private var model
    var segmented = false

    var body: some View {
        let selection = Binding(get: { model.appearance }, set: { model.setAppearance($0) })
        if segmented {
            Picker("Light or dark", selection: selection) {
                ForEach(AppAppearance.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.segmented)
        } else {
            Picker("Appearance", selection: selection) {
                ForEach(AppAppearance.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

/// Settings → General.
struct GeneralSettings: View {
    var body: some View {
        Form {
            LanguageSection()
            Section {
                AppearancePicker(segmented: true)
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows the setting in macOS. You can also switch with the button in the toolbar, or with ⌘⇧L (View → Appearance).")
            }
            UpdateSection()
        }
        .formStyle(.grouped)
    }
}
