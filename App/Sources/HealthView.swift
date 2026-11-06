import HeatPumpKit
import SwiftUI

struct HealthView: View {
    @Environment(AppModel.self) private var model
    @State private var recording: MaintenanceKind?
    @State private var document: KnowledgeDocumentItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                StatusBanner()
                kpis
                findings
                errorLog
                maintenance
                FirmwareSection()
                knowledge
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $recording) { kind in
            RecordMaintenanceSheet(kind: kind)
        }
        .sheet(item: $document) { item in
            KnowledgeSheet(document: item.document)
        }
    }

    private var kpis: some View {
        KPIRow {
            if let report = model.health {
                KPITile(
                    label: "Health", value: report.overall == .ok ? String(localized: "All OK") : report.overall.displayName,
                    detail: "\(report.findings.filter { $0.severity != .ok }.count) things to check",
                    systemImage: report.overall.systemImage, tint: report.overall.color)
            }
            ForEach(model.maintenance.filter { $0.recommendedIntervalDays != nil }, id: \.kind) { item in
                KPITile(
                    label: .verbatim(item.displayName),
                    value: item.nextDue.map { Format.dayMonth($0) } ?? String(localized: "Not recorded"),
                    detail: item.nextDue == nil ? "Record it when you have done it" : "next time",
                    systemImage: icon(item.status), tint: color(item.status))
            }
            if let hours = model.live?.sample?.runtimeHours {
                KPITile(
                    label: "Total runtime", value: String(localized: "\(hours) h"), detail: "according to the indoor unit (probably since installation)",
                    systemImage: "hourglass", tint: Theme.Data.orange)
            }
            KPITile(
                label: "Errors, last 90 days", value: "\(model.errorLog.count)",
                detail: model.errorLog.first.map { "Latest: \(Display.date($0.start))" }, systemImage: "list.bullet.rectangle",
                tint: model.errorLog.isEmpty ? Theme.Status.good : Theme.Status.caution)
        }
    }

    @ViewBuilder private var findings: some View {
        if let report = model.health {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Findings", hint: "Most important first")
                ForEach(report.findings) { finding in
                    InsightCard(
                        title: .verbatim(finding.title), detail: "\(finding.detail)\nAdvice: \(finding.recommendation)",
                        systemImage: finding.severity.systemImage, tint: finding.severity.color)
                    .textSelection(.enabled)
                }
            }
        }
    }

    private var errorLog: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Error log", hint: "90 days")
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if model.errorLog.isEmpty {
                        Label("No errors recorded in the last 90 days.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.errorLog.enumerated()), id: \.offset) { index, entry in
                        let explanation = model.errorCodes.lookup(errorCode: entry.code.flatMap(Int.init), message: entry.message)
                        if index > 0 { Divider() }
                        HStack(alignment: .top, spacing: Theme.Space.m) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.caution)
                            VStack(alignment: .leading, spacing: 4) {
                                // The date moves below the message when they don't fit on one line.
                                ViewThatFits(in: .horizontal) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(entry.message).font(.body.weight(.medium))
                                        Spacer()
                                        Text(Display.dateTime(entry.start)).foregroundStyle(.secondary)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.message).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                                        Text(Display.dateTime(entry.start)).foregroundStyle(.secondary)
                                    }
                                }
                                Text(entry.end.map { String(localized: "Cleared \(Display.dateTime($0))") } ?? String(localized: "Not recorded as cleared"))
                                    .font(.caption).foregroundStyle(.secondary)
                                if explanation.confidence != .serviceText || model.errorCodes.hasExplanation(errorCode: entry.code.flatMap(Int.init)) {
                                    Text(explanation.explanation).font(.callout)
                                }
                                Text(confidenceNote(explanation.confidence)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func confidenceNote(_ confidence: CatalogConfidence) -> String {
        switch confidence {
        case .serviceText: String(localized: "The error text comes from \(model.serviceName).")
        case .medium: String(localized: "The explanation comes from a related model and is likely, but not certain.")
        case .low, .unknown: model.errorCodes.caveat
        }
    }

    private var maintenance: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Maintenance", hint: "Air filter every 2 weeks, deodorizing filter every 3 months")
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(Array(model.maintenance.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Divider() }
                        HStack(alignment: .center, spacing: Theme.Space.m) {
                            Image(systemName: icon(item.status)).foregroundStyle(color(item.status)).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName).font(.body.weight(.medium))
                                Text(detail(item)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Record as Done") { recording = item.kind }
                        }
                    }
                }
            }
        }
    }

    private func detail(_ item: MaintenanceStatus) -> String {
        var parts: [String] = []
        if let last = item.lastDone {
            parts.append(String(localized: "Last: \(Display.date(last))"))
        } else if item.recommendedIntervalDays != nil {
            parts.append(String(localized: "Not recorded"))
        }
        if let next = item.nextDue { parts.append(String(localized: "Next: \(Display.date(next))")) }
        if let days = item.recommendedIntervalDays { parts.append(String(localized: "every \(days) days")) }
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
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Read more")
            ForEach(model.knowledge.all(), id: \.name) { doc in
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
            Text("Record: \(kind.displayName)").font(.title2.weight(.semibold))
            Form {
                DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: [.date])
                TextField("Note (optional)", text: $note, axis: .vertical)
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
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
