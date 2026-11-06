import Foundation
import HeatPumpKit

/// E-mail and password for a MELCloud account, over the generic `CredentialValues`.
public struct MELCloudCredentials: Sendable, Equatable {
    public var email: String
    public var password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }

    /// Nil unless both fields are there.
    public init?(_ values: CredentialValues) {
        guard let email = values["email"], let password = values["password"] else { return nil }
        self.init(email: email, password: password)
    }

    public var values: CredentialValues { CredentialValues(["email": email, "password": password]) }
}

/// MELCloud's view of a credential store, through `MELCloudIntegration.credentialMapping`.
extension CredentialProviding {
    func loadCredentials() throws -> MELCloudCredentials? {
        try loadValues(for: MELCloudIntegration.credentialMapping).flatMap(MELCloudCredentials.init)
    }

    func storedEmail() -> String? { storedIdentity(for: MELCloudIntegration.credentialMapping) }

    /// MELCloud's session token (`X-MitsContextKey`), shared by the app and the helper.
    func loadContextKey() -> String? { loadSessionKey(for: MELCloudIntegration.credentialMapping) }

    func saveContextKey(_ key: String?) throws { try saveSessionKey(key, for: MELCloudIntegration.credentialMapping) }
}
