import Foundation
import Testing
@testable import HeatPumpKit

@Suite("App update")
struct AppUpdateTests {
    @Test func versionsCompareNumerically() throws {
        let v = { (text: String) throws -> AppVersion in try #require(AppVersion(text)) }
        #expect(try v("1.1.5") > v("1.1.0"))
        #expect(try v("v1.10.0") > v("1.9.9"))
        #expect(try v("1.1") == v("1.1.0"))
        #expect(try v("2.0.0") > v("1.99.99"))
        #expect(try v("v1.1.5").description == "1.1.5")
        for bad in ["", "v", "1..2", "1.2.x", "1.2.3-beta", "-1.0", "1.2.3.4.5"] {
            #expect(AppVersion(bad) == nil, "\(bad)")
        }
    }

    /// Shape of GitHub's /releases/latest (trimmed), as published by the Release workflow.
    private func releaseJSON(tag: String = "v1.1.5", draft: Bool = false, digest: String? = String(repeating: "AB", count: 32), assets: [String]? = nil) -> Data {
        let names = assets ?? ["Varmepumpe-1.1.5.zip", "Varmepumpe-1.1.5.zip.sha256"]
        let list = names.map { name -> [String: Any] in
            var asset: [String: Any] = [
                "name": name, "browser_download_url": "https://github.com/stigoleg/Husly/releases/download/\(tag)/\(name)",
            ]
            if name.hasSuffix(".zip"), let digest { asset["digest"] = "sha256:\(digest)" }
            return asset
        }
        let object: [String: Any] = [
            "tag_name": tag, "name": "Varmepumpe 1.1.5", "draft": draft, "prerelease": false,
            "published_at": "2026-11-05T21:21:08Z", "html_url": "https://github.com/stigoleg/Husly/releases/tag/\(tag)",
            "body": "- **Oppdateringer**: ny\n", "assets": list,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func parsesLatestRelease() throws {
        let release = try AppUpdate.parseRelease(releaseJSON())
        #expect(release.version == AppVersion("1.1.5"))
        #expect(release.zipName == "Varmepumpe-1.1.5.zip")
        #expect(release.zipURL.absoluteString.hasSuffix("/v1.1.5/Varmepumpe-1.1.5.zip"))
        #expect(release.zipDigest == String(repeating: "ab", count: 32))
        #expect(release.checksumURL?.lastPathComponent == "Varmepumpe-1.1.5.zip.sha256")
        #expect(release.notes == "- **Oppdateringer**: ny")
        #expect(release.publishedAt != nil)
    }

    @Test func refusesReleasesWithoutAnApp() {
        #expect(throws: AppUpdate.ParseError.draftOrPrerelease) { try AppUpdate.parseRelease(releaseJSON(draft: true)) }
        #expect(throws: AppUpdate.ParseError.badVersion("nightly")) { try AppUpdate.parseRelease(releaseJSON(tag: "nightly")) }
        #expect(throws: AppUpdate.ParseError.noZip) { try AppUpdate.parseRelease(releaseJSON(assets: ["notes.txt"])) }
        #expect(throws: AppUpdate.ParseError.notJSON) { try AppUpdate.parseRelease(Data("<html>".utf8)) }
    }

    @Test func digestIsOptional() throws {
        let release = try AppUpdate.parseRelease(releaseJSON(digest: nil))
        #expect(release.zipDigest == nil)
        #expect(release.checksumURL != nil)
        #expect(try AppUpdate.parseRelease(releaseJSON(digest: "nothex")).zipDigest == nil)
    }

    @Test func readsShasumOutput() {
        let hash = "f7d7da3d91097fee0ed657e32269a8a457241a54611e42bae5458bb6e4795c95"
        #expect(AppUpdate.parseChecksum("\(hash)  Varmepumpe-1.1.0.zip\n", fileName: "Varmepumpe-1.1.0.zip") == hash)
        #expect(AppUpdate.parseChecksum("\(hash.uppercased()) *Varmepumpe-1.1.0.zip", fileName: "Varmepumpe-1.1.0.zip") == hash)
        #expect(AppUpdate.parseChecksum(hash, fileName: "Varmepumpe-1.1.0.zip") == hash)
        #expect(AppUpdate.parseChecksum("\(hash)  Other.zip", fileName: "Varmepumpe-1.1.0.zip") == nil)
        #expect(AppUpdate.parseChecksum("garbage", fileName: "Varmepumpe-1.1.0.zip") == nil)
    }

    @Test func checksOncePerDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AppUpdate.isCheckDue(lastCheck: nil, now: now))
        #expect(!AppUpdate.isCheckDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(AppUpdate.isCheckDue(lastCheck: now.addingTimeInterval(-AppUpdate.checkInterval), now: now))
        // A clock set back does not stop checks for good.
        #expect(AppUpdate.isCheckDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }
}
