import HeatPumpKit
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all, claude, app
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "Alle"
            case .claude: "Claude"
            case .app: "App"
            }
        }
    }

    struct Row: Identifiable {
        let id: Int64
        let record: ChangeRecord
    }

    private var rows: [Row] {
        model.changes
            .filter { record in
                switch filter {
                case .all: true
                case .claude: record.source == .claude
                case .app: record.source == .app
                }
            }
            .enumerated()
            .map { index, record in Row(id: record.id ?? Int64(-index - 1), record: record) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Slik er Claude koblet til", systemImage: "sparkles").font(.headline)
                    Text(
                        "Claude kan lese status, historikk og helse fra varmepumpen gjennom MCP-serveren som følger med appen. Når Claude vil endre noe, åpner Macen et eget vindu, «Claude vil endre varmepumpen», med endringen og begrunnelsen. Endringen sendes bare hvis du trykker Godkjenn. Avvis, eller ingen svar innen 2 minutter, stopper den. Alt som sendes eller avvises vises her."
                    )
                    Text("Oppsett finner du under Innstillinger → Claude.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Picker("Kilde", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if rows.isEmpty {
                ContentUnavailableView(
                    "Ingen endringer ennå", systemImage: "list.bullet.rectangle",
                    description: Text("Endringer fra appen og fra Claude vises her."))
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                List(rows) { row in
                    ActivityRow(record: row.record)
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

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: record.source == .claude ? "sparkles" : "macwindow")
                .foregroundStyle(record.source == .claude ? Color.purple : Color.secondary)
                .frame(width: 18)
                .help(record.source.displayName)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(record.displaySummary).font(.body.weight(.medium))
                    Spacer()
                    resultLabel(record)
                }
                Text("\(record.source.displayName) · \(Norwegian.dateTime(record.timestamp)) · \(record.oldDisplayValue) → \(record.newDisplayValue)")
                    .font(.callout).foregroundStyle(.secondary)
                if let reason = record.reason, !reason.isEmpty {
                    Text("Begrunnelse: \(reason)").font(.callout)
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
