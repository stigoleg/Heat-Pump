import Foundation

/// User-facing text in the user's language (English or Norwegian bokmål).
///
/// English is the source language: keys are the English text. Translations live in the app's
/// string catalog `HeatPumpKit.xcstrings` (table `HeatPumpKit`), compiled into `<lang>.lproj`
/// inside `Varmepumpe.app`. The package itself has no resource bundle, so the embedded MCP
/// helper finds the strings by walking up to the enclosing app. Without an app bundle
/// (`swift test`, `swift run`) every lookup returns the English key.
///
/// The language is fixed for the life of the process; changing it in the app takes a restart.
/// Keys must be string literals passed directly to `tr` or `format`, so
/// `scripts/l10n.py` can find them.
public enum L10n {
    public enum Language: String, Sendable, CaseIterable {
        case english = "en"
        case norwegian = "nb"
    }

    /// Bundle identifier of the app, whose defaults domain holds the language choice.
    public static let appBundleIdentifier = "com.stigole.varmepumpe"
    public static let table = "HeatPumpKit"
    /// Dev/test override: `VARMEPUMPE_LANGUAGE=en|nb`.
    public static let environmentKey = "VARMEPUMPE_LANGUAGE"

    /// The language for this process. Without an app bundle there are no translations, so it is
    /// English unless overridden; that keeps `swift test` the same on every Mac.
    public static let language: Language = resolveLanguage(
        override: ProcessInfo.processInfo.environment[environmentKey],
        preferences: hostApp() == nil ? [] : languagePreferences()
    )

    /// Formatting locale: the chosen language with the Mac's region (e.g. `en_NO`, `nb_NO`).
    /// Without an app bundle the region is Norway, so `swift test` formats the same everywhere.
    public static let locale: Locale = makeLocale(
        language: language, region: hostApp() == nil ? "NO" : Locale.current.region?.identifier)

    /// The `<lang>.lproj` folder of the enclosing app, or nil outside an app bundle.
    static let strings: Bundle? = localizedBundle(for: language, in: hostApp())

    /// Translates `key` (English source text).
    public static func tr(_ key: String) -> String {
        lookup(key, in: strings)
    }

    /// Translates the printf-style `key` and fills in the arguments with `locale`.
    /// Plural variants in the catalog are resolved from the arguments.
    public static func format(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: lookup(key, in: strings), locale: locale, arguments: arguments)
    }

    /// The language a choice in the app resolves to: an explicit code (`en`, `nb`), or macOS's
    /// own language list when nil ("System").
    public static func resolve(choice: String?) -> Language {
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        return resolveLanguage(override: choice, preferences: system ?? Locale.preferredLanguages)
    }

    // MARK: Resolution (internal for tests)

    static func lookup(_ key: String, in bundle: Bundle?) -> String {
        guard let bundle else { return key }
        return bundle.localizedString(forKey: key, value: key, table: table)
    }

    /// Picks English or Norwegian from an override or the ordered preference list.
    static func resolveLanguage(override: String?, preferences: [String]) -> Language {
        if let override, let match = match(override) { return match }
        for preference in preferences {
            if let match = match(preference) { return match }
        }
        return .english
    }

    /// `nb`, `nb-NO`, `no`, `nn` → Norwegian; `en…` → English; anything else nil.
    public static func match(_ identifier: String) -> Language? {
        let code = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        switch code {
        case "en": return .english
        case "nb", "no", "nn": return .norwegian
        default: return nil
        }
    }

    static func makeLocale(language: Language, region: String?) -> Locale {
        let region = region ?? "NO"
        return Locale(identifier: "\(language.rawValue)_\(region)")
    }

    /// The app's language list: inside the app the merged defaults (launch arguments, the app's
    /// own choice, then macOS); in the helper the app's own domain first, then macOS.
    static func languagePreferences() -> [String] {
        if Bundle.main.bundleIdentifier == appBundleIdentifier {
            return UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
        }
        let appChoice = UserDefaults.standard.persistentDomain(forName: appBundleIdentifier)?["AppleLanguages"] as? [String]
        return (appChoice ?? []) + Locale.preferredLanguages
    }

    /// Varmepumpe.app: the main bundle, or the app around the helper (`Contents/Helpers/…`).
    static func hostApp() -> Bundle? {
        if Bundle.main.bundleIdentifier == appBundleIdentifier { return Bundle.main }
        var url = (Bundle.main.executableURL ?? Bundle.main.bundleURL).resolvingSymlinksInPath()
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), bundle.bundleIdentifier == appBundleIdentifier else { return nil }
                return bundle
            }
        }
        return nil
    }

    static func localizedBundle(for language: Language, in app: Bundle?) -> Bundle? {
        guard let url = app?.url(forResource: language.rawValue, withExtension: "lproj") else { return nil }
        return Bundle(url: url)
    }
}

/// Display formatting for user-facing text in the chosen language and the Mac's region.
public enum Display {
    public static var locale: Locale { L10n.locale }

    public static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    public static func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }

    public static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    /// `String(format:)` with the locale's decimal separator. Not translated; use
    /// `L10n.format` for text.
    public static func format(_ format: String, _ arguments: any CVarArg...) -> String {
        String(format: format, locale: locale, arguments: arguments)
    }
}
