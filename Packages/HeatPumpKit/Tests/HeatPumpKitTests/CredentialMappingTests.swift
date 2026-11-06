import Foundation
import Synchronization
import Testing
@testable import HeatPumpKit
@testable import MELCloudIntegration

/// Keychain items in memory, by account (never the real keychain).
final class MemoryKeychainItems: KeychainItems {
    struct Item: Equatable {
        var data: Data
        var label: String
        var generic: Data?
    }

    private let state = Mutex<[String: Item]>([:])

    var items: [String: Item] { state.withLock { $0 } }

    func set(_ account: String, _ item: Item) { state.withLock { $0[account] = item } }

    func read(account: String) throws -> Data? { state.withLock { $0[account]?.data } }

    func attributes(account: String) -> KeychainItemAttributes? {
        state.withLock { $0[account].map { KeychainItemAttributes(generic: $0.generic, comment: nil) } }
    }

    func update(account: String, data: Data, generic: Data?) throws -> Bool {
        state.withLock {
            guard var item = $0[account] else { return false }
            item.data = data
            if let generic { item.generic = generic }
            $0[account] = item
            return true
        }
    }

    func add(account: String, data: Data, label: String, generic: Data?, shared: Bool, marked: Bool) throws {
        state.withLock { $0[account] = Item(data: data, label: label, generic: generic) }
    }

    func delete(account: String) throws { _ = state.withLock { $0.removeValue(forKey: account) } }
}

@Suite("Credentials per integration")
struct CredentialMappingTests {
    let mapping = MELCloudIntegration.credentialMapping

    @Test func melcloudReadsTheItemsEarlierVersionsWrote() throws {
        let items = MemoryKeychainItems()
        // As 1.x stored them: one JSON item with the e-mail in the attribute, and the session key.
        items.set(
            "melcloud-credentials",
            .init(
                data: try JSONEncoder().encode(["email": "a@b.no", "password": "pw"]), label: "Heat Pump – MELCloud login",
                generic: Data("a@b.no".utf8)))
        items.set("melcloud-context-key", .init(data: Data("KEY".utf8), label: "Heat Pump – MELCloud session"))
        let store = KeychainCredentialStore(items: items, mappings: [mapping])

        #expect(store.hasValues(for: mapping))
        #expect(store.storedIdentity(for: mapping) == "a@b.no")
        #expect(try store.loadCredentials() == MELCloudCredentials(email: "a@b.no", password: "pw"))
        #expect(store.loadContextKey() == "KEY")
    }

    @Test func melcloudWritesTheSameItemsInPlace() throws {
        let items = MemoryKeychainItems()
        let store = KeychainCredentialStore(items: items, mappings: [mapping])
        try store.saveContextKey(nil)  // nothing stored: nothing created
        #expect(items.items.isEmpty)

        try store.saveValues(MELCloudCredentials(email: "a@b.no", password: "pw").values, for: mapping)
        try store.saveContextKey("KEY")
        #expect(Set(items.items.keys) == ["melcloud-credentials", "melcloud-context-key"])
        let login = try #require(items.items["melcloud-credentials"])
        #expect(try JSONDecoder().decode([String: String].self, from: login.data) == ["email": "a@b.no", "password": "pw"])
        #expect(login.generic == Data("a@b.no".utf8))
        #expect(login.label == "Heat Pump – MELCloud login")

        // New credentials update the same item and empty (not delete) the session.
        try store.saveValues(MELCloudCredentials(email: "c@d.no", password: "pw2").values, for: mapping)
        #expect(Set(items.items.keys) == ["melcloud-credentials", "melcloud-context-key"])
        #expect(items.items["melcloud-context-key"]?.data == Data())
        #expect(store.loadContextKey() == nil)
        #expect(store.storedIdentity(for: mapping) == "c@d.no")

        try store.deleteValues(for: mapping)
        #expect(items.items.isEmpty)
        #expect(!store.hasValues(for: mapping))
    }

    @Test func environmentVariablesStillWinForMELCloud() throws {
        let store = KeychainCredentialStore(
            items: MemoryKeychainItems(), environment: ["MELCLOUD_EMAIL": "dev@example.com", "MELCLOUD_PASSWORD": "pw"], mappings: [mapping])
        #expect(store.hasValues(for: mapping))
        #expect(store.storedIdentity(for: mapping) == "dev@example.com")
        #expect(try store.loadCredentials() == MELCloudCredentials(email: "dev@example.com", password: "pw"))
    }

    @Test func newIntegrationsGetOneItemPerField() throws {
        let fields = [
            CredentialField(id: "email", kind: .email, isSecret: false), CredentialField(id: "token", kind: .token, isSecret: true),
        ]
        let other = CredentialMapping.standard(integrationId: "acme-cloud", serviceName: "Acme", fields: fields)
        #expect(other.items.map(\.account) == ["acme-cloud/email", "acme-cloud/token"])
        #expect(other.sessionAccount == "acme-cloud/session")
        #expect(other.identityField == "email")

        let items = MemoryKeychainItems()
        let store = KeychainCredentialStore(items: items, mappings: [mapping, other])
        try store.saveValues(CredentialValues(["email": "x@y.no", "token": "T"]), for: other)
        try store.saveSessionKey("S", for: other)
        #expect(items.items["acme-cloud/email"]?.data == Data("x@y.no".utf8))
        #expect(items.items["acme-cloud/email"]?.generic == Data("x@y.no".utf8))
        #expect(items.items["acme-cloud/token"]?.data == Data("T".utf8))
        #expect(items.items["acme-cloud/token"]?.generic == nil)
        #expect(items.items["acme-cloud/token"]?.label == "Heat Pump – Acme login")
        #expect(try store.loadValues(for: other) == CredentialValues(["email": "x@y.no", "token": "T"]))
        #expect(store.loadSessionKey(for: other) == "S")
        // MELCloud's items are untouched and still absent.
        #expect(try store.loadCredentials() == nil)
        #expect(items.items["melcloud-credentials"] == nil)

        // A missing field means no credentials.
        try items.delete(account: "acme-cloud/token")
        #expect(try store.loadValues(for: other) == nil)
        #expect(!store.hasValues(for: other))
    }

    @Test func tibberTokenKeepsItsAccount() throws {
        let items = MemoryKeychainItems()
        let store = KeychainCredentialStore(items: items, mappings: [mapping])
        try store.saveTibberToken(" tok ")
        #expect(items.items["tibber-token"]?.data == Data("tok".utf8))
        #expect(store.loadTibberToken() == "tok")
        try store.saveTibberToken(nil)
        #expect(items.items["tibber-token"] == nil)
    }

    @Test func serviceSignsInWithGenericValues() async throws {
        let credentials = InMemoryCredentialStore()
        let clock = TestClock()
        let service = HeatPumpService(
            backend: CountingBackend(now: clock.provider), store: try HistoryStore(path: temporaryDatabasePath()),
            credentials: credentials, now: clock.provider, sleep: clock.sleeper)
        _ = try await service.signIn(CredentialValues(["email": "a@b.no", "password": "pw"]))
        #expect(try credentials.loadCredentials() == MELCloudCredentials(email: "a@b.no", password: "pw"))
        #expect(await service.accountEmail() == "a@b.no")
    }
}
