import Foundation
import Security
import Synchronization

/// The values of an integration's sign-in fields, keyed by `CredentialField.id` (e.g. `email`).
public struct CredentialValues: Sendable, Equatable {
    public var fields: [String: String]

    public init(_ fields: [String: String] = [:]) {
        self.fields = fields
    }

    public subscript(field: String) -> String? {
        get { fields[field] }
        set { fields[field] = newValue }
    }
}

/// Where an integration's sign-in values and session live in the keychain (generic-password
/// items under one service, addressed by account). Persisted: an integration never moves its
/// existing items, because a new item would lose the access shared by the app and the helper.
public struct CredentialMapping: Sendable, Equatable {
    /// One keychain item and the fields it holds: one field is stored as the value itself,
    /// several as a JSON object of field → value.
    public struct Item: Sendable, Equatable {
        public var account: String
        public var fields: [String]

        public init(account: String, fields: [String]) {
            self.account = account
            self.fields = fields
        }
    }

    /// `Integration.id`.
    public var integrationId: String
    /// Names the service in the item labels shown in Keychain Access.
    public var serviceName: String
    public var items: [Item]
    /// Field also kept in its item's non-secret attribute, so it can be shown without reading
    /// the secret (e.g. the e-mail address).
    public var identityField: String?
    /// The item holding the service's session token, nil when there is none.
    public var sessionAccount: String?
    /// Dev only: environment variables (field → variable) that replace the keychain values when
    /// all of them are set.
    public var environment: [String: String]
    /// The values are also used outside the integration (the electricity price source reads the
    /// same token), so removing the integration keeps them; only signing out deletes them.
    public var isShared: Bool

    public init(
        integrationId: String, serviceName: String, items: [Item], identityField: String? = nil, sessionAccount: String? = nil,
        environment: [String: String] = [:], isShared: Bool = false
    ) {
        self.integrationId = integrationId
        self.serviceName = serviceName
        self.items = items
        self.identityField = identityField
        self.sessionAccount = sessionAccount
        self.environment = environment
        self.isShared = isShared
    }

    /// One item per field named `<integration id>/<field>`, the session in
    /// `<integration id>/session`, and the first non-secret field as the identity.
    public static func standard(integrationId: String, serviceName: String, fields: [CredentialField]) -> CredentialMapping {
        CredentialMapping(
            integrationId: integrationId, serviceName: serviceName,
            items: fields.map { Item(account: "\(integrationId)/\($0.id)", fields: [$0.id]) },
            identityField: fields.first { !$0.isSecret }?.id, sessionAccount: "\(integrationId)/session")
    }

    /// Every field the items hold.
    public var fields: [String] { items.flatMap(\.fields) }
}

/// Supplies an integration's sign-in values and persists its session. Values are addressed by
/// the integration's mapping (integration id and fields).
public protocol CredentialProviding: Sendable {
    /// All of the integration's fields, or nil when any is missing.
    func loadValues(for mapping: CredentialMapping) throws -> CredentialValues?
    /// Whether values are stored, without reading a secret (no keychain prompt).
    func hasValues(for mapping: CredentialMapping) -> Bool
    /// The identity field's value (e.g. the account's e-mail), without reading a secret where possible.
    func storedIdentity(for mapping: CredentialMapping) -> String?
    /// Saves the values and clears the session (a new account invalidates it).
    func saveValues(_ values: CredentialValues, for mapping: CredentialMapping) throws
    func loadSessionKey(for mapping: CredentialMapping) -> String?
    /// nil clears the session.
    func saveSessionKey(_ key: String?, for mapping: CredentialMapping) throws
    /// Removes the values and the session.
    func deleteValues(for mapping: CredentialMapping) throws
    /// Tibber personal access token (developer.tibber.com), nil when not set.
    func loadTibberToken() -> String?
    /// Whether a Tibber token is stored, without reading it (no keychain prompt).
    func hasTibberToken() -> Bool
    /// Saves the Tibber token; nil or empty removes it.
    func saveTibberToken(_ token: String?) throws
}

extension CredentialProviding {
    public func storedIdentity(for mapping: CredentialMapping) -> String? {
        mapping.identityField.flatMap { (try? loadValues(for: mapping))?[$0] }
    }
    public func hasTibberToken() -> Bool { loadTibberToken() != nil }
}

