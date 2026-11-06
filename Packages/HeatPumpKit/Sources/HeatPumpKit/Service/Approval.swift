import Foundation

/// What a human is asked to approve before Claude's change reaches the heat pump.
public struct ApprovalRequest: Sendable, Equatable {
    public static let title = L10n.tr("Claude wants to change the heat pump")

    /// One-line summary per change.
    public var summaries: [String]
    /// Claude's stated reason.
    public var reason: String

    public init(summaries: [String], reason: String) {
        self.summaries = summaries
        self.reason = reason
    }

    /// Body text for the dialog.
    public var message: String {
        // Non-breaking space keeps "21.5 °C" on one line in a narrow dialog.
        let list = summaries.map { "• \($0.replacingOccurrences(of: " °C", with: "\u{00A0}°C"))" }.joined(separator: "\n")
        return L10n.format("%@\n\nReason from Claude: %@", list, reason)
    }
}

public enum ApprovalDecision: Sendable, Equatable {
    case approved
    case rejected
    case timedOut
    /// No dialog could be shown (for example no GUI session).
    case unavailable(String)

    /// Text logged with a rejected change.
    public var rejectionText: String {
        switch self {
        case .approved: ""
        case .rejected: L10n.tr("Rejected by the user in the approval dialog.")
        case .timedOut:
            L10n.format("No answer in the approval dialog within %lld seconds, counted as rejected.", Int(ApprovalPolicy.timeout))
        case .unavailable(let detail): L10n.format("Could not show the approval dialog (%@), so the change was not sent.", detail)
        }
    }
}

/// Asks a human whether a change may be sent. The MCP helper implements it with a native dialog.
public protocol ChangeApprover: Sendable {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision
}

/// Always answers the same. Used by tests and by the dev-only `VARMEPUMPE_APPROVAL` switch.
public struct FixedApprover: ChangeApprover {
    public let decision: ApprovalDecision

    public init(_ decision: ApprovalDecision) {
        self.decision = decision
    }

    public func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision { decision }
}

public enum ApprovalPolicy {
    /// No answer within this time counts as rejected.
    public static let timeout: TimeInterval = 120

    /// The interactive approver, unless the dev-only `VARMEPUMPE_APPROVAL=auto-approve|auto-reject`
    /// is set together with `VARMEPUMPE_BACKEND=mock`. With a real backend the variable is
    /// ignored, so it can never bypass the dialog for the real heat pump.
    public static func approver(
        environment: [String: String], interactive: any ChangeApprover
    ) -> any ChangeApprover {
        guard HeatPumpService.isMock(environment: environment), let value = environment["VARMEPUMPE_APPROVAL"] else {
            return interactive
        }
        switch value.lowercased() {
        case "auto-approve": return FixedApprover(.approved)
        case "auto-reject": return FixedApprover(.rejected)
        default: return interactive
        }
    }
}
