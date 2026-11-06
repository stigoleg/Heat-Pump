import AppKit
import CryptoKit
import HeatPumpKit
import Observation
import Security
import UserNotifications

/// Updates the app from GitHub releases. Checks once a day (and on request), downloads the zip,
/// checks its SHA-256, unpacks it next to the installed app and only accepts it when it is a
/// notarized Developer ID build of this app from the same team. The swap is atomic: when the
/// app quits (automatic mode) or at once with a relaunch ("Installer og start på nytt").
@MainActor
@Observable
final class Updater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        /// Downloaded and verified; installed on quit or with `installAndRelaunch()`.
        case ready
        case installing
        case failed(String)
    }

    private(set) var phase = Phase.idle
    /// The newest release seen, when it is newer than the running app.
    private(set) var release: AppRelease?
    private(set) var lastCheck: Date?
    /// The running version (CFBundleShortVersionString).
    let current: AppVersion?
    /// Why this copy cannot replace itself (development build, read-only folder), or nil.
    let installBlocker: String?

    /// Check, download and install (on quit) without asking.
    var automatic: Bool {
        didSet { defaults.set(automatic, forKey: Self.automaticKey) }
    }

    var canInstall: Bool { installBlocker == nil }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var staged: Staged?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var installed = false

    private static let automaticKey = "updates.automatic"
    private static let lastCheckKey = "updates.lastCheck"

    /// A verified app unpacked in a folder on the same volume as the installed one.
    private struct Staged {
        let version: AppVersion
        let folder: URL
        let app: URL
    }

    init(bundle: Bundle = .main) {
        current = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
        installBlocker = Self.blocker(for: bundle.bundleURL)
    }

    // MARK: Schedule

    /// Daily automatic check, the first a little after launch.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                guard let self else { return }
                if self.automatic, AppUpdate.isCheckDue(lastCheck: self.lastCheck, now: Date()) {
                    await self.check(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    // MARK: Check

    /// Asks GitHub for the latest release. In automatic mode a newer one is downloaded at once.
    func check(userInitiated: Bool) async {
        guard ![.checking, .downloading, .installing].contains(phase) else { return }
        if phase == .ready, !userInitiated { return }
        phase = .checking
        let found: AppRelease?
        do {
            found = try await Self.fetchLatest(current: current)
        } catch {
            phase = userInitiated ? .failed(Self.message(error)) : .idle
            return
        }
        lastCheck = Date()
        defaults.set(lastCheck, forKey: Self.lastCheckKey)
        guard let found, let current, found.version > current else {
            release = nil
            phase = .upToDate
            return
        }
        release = found
        if let staged, staged.version == found.version {
            phase = .ready
            return
        }
        phase = .available
        if automatic, canInstall { await download() }
    }

    // MARK: Download

    /// Downloads and verifies the release found by `check`.
    func download() async {
        guard let release, canInstall, phase == .available || isFailed else { return }
        phase = .downloading
        do {
            let next = try await Self.fetchAndVerify(release, installedApp: Bundle.main.bundleURL, current: current)
            if let old = staged { try? FileManager.default.removeItem(at: old.folder) }
            staged = Staged(version: release.version, folder: next.folder, app: next.app)
            phase = .ready
            if automatic { await notifyReady(release.version) }
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: Install

    /// Swaps in the new version, then quits and opens it again.
    func installAndRelaunch() {
        guard let staged, !installed else { return }
        phase = .installing
        let target = Bundle.main.bundleURL
        do {
            try Self.swap(staged.app, into: target)
        } catch {
            phase = .failed(Self.message(error))
            return
        }
        installed = true
        // Opens the new version once this process has ended and removes the old one.
        AppRelauncher.relaunch(target, removing: staged.folder)
    }

    /// From `applicationWillTerminate`: in automatic mode a downloaded update replaces the app now,
    /// so it opens as the new version next time. Otherwise the download is thrown away.
    func finishOnQuit() {
        guard !installed, let staged else { return }
        if automatic {
            try? Self.swap(staged.app, into: Bundle.main.bundleURL)
            installed = true
        }
        try? FileManager.default.removeItem(at: staged.folder)
    }

    // MARK: Steps (off the main actor)

    enum UpdateError: LocalizedError {
        case http(Int)
        case noChecksum
        case checksumMismatch
        case unpackFailed
        case wrongApp(String)
        case notTrusted(OSStatus)
        case swapFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .http(let code):
                code == 403 || code == 429
                    ? "GitHub avviste forespørselen (for mange på kort tid). Prøv igjen senere."
                    : "GitHub svarte med feilkode \(code)."
            case .noChecksum: "Utgivelsen mangler sjekksum, så nedlastingen kan ikke kontrolleres."
            case .checksumMismatch: "Nedlastingen var ødelagt (sjekksummen stemte ikke). Prøv igjen."
            case .unpackFailed: "Kunne ikke pakke ut oppdateringen."
            case .wrongApp(let detail): "Nedlastingen er ikke en gyldig Varmepumpe-versjon: \(detail)."
            case .notTrusted(let status):
                "Oppdateringen er ikke signert og notarisert av samme utvikler (kode \(status)), så den installeres ikke."
            case .swapFailed(let code): "Kunne ikke bytte ut appen (feil \(code))."
            }
        }
    }

    private nonisolated static func message(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        if (error as? URLError)?.code == .notConnectedToInternet { return "Ingen internettforbindelse." }
        return error.localizedDescription
    }

    private nonisolated static func request(_ url: URL, current: AppVersion?) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Varmepumpe/\(current?.description ?? "0")", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The latest release, or nil when the repository has none yet.
    private nonisolated static func fetchLatest(current: AppVersion?) async throws -> AppRelease? {
        var request = request(AppUpdate.latestReleaseURL, current: current)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw UpdateError.http(status) }
        return try AppUpdate.parseRelease(data)
    }

    /// Downloads, checks the hash, unpacks next to `installedApp` and checks the signature.
    private nonisolated static func fetchAndVerify(
        _ release: AppRelease, installedApp: URL, current: AppVersion?
    ) async throws -> (folder: URL, app: URL) {
        var expected = release.zipDigest
        if expected == nil, let checksumURL = release.checksumURL {
            let (data, response) = try await URLSession.shared.data(for: request(checksumURL, current: current))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.noChecksum }
            expected = AppUpdate.parseChecksum(String(decoding: data, as: UTF8.self), fileName: release.zipName)
        }
        guard let expected else { throw UpdateError.noChecksum }

        let (download, response) = try await URLSession.shared.download(for: request(release.zipURL, current: current))
        defer { try? FileManager.default.removeItem(at: download) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.http(status) }
        let hash = try await Task.detached { () throws -> String in
            let data = try Data(contentsOf: download, options: .alwaysMapped)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }.value
        guard hash == expected else { throw UpdateError.checksumMismatch }

        // Same volume as the installed app, so the swap is a rename.
        let folder = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installedApp, create: true)
        do {
            guard try await run("/usr/bin/ditto", ["-x", "-k", download.path, folder.path]) == 0 else {
                throw UpdateError.unpackFailed
            }
            let app = folder.appendingPathComponent("Varmepumpe.app")
            guard let info = Bundle(url: app)?.infoDictionary else { throw UpdateError.wrongApp("fant ikke Varmepumpe.app") }
            guard info["CFBundleIdentifier"] as? String == AppUpdate.bundleIdentifier else {
                throw UpdateError.wrongApp("feil identitet")
            }
            guard let version = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init), version == release.version
            else { throw UpdateError.wrongApp("versjonen stemmer ikke med utgivelsen") }
            try await Task.detached { try checkSignature(app) }.value
            return (folder, app)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Developer ID from the same team, this app's identifier, notarized, every nested binary valid.
    private nonisolated static func checkSignature(_ app: URL) throws {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw UpdateError.notTrusted(status) }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString((AppUpdate.codeRequirement + " and notarized") as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { throw UpdateError.notTrusted(status) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else { throw UpdateError.notTrusted(status) }
    }

    /// Exchanges the two bundles in one step; the old version ends up where the new one was.
    private nonisolated static func swap(_ new: URL, into target: URL) throws {
        guard renamex_np(new.path, target.path, UInt32(RENAME_SWAP)) == 0 else { throw UpdateError.swapFailed(errno) }
        // Finder and Launch Services pick up the new version.
        NSWorkspace.shared.noteFileSystemChanged(target.path)
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Why the running copy cannot update itself, or nil.
    private static func blocker(for bundleURL: URL) -> String? {
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(AppUpdate.codeRequirement as CFString, [], &requirement) == errSecSuccess,
            let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        else {
            return "Dette er en utviklerversjon. Den oppdateres med make install, ikke herfra."
        }
        let files = FileManager.default
        guard files.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path), files.isWritableFile(atPath: bundleURL.path)
        else {
            return "Appen ligger i en mappe du ikke kan endre (\(bundleURL.deletingLastPathComponent().path)). Flytt den til Programmer-mappen, eller last ned nye versjoner selv."
        }
        return nil
    }

    private func notifyReady(_ version: AppVersion) async {
        let content = UNMutableNotificationContent()
        content.title = "Varmepumpe \(version) er klar"
        content.body = "Den installeres når du avslutter appen. Du kan også installere den nå under Innstillinger → Generelt."
        let request = UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
