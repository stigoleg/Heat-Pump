import Foundation
import Testing
@testable import HeatPumpKit

@Suite("Localization")
struct L10nTests {
    @Test func matchesLanguageCodes() {
        #expect(L10n.match("en") == .english)
        #expect(L10n.match("en-GB") == .english)
        #expect(L10n.match("nb-NO") == .norwegian)
        #expect(L10n.match("nb_NO") == .norwegian)
        #expect(L10n.match("no") == .norwegian)
        #expect(L10n.match("nn-NO") == .norwegian)
        #expect(L10n.match("de-DE") == nil)
    }

    @Test func resolvesFromOverrideThenPreferences() {
        #expect(L10n.resolveLanguage(override: "nb", preferences: ["en-US"]) == .norwegian)
        #expect(L10n.resolveLanguage(override: "xx", preferences: ["nb-NO"]) == .norwegian)
        #expect(L10n.resolveLanguage(override: nil, preferences: ["de-DE", "nb-NO", "en"]) == .norwegian)
        #expect(L10n.resolveLanguage(override: nil, preferences: ["sv-SE", "de"]) == .english)
        #expect(L10n.resolveLanguage(override: nil, preferences: []) == .english)
    }

    @Test func localeKeepsRegion() {
        #expect(L10n.makeLocale(language: .english, region: "NO").identifier == "en_NO")
        #expect(L10n.makeLocale(language: .norwegian, region: nil).identifier == "nb_NO")
    }

    /// `swift test` has no app bundle: every key comes back as the English source.
    @Test func withoutAppBundleReturnsEnglishSource() {
        #expect(L10n.hostApp() == nil)
        #expect(L10n.language == .english)
        #expect(L10n.locale.identifier == "en_NO")
        #expect(L10n.tr("Heat") == "Heat")
        #expect(L10n.format("%lld new errors", 3) == "3 new errors")
        #expect(L10n.lookup("Heat", in: nil) == "Heat")
    }

    @Test func looksUpInLanguageFolder() throws {
        let app = FileManager.default.temporaryDirectory.appending(path: "L10nTests-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let lproj = app.appending(path: "Contents/Resources/nb.lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        try #"""
        "Heat" = "Varme";
        """#.write(to: lproj.appending(path: "HeatPumpKit.strings"), atomically: true, encoding: .utf8)
        let folder = try #require(Bundle(url: lproj))
        #expect(L10n.lookup("Heat", in: folder) == "Varme")
        #expect(L10n.lookup("Cool", in: folder) == "Cool")
    }

    /// Fails when an `L10n.tr`/`L10n.format` key is missing from App/Resources/HeatPumpKit.xcstrings,
    /// is unused there, or has no Norwegian translation. Fix with `make l10n`.
    @Test func kitCatalogIsCompleteAndTranslated() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appending(path: "scripts/l10n.py").path, "check", "--kit-only"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(output)")
    }
}
