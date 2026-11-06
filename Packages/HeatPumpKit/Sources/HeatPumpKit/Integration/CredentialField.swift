import Foundation

/// One field of an integration's sign-in form (declared; the UI does not use it yet).
public struct CredentialField: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case email
        case password
        case token
    }

    /// Stable key, e.g. `email`.
    public var id: String
    public var kind: Kind
    /// Stored only in the keychain and never shown again.
    public var isSecret: Bool

    public init(id: String, kind: Kind, isSecret: Bool) {
        self.id = id
        self.kind = kind
        self.isSecret = isSecret
    }
}
