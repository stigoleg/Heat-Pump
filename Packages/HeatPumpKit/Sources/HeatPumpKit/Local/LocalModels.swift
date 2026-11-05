import Foundation

/// User settings for the local connection (shared by the app and the MCP helper). Default off.
public struct LocalSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// IPv4 address of the Wi-Fi adapter on the home network.
    public var host: String?

    public init(enabled: Bool = false, host: String? = nil) {
        self.enabled = enabled
        self.host = host
    }

    public static let `default` = LocalSettings()
}

/// Failure bookkeeping shared across processes (`app_settings`), used for back-off and health.
struct LocalStatusRecord: Codable, Sendable, Equatable {
    var consecutiveFailures = 0
    /// Start of the current run of failures.
    var failingSince: Date?
    var lastError: String?
}

/// Whether and how well the adapter answers.
public struct LocalReachability: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var host: String?
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var consecutiveFailures: Int
    public var failingSince: Date?
    /// Norwegian text of the last failure.
    public var lastError: String?
    /// Earliest next read (20 s spacing, longer after failures).
    public var nextAttemptAllowed: Date?
}

/// Latest local reading plus freshness.
public struct LiveStatus: Codable, Sendable, Equatable {
    public var sample: LocalSample?
    public var ageSeconds: Int?
    /// True when this call read the adapter.
    public var refreshed: Bool
    public var reachability: LocalReachability
    /// Norwegian message when the read failed or was not possible.
    public var message: String?
}

/// Power and compressor activity aggregated over one time bucket.
public struct LocalPowerBucket: Codable, Sendable, Equatable {
    public var start: Date
    public var averageW: Double
    public var maxW: Double
    public var minW: Double
    public var averageHz: Double
    public var maxHz: Double
    /// Share of readings with the compressor running (0…1).
    public var runningShare: Double
    public var count: Int
}

/// Everything `get_live_status` returns.
public struct LiveSummary: Codable, Sendable, Equatable {
    public struct PowerStats: Codable, Sendable, Equatable {
        public var minW: Int
        public var averageW: Int
        public var maxW: Int
        public var readings: Int
    }

    public var live: LiveStatus
    /// Compressor starts in the last 1, 3 and 24 hours (only seen while readings were ≤ 5 min apart).
    public var startsLastHour: Int
    public var startsLast3Hours: Int
    public var startsLast24Hours: Int
    /// Hours of the last 24 with readings close enough together to count starts.
    public var observedHoursLast24: Double
    public var powerLast60Minutes: PowerStats?
}

/// Result of "Test" in Settings.
public struct LocalTestResult: Sendable, Equatable {
    public var ok: Bool
    public var message: String
    public var sample: LocalSample?

    public init(ok: Bool, message: String, sample: LocalSample?) {
        self.ok = ok
        self.message = message
        self.sample = sample
    }
}

/// Result of "Finn automatisk".
public struct LocalDiscoveryResult: Sendable, Equatable {
    public var host: String?
    public var message: String

    public init(host: String?, message: String) {
        self.host = host
        self.message = message
    }
}

/// Finds the adapter on the Mac's own subnet by its hardware address.
public protocol LocalNetworkScanning: Sendable {
    /// IPv4 addresses on the local /24 whose hardware address is `mac` (any notation).
    func hosts(matchingMAC mac: String) async throws -> [String]
}

/// How the service reaches the adapter. Injected so tests and demo mode never touch the network.
public struct LocalAccess: Sendable {
    public var makeClient: @Sendable (String) throws -> any LocalStatusReading
    public var scanner: any LocalNetworkScanning
    /// Demo mode only: seed history with short compressor cycles too.
    public var simulatedShortCycling: Bool

    public init(
        makeClient: @escaping @Sendable (String) throws -> any LocalStatusReading, scanner: any LocalNetworkScanning,
        simulatedShortCycling: Bool = false
    ) {
        self.makeClient = makeClient
        self.scanner = scanner
        self.simulatedShortCycling = simulatedShortCycling
    }

    /// No local access (default; tests opt in with fakes).
    public static let unavailable = LocalAccess(
        makeClient: { _ in throw LocalAccessError.notConfigured }, scanner: NoNetworkScanner())

    /// The real adapter over HTTP on the home network.
    public static let network = LocalAccess(makeClient: { try LocalSmartClient(host: $0) }, scanner: ARPScanner())
}

struct NoNetworkScanner: LocalNetworkScanning {
    func hosts(matchingMAC mac: String) async throws -> [String] { [] }
}

/// Normalised hardware address: 12 lowercase hex digits, or nil.
func normalizedMAC(_ text: String) -> String? {
    let hex = text.lowercased().filter(\.isHexDigit)
    return hex.count == 12 ? hex : nil
}
