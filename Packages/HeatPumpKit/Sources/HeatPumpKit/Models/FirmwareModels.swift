import Foundation

/// Where a firmware update of the Wi-Fi adapter stands, mapped from MELCloud's `CurrentPhase` and
/// `CurrentApprovalStatus` the same way MELCloud's own web client does (`getFirmwareStatus`).
public enum FirmwareUpdatePhase: String, Codable, Sendable, CaseIterable {
    /// Waiting for the owner to approve (phase 0, approval 0/1).
    case approvalRequired
    /// Waiting for approval, but the unit has been offline for more than 5 minutes.
    case unitOffline
    /// Approved; waiting for the unit to fetch it (phase 1, approval 3/6).
    case approved
    /// Cancel requested (phase 1, approval 4).
    case cancelling
    /// The adapter is about to restart (phase 6).
    case resetPending
    /// The adapter is restarting (phase 7).
    case resetting
    /// Files are being downloaded (phase 2).
    case downloading
    /// Download is retried (phase 3).
    case retrying
    /// Done (phase 4).
    case complete
    /// MELCloud blocks the update (approval 5).
    case blocked
    /// Stopped before it finished (phase 5).
    case aborted
    /// Stopped because the unit was offline (phase 5, at least 5 minutes offline).
    case abortedOffline
    /// MELCloud forces the update (approval 6).
    case forced
    /// A combination the web client does not know either.
    case unknown

    /// First match wins, in exactly the web client's order. `minutesOffline` nil counts as 0.
    public static func from(phase: Int?, approval: Int?, minutesOffline: Int?) -> FirmwareUpdatePhase {
        guard let p = phase, let a = approval else { return .unknown }
        let m = minutesOffline ?? 0
        let approvedOrForced = a == 3 || a == 6
        if p == 0, a == 0 || a == 1 { return m > 5 ? .unitOffline : .approvalRequired }
        if p == 1, approvedOrForced { return .approved }
        if p == 1, a == 4 { return .cancelling }
        if p == 6, approvedOrForced { return .resetPending }
        if p == 7, approvedOrForced { return .resetting }
        if p == 2, approvedOrForced { return .downloading }
        if p == 3, approvedOrForced { return .retrying }
        if p == 4, a <= 6 { return .complete }
        if p != 5, a == 5 { return .blocked }
        if p == 5, a <= 4 || a == 6 { return m >= 5 ? .abortedOffline : .aborted }
        if p < 4 || p > 5, a == 6 { return .forced }
        return .unknown
    }

    /// Status text.
    public var displayText: String {
        switch self {
        case .approvalRequired: L10n.tr("New firmware is ready and waiting for you to start the update.")
        case .unitOffline: L10n.tr("New firmware is ready, but the unit is offline. The update can be started when it is connected again.")
        case .approved: L10n.tr("The update has started and is waiting for the unit to fetch it.")
        case .cancelling: L10n.tr("The update is being cancelled.")
        case .resetPending: L10n.tr("The Wi-Fi adapter will restart soon.")
        case .resetting: L10n.tr("The Wi-Fi adapter is restarting.")
        case .downloading: L10n.tr("The unit is downloading new firmware.")
        case .retrying: L10n.tr("The download is being retried.")
        case .complete: L10n.tr("The update is complete.")
        case .blocked: L10n.tr("MELCloud has blocked the update.")
        case .aborted: L10n.tr("The update was aborted. You can try again.")
        case .abortedOffline: L10n.tr("The update was aborted because the unit was offline.")
        case .forced: L10n.tr("MELCloud is carrying out a required update.")
        case .unknown: L10n.tr("MELCloud reports an unknown status for the update.")
        }
    }

    /// The web client offers "Approve" (or "Try again").
    public var canApprove: Bool { self == .approvalRequired || self == .aborted || self == .abortedOffline }

    /// The web client offers "Cancel".
    public var canCancel: Bool { self == .approved || self == .downloading || self == .retrying || self == .forced }

    /// Something is happening that is worth following closely.
    public var isInProgress: Bool {
        switch self {
        case .approved, .cancelling, .resetPending, .resetting, .downloading, .retrying, .forced: true
        default: false
        }
    }
}

/// One entry from `FirmwareUpdate/List2`. Every field is optional; the raw phase numbers are kept.
public struct FirmwareUpdateStatus: Codable, Sendable, Equatable {
    /// MELCloud's id of this update (sent back with Approve2/Cancel2).
    public var id: Int?
    public var deviceId: Int?
    public var currentPhase: Int?
    public var approvalStatus: Int?
    public var minutesOffline: Int?
    public var filesDownloaded: Int?
    public var filesToDownload: Int?
    public var retries: Int?
    public var dateApproved: Date?
    public var dateCreated: Date?
    public var lastCommunication: Date?

