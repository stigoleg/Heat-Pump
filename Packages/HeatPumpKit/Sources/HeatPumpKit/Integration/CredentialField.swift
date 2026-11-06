import Foundation

/// One field of an integration's sign-in form (the app's generic sign-in form draws it).
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
    /// Where the user gets the value (e.g. a page to create a token), shown as a link by the field.
    public var helpURL: URL?

    public init(id: String, kind: Kind, isSecret: Bool, helpURL: URL? = nil) {
        self.id = id
        self.kind = kind
        self.isSecret = isSecret
        self.helpURL = helpURL
    }
}
