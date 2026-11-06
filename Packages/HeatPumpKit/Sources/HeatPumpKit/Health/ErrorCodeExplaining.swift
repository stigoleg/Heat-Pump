import Foundation

/// How much we trust an error-code explanation.
public enum CatalogConfidence: String, Codable, Sendable {
    /// Text that the service itself returned. The raw value is persisted in MCP output and kept.
    case serviceText = "melcloud"
    /// From a vendor document for a closely related model.
    case medium
    /// Generic vendor code or community knowledge, not confirmed for this model.
    case low
    /// Nothing known.
    case unknown
}

public struct ErrorCatalogEntry: Codable, Sendable, Equatable {
    public var code: String
    public var title: String
    public var explanation: String
    public var recommendation: String
    public var confidence: CatalogConfidence
    public var source: String

    public init(code: String, title: String, explanation: String, recommendation: String, confidence: CatalogConfidence, source: String) {
        self.code = code
        self.title = title
        self.explanation = explanation
        self.recommendation = recommendation
        self.confidence = confidence
        self.source = source
    }
}

/// An integration's error-code knowledge, used by the health check, the Health page's error log
/// and the MCP helper. Every entry carries a `confidence`.
public protocol ErrorCodeExplaining: Sendable {
    /// Repeated in user-facing text whenever an explanation is uncertain.
    var caveat: String { get }
    /// Whether there is an own explanation for a numeric code.
    func hasExplanation(errorCode: Int?) -> Bool
    /// Explains an error. The service's own `message` text wins when present.
    func lookup(errorCode: Int?, message: String?) -> ErrorCatalogEntry
}

extension ErrorCodeExplaining {
    public func lookup(errorCode: Int?) -> ErrorCatalogEntry { lookup(errorCode: errorCode, message: nil) }
}
