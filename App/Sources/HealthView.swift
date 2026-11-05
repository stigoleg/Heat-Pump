import HeatPumpKit
import SwiftUI

struct HealthView: View {
    @Environment(AppModel.self) private var model
    @State private var recording: MaintenanceKind?
    @State private var document: KnowledgeDocumentItem?

    var body: some View {
        List {
            findings
            errorLog
            maintenance
            knowledge
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .top, spacing: 0) { StatusBanner(inset: 16) }
        .sheet(item: $recording) { kind in
            RecordMaintenanceSheet(kind: kind)
        }
        .sheet(item: $document) { item in
            KnowledgeSheet(document: item.document)
        }
    }

    @ViewBuilder private var findings: some View {
        if let report = model.health {
            ForEach(HealthSeverity.allCases.reversed(), id: \.self) { severity in
                let group = report.findings.filter { $0.severity == severity }
                if !group.isEmpty {
                    Section {
                        ForEach(group) { finding in
                            VStack(alignment: .leading, spacing: 6) {
                                Label(finding.title, systemImage: severity.systemImage)
                                    .font(.headline)
                                    .foregroundStyle(severity == .ok ? Color.primary : severity.color)
                                Text(finding.detail)
                                Text("Råd: \(finding.recommendation)")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            .textSelection(.enabled)
                        }
                    } header: {
                        Text(sectionTitle(severity))
                    }
                }
            }
        }
    }

    private func sectionTitle(_ severity: HealthSeverity) -> String {
        switch severity {
        case .critical: "Kritisk – gjør noe nå"
        case .warning: "Advarsler"
        case .info: "Til informasjon"
        case .ok: "I orden"
        }
    }

    private var errorLog: some View {
        Section {
            if model.errorLog.isEmpty {
                Text("Ingen feil registrert de siste 90 dagene.").foregroundStyle(.secondary)
            }
            ForEach(Array(model.errorLog.enumerated()), id: \.offset) { _, entry in
                let explanation = ErrorCatalog.lookup(errorCode: entry.code.flatMap(Int.init), message: entry.message)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.message).font(.body.weight(.medium))
                        Spacer()
                        Text(entry.start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Norwegian.locale)))
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.end.map { "Gikk over \(Norwegian.dateTime($0))" } ?? "Ikke registrert som avsluttet")
                        .font(.caption).foregroundStyle(.secondary)
                    if explanation.confidence != .melcloud || explanation.explanation.contains("Mulig tolkning") {
                        Text(explanation.explanation).font(.callout)
                    }
                    Text(confidenceNote(explanation.confidence)).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Feillogg (90 dager)")
        }
    }

    private func confidenceNote(_ confidence: CatalogConfidence) -> String {
        switch confidence {
        case .melcloud: "Feilteksten kommer fra MELCloud."
        case .medium: "Forklaringen er hentet fra en beslektet modell og er sannsynlig, men ikke sikker."
        case .low, .unknown: ErrorCatalog.caveat
        }
    }

    private var maintenance: some View {
        Section {
            ForEach(model.maintenance, id: \.kind) { item in
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: icon(item.status)).foregroundStyle(color(item.status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName).font(.body.weight(.medium))
                        Text(detail(item)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Registrer utført") { recording = item.kind }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Vedlikehold")
        } footer: {
            Text("Bruksanvisningen anbefaler å rengjøre luftfilteret hver 2. uke og luktfilteret/luftrenseren hver 3. måned.")
        }
    }

    private func detail(_ item: MaintenanceStatus) -> String {
        var parts: [String] = []
        if let last = item.lastDone {
            parts.append("Sist: \(Norwegian.date(last))")
        } else if item.recommendedIntervalDays != nil {
            parts.append("Ikke registrert")
        }
        if let next = item.nextDue { parts.append("Neste: \(Norwegian.date(next))") }
        if let days = item.recommendedIntervalDays { parts.append("hver \(days). dag") }
        return parts.joined(separator: " · ")
    }

    private func icon(_ status: String) -> String {
        switch status {
        case "ok": "checkmark.circle.fill"
        case "due": "clock.badge.exclamationmark"
        case "overdue": "exclamationmark.triangle.fill"
        default: "circle.dashed"
        }
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "ok": .green
        case "due": .blue
        case "overdue": .orange
        default: .secondary
        }
    }

    private var knowledge: some View {
        Section("Les mer") {
            ForEach(Knowledge.all(), id: \.name) { doc in
                Button {
                    document = KnowledgeDocumentItem(document: doc)
                } label: {
                    Label(doc.title, systemImage: "doc.text")
                }
                .buttonStyle(.link)
            }
        }
    }
}

extension MaintenanceKind: @retroactive Identifiable {
    public var id: String { rawValue }
}

struct KnowledgeDocumentItem: Identifiable {
    let document: KnowledgeDocument
    var id: String { document.name }
}

struct RecordMaintenanceSheet: View {
    let kind: MaintenanceKind
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var note = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Registrer: \(kind.displayName)").font(.title2.weight(.semibold))
            Form {
                DatePicker("Dato", selection: $date, in: ...Date(), displayedComponents: [.date])
                TextField("Merknad (valgfritt)", text: $note, axis: .vertical)
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Avbryt", role: .cancel) { dismiss() }
                Button("Lagre") {
                    Task {
                        saving = true
                        error = await model.recordMaintenance(kind: kind, date: date, note: note)
                        saving = false
                        if error == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
