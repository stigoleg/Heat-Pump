import HeatPumpKit
import SwiftUI

/// Settings → General → Updates.
struct UpdateSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updater = model.updater
        Section {
            LabeledContent("Installed version") {
                if let current = updater.current { Text(current.description) } else { Text("unknown") }
            }
            Toggle("Download and install updates automatically", isOn: $updater.automatic)
            HStack(alignment: .firstTextBaseline) {
                status(updater)
                Spacer()
                actions(updater)
            }
            if let release = updater.release {
                DisclosureGroup("What's new in \(release.version.description)") {
                    Text(notes(release))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let page = release.pageURL { Link("View the Release on GitHub", destination: page) }
                }
            }
            if let blocker = updater.installBlocker {
                Label(blocker, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Open the Downloads Page", destination: AppUpdate.releasesPageURL).font(.caption)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(
                "The app checks GitHub for new versions once a day. A download is installed only when the checksum matches and the app is signed and notarized by the same developer. In automatic mode it is installed when you quit the app; “Install and Restart” does it right away. If price control is on, the temperature is restored before the app restarts."
            )
        }
    }

    @ViewBuilder private func status(_ updater: Updater) -> some View {
        switch updater.phase {
        case .idle:
            Group {
                if let lastCheck = updater.lastCheck {
                    Text("Last checked \(Format.relative(lastCheck))")
                } else {
                    Text("Not checked yet")
                }
            }
            .foregroundStyle(.secondary)
        case .checking:
            Label { Text("Checking for updates…") } icon: { ProgressView().controlSize(.small) }
        case .upToDate:
            Label("You have the latest version", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.Status.good)
        case .available:
            Label("Version \(updater.release?.version.description ?? "") is available", systemImage: "arrow.down.circle")
        case .downloading:
            Label { Text("Downloading and verifying…") } icon: { ProgressView().controlSize(.small) }
        case .ready:
            Label("Version \(updater.release?.version.description ?? "") is ready to install", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Theme.Status.good)
        case .installing:
            Label { Text("Installing…") } icon: { ProgressView().controlSize(.small) }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Status.caution)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func actions(_ updater: Updater) -> some View {
        switch updater.phase {
        case .ready:
            Button("Install and Restart") { updater.installAndRelaunch() }
                .buttonStyle(.borderedProminent)
        case .available where updater.canInstall:
            Button("Download") { Task { await updater.download() } }
                .buttonStyle(.borderedProminent)
        case .failed where updater.release != nil && updater.canInstall:
            Button("Try Again") { Task { await updater.download() } }
        case .checking, .downloading, .installing:
            EmptyView()
        default:
            Button("Check Now") { Task { await updater.check(userInitiated: true) } }
        }
    }

    private func notes(_ release: AppRelease) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: release.notes.isEmpty ? release.title : release.notes, options: options))
            ?? AttributedString(release.notes)
    }
}

/// App menu → "Check for Updates…": opens Settings → General and checks.
struct CheckForUpdatesCommand: View {
    @Environment(\.openSettings) private var openSettings
    let model: AppModel

    var body: some View {
        Button("Check for Updates…") {
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
                Label("Install Version \(version.description)", systemImage: "arrow.down.app")
            }
            .buttonStyle(.borderless)
            .help("Version \(version.description) has been downloaded and verified. The app quits and restarts.")
        }
    }
}
