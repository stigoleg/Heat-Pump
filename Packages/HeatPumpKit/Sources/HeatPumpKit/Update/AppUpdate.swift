import Foundation

/// A release version such as 1.2.3 (a leading "v" is accepted). Missing parts count as 0.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") { trimmed.removeFirst() }
        let pieces = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy(\.isASCII), let value = Int(piece), value >= 0 else { return nil }
            parts.append(value)
        }
        self.parts = parts
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let l = index < lhs.parts.count ? lhs.parts[index] : 0
            let r = index < rhs.parts.count ? rhs.parts[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    public func hash(into hasher: inout Hasher) {
        var parts = parts
        while parts.last == 0 { parts.removeLast() }
        hasher.combine(parts)
    }
}

/// A published release with a downloadable app, from GitHub's "latest release" endpoint.
public struct AppRelease: Equatable, Sendable {
    public let version: AppVersion
    public let title: String
    /// Release notes (Markdown, from the changelog).
    public let notes: String
    public let publishedAt: Date?
    public let pageURL: URL?
    public let zipURL: URL
    public let zipName: String
    /// SHA-256 of the zip as lowercase hex, when GitHub reports it on the asset.
    public let zipDigest: String?
    /// The `<zip>.sha256` asset written by scripts/release.sh, if present.
    public let checksumURL: URL?

    public init(
        version: AppVersion, title: String, notes: String, publishedAt: Date?, pageURL: URL?,
        zipURL: URL, zipName: String, zipDigest: String?, checksumURL: URL?
    ) {
        self.version = version
        self.title = title
        self.notes = notes
        self.publishedAt = publishedAt
        self.pageURL = pageURL
        self.zipURL = zipURL
        self.zipName = zipName
        self.zipDigest = zipDigest
        self.checksumURL = checksumURL
    }
}

public enum AppUpdate {
    public static let repository = "stigoleg/Heat-Pump"
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let releasesPageURL = URL(string: "https://github.com/\(repository)/releases")!
    /// Developer ID team that signs releases.
    public static let teamIdentifier = "49P95434EE"
    public static let bundleIdentifier = "com.stigole.varmepumpe"
    /// Code requirement a downloaded app must meet before it replaces the running one:
    /// Developer ID signed by this team, with this app's identifier.
    public static let codeRequirement =
        "anchor apple generic and identifier \"\(bundleIdentifier)\""
        + " and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */"
        + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    /// Automatic checks run at most this often.
    public static let checkInterval: TimeInterval = 24 * 3600

    public enum ParseError: Error, Equatable {
        case notJSON
        case draftOrPrerelease
        case badVersion(String)
        case noZip
    }

    /// Reads GitHub's release JSON. The app is the `Varmepumpe-<version>.zip` asset.
    public static func parseRelease(_ data: Data) throws -> AppRelease {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON }
        if object["draft"] as? Bool == true || object["prerelease"] as? Bool == true { throw ParseError.draftOrPrerelease }
        let tag = object["tag_name"] as? String ?? ""
        guard let version = AppVersion(tag) else { throw ParseError.badVersion(tag) }
        let assets = object["assets"] as? [[String: Any]] ?? []
        func url(_ asset: [String: Any]) -> URL? {
            (asset["browser_download_url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        }
        let expected = "Varmepumpe-\(version).zip"
        let zips = assets.filter { ($0["name"] as? String)?.hasSuffix(".zip") == true && url($0) != nil }
        guard let zip = zips.first(where: { $0["name"] as? String == expected }) ?? zips.first,
            let zipName = zip["name"] as? String, let zipURL = url(zip)
        else { throw ParseError.noZip }
        let digest = (zip["digest"] as? String).flatMap { value -> String? in
            guard value.hasPrefix("sha256:") else { return nil }
            return normalizedHex(String(value.dropFirst("sha256:".count)))
        }
        let checksum = assets.first { $0["name"] as? String == zipName + ".sha256" }.flatMap(url)
        let published = (object["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return AppRelease(
            version: version,
            title: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Varmepumpe \(version)",
            notes: (object["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            publishedAt: published,
            pageURL: (object["html_url"] as? String).flatMap(URL.init(string:)),
            zipURL: zipURL, zipName: zipName, zipDigest: digest, checksumURL: checksum)
    }

    /// The hash for `fileName` in `shasum -a 256` output ("<hex>  <name>"), or the only hash.
    public static func parseChecksum(_ text: String, fileName: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace) }
        let entries = lines.compactMap { fields -> (hash: String, name: String?)? in
            guard let first = fields.first, let hash = normalizedHex(String(first)) else { return nil }
            let name = fields.dropFirst().first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "*")) }
            return (hash, name)
        }
        if let match = entries.first(where: { $0.name == fileName }) { return match.hash }
        return entries.count == 1 && entries[0].name == nil ? entries[0].hash : nil
    }

    /// True when an automatic check is due.
    public static func isCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval || lastCheck > now
    }

    /// 64 hex digits, lowercased, or nil.
    static func normalizedHex(_ text: String) -> String? {
        let lower = text.lowercased()
        guard lower.count == 64, lower.allSatisfy({ $0.isHexDigit }) else { return nil }
        return lower
    }
}
