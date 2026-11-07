import AppKit
import CoreGraphics
import HeatPumpKit

/// Asks the user with a native macOS dialog shown by the helper itself (accessory app, no Dock
/// icon), independent of the MCP client and its permission mode. One dialog at a time.
actor DialogApprover: ChangeApprover {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        await acquire()
        defer { release() }
        guard CGSessionCopyCurrentDictionary() != nil else {
            Log.error("no GUI session; change rejected")
            return .unavailable(L10n.tr("no graphical session on the Mac"))
        }
        return await MainActor.run { ApprovalAlert.present(request, timeout: ApprovalPolicy.timeout) }
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Target for the "Approve" button. Approval is recorded only through this action, so any
/// other way the dialog ends (Reject, Escape, Return, timeout, closed) counts as rejected.
@MainActor
private final class ApproveTarget: NSObject {
    static let approvedCode = NSApplication.ModalResponse(rawValue: 4242)
    private(set) var clicked = false

    @objc func approve(_ sender: Any?) {
        clicked = true
        NSApp.stopModal(withCode: Self.approvedCode)
    }
}

@MainActor
enum ApprovalAlert {
    /// Escape key code.
    private static let escape: UInt16 = 53

    /// Shows the dialog and blocks (in a modal run loop) until answered or timed out.
    /// "Reject" is the default (Return) and Escape button; approving needs a click on "Approve".
    static func present(_ request: ApprovalRequest, timeout: TimeInterval) -> ApprovalDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let icon = NSImage(systemSymbolName: "thermometer.and.liquid.waves", accessibilityDescription: "Husly")
            ?? NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "Husly")
        {
            alert.icon = icon.withSymbolConfiguration(.init(pointSize: 48, weight: .regular))
        }
        alert.messageText = ApprovalRequest.title
        alert.informativeText = request.message
            + "\n\n" + L10n.format("If you do not answer within %lld minutes, the change is rejected.", Int(timeout / 60))
        let reject = alert.addButton(withTitle: L10n.tr("Reject"))
        let approve = alert.addButton(withTitle: L10n.tr("Approve"))
        reject.keyEquivalent = "\r"
        approve.keyEquivalent = ""
        let target = ApproveTarget()
        approve.target = target
        approve.action = #selector(ApproveTarget.approve(_:))

        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == escape else { return event }
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
            return nil
        }
        let timer = Timer(timeInterval: timeout, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.abortModal() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)

        alert.window.level = .floating
        NSApp.activate()
        let response = alert.runModal()

        timer.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if target.clicked && response == ApproveTarget.approvedCode {
            Log.info("approval dialog: approved by click")
            return .approved
        }
        Log.info("approval dialog: not approved (response \(response.rawValue))")
        return response == .abort ? .timedOut : .rejected
    }
}
