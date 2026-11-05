import Foundation

/// A bundled Norwegian knowledge document (markdown).
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

    public static func all() -> [KnowledgeDocument] {
        names.compactMap(document(named:))
    }

    public static func document(named name: String) -> KnowledgeDocument? {
        guard names.contains(name),
            let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Knowledge"),
            let markdown = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let title = markdown.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? name
        return KnowledgeDocument(name: name, title: title, markdown: markdown)
    }
}
