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
    func saveCredentials(_ credentials: MELCloudCredentials) throws
    func loadContextKey() -> String?
    func saveContextKey(_ key: String?) throws
    func deleteAll() throws
}

/// Keychain-backed credential store shared by the app and the MCP helper.
///
/// Uses generic-password items in the login (file-based) keychain under service
/// `com.stigole.varmepumpe`. That keychain works for a command-line helper without a
/// provisioning profile or keychain-access-group entitlement. The item ACL trusts the
/// binary that created it; the other binary gets a one-time macOS prompt where the user
/// chooses "Always Allow". No secrets are written to disk in plain text.
///
/// Dev only: `MELCLOUD_EMAIL` / `MELCLOUD_PASSWORD` environment variables take precedence
/// over the keychain when both are set.
public struct KeychainCredentialStore: CredentialProviding {
    public static let service = "com.stigole.varmepumpe"
    static let credentialsAccount = "melcloud-credentials"
    static let contextKeyAccount = "melcloud-context-key"

    private let environment: [String: String]
    private let service: String

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

    public func hasCredentials() -> Bool {
        if let email = environment["MELCLOUD_EMAIL"], let password = environment["MELCLOUD_PASSWORD"],
            !email.isEmpty, !password.isEmpty
        {
            return true
        }
        var query = baseQuery(account: Self.credentialsAccount)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    public func saveCredentials(_ credentials: MELCloudCredentials) throws {
        let data = try JSONEncoder().encode(["email": credentials.email, "password": credentials.password])
        try write(account: Self.credentialsAccount, data: data, label: "Varmepumpe – MELCloud-innlogging")
        // A new account invalidates any cached session.
        try saveContextKey(nil)
    }

    public func loadContextKey() -> String? {
        guard let data = try? read(account: Self.contextKeyAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func saveContextKey(_ key: String?) throws {
        if let key {
            try write(account: Self.contextKeyAccount, data: Data(key.utf8), label: "Varmepumpe – MELCloud-økt")
        } else {
            try delete(account: Self.contextKeyAccount)
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

    private func write(account: String, data: Data, label: String) throws {
        let query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, Sendable, LocalizedError {
    public var status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "ukjent"
        return "Nøkkelring-feil \(status): \(message)"
    }
}

/// In-memory store for tests and the mock backend.
public final class InMemoryCredentialStore: CredentialProviding {
    private struct State {
        var credentials: MELCloudCredentials?
        var contextKey: String?
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
    public func deleteAll() throws {
        state.withLock {
            $0.credentials = nil
            $0.contextKey = nil
        }
    }
}
