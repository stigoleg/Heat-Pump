import HeatPumpKit
import SwiftUI

/// Health → Firmware: the Wi-Fi adapter's firmware and MELCloud's update status. Starting needs a
/// confirmation sheet with the warnings (firmware cannot be rolled back). While an update runs and
/// the page is visible, the status is read every 15 s.
struct FirmwareSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var confirmingCancel = false
    @State private var sending = false
    @State private var outcome: (ok: Bool, message: String)?

    private static let pollInterval: Duration = .seconds(15)
    private static let idleInterval: Duration = .seconds(60)

    private var status: FirmwareStatus? { model.firmware }
    private var running: Bool { status?.isInProgress(now: Date()) == true }

    private var adapterHint: LocalizedStringKey {
        if let version = model.state?.firmware.version ?? status?.currentVersion { return "Wi-Fi adapter \(version)" }
        return "Wi-Fi adapter, unknown version"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Firmware", hint: adapterHint)
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    statusLine
                    if let current = status?.current, current.phase == .downloading || current.phase == .retrying,
                        let progress = current.progress
                    {
                        ProgressView(value: progress) {
                            Text(current.progressText ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let message = status?.message {
                        Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if let status, status.updateAvailable, !running, status.phase != .complete, !status.canStart,
                        let problem = status.startProblem
                    {
                        Text(problem).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let outcome {
                        Label(outcome.message, systemImage: outcome.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(outcome.ok ? Theme.Status.good : Theme.Status.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    actions
                }
            }
        }
        .task(id: running) { await poll() }
        .sheet(isPresented: $confirming) { confirmSheet }
        .confirmationDialog("Cancel the firmware update?", isPresented: $confirmingCancel) {
            Button("Cancel Update", role: .destructive) { send { await model.cancelFirmwareUpdate() } }
            Button("Continue Update", role: .cancel) {}
        } message: {
            Text("MELCloud stops the update if it is not installed yet. You can start it again later.")
        }
    }

    /// Reads while the page is visible (hiding it cancels the task): every 15 s while an update runs,
    /// otherwise every minute. The service only asks MELCloud when an update waits or runs.
    private func poll() async {
        while !Task.isCancelled {
            await model.loadFirmware()
            try? await Task.sleep(for: running ? Self.pollInterval : Self.idleInterval)
        }
    }

    @ViewBuilder private var statusLine: some View {
        if let current = status?.current, status?.updateAvailable == true || running || current.phase == .complete {
            if running, current.phase == .approvalRequired {
                Label("The update has been sent to MELCloud. Waiting for the unit to accept it.", systemImage: "clock.arrow.circlepath")
            } else {
                Label(current.displayText, systemImage: icon(current.phase)).foregroundStyle(color(current.phase))
            }
        } else if status?.updateAvailable == true || model.state?.firmware.updateAvailable == true {
            Label("MELCloud has newer firmware ready for the Wi-Fi adapter.", systemImage: "arrow.down.circle")
        } else {
            Label("No new firmware is waiting in MELCloud.", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.m) {
            if let at = status?.fetchedAt {
                Text("Status fetched \(Format.relative(at))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status?.updateAvailable == true || running {
                Button("Refresh Status") { Task { await model.loadFirmware(force: true) } }
            }
            if status?.canCancel == true {
                Button("Cancel Update", role: .destructive) { confirmingCancel = true }
            }
            if status?.canStart == true, !running {
                Button("Update Firmware…") { confirming = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .disabled(sending)
    }

    private func send(_ action: @escaping () async -> (ok: Bool, message: String)) {
        sending = true
        Task {
            outcome = await action()
            sending = false
        }
    }

    // MARK: Confirmation

    private var confirmSheet: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Label("Update the firmware?", systemImage: "arrow.down.circle.fill").font(.title2.bold())
            Text(HeatPumpService.firmwareApprovalSummaries(version: status?.currentVersion).first ?? "")
                .font(.body.weight(.medium))
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(FirmwareStatus.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Theme.Status.caution)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { confirming = false }
                    .keyboardShortcut(.cancelAction)
                Button("Start Update") {
                    confirming = false
                    send { await model.startFirmwareUpdate() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 480)
    }

    private func icon(_ phase: FirmwareUpdatePhase) -> String {
        switch phase {
        case .complete: "checkmark.circle.fill"
        case .approvalRequired: "arrow.down.circle"
        case .downloading, .retrying, .approved, .forced: "arrow.down.circle.dotted"
        case .resetPending, .resetting, .cancelling: "arrow.clockwise.circle"
        case .blocked, .aborted, .abortedOffline, .unitOffline: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private func color(_ phase: FirmwareUpdatePhase) -> Color {
        switch phase {
        case .complete: Theme.Status.good
        case .blocked, .aborted, .abortedOffline, .unitOffline: Theme.Status.caution
        default: .primary
        }
    }
}