/// Keychain-backed credential store shared by the app and the MCP helper.
///
/// Uses generic-password items in the login (file-based) keychain under service
/// `com.stigole.varmepumpe`. That keychain works for a command-line helper without a
/// provisioning profile or keychain-access-group entitlement. New items trust both the app
/// and the helper (`KeychainAccess`), so neither gets a prompt; items are updated in place,
/// never deleted and re-created, so the ACL survives new logins. Items from older versions
/// are moved to the shared ACL once by `migrateAccessIfNeeded()`. The identity field (e-mail) is
/// kept in a non-secret attribute so showing it needs no secret read. No secrets are written to
/// disk in plain text. Which items an integration uses is its `CredentialMapping`.
public struct KeychainCredentialStore: CredentialProviding {
    public static let service = "com.stigole.varmepumpe"
    /// The price token's item. An integration may map a field to it (`CredentialMapping.isShared`);
    /// it is then read and written through the token's cache.
    public static let tibberTokenAccount = "tibber-token"

    private let environment: [String: String]
    private let items: any KeychainItems
    /// The integrations whose items `migrateAccessIfNeeded()` looks after.
    private let mappings: [CredentialMapping]
    /// The Tibber token is read at most once per process (fetches build a provider hourly).
    private let tibberCache = TokenCache()

    public init(
        service: String = KeychainCredentialStore.service, environment: [String: String] = ProcessInfo.processInfo.environment,
        mappings: [CredentialMapping]
    ) {
        self.init(items: SecKeychainItems(service: service), environment: environment, mappings: mappings)
    }

    init(items: any KeychainItems, environment: [String: String] = [:], mappings: [CredentialMapping]) {
        self.items = items
        self.environment = environment
        self.mappings = mappings
    }

    // MARK: Values

    /// The values from the dev environment variables, when the mapping has them and all are set.
    private func environmentValues(_ mapping: CredentialMapping) -> CredentialValues? {
        guard !mapping.environment.isEmpty else { return nil }
        var values = CredentialValues()
        for (field, variable) in mapping.environment {
            guard let value = environment[variable], !value.isEmpty else { return nil }
            values[field] = value
        }
        return values
    }

    public func loadValues(for mapping: CredentialMapping) throws -> CredentialValues? {
        if let values = environmentValues(mapping) { return values }
        var values = CredentialValues()
        for item in mapping.items {
            // The price token's item, shared with an integration: read through its cache.
            if item.account == Self.tibberTokenAccount, let field = item.fields.first, item.fields.count == 1 {
                guard let token = loadTibberToken() else { return nil }
                values[field] = token
                continue
            }
            guard let data = try items.read(account: item.account) else { return nil }
            guard let decoded = Self.decode(data, item: item) else { return nil }
            values.fields.merge(decoded.fields) { _, new in new }
        }
        return mapping.fields.allSatisfy({ values[$0] != nil }) && !mapping.items.isEmpty ? values : nil
    }

    public func hasValues(for mapping: CredentialMapping) -> Bool {
        if environmentValues(mapping) != nil { return true }
        if mapping.items.map(\.account) == [Self.tibberTokenAccount] { return hasTibberToken() }
        return !mapping.items.isEmpty && mapping.items.allSatisfy { items.attributes(account: $0.account) != nil }
    }

    public func storedIdentity(for mapping: CredentialMapping) -> String? {
        guard let field = mapping.identityField else { return nil }
        if let values = environmentValues(mapping) { return values[field] }
        guard let item = mapping.items.first(where: { $0.fields.contains(field) }),
            let attributes = items.attributes(account: item.account)
        else { return nil }
        if let generic = attributes.generic, let identity = String(data: generic, encoding: .utf8) { return identity }
        // Item from an older version without the attribute.
        return (try? loadValues(for: mapping))?[field]
    }

    public func saveValues(_ values: CredentialValues, for mapping: CredentialMapping) throws {
        for item in mapping.items {
            if item.account == Self.tibberTokenAccount, let field = item.fields.first, item.fields.count == 1 {
                try saveTibberToken(values[field])
                continue
            }
            let identity = mapping.identityField.flatMap { item.fields.contains($0) ? values[$0] : nil }
            try write(
                account: item.account, data: try Self.encode(values, item: item), label: Self.loginLabel(mapping),
                generic: identity.map { Data($0.utf8) })
        }
        // A new account invalidates any cached session.
        try saveSessionKey(nil, for: mapping)
    }

