import Foundation
import Testing
@testable import HeatPumpKit

@Suite("Keychain access")
struct KeychainAccessTests {
    @Test func appAndHelperTrustedFromEitherBinary() {
        let exists: (String) -> Bool = { $0.hasSuffix("Contents/Helpers/varmepumpe-mcp") }
        let expected = ["/Applications/Varmepumpe.app", "/Applications/Varmepumpe.app/Contents/Helpers/varmepumpe-mcp"]
        #expect(
            KeychainAccess.trustedPaths(
                executable: URL(filePath: "/Applications/Varmepumpe.app/Contents/MacOS/Varmepumpe"), fileExists: exists)
                == expected)
        #expect(
            KeychainAccess.trustedPaths(
                executable: URL(filePath: "/Applications/Varmepumpe.app/Contents/Helpers/varmepumpe-mcp"), fileExists: exists)
                == expected)
    }

    @Test func outsideAppBundleKeepsDefaultAccess() {
        #expect(KeychainAccess.trustedPaths(executable: URL(filePath: "/usr/local/bin/varmepumpe-mcp")) == nil)
        #expect(KeychainAccess.trustedPaths(executable: nil) == nil)
    }

    @Test func tokenCacheReadsOnce() {
        let cache = TokenCache()
        var reads = 0
        #expect(cache.value { reads += 1; return nil } == nil)
        #expect(cache.value { reads += 1; return "x" } == nil)
        #expect(reads == 1)
        cache.set("ny")
        #expect(cache.value { reads += 1; return nil } == "ny")
        #expect(reads == 1)
    }

    @Test func storedEmailDefaultsToCredentials() {
        let store = InMemoryCredentialStore(credentials: MELCloudCredentials(email: "a@b.no", password: "pw"))
        #expect(store.storedEmail() == "a@b.no")
    }
}
