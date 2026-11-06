import Foundation

/// Health rules an integration adds for its own units. `HealthEngine` runs the generic rules and
/// asks the integration at fixed points, so the order of the findings stays stable.
public protocol HealthCheckProviding: Sendable {
    /// Rules on the local adapter's own signals (its error codes, its link to the service). They
    /// come first among the local findings. `cloudErrorShown` is true when the service already
    /// reports an active error.
    func localAdapterFindings(_ input: LocalHealthInput, cloudErrorShown: Bool, now: Date) -> [HealthFinding]
}

/// For integrations without rules of their own.
public struct NoHealthChecks: HealthCheckProviding {
    public init() {}
    public func localAdapterFindings(_ input: LocalHealthInput, cloudErrorShown: Bool, now: Date) -> [HealthFinding] { [] }
}
