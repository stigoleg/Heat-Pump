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
    /// Text of the last failure.
    public var lastError: String?
    /// Earliest next read (20 s spacing, longer after failures).
    public var nextAttemptAllowed: Date?
    /// False when the Mac is on another network than the saved address (reads are paused);
    /// nil without a saved address.
    public var onHomeNetwork: Bool?
}

/// Latest local reading plus freshness.
public struct LiveStatus: Codable, Sendable, Equatable {
    public var sample: LocalSample?
    public var ageSeconds: Int?
    /// True when this call read the adapter.
    public var refreshed: Bool
    public var reachability: LocalReachability
    /// Message when the read failed or was not possible.
    public var message: String?
}

/// Readings aggregated over one time bucket (computed in SQL).
public struct LocalPowerBucket: Codable, Sendable, Equatable {
    public var start: Date
    /// Average power over all readings, idle ones included (≈ mean power of the bucket).
    public var averageW: Double?
    public var maxW: Double?
    public var minW: Double?
    /// Average compressor frequency over all readings, stopped ones included.
    public var averageHz: Double?
    public var maxHz: Double?
    /// Average frequency while the compressor runs.
    public var averageRunningHz: Double?
    /// Share of readings with the compressor running (0…1).
    public var runningShare: Double
    /// Share of readings with the unit on in heat mode (nil without general-state data).
    public var heatingShare: Double?
    /// Average indoor − outdoor temperature (readings with both).
    public var averageDelta: Double?
    /// Seconds covered by readings ≤ 5 min apart (starts can only be seen there).
    public var observedSeconds: Double
    public var runningSeconds: Double
    public var starts: Int
    public var count: Int
    /// Defrosts started (sub-mode changed to defrost between readings ≤ 5 min apart).
    public var defrosts: Int
    /// Seconds spent defrosting (readings ≤ 5 min apart).
    public var defrostSeconds: Double
    /// Readings with a known sub-mode (0x09); defrost figures mean nothing without them.
    public var phaseCount: Int
    public var averageOutdoor: Double?

    public init(
        start: Date, averageW: Double? = nil, maxW: Double? = nil, minW: Double? = nil, averageHz: Double? = nil,
        maxHz: Double? = nil, averageRunningHz: Double? = nil, runningShare: Double = 0, heatingShare: Double? = nil,
        averageDelta: Double? = nil, observedSeconds: Double = 0, runningSeconds: Double = 0, starts: Int = 0, count: Int = 0,
        defrosts: Int = 0, defrostSeconds: Double = 0, phaseCount: Int = 0, averageOutdoor: Double? = nil
    ) {
        self.defrosts = defrosts
        self.defrostSeconds = defrostSeconds
        self.phaseCount = phaseCount
        self.averageOutdoor = averageOutdoor
        self.start = start
        self.averageW = averageW
        self.maxW = maxW
        self.minW = minW
        self.averageHz = averageHz
        self.maxHz = maxHz
        self.averageRunningHz = averageRunningHz
        self.runningShare = runningShare
        self.heatingShare = heatingShare
        self.averageDelta = averageDelta
        self.observedSeconds = observedSeconds
        self.runningSeconds = runningSeconds
        self.starts = starts
        self.count = count
    }
}

