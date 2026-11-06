import Foundation

/// A bundled knowledge document (markdown) in English or Norwegian.
public struct KnowledgeDocument: Sendable, Equatable {
    /// File name without extension, e.g. `maintenance`.
    public var name: String
    public var title: String
    public var markdown: String

    public var uri: String { "varmepumpe://knowledge/\(name)" }
}

public enum Knowledge {
    /// Document names in display order.
    public static let names = [
        "unit-profile", "maintenance", "error-codes", "when-to-call-dealer", "safe-operating-guidance",
    ]

    public static func all(language: L10n.Language = L10n.language) -> [KnowledgeDocument] {
        names.compactMap { document(named: $0, language: language) }
    }

    /// The document in `language`, falling back to English.
    public static func document(named name: String, language: L10n.Language = L10n.language) -> KnowledgeDocument? {
        let markdown = KnowledgeContent.documents[language.rawValue]?[name] ?? KnowledgeContent.documents["en"]?[name]
        guard names.contains(name), let markdown else { return nil }
        let title = markdown.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? name
        return KnowledgeDocument(name: name, title: title, markdown: markdown)
    }
}
