import HeatPumpKit
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusBanner()
                if let state = model.state {
                    hero(state)
                    LazyVGrid(columns: columns, spacing: 16) {
                        Card(title: "Ute", systemImage: "cloud.sun") {
                            Text(Format.temperature(state.outdoorTemperature)).font(.title.weight(.semibold))
                        }
                        Card(title: "Ønsket temperatur", systemImage: "target") {
                            Text(Format.temperature(state.setTemperature)).font(.title.weight(.semibold))
                        }
                        Card(title: "Modus", systemImage: state.mode?.systemImage ?? "questionmark") {
                            Text(state.mode?.displayName ?? "Ukjent").font(.title.weight(.semibold))
                        }
                        Card(title: "Av/på", systemImage: "power") {
                            Text(state.power ? "På" : "Av")
                                .font(.title.weight(.semibold))
                                .foregroundStyle(state.power ? Color.primary : Color.secondary)
                        }
                        connectionCard(state)
                        Card(title: "Data hentet", systemImage: "clock") {
                            Text(Format.relative(state.fetchedAt)).font(.title3.weight(.semibold))
                            Text("Oppdateres automatisk hvert 10. minutt mens appen er åpen.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    healthSummary
                } else if model.startupError == nil {
                    ContentUnavailableView(
                        "Ingen status ennå", systemImage: "thermometer.medium",
                        description: Text("Henter status fra varmepumpen …"))
                }
            }
            .padding(24)
        }
    }

    private func hero(_ state: DeviceState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Inne nå").font(.headline).foregroundStyle(.secondary)
            Text(Format.temperature(state.roomTemperature))
                .font(.system(size: 64, weight: .light, design: .rounded))
                .monospacedDigit()
            if model.isAwaitingConfirmation {
                Label("Venter på at varmepumpen bekrefter en endring", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func connectionCard(_ state: DeviceState) -> some View {
        Card(title: "Tilkobling", systemImage: state.offline ? "wifi.slash" : "wifi") {
            Text(state.offline ? "Frakoblet" : "Tilkoblet")
                .font(.title.weight(.semibold))
                .foregroundStyle(state.offline ? .orange : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Siste kontakt: \(Format.relative(state.lastCommunication))")
                if let rssi = state.wifiSignal {
                    Text("Wi-Fi: \(rssi) dBm (\(wifiWord(rssi)))")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func wifiWord(_ rssi: Int) -> String {
        switch rssi {
        case ..<(-80): "svakt"
        case ..<(-70): "middels"
        default: "godt"
        }
    }

    @ViewBuilder private var healthSummary: some View {
        if let report = model.health {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Helse").font(.title2.weight(.semibold))
                    SeverityBadge(severity: report.overall)
                    Spacer()
                    Button("Se alt") { model.selection = .health }
                }
                ForEach(report.findings.prefix(3)) { finding in
                    Button {
                        model.selection = .health
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: finding.severity.systemImage).foregroundStyle(finding.severity.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding.title).font(.body.weight(.medium))
                                Text(finding.recommendation).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}
