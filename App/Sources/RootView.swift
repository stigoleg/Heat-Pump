import HeatPumpKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(Screen.allCases, selection: $model.selection) { screen in
                Label {
                    Text(screen.title)
                } icon: {
                    IconBadge(systemImage: screen.systemImage, color: screen.color)
                }
                .tag(screen)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if model.isDemo { DemoBadge() }
                    SettingsLink {
                        Label("Innstillinger", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        } detail: {
            NavigationStack {
                detail
                    .navigationTitle(model.selection?.title ?? "Varmepumpe")
                    .navigationSubtitle(model.deviceName)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { RefreshButton() }
        }
        .task {
            // Dev only (screenshots): open Settings on a given tab without keyboard input.
            if ProcessInfo.processInfo.environment["VARMEPUMPE_SETTINGS_TAB"] != nil { openSettings() }
        }
    }

    @ViewBuilder private var detail: some View {
        if model.needsOnboarding {
            OnboardingView()
        } else {
            switch model.selection ?? .overview {
            case .overview: OverviewView()
            case .control: ControlView()
            case .history: HistoryView()
            case .health: HealthView()
            case .activity: ActivityView()
            }
        }
    }
}

/// Refresh that respects the service's throttle and shows a countdown.
struct RefreshButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let wait = waitUntil(now: context.date)
            Button {
                Task { await model.refresh(force: true) }
            } label: {
                if let wait {
                    Label("Neste oppdatering om \(Format.countdown(to: wait, now: context.date))", systemImage: "clock")
                        .labelStyle(.titleAndIcon)
                } else if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Oppdater", systemImage: "arrow.clockwise")
                }
            }
            .disabled(wait != nil || model.isRefreshing || model.service == nil)
            .help("Henter ny status fra MELCloud. Høyst én gang i minuttet, så kontoen ikke blir sperret.")
        }
    }

    private func waitUntil(now: Date) -> Date? {
        guard let result = model.stateResult else { return nil }
        if let until = result.blockedUntil, until > now { return until }
        if let next = result.nextRefreshAllowed, next > now { return next }
        if result.refreshed, let fetched = result.fetchedAt {
            let next = fetched.addingTimeInterval(HeatPumpService.minRefreshInterval)
            if next > now { return next }
        }
        return nil
    }
}

struct OnboardingView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "thermometer.sun")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Velkommen")
                    .font(.largeTitle.bold())
                Text(
                    "Appen henter status fra varmepumpen gjennom MELCloud, den samme tjenesten som Mitsubishi-appen bruker. Logg inn med e-post og passord til MELCloud-kontoen din. Passordet lagres trygt i nøkkelringen på Macen."
                )
                .fixedSize(horizontal: false, vertical: true)
                LoginForm()
                    .frame(maxWidth: 420)
            }
            .padding(32)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}
