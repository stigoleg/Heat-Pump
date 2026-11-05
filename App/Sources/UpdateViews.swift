import HeatPumpKit
import SwiftUI

/// Settings → Generelt → Oppdateringer.
struct UpdateSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updater = model.updater
        Section {
            LabeledContent("Installert versjon", value: updater.current?.description ?? "ukjent")
            Toggle("Hent og installer oppdateringer automatisk", isOn: $updater.automatic)
            HStack(alignment: .firstTextBaseline) {
                status(updater)
                Spacer()
                actions(updater)
            }
            if let release = updater.release {
                DisclosureGroup("Nytt i \(release.version.description)") {
                    Text(notes(release))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let page = release.pageURL { Link("Vis utgivelsen på GitHub", destination: page) }
                }
            }
            if let blocker = updater.installBlocker {
                Label(blocker, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Åpne nedlastingssiden", destination: AppUpdate.releasesPageURL).font(.caption)
            }
        } header: {
            Text("Oppdateringer")
        } footer: {
            Text(
                "Appen ser etter nye versjoner på GitHub én gang i døgnet. En nedlasting installeres bare når sjekksummen stemmer og appen er signert og notarisert av samme utvikler. Automatisk installeres den når du avslutter appen; «Installer og start på nytt» gjør det med en gang. Er prisstyring på, settes temperaturen tilbake før appen starter på nytt."
            )
        }
    }

    @ViewBuilder private func status(_ updater: Updater) -> some View {
        switch updater.phase {
        case .idle:
            Text(updater.lastCheck.map { "Sist sjekket \(Format.relative($0))" } ?? "Ikke sjekket ennå")
                .foregroundStyle(.secondary)
        case .checking:
            Label { Text("Ser etter oppdateringer …") } icon: { ProgressView().controlSize(.small) }
        case .upToDate:
            Label("Du har nyeste versjon", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.Status.good)
        case .available:
            Label("Versjon \(updater.release?.version.description ?? "") er tilgjengelig", systemImage: "arrow.down.circle")
        case .downloading:
            Label { Text("Laster ned og kontrollerer …") } icon: { ProgressView().controlSize(.small) }
        case .ready:
            Label("Versjon \(updater.release?.version.description ?? "") er klar til å installeres", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Theme.Status.good)
        case .installing:
            Label { Text("Installerer …") } icon: { ProgressView().controlSize(.small) }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Status.caution)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func actions(_ updater: Updater) -> some View {
        switch updater.phase {
        case .ready:
            Button("Installer og start på nytt") { updater.installAndRelaunch() }
                .buttonStyle(.borderedProminent)
        case .available where updater.canInstall:
            Button("Last ned") { Task { await updater.download() } }
                .buttonStyle(.borderedProminent)
        case .failed where updater.release != nil && updater.canInstall:
            Button("Prøv igjen") { Task { await updater.download() } }
        case .checking, .downloading, .installing:
            EmptyView()
        default:
            Button("Se etter nå") { Task { await updater.check(userInitiated: true) } }
        }
    }

    private func notes(_ release: AppRelease) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: release.notes.isEmpty ? release.title : release.notes, options: options))
            ?? AttributedString(release.notes)
    }
}

/// App menu → "Se etter oppdateringer …": opens Settings → Generelt and checks.
struct CheckForUpdatesCommand: View {
    @Environment(\.openSettings) private var openSettings
    let model: AppModel

    var body: some View {
        Button("Se etter oppdateringer …") {
            model.settingsTab = "generelt"
            openSettings()
            Task { await model.updater.check(userInitiated: true) }
        }
        .disabled([.checking, .downloading, .installing].contains(model.updater.phase))
    }
}

/// Sidebar note while a downloaded update waits.
struct UpdateReadyBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.updater.phase == .ready, let version = model.updater.release?.version {
            Button {
                model.updater.installAndRelaunch()
            } label: {
                Label("Installer versjon \(version.description)", systemImage: "arrow.down.app")
            }
            .buttonStyle(.borderless)
            .help("Versjon \(version.description) er lastet ned og kontrollert. Appen avslutter og starter på nytt.")
        }
    }
}
