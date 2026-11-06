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
        case .system: "System"
        case .light: "Lys"
        case .dark: "Mørk"
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

    /// System → Lys → Mørk → System (⌘⇧L).
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
            Label("Utseende", systemImage: model.appearance.systemImage)
        }
        .help("Utseende: \(model.appearance.title). Velg System, Lys eller Mørk (⌘⇧L bytter).")
    }
}

/// The three choices with a checkmark (menus) or as a segmented control (Settings).
struct AppearancePicker: View {
    @Environment(AppModel.self) private var model
    var segmented = false

    var body: some View {
        let selection = Binding(get: { model.appearance }, set: { model.setAppearance($0) })
        if segmented {
            Picker("Lys eller mørk", selection: selection) {
                ForEach(AppAppearance.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.segmented)
        } else {
            Picker("Utseende", selection: selection) {
                ForEach(AppAppearance.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

/// Settings → Generelt.
struct GeneralSettings: View {
    var body: some View {
        Form {
            LanguageSection()
            Section {
                AppearancePicker(segmented: true)
            } header: {
                Text("Utseende")
            } footer: {
                Text("System følger innstillingen i macOS. Du kan også bytte med knappen i verktøylinjen, eller med ⌘⇧L (Visning → Utseende).")
            }
            UpdateSection()
        }
        .formStyle(.grouped)
    }
}
