import Foundation
import Security
import Synchronization

public struct MELCloudCredentials: Sendable, Equatable {
    public var email: String
    public var password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

/// Supplies MELCloud credentials and persists the session ContextKey.
public protocol CredentialProviding: Sendable {
    func loadCredentials() throws -> MELCloudCredentials?
    /// Whether credentials exist, without reading the secret (no keychain prompt).
    func hasCredentials() -> Bool
    /// E-mail of the stored account, without reading the password where possible.
    func storedEmail() -> String?
    func saveCredentials(_ credentials: MELCloudCredentials) throws
    func loadContextKey() -> String?
    func saveContextKey(_ key: String?) throws
    func deleteAll() throws
    /// Tibber personal access token (developer.tibber.com), nil when not set.
    func loadTibberToken() -> String?
    /// Whether a Tibber token is stored, without reading it (no keychain prompt).
    func hasTibberToken() -> Bool
    /// Saves the Tibber token; nil or empty removes it.
    func saveTibberToken(_ token: String?) throws
}

extension CredentialProviding {
    public func storedEmail() -> String? { (try? loadCredentials())?.email }
    public func hasTibberToken() -> Bool { loadTibberToken() != nil }
}

/// Keychain-backed credential store shared by the app and the MCP helper.
///
/// Uses generic-password items in the login (file-based) keychain under service
/// `com.stigole.varmepumpe`. That keychain works for a command-line helper without a
/// provisioning profile or keychain-access-group entitlement. New items trust both the app
/// and the helper (`KeychainAccess`), so neither gets a prompt; items are updated in place,
/// never deleted and re-created, so the ACL survives new logins. Items from older versions
/// are moved to the shared ACL once by `migrateAccessIfNeeded()`. The e-mail address is kept
/// in a non-secret attribute so showing it needs no secret read. No secrets are written to
/// disk in plain text.
///
/// Dev only: `MELCLOUD_EMAIL` / `MELCLOUD_PASSWORD` environment variables take precedence
/// over the keychain when both are set.
public struct KeychainCredentialStore: CredentialProviding {
    public static let service = "com.stigole.varmepumpe"
    static let credentialsAccount = "melcloud-credentials"
    static let contextKeyAccount = "melcloud-context-key"
    static let tibberTokenAccount = "tibber-token"

    private let environment: [String: String]
    private let service: String
    /// The Tibber token is read at most once per process (fetches build a provider hourly).
    private let tibberCache = TokenCache()

    public init(service: String = KeychainCredentialStore.service, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.service = service
        self.environment = environment
    }

    public func loadCredentials() throws -> MELCloudCredentials? {
        if let email = environment["MELCLOUD_EMAIL"], let password = environment["MELCLOUD_PASSWORD"],
            !email.isEmpty, !password.isEmpty
        {
            return MELCloudCredentials(email: email, password: password)
        }
        guard let data = try read(account: Self.credentialsAccount),
            let object = try? JSONDecoder().decode([String: String].self, from: data),
            let email = object["email"], let password = object["password"]
        else { return nil }
        return MELCloudCredentials(email: email, password: password)
    }

    private var environmentCredentials: Bool {
        guard let email = environment["MELCLOUD_EMAIL"], let password = environment["MELCLOUD_PASSWORD"] else { return false }
        return !email.isEmpty && !password.isEmpty
    }

    public func hasCredentials() -> Bool {
        environmentCredentials || attributes(account: Self.credentialsAccount) != nil
    }

    public func storedEmail() -> String? {
        if environmentCredentials { return environment["MELCLOUD_EMAIL"] }
        guard let attributes = attributes(account: Self.credentialsAccount) else { return nil }
        if let data = attributes[kSecAttrGeneric as String] as? Data, let email = String(data: data, encoding: .utf8) {
            return email
        }
        // Item from an older version without the attribute.
        return (try? loadCredentials())?.email
    }

    public func saveCredentials(_ credentials: MELCloudCredentials) throws {
        let data = try JSONEncoder().encode(["email": credentials.email, "password": credentials.password])
        try write(
            account: Self.credentialsAccount, data: data, label: Self.credentialsLabel,
            generic: Data(credentials.email.utf8))
        // A new account invalidates any cached session.
        try saveContextKey(nil)
    }

    public func loadContextKey() -> String? {
        guard let data = try? read(account: Self.contextKeyAccount), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil clears the session by emptying the item; deleting it would drop its ACL.
    public func saveContextKey(_ key: String?) throws {
        if key == nil, attributes(account: Self.contextKeyAccount) == nil { return }
        try write(account: Self.contextKeyAccount, data: Data((key ?? "").utf8), label: Self.contextKeyLabel)
    }

    public func loadTibberToken() -> String? {
        tibberCache.value {
            // A refused or failed read (Deny, locked keychain) is not cached; "not stored" is.
            let stored: Data?
            do { stored = try read(account: Self.tibberTokenAccount) } catch { return .none }
            guard let data = stored else { return .some(nil) }
            let token = String(decoding: data, as: UTF8.self)
            return .some(token.isEmpty ? nil : token)
        }
    }

    public func hasTibberToken() -> Bool {
        if let cached = tibberCache.cached { return cached != nil }
        return attributes(account: Self.tibberTokenAccount) != nil
    }

    public func saveTibberToken(_ token: String?) throws {
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            try write(account: Self.tibberTokenAccount, data: Data(token.utf8), label: Self.tibberLabel)
            tibberCache.set(token)
        } else {
            try delete(account: Self.tibberTokenAccount)
            tibberCache.set(nil)
        }
    }

