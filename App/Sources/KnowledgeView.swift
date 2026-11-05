import HeatPumpKit
import SwiftUI

struct KnowledgeSheet: View {
    let document: KnowledgeDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                MarkdownView(markdown: document.markdown)
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Ferdig") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 600)
    }
}

/// Small read-only renderer for the bundled knowledge markdown:
/// headings, paragraphs, bullet and numbered lists, and pipe tables.
struct MarkdownView: View {
    let markdown: String

    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String)
        case numbered(String, String)
        case table([[String]])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level == 1 ? .title.bold() : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level == 1 ? 0 : 8)
        case .paragraph(let text):
            Text(inline(text)).fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text(inline(text)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 8)
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(number).monospacedDigit()
                Text(inline(text)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 8)
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell))
                                .font(index == 0 ? .callout.weight(.semibold) : .callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var table: [[String]] = []
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
            if !table.isEmpty {
                blocks.append(.table(table))
                table = []
            }
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("|") {
                if !paragraph.isEmpty { flush() }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
                table.append(cells)
            } else if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"),
                line[hashes] == " "
            {
                flush()
                let level = line.distance(from: line.startIndex, to: hashes)
                blocks.append(.heading(level, String(line[hashes...]).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), dot > line.startIndex,
                line[..<dot].allSatisfy(\.isNumber), line[line.index(after: dot)...].hasPrefix(" ")
            {
                flush()
                blocks.append(
                    .numbered(String(line[...dot]), String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)))
            } else {
                if !table.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}
