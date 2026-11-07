import HeatPumpKit
import SwiftUI

/// An air quality sensor's overview: radon (short- and long-term) first, a tile per value with
/// its level, when it was measured and the battery, findings with advice, the radon notification
/// and the knowledge documents.
struct AirQualityOverviewView: View {
    @Environment(AirQualityDeviceModel.self) private var model
    @State private var document: KnowledgeDocumentItem?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    StatusBanner(showsDevice: false)
                    if let problem { problemCard(problem) }
                    if let status = model.status {
                        if hasRadon(status) { radonSection(status).id("radon") }
                        valuesSection(status).id("values")
                        findingsSection(status).id("findings")
                        if hasRadon(status) { alertsSection.id("alerts") }
                    } else {
                        ContentUnavailableView(
                            "No readings yet", systemImage: DeviceKind.airQualitySensor.systemImage,
                            description: Text("The values appear after the first fetch from \(model.serviceName)."))
                    }
                    knowledgeSection
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .devScrollTarget(proxy)
        }
        .sheet(item: $document) { item in
            KnowledgeSheet(document: item.document)
        }
    }

    // MARK: Problems

    private var problem: String? {
        if !model.hasCredentials { return String(localized: "Sign in to \(model.serviceName) under Settings → Account.") }
        return model.syncProblem
    }

    private func problemCard(_ text: String) -> some View {
        InsightCard(
            title: "Some data could not be fetched", detail: .verbatim(text), systemImage: "exclamationmark.triangle.fill",
            tint: Theme.Status.caution)
    }

    // MARK: Radon

    private func hasRadon(_ status: AirQualityStatus) -> Bool {
        status.value(.radonShortTerm) != nil || status.value(.radonLongTerm) != nil
    }

    private func radonSection(_ status: AirQualityStatus) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Radon", hint: .verbatim(model.displayName))
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: Theme.Space.xl) { radonFigures(status) }
                        VStack(alignment: .leading, spacing: Theme.Space.l) { radonFigures(status) }
                    }
                    Divider()
                    Text("Radon is judged by the annual average: measures are recommended from 100 Bq/m³, and 200 Bq/m³ is the limit. Short-term values swing with weather and ventilation, so measure for at least two months in the winter half-year.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func radonFigures(_ status: AirQualityStatus) -> some View {
        if let short = status.value(.radonShortTerm) {
            radonFigure(short, label: "Short-term average", detail: "About the last 24 hours")
        }
        if let long = status.value(.radonLongTerm) {
            radonFigure(long, label: "Long-term average", detail: "Since the sensor was set up, up to a year")
        }
    }

    private func radonFigure(_ value: AirQualityValue, label: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(Display.format("%.0f", value.value))
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text(verbatim: value.metric.unit).font(.title3).foregroundStyle(.secondary)
            }
            if let level = value.level {
                Label(level.title, systemImage: level.systemImage)
                    .font(.callout)
                    .foregroundStyle(level.color)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 200, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Values

    private func valuesSection(_ status: AirQualityStatus) -> some View {
        let tiles = status.values.filter { !$0.metric.isRadon && $0.metric != .battery }
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Now", hint: .verbatim(measured(status)))
            if !tiles.isEmpty {
                CardSurface {
                    KPIRow {
                        ForEach(tiles) { value in
                            KPITile(
                                label: .verbatim(value.metric.title), value: value.metric.formatted(value.value),
                                detail: value.level.map { .verbatim($0.title) }, systemImage: value.level?.systemImage ?? value.metric.systemImage,
                                tint: value.level?.color ?? value.metric.tint)
                        }
                    }
                }
            }
        }
    }

    /// "Measured 3 minutes ago · Battery 78 %".
    private func measured(_ status: AirQualityStatus) -> String {
        let when = String(localized: "Measured \(Format.relative(status.recorded ?? status.fetchedAt))")
        guard let battery = status.value(.battery) else { return when }
        return String(localized: "\(when) · Battery \(AirQualityMetric.battery.formatted(battery.value))")
    }

    // MARK: Findings

    private func findingsSection(_ status: AirQualityStatus) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("What to do", hint: "Most important first")
            if status.findings.isEmpty {
                InsightCard(
                    title: "Nothing to do right now", detail: "No value calls for action.", systemImage: "checkmark.circle.fill",
                    tint: Theme.Status.good)
            }
            ForEach(HealthReport(generatedAt: Date(), findings: status.findings).findings) { finding in
                InsightCard(
                    title: .verbatim(finding.title), detail: "\(finding.detail)\nAdvice: \(finding.recommendation)",
                    systemImage: finding.severity.systemImage, tint: finding.severity.color)
                .textSelection(.enabled)
            }
        }
    }

    // MARK: Notification

    private var alertsSection: some View {
        CardSurface {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Image(systemName: "bell.badge.fill").foregroundStyle(Theme.Status.info)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Notify me about high radon")
                    Text("When the long-term average is 100 Bq/m³ or more; at most once a week while it lasts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Space.m)
                Toggle(
                    "Notify me about high radon",
                    isOn: Binding(get: { model.radonAlerts }, set: { enabled in Task { await model.setRadonAlerts(enabled) } })
                )
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }

    // MARK: Knowledge

    @ViewBuilder private var knowledgeSection: some View {
        let documents = model.knowledge.all()
        if !documents.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionHeader("Read more")
                ForEach(documents, id: \.name) { doc in
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

    private var footnote: String {
        if model.status?.thresholdsFromDevice == true {
            return String(
                localized:
                    "Levels follow the thresholds set for this sensor in the \(model.serviceName) app. Sensors report every few minutes through a hub (radon hourly), or when the phone app syncs.")
        }
        return String(
            localized:
                "Levels follow common defaults until the sensor's own thresholds are fetched. Sensors report every few minutes through a hub (radon hourly), or when the phone app syncs.")
    }
}