    public init(
        id: Int? = nil, deviceId: Int? = nil, currentPhase: Int? = nil, approvalStatus: Int? = nil, minutesOffline: Int? = nil,
        filesDownloaded: Int? = nil, filesToDownload: Int? = nil, retries: Int? = nil, dateApproved: Date? = nil,
        dateCreated: Date? = nil, lastCommunication: Date? = nil
    ) {
        self.id = id
        self.deviceId = deviceId
        self.currentPhase = currentPhase
        self.approvalStatus = approvalStatus
        self.minutesOffline = minutesOffline
        self.filesDownloaded = filesDownloaded
        self.filesToDownload = filesToDownload
        self.retries = retries
        self.dateApproved = dateApproved
        self.dateCreated = dateCreated
        self.lastCommunication = lastCommunication
    }

    public var phase: FirmwareUpdatePhase {
        .from(phase: currentPhase, approval: approvalStatus, minutesOffline: minutesOffline)
    }

    /// The unit has been offline longer than the web client accepts for starting an update.
    public var unitOffline: Bool { (minutesOffline ?? 0) > 5 }

    /// "x of y files" while files are known.
    public var progressText: String? {
        guard let total = filesToDownload, total > 0 else { return nil }
        return L10n.format("%lld of %lld files", min(filesDownloaded ?? 0, total), total)
    }

    /// Download progress 0…1 (nil when unknown).
    public var progress: Double? {
        guard let total = filesToDownload, total > 0 else { return nil }
        return Double(min(filesDownloaded ?? 0, total)) / Double(total)
    }

    /// Status text with progress, retries and the raw numbers for an unknown combination.
    public var displayText: String {
        var text = phase.displayText
        switch phase {
        case .downloading, .retrying:
            if let progress = progressText { text += " " + L10n.format("%@ downloaded.", progress) }
            if phase == .retrying, let retries, retries > 0 { text += " " + L10n.format("Attempt %lld.", retries) }
        case .unknown:
            text += " " + L10n.format("(phase %@, approval %@)", currentPhase.map(String.init) ?? "–", approvalStatus.map(String.init) ?? "–")
        default:
            break
        }
        return text
    }
}

/// Firmware state for the app and Claude: what the unit reports plus MELCloud's update list.
public struct FirmwareStatus: Codable, Sendable, Equatable {
    /// Adapter firmware version, e.g. "34.00".
    public var currentVersion: String?
    /// MELCloud has a newer firmware ready (`FirmwareDeployment` in the device listing).
    public var updateAvailable: Bool
    /// The account owns the unit (`AccessLevel` 4); only owners may start an update.
    public var isOwner: Bool?
    /// Entries from `FirmwareUpdate/List2` for this device.
    public var updates: [FirmwareUpdateStatus]
    /// When the list was read from MELCloud (nil: never).
    public var fetchedAt: Date?
    /// When this app or Claude last started an update.
    public var startedAt: Date?
    /// Note (reads paused, failed read …).
    public var message: String?
    /// Set by the service on every read: why an update cannot be started now (nil: it can).
    public var startProblem: String?
    /// Set by the service on every read: MELCloud lists an update that can be cancelled.
    public var canCancel: Bool

    public init(
        currentVersion: String? = nil, updateAvailable: Bool = false, isOwner: Bool? = nil, updates: [FirmwareUpdateStatus] = [],
        fetchedAt: Date? = nil, startedAt: Date? = nil, message: String? = nil, startProblem: String? = nil, canCancel: Bool = false
    ) {
        self.currentVersion = currentVersion
        self.updateAvailable = updateAvailable
        self.isOwner = isOwner
        self.updates = updates
        self.fetchedAt = fetchedAt
        self.startedAt = startedAt
        self.message = message
        self.startProblem = startProblem
        self.canCancel = canCancel
    }

    /// An update can be started now (owner, update waiting, unit online, MELCloud offers it).
    public var canStart: Bool { startProblem == nil }

    /// The entry that matters: the newest one MELCloud lists.
    public var current: FirmwareUpdateStatus? {
        updates.max { ($0.dateCreated ?? .distantPast, $0.id ?? 0) < ($1.dateCreated ?? .distantPast, $1.id ?? 0) }
    }

    public var phase: FirmwareUpdatePhase? { current?.phase }

    /// Follow closely (poll every 15 s): MELCloud says it is running, or it was just started and
    /// MELCloud has not caught up yet.
    public func isInProgress(now: Date) -> Bool {
        if phase?.isInProgress == true { return true }
        guard let startedAt, now.timeIntervalSince(startedAt) < FirmwareStatus.startGrace else { return false }
        return phase == nil || phase == .approvalRequired
    }

    /// How long a just-started update counts as in progress while MELCloud still lists it as waiting.
    public static let startGrace: TimeInterval = 10 * 60

    /// What the user (and Claude's approval dialog) must know before starting. MELCloud's own
    /// warning (FirmwareUpdateMessageOwner) says not to cut power or use the local controller.
    public static let warnings = [
        L10n.tr("Firmware cannot be rolled back once the update has started."),
        L10n.tr("The heat pump must have power and good Wi-Fi the whole time. Do not disconnect it from power and do not use the remote control (the local controller) while the update runs."),
        L10n.tr("The update can take a while. The Wi-Fi adapter restarts along the way, and the heat pump then cannot be controlled from the app or MELCloud."),
    ]
}