extension LocalPowerBucket {
    /// Several buckets combined into one (averages weighted by readings), or nil when empty.
    public static func merged(_ buckets: [LocalPowerBucket]) -> LocalPowerBucket? {
        guard let first = buckets.first else { return nil }
        let count = buckets.reduce(0) { $0 + $1.count }
        func average(_ value: (LocalPowerBucket) -> Double?) -> Double? {
            let parts = buckets.compactMap { b in value(b).map { ($0, Double(b.count)) } }
            let weight = parts.reduce(0) { $0 + $1.1 }
            return weight > 0 ? parts.reduce(0) { $0 + $1.0 * $1.1 } / weight : nil
        }
        return LocalPowerBucket(
            start: first.start, averageW: average(\.averageW), maxW: buckets.compactMap(\.maxW).max(),
            minW: buckets.compactMap(\.minW).min(), averageHz: average(\.averageHz), maxHz: buckets.compactMap(\.maxHz).max(),
            averageRunningHz: average(\.averageRunningHz), runningShare: average { $0.runningShare } ?? 0,
            heatingShare: average(\.heatingShare), averageDelta: average(\.averageDelta),
            observedSeconds: buckets.reduce(0) { $0 + $1.observedSeconds },
            runningSeconds: buckets.reduce(0) { $0 + $1.runningSeconds }, starts: buckets.reduce(0) { $0 + $1.starts },
            count: count, defrosts: buckets.reduce(0) { $0 + $1.defrosts },
            defrostSeconds: buckets.reduce(0) { $0 + $1.defrostSeconds }, phaseCount: buckets.reduce(0) { $0 + $1.phaseCount },
            averageOutdoor: average(\.averageOutdoor))
    }
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
    /// Defrosts started and minutes defrosting in the last 24 h (nil without 0x09 data).
    public var defrostsLast24Hours: Int?
    public var defrostMinutesLast24Hours: Double?
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

/// Result of "Find automatically".
public struct LocalDiscoveryResult: Sendable, Equatable {
    public var host: String?
    public var message: String

    public init(host: String?, message: String) {
        self.host = host
        self.message = message
    }
}

/// One read-only status request to a local adapter (the real client, or a test fake).
public protocol LocalStatusReading: Sendable {
    /// Reads the adapter once and returns the parsed reading, stamped with `now()` taken when the
    /// answer arrived. Throws `LocalAccessError.noFrames` when the answer holds no readings.
    func readSample(now: @Sendable () -> Date) async throws -> LocalSample
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
    /// The /24 networks (network base, host byte order) the Mac is on right now. Automatic reads
    /// only happen when the saved address is in one of them.
    public var currentSubnets: @Sendable () -> [UInt32]
    /// Demo mode only: seed history with short compressor cycles too.
    public var simulatedShortCycling: Bool

    public init(
        makeClient: @escaping @Sendable (String) throws -> any LocalStatusReading, scanner: any LocalNetworkScanning,
        currentSubnets: @escaping @Sendable () -> [UInt32], simulatedShortCycling: Bool = false
    ) {
        self.makeClient = makeClient
        self.scanner = scanner
        self.currentSubnets = currentSubnets
        self.simulatedShortCycling = simulatedShortCycling
    }

    /// No local access (default; tests opt in with fakes).
    public static let unavailable = LocalAccess(
        makeClient: { _ in throw LocalAccessError.notConfigured }, scanner: NoNetworkScanner(), currentSubnets: { [] })

    /// Accepts dotted IPv4 addresses in the private ranges (10/8, 172.16/12, 192.168/16) only,
    /// so a local client can never be pointed at anything outside the home network.
    public static func validatedHost(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                let value = Int(part), (0...255).contains(value)
            else { return nil }
            octets.append(value)
        }
        let isPrivate =
            octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168)
        guard isPrivate, octets[3] != 0, octets[3] != 255 else { return nil }
        return octets.map(String.init).joined(separator: ".")
    }
}

/// Network base of the /24 containing a dotted IPv4 address.
package func subnet24(_ host: String) -> UInt32? {
    let parts = host.split(separator: ".").compactMap { UInt32($0) }
    guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
    return parts[0] << 24 | parts[1] << 16 | parts[2] << 8
}

struct NoNetworkScanner: LocalNetworkScanning {
    func hosts(matchingMAC mac: String) async throws -> [String] { [] }
}

/// Normalised hardware address: 12 lowercase hex digits, or nil.
package func normalizedMAC(_ text: String) -> String? {
    let hex = text.lowercased().filter(\.isHexDigit)
    return hex.count == 12 ? hex : nil
}
