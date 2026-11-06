import HeatPumpKit
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all, claude, app, automation
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .claude: "Claude"
            case .app: String(localized: "App")
            case .automation: String(localized: "Price control")
            }
        }
    }

    struct Row: Identifiable {
        let id: Int64
        let record: ChangeRecord
        /// The device's name, with two or more devices.
        var device: String?
    }

    /// One device: its changes. Two or more: every device's, with its name.
    private var changes: [(device: String?, record: ChangeRecord)] {
        guard model.isGrouped else { return model.primaryHeatPump.changes.map { (nil, $0) } }
        return model.allChanges.map { ($0.device?.name, $0.record) }
    }

    private var rows: [Row] {
        changes
            .filter { change in
                let record = change.record
                return switch filter {
                case .all: true
                case .claude: record.source == .claude
                case .app: record.source == .app
                case .automation: record.source == .automation
                }
            }
            .enumerated()
            .map { index, change in Row(id: change.record.id ?? Int64(-index - 1), record: change.record, device: change.device) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardSurface {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("How Claude is connected")
                    } icon: {
                        IconBadge(systemImage: "sparkles", color: .purple)
                    }
                    .font(.headline)
                    Text(
                        "Claude can read status, history and health from the heat pump through the MCP server that comes with the app. When Claude wants to change something, the Mac opens a separate window, “Claude wants to change the heat pump”, with the change and the reason. The change is only sent if you click Approve. Reject, or no answer within 2 minutes, stops it. Everything that is sent or rejected is shown here."
                    )
                    Text("You will find the setup under Settings → Claude.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Picker("Source", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if rows.isEmpty {
                ContentUnavailableView(
                    "No changes yet", systemImage: "list.bullet.rectangle",
                    description: Text("Changes from the app and from Claude are shown here."))
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                List(rows) { row in
                    ActivityRow(record: row.record, device: row.device)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

}

/// One change: what, when, who, old → new, why and the result.
struct ActivityRow: View {
    let record: ChangeRecord
    /// The device's name, shown with two or more devices.
    var device: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: record.source.systemImage)
                .foregroundStyle(record.source.tint)
                .frame(width: 18)
                .help(record.source.displayName)
            VStack(alignment: .leading, spacing: 3) {
                // The result moves below the summary when they don't fit on one line.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(record.displaySummary).font(.body.weight(.medium))
                        Spacer()
                        resultLabel(record)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.displaySummary).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        resultLabel(record)
                    }
                }
                Group {
                    if let device {
                        Text(verbatim: "\(device) · \(record.source.displayName) · \(Display.dateTime(record.timestamp)) · \(record.oldDisplayValue) → \(record.newDisplayValue)")
                    } else {
                        Text(verbatim: "\(record.source.displayName) · \(Display.dateTime(record.timestamp)) · \(record.oldDisplayValue) → \(record.newDisplayValue)")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                if let reason = record.reason, !reason.isEmpty {
                    Text("Reason: \(reason)").font(.callout)
                }
                if let error = record.error, record.result != .ok {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }

    private func resultLabel(_ record: ChangeRecord) -> some View {
        let color: Color =
            switch record.result {
            case .ok: .green
            case .pending: .blue
            case .failed: .red
            case .rejected: .orange
            }
        return Text(record.result.displayName)
            .foregroundStyle(color)
            .help(record.error ?? "")
    }
}

extension ChangeSource {
    var systemImage: String {
        switch self {
        case .claude: "sparkles"
        case .app: "macwindow"
        case .automation: "bolt.badge.clock"
        }
    }

    var tint: Color {
        switch self {
        case .claude: .purple
        case .app: .secondary
        case .automation: .cyan
        }
    }
}
