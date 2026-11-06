import AppKit
import HeatPumpKit
import SwiftUI

/// The app's language: macOS's choice, or English or Norwegian bokmål regardless of it.
///
/// Stored as `AppleLanguages` in the app's own defaults domain, the same key macOS writes for
/// a per-app language (System Settings → General → Language & Region → Applications), so the
/// two never disagree. The MCP helper reads the same key (`L10n.languagePreferences`).
/// Takes effect at the next launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english, norwegian

    var id: String { rawValue }

    /// Language code written to `AppleLanguages`; nil follows macOS.
    var code: String? {
        switch self {
        case .system: nil
        case .english: L10n.Language.english.rawValue
        case .norwegian: L10n.Language.norwegian.rawValue
        }
    }

    /// Language names are shown in their own language.
    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .english: "English"
        case .norwegian: "Norsk"
        }
    }

    /// The saved choice (not including a launch-argument or environment override).
    static var saved: AppLanguage {
        let domain = UserDefaults.standard.persistentDomain(forName: L10n.appBundleIdentifier)
        guard let first = (domain?["AppleLanguages"] as? [String])?.first else { return .system }
        switch L10n.match(first) {
        case .english: return .english
        case .norwegian: return .norwegian
        case nil: return .system
        }
    }

    func save() {
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// Dev override `VARMEPUMPE_LANGUAGE=en|nb` for the whole process, without saving it.
    /// Must run before the first localized string is looked up.
    static func applyEnvironmentOverride() {
        guard let value = ProcessInfo.processInfo.environment[L10n.environmentKey], let language = L10n.match(value) else { return }
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleLanguages"] = [language.rawValue]
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}

/// Quits and opens the app again once this process has ended. Quitting goes through
/// `applicationShouldTerminate`, so price control sets the temperature back first.
enum AppRelauncher {
    /// - Parameters:
    ///   - app: the app to open (the running one unless an update was swapped in).
    ///   - removing: a folder to delete after the new instance is opened.
    @MainActor static func relaunch(_ app: URL = Bundle.main.bundleURL, removing: URL? = nil) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done; /usr/bin/open \"$2\"; [ -n \"$3\" ] && /bin/rm -rf \"$3\"; exit 0",
            "sh", String(ProcessInfo.processInfo.processIdentifier), app.path, removing?.path ?? "",
        ]
        try? process.run()
        NSApp.terminate(nil)
    }
}

/// Settings → General → Language.
struct LanguageSection: View {
    @State private var choice = AppLanguage.saved

    /// The language this process runs in differs from what the saved choice gives.
    private var needsRestart: Bool { L10n.resolve(choice: choice.code) != L10n.language }

    var body: some View {
        Section {
            Picker("Language", selection: $choice) {
                ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .onChange(of: choice) { _, value in value.save() }
            if needsRestart {
                HStack {
                    Text("Restart the app to change the language.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Now") { AppRelauncher.relaunch() }
                }
            }
        } header: {
            Text("Language")
        } footer: {
            Text("System uses the language set in macOS: Norwegian if it is Norwegian, otherwise English. Claude's change approvals and health texts follow this choice too.")
        }
    }
}
