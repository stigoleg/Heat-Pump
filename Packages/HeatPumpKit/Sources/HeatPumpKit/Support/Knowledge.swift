import Foundation

/// A bundled knowledge document (markdown) in English or Norwegian.
public struct KnowledgeDocument: Sendable, Equatable {
    /// File name without extension, e.g. `maintenance`.
    public var name: String
    public var title: String
    public var markdown: String

    public var uri: String { "varmepumpe://knowledge/\(name)" }
}

/// The documents one module ships. Each module with a `Knowledge/<lang>/*.md` folder has them
/// compiled into its own `KnowledgeContent.generated.swift` by `scripts/generate-knowledge.py`,
/// so the embedded helper needs no resource bundle.
public struct KnowledgeSource: Sendable {
    /// Document names in display order.
    public var names: [String]
    /// Language code → document name → markdown.
    public var documents: [String: [String: String]]

    public init(names: [String] = [], documents: [String: [String: String]] = [:]) {
        self.names = names
        self.documents = documents
    }
}

/// The knowledge documents for the active integration: the core's own (none yet) followed by
/// the integration's. Names and URIs are stable; the MCP helper lists them as resources.
public struct Knowledge: Sendable {
    public var sources: [KnowledgeSource]

    public init(integration: any Integration) {
        sources = [integration.knowledge]
    }

    /// Document names in display order.
    public var names: [String] { sources.flatMap(\.names) }

    public func all(language: L10n.Language = L10n.language) -> [KnowledgeDocument] {
        names.compactMap { document(named: $0, language: language) }
    }

    /// The document in `language`, falling back to English.
    public func document(named name: String, language: L10n.Language = L10n.language) -> KnowledgeDocument? {
        guard let source = sources.first(where: { $0.names.contains(name) }),
            let markdown = source.documents[language.rawValue]?[name] ?? source.documents["en"]?[name]
        else { return nil }
        let title = markdown.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? name
        return KnowledgeDocument(name: name, title: title, markdown: markdown)
    }
}