    // Labels shown in Keychain Access (the service and account names stay fixed).
    static let credentialsLabel = L10n.tr("Heat Pump – MELCloud login")
    static let contextKeyLabel = L10n.tr("Heat Pump – MELCloud session")
    static let tibberLabel = L10n.tr("Heat Pump – Tibber token")

    /// Moves items created by older versions (ACL trusting only their creator) to the shared
    /// ACL: each is read once (at most one prompt per item, once) and written back. Items
    /// already carrying the marker are left alone, so later calls touch no secrets. Does
    /// nothing outside an app bundle.
    public func migrateAccessIfNeeded() {
        // Without a shared access there is nothing to migrate to; leave the items alone.
        guard KeychainAccess.shared(label: Self.credentialsLabel) != nil else { return }
        let items = [
            (Self.credentialsAccount, Self.credentialsLabel),
            (Self.contextKeyAccount, Self.contextKeyLabel),
            (Self.tibberTokenAccount, Self.tibberLabel),
        ]
        for (account, label) in items {
            guard let attributes = attributes(account: account),
                attributes[kSecAttrComment as String] as? String != KeychainAccess.marker,
                let data = try? read(account: account)
            else { continue }
            var generic = attributes[kSecAttrGeneric as String] as? Data
            if account == Self.credentialsAccount, generic == nil,
                let object = try? JSONDecoder().decode([String: String].self, from: data), let email = object["email"]
            {
                generic = Data(email.utf8)
            }
            do {
                try delete(account: account)
                try add(account: account, data: data, label: label, generic: generic)
            } catch {
                // Put it back with default access rather than lose it, marked so the next launch
                // does not delete it again (that would drop the helper's "Always Allow" each time).
                FileHandle.standardError.write(Data("[keychain] migration of \(account) failed: \(error)\n".utf8))
                try? add(account: account, data: data, label: label, generic: generic, shared: false, marked: true)
            }
        }
    }

    public func deleteAll() throws {
        try delete(account: Self.credentialsAccount)
        try delete(account: Self.contextKeyAccount)
    }

    // MARK: - Keychain primitives

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    /// Attributes only (no secret, no prompt), nil when the item does not exist.
    private func attributes(account: String) -> [String: Any]? {
        var query = baseQuery(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }

    /// Updates the item in place (keeping its ACL), or adds it with the shared access.
    private func write(account: String, data: Data, label: String, generic: Data? = nil) throws {
        let query = baseQuery(account: account)
        var update: [String: Any] = [kSecValueData as String: data]
        if let generic { update[kSecAttrGeneric as String] = generic }
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            try add(account: account, data: data, label: label, generic: generic)
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    private func add(account: String, data: Data, label: String, generic: Data?, shared: Bool = true, marked: Bool = false) throws {
        var add = baseQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if let generic { add[kSecAttrGeneric as String] = generic }
        if shared, let access = KeychainAccess.shared(label: label) {
            add[kSecAttrAccess as String] = access
            add[kSecAttrComment as String] = KeychainAccess.marker
        } else if marked {
            add[kSecAttrComment as String] = KeychainAccess.marker
        }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// Per-process cache of one secret: `.some(nil)` means "read, not set".
final class TokenCache: Sendable {
    private let state = Mutex<String??>(nil)

    var cached: String?? { state.withLock { $0 } }

    /// `load` returns `.none` when the read failed; that is not cached, so the next call retries.
    func value(_ load: () -> String??) -> String? {
        if let cached = state.withLock({ $0 }) { return cached }
        guard let loaded = load() else { return nil }
        state.withLock { $0 = .some(loaded) }
        return loaded
    }

    func set(_ token: String?) { state.withLock { $0 = .some(token) } }
}

public struct KeychainError: Error, Sendable, LocalizedError {
    public var status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? L10n.tr("unknown")
        return L10n.format("Keychain error %@: %@", String(status), message)
    }
}

/// In-memory store for tests and the mock backend.
public final class InMemoryCredentialStore: CredentialProviding {
    private struct State {
        var credentials: MELCloudCredentials?
        var contextKey: String?
        var tibberToken: String?
        var loadCount = 0
        var existenceChecks = 0
    }

    private let state: Mutex<State>

    public init(credentials: MELCloudCredentials? = nil, contextKey: String? = nil) {
        state = Mutex(State(credentials: credentials, contextKey: contextKey))
    }

    public func loadCredentials() throws -> MELCloudCredentials? {
        state.withLock {
            $0.loadCount += 1
            return $0.credentials
        }
    }
    public func hasCredentials() -> Bool {
        state.withLock {
            $0.existenceChecks += 1
            return $0.credentials != nil
        }
    }
    /// Number of `hasCredentials` calls.
    public var existenceChecks: Int { state.withLock { $0.existenceChecks } }
    /// Number of `loadCredentials` calls (tests check that polling does not read secrets).
    public var loadCount: Int { state.withLock { $0.loadCount } }
    public func saveCredentials(_ credentials: MELCloudCredentials) throws { state.withLock { $0.credentials = credentials } }
    public func loadContextKey() -> String? { state.withLock { $0.contextKey } }
    public func saveContextKey(_ key: String?) throws { state.withLock { $0.contextKey = key } }
    public func loadTibberToken() -> String? { state.withLock { $0.tibberToken } }
    public func saveTibberToken(_ token: String?) throws {
        state.withLock { $0.tibberToken = token?.isEmpty == true ? nil : token }
    }
    public func deleteAll() throws {
        state.withLock {
            $0.credentials = nil
            $0.contextKey = nil
        }
    }
}
