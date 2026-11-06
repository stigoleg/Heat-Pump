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
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if model.isDemo { DemoBadge() }
                    UpdateReadyBadge()
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        } detail: {
            NavigationStack {
                detail
                    .navigationTitle(model.selection?.title ?? String(localized: "Heat Pump"))
                    .navigationSubtitle(model.deviceName)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { AppearanceMenu() }
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
            case .schedule: ScheduleView()
            case .history: HistoryView()
            case .outlook: OutlookView()
            case .away: AwayView()
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
                    Label("Next refresh in \(Format.countdown(to: wait, now: context.date))", systemImage: "clock")
                        .labelStyle(.titleAndIcon)
                } else if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(wait != nil || model.isRefreshing || model.service == nil)
            .help("Fetches new status from MELCloud. At most once a minute, so the account is not blocked.")
        }
    }

    private func waitUntil(now: Date) -> Date? {
        guard let result = model.stateResult else { return nil }
        if let until = result.blockedUntil, until > now { return until }
        if let next = result.nextRefreshAllowed, next > now { return next }
        if result.refreshed, let fetched = result.fetchedAt {
            let next = fetched.addingTimeInterval(model.service?.policy.minRefreshInterval ?? RateLimitPolicy.standard.minRefreshInterval)
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
                Text("Welcome")
                    .font(.largeTitle.bold())
                Text(
                    "The app fetches status from the heat pump through MELCloud, the same service the Mitsubishi app uses. Sign in with the email and password for your MELCloud account. The password is stored securely in the keychain on the Mac."
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