    public func loadSessionKey(for mapping: CredentialMapping) -> String? {
        guard let account = mapping.sessionAccount, let data = try? items.read(account: account), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil clears the session by emptying the item; deleting it would drop its ACL.
    public func saveSessionKey(_ key: String?, for mapping: CredentialMapping) throws {
        guard let account = mapping.sessionAccount else { return }
        if key == nil, items.attributes(account: account) == nil { return }
        try write(account: account, data: Data((key ?? "").utf8), label: Self.sessionLabel(mapping))
    }

    public func deleteValues(for mapping: CredentialMapping) throws {
        for item in mapping.items {
            try items.delete(account: item.account)
            if item.account == Self.tibberTokenAccount { tibberCache.set(nil) }
        }
        if let account = mapping.sessionAccount { try items.delete(account: account) }
    }

    /// One field: the value; several: a JSON object of field → value.
    static func encode(_ values: CredentialValues, item: CredentialMapping.Item) throws -> Data {
        if item.fields.count == 1, let field = item.fields.first { return Data((values[field] ?? "").utf8) }
        let object = Dictionary(uniqueKeysWithValues: item.fields.compactMap { field in values[field].map { (field, $0) } })
        return try JSONEncoder().encode(object)
    }

    static func decode(_ data: Data, item: CredentialMapping.Item) -> CredentialValues? {
        if item.fields.count == 1, let field = item.fields.first {
            let value = String(decoding: data, as: UTF8.self)
            return value.isEmpty ? nil : CredentialValues([field: value])
        }
        guard let object = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return CredentialValues(object.filter { item.fields.contains($0.key) })
    }

    // MARK: Tibber token

    public func loadTibberToken() -> String? {
        tibberCache.value {
            // A refused or failed read (Deny, locked keychain) is not cached; "not stored" is.
            let stored: Data?
            do { stored = try items.read(account: Self.tibberTokenAccount) } catch { return .none }
            guard let data = stored else { return .some(nil) }
            let token = String(decoding: data, as: UTF8.self)
            return .some(token.isEmpty ? nil : token)
        }
    }

    public func hasTibberToken() -> Bool {
        if let cached = tibberCache.cached { return cached != nil }
        return items.attributes(account: Self.tibberTokenAccount) != nil
    }

    public func saveTibberToken(_ token: String?) throws {
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            try write(account: Self.tibberTokenAccount, data: Data(token.utf8), label: Self.tibberLabel)
            tibberCache.set(token)
        } else {
            try items.delete(account: Self.tibberTokenAccount)
            tibberCache.set(nil)
        }
    }

    // Labels shown in Keychain Access (the service and account names stay fixed).
    static func loginLabel(_ mapping: CredentialMapping) -> String { L10n.format("Husly – %@ login", mapping.serviceName) }
    static func sessionLabel(_ mapping: CredentialMapping) -> String { L10n.format("Husly – %@ session", mapping.serviceName) }
    static let tibberLabel = L10n.tr("Husly – Tibber token")

    // MARK: Access migration

    /// Moves items created by older versions (ACL trusting only their creator) to the shared
    /// ACL: each is read once (at most one prompt per item, once) and written back. Items
    /// already carrying the marker are left alone, so later calls touch no secrets. Does
    /// nothing outside an app bundle.
    public func migrateAccessIfNeeded() {
        // Without a shared access there is nothing to migrate to; leave the items alone.
        guard KeychainAccess.shared(label: Self.tibberLabel) != nil else { return }
        var accounts: [(account: String, label: String, identity: (item: CredentialMapping.Item, field: String)?)] = []
        for mapping in mappings {
            // The price token's item is listed once below, under its own label.
            for item in mapping.items where item.account != Self.tibberTokenAccount {
                let identity = mapping.identityField.flatMap { item.fields.contains($0) ? (item, $0) : nil }
                accounts.append((item.account, Self.loginLabel(mapping), identity))
            }
            if let session = mapping.sessionAccount { accounts.append((session, Self.sessionLabel(mapping), nil)) }
        }
        accounts.append((Self.tibberTokenAccount, Self.tibberLabel, nil))
        for (account, label, identity) in accounts {
            guard let attributes = items.attributes(account: account), attributes.comment != KeychainAccess.marker,
                let data = try? items.read(account: account)
            else { continue }
            var generic = attributes.generic
            if generic == nil, let identity, let value = Self.decode(data, item: identity.item)?[identity.field] {
                generic = Data(value.utf8)
            }
            do {
                try items.delete(account: account)
                try items.add(account: account, data: data, label: label, generic: generic, shared: true, marked: false)
            } catch {
                // Put it back with default access rather than lose it, marked so the next launch
                // does not delete it again (that would drop the helper's "Always Allow" each time).
                FileHandle.standardError.write(Data("[keychain] migration of \(account) failed: \(error)\n".utf8))
                try? items.add(account: account, data: data, label: label, generic: generic, shared: false, marked: true)
            }
        }
    }

    /// Updates the item in place (keeping its ACL), or adds it with the shared access.
    private func write(account: String, data: Data, label: String, generic: Data? = nil) throws {
        if try !items.update(account: account, data: data, generic: generic) {
            try items.add(account: account, data: data, label: label, generic: generic, shared: true, marked: false)
        }
    }
}

