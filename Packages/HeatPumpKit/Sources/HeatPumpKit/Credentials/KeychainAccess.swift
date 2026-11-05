import Foundation
import Security

/// Access control for new keychain items: both the app and the embedded MCP helper are
/// trusted applications, so neither gets a keychain prompt for an item the other created.
/// Trust rests on each binary's designated requirement, which stays the same across
/// releases signed with the same Developer ID.
///
/// `SecAccess` and `SecTrustedApplication` are deprecated but remain the only way to set the
/// ACL of an item in the file-based login keychain, which the helper needs (a command-line
/// tool cannot carry the keychain-access-group entitlement of the data-protection keychain).
enum KeychainAccess {
    /// Stored in `kSecAttrComment` on items created with the shared access.
    static let marker = "varmepumpe-acl-2"

    static let helperSubpath = "Contents/Helpers/varmepumpe-mcp"

    /// Access trusting the app and its helper, or nil outside an app bundle (`swift run`,
    /// tests), where an item trusts only its creator as before.
    static func shared(label: String) -> SecAccess? {
        guard let paths = trustedPaths() else { return nil }
        var apps: [SecTrustedApplication] = []
        for path in paths {
            var app: SecTrustedApplication?
            guard SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app else { return nil }
            apps.append(app)
        }
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, apps as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }

    /// The enclosing `.app` and its helper, found from the running executable (the app's
    /// `Contents/MacOS/Varmepumpe` or the helper's `Contents/Helpers/varmepumpe-mcp`).
    static func trustedPaths(
        executable: URL? = Bundle.main.executableURL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String]? {
        guard var url = executable?.resolvingSymlinksInPath() else { return nil }
        while url.pathExtension != "app" {
            guard url.pathComponents.count > 1 else { return nil }
            url.deleteLastPathComponent()
        }
        let helper = url.appending(path: helperSubpath).path
        return fileExists(helper) ? [url.path, helper] : [url.path]
    }
}
