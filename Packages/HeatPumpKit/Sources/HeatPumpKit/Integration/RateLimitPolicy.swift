import Foundation

/// How often the service may call an integration's cloud, and how it backs off. Enforced across
/// processes by `HistoryStore` (`reserveFetch`, `reserveChange`); drivers never retry on their own.
public struct RateLimitPolicy: Sendable, Equatable {
    /// Cached state younger than this is returned without a fetch.
    public var maxAge: TimeInterval
    /// Shortest gap between two state fetches, across processes.
    public var minRefreshInterval: TimeInterval
    /// Each report type (error log, temperature log, energy) is fetched at most this often.
    public var reportInterval: TimeInterval
    /// Used when a login throttle does not say how long it lasts.
    public var defaultLoginBlock: TimeInterval
    /// Global block after a persistent 401 (login works but the cloud still refuses).
    public var unauthorizedBlock: TimeInterval
    /// Longest a write waits for the cross-process spacing before giving up.
    public var maxWriteWait: TimeInterval
    /// Oldest device object a write may be based on (drivers with `requiresFreshStateForWrites`);
    /// older means a fresh read first.
    public var writeBaseMaxAge: TimeInterval
    public var changeBudget: ChangeBudgetPolicy

    public init(
        maxAge: TimeInterval, minRefreshInterval: TimeInterval, reportInterval: TimeInterval, defaultLoginBlock: TimeInterval,
        unauthorizedBlock: TimeInterval, maxWriteWait: TimeInterval, writeBaseMaxAge: TimeInterval, changeBudget: ChangeBudgetPolicy
    ) {
        self.maxAge = maxAge
        self.minRefreshInterval = minRefreshInterval
        self.reportInterval = reportInterval
        self.defaultLoginBlock = defaultLoginBlock
        self.unauthorizedBlock = unauthorizedBlock
        self.maxWriteWait = maxWriteWait
        self.writeBaseMaxAge = writeBaseMaxAge
        self.changeBudget = changeBudget
    }

    /// The limits the app has always used (MELCloud's): one fetch per minute, reports hourly,
    /// 12 writes per rolling hour with 5 s spacing.
    public static let standard = RateLimitPolicy(
        maxAge: 10 * 60, minRefreshInterval: 60, reportInterval: 3600, defaultLoginBlock: 30 * 60, unauthorizedBlock: 3600,
        maxWriteWait: 10, writeBaseMaxAge: 60, changeBudget: .standard)
}

/// Writes allowed per rolling window, across processes.
public struct ChangeBudgetPolicy: Sendable, Equatable {
    /// Maximum write requests per rolling window.
    public var maxChangesPerHour: Int
    public var window: TimeInterval
    /// Minimum time between two write requests.
    public var minSpacing: TimeInterval

    public init(maxChangesPerHour: Int, window: TimeInterval, minSpacing: TimeInterval) {
        self.maxChangesPerHour = maxChangesPerHour
        self.window = window
        self.minSpacing = minSpacing
    }

    public static let standard = ChangeBudgetPolicy(maxChangesPerHour: 12, window: 3600, minSpacing: 5)
}
