import Foundation
import Testing

/// The core names no vendor, so a second integration gets its own texts, error codes, health
/// rules and knowledge from its module. The app and the MCP helper may refer to the integration
/// in code, but every text they show comes from the integration (`serviceName`, `brandName`, …).
@Suite("Integration boundary")
struct BoundaryTests {
    static let vendorWords = ["MELCloud", "Mitsubishi", "MSZ-", "CN105"]

    /// Files that may name the vendor in their texts, and why.
    static let allowlist: [String: String] = [
        // Settings for the Mitsubishi Wi-Fi adapter; becomes an integration-provided settings
        // section with multi-device support (phase 4).
        "LocalSettingsView.swift": "integration-specific settings section"
    ]

    static let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let repository = package.deletingLastPathComponent().deletingLastPathComponent()

    @Test func coreNamesNoVendorOutsideComments() throws {
        let core = Self.package.appending(path: "Sources/HeatPumpKit")
        let files = try Self.files(in: core, recursive: true)
        #expect(files.contains { $0.lastPathComponent == "HeatPumpService.swift" })
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            // Markdown (knowledge documents) is compiled into the core as is.
            let checked = file.pathExtension == "swift" ? SwiftSourceScan(text).withoutComments : text
            let found = Self.vendorWords.filter(checked.contains)
            #expect(found.isEmpty, "\(file.path(percentEncoded: false)) names \(found)")
        }
    }

    @Test(arguments: ["App/Sources", "Packages/HeatPumpKit/Sources/varmepumpe-mcp"])
    func textsNameNoVendor(folder: String) throws {
        let files = try Self.files(in: Self.repository.appending(path: folder), recursive: false)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files where Self.allowlist[file.lastPathComponent] == nil {
            let strings = SwiftSourceScan(try String(contentsOf: file, encoding: .utf8)).stringLiterals
            let found = Self.vendorWords.filter(strings.contains)
            #expect(found.isEmpty, "\(folder)/\(file.lastPathComponent) has \(found) in a string literal")
        }
    }

    @Test func scanSeparatesCommentsStringsAndInterpolation() {
        let scan = SwiftSourceScan(
            ##"""
            // A comment
            let a = "text \(call("inner")) end" /* block /* nested */ */ + b
            let url = "https://example.com" // trailing
            let raw = #"raw "quoted" \#(x)"#
            let multi = """
                line "one"
                """
            """##)
        #expect(!scan.withoutComments.contains("comment"))
        #expect(!scan.withoutComments.contains("block"))
        #expect(!scan.withoutComments.contains("trailing"))
        #expect(scan.withoutComments.contains("let a"))
        #expect(scan.stringLiterals.contains("text "))
        #expect(scan.stringLiterals.contains("inner"))
        #expect(scan.stringLiterals.contains("https://example.com"))
        #expect(scan.stringLiterals.contains(#"raw "quoted" "#))
        #expect(scan.stringLiterals.contains(#"line "one""#))
        #expect(!scan.stringLiterals.contains("call"))
        #expect(!scan.stringLiterals.contains("let"))
    }

    static func files(in directory: URL, recursive: Bool) throws -> [URL] {
        if !recursive {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        }
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { ["swift", "md"].contains($0.pathExtension) }
    }
}

/// Splits Swift source into what is not a comment and what is inside string literals. Enough of
/// the grammar for this test: line and (nested) block comments, single-line, multi-line and raw
/// strings, escapes and interpolations (code, which may hold strings of its own).
struct SwiftSourceScan {
    /// Code and string literals, comments removed.
    private(set) var withoutComments = ""
    /// The text of every string literal, one per line; interpolated code is left out.
    private(set) var stringLiterals = ""
    private let s: [Character]
    private var i = 0

    init(_ text: String) {
        s = Array(text)
        code(untilClosingParenthesis: false)
    }

    private func at(_ offset: Int) -> Character? { i + offset < s.count ? s[i + offset] : nil }

    private func matches(_ pattern: [Character]) -> Bool {
        i + pattern.count <= s.count && Array(s[i..<(i + pattern.count)]) == pattern
    }

    private mutating func code(untilClosingParenthesis: Bool) {
        var depth = 0
        while i < s.count {
            let c = s[i]
            if c == "/" && at(1) == "/" {
                while i < s.count && s[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && at(1) == "*" {
                blockComment()
                continue
            }
            if (c == "\"" || c == "#") && string() { continue }
            if untilClosingParenthesis {
                if c == "(" { depth += 1 }
                if c == ")" {
                    if depth == 0 {
                        i += 1
                        return
                    }
                    depth -= 1
                }
            }
            withoutComments.append(c)
            i += 1
        }
    }

    private mutating func blockComment() {
        var depth = 0
        while i < s.count {
            if matches(["/", "*"]) {
                depth += 1
                i += 2
            } else if matches(["*", "/"]) {
                depth -= 1
                i += 2
                if depth == 0 { return }
            } else {
                i += 1
            }
        }
    }

    /// Reads a string literal starting at `i`; false (nothing read) when there is none.
    private mutating func string() -> Bool {
        var j = i
        while j < s.count && s[j] == "#" { j += 1 }
        let hashes = Array(repeating: Character("#"), count: j - i)
        guard j < s.count, s[j] == "\"" else { return false }
        let multiline = j + 2 < s.count && s[j + 1] == "\"" && s[j + 2] == "\""
        let quote: [Character] = multiline ? ["\"", "\"", "\""] : ["\""]
        i = j + quote.count
        let closing = quote + hashes
        let escape = [Character("\\")] + hashes
        while i < s.count {
            if matches(closing) {
                i += closing.count
                break
            }
            if matches(escape) {
                i += escape.count
                if at(0) == "(" {
                    i += 1
                    code(untilClosingParenthesis: true)
                } else if let escaped = at(0) {
                    stringLiterals.append(escaped)
                    withoutComments.append(escaped)
                    i += 1
                }
                continue
            }
            stringLiterals.append(s[i])
            withoutComments.append(s[i])
            i += 1
        }
        stringLiterals.append("\n")
        withoutComments.append(" ")
        return true
    }
}