/// The non-secret attributes of a keychain item.
struct KeychainItemAttributes: Sendable, Equatable {
    /// `kSecAttrGeneric` (the identity field, e.g. the e-mail).
    var generic: Data?
    /// `kSecAttrComment` (the shared-access marker).
    var comment: String?
}

/// Generic-password items under one service, by account. The seam that lets tests check which
/// accounts an integration reads and writes without touching the real keychain.
protocol KeychainItems: Sendable {
    func read(account: String) throws -> Data?
    /// Attributes only (no secret, no prompt), nil when the item does not exist.
    func attributes(account: String) -> KeychainItemAttributes?
    /// Updates data (and the attribute when given) in place; false when the item does not exist.
    func update(account: String, data: Data, generic: Data?) throws -> Bool
    /// Adds an item; `shared` gives it the access trusting app and helper (`KeychainAccess`),
    /// `marked` marks it as migrated without that access.
    func add(account: String, data: Data, label: String, generic: Data?, shared: Bool, marked: Bool) throws
    func delete(account: String) throws
}

/// The login keychain.
struct SecKeychainItems: KeychainItems {
    let service: String

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(account: String) throws -> Data? {
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

    func attributes(account: String) -> KeychainItemAttributes? {
        var query = baseQuery(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let attributes = result as? [String: Any]
        else { return nil }
        return KeychainItemAttributes(
            generic: attributes[kSecAttrGeneric as String] as? Data, comment: attributes[kSecAttrComment as String] as? String)
    }

    func update(account: String, data: Data, generic: Data?) throws -> Bool {
        var update: [String: Any] = [kSecValueData as String: data]
        if let generic { update[kSecAttrGeneric as String] = generic }
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return true
    }

    func add(account: String, data: Data, label: String, generic: Data?, shared: Bool, marked: Bool) throws {
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

    func delete(account: String) throws {
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

/// In-memory store for tests and the mock backend, keyed by integration id.
public final class InMemoryCredentialStore: CredentialProviding {
    private struct State {
        var values: [String: CredentialValues]
        var sessions: [String: String]
        var tibberToken: String?
        var loadCount = 0
        var existenceChecks = 0
    }

    private let state: Mutex<State>

    /// `values` and `sessionKeys` by integration id.
    public init(values: [String: CredentialValues] = [:], sessionKeys: [String: String] = [:]) {
        state = Mutex(State(values: values, sessions: sessionKeys))
    }

    public func loadValues(for mapping: CredentialMapping) throws -> CredentialValues? {
        state.withLock {
            $0.loadCount += 1
            if let field = Self.tokenField(mapping) { return $0.tibberToken.map { CredentialValues([field: $0]) } }
            return $0.values[mapping.integrationId]
        }
    }
    public func hasValues(for mapping: CredentialMapping) -> Bool {
        state.withLock {
            $0.existenceChecks += 1
            if Self.tokenField(mapping) != nil { return $0.tibberToken != nil }
            return $0.values[mapping.integrationId] != nil
        }
    }

    /// The field of a mapping that uses the price token's item, like the keychain store.
    private static func tokenField(_ mapping: CredentialMapping) -> String? {
        guard mapping.items.count == 1, let item = mapping.items.first, item.account == KeychainCredentialStore.tibberTokenAccount
        else { return nil }
        return item.fields.first
    }
    /// Number of `hasValues` calls.
    public var existenceChecks: Int { state.withLock { $0.existenceChecks } }
    /// Number of `loadValues` calls (tests check that polling does not read secrets).
    public var loadCount: Int { state.withLock { $0.loadCount } }
    public func saveValues(_ values: CredentialValues, for mapping: CredentialMapping) throws {
        state.withLock {
            if let field = Self.tokenField(mapping) {
                $0.tibberToken = values[field]
            } else {
                $0.values[mapping.integrationId] = values
            }
        }
    }
    public func loadSessionKey(for mapping: CredentialMapping) -> String? { state.withLock { $0.sessions[mapping.integrationId] } }
    public func saveSessionKey(_ key: String?, for mapping: CredentialMapping) throws {
        state.withLock { $0.sessions[mapping.integrationId] = key }
    }
    public func loadTibberToken() -> String? { state.withLock { $0.tibberToken } }
    public func saveTibberToken(_ token: String?) throws {
        state.withLock { $0.tibberToken = token?.isEmpty == true ? nil : token }
    }
    public func deleteValues(for mapping: CredentialMapping) throws {
        state.withLock {
            if Self.tokenField(mapping) != nil { $0.tibberToken = nil }
            $0.values[mapping.integrationId] = nil
            $0.sessions[mapping.integrationId] = nil
        }
    }
}
