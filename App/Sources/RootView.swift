import HeatPumpKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            sidebar
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
                    .navigationTitle(title)
                    .navigationSubtitle(subtitle)
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
        // Home and the toolbar use the primary device; device screens get their own.
        .environment(model.primaryHeatPump)
    }

    private var selection: Binding<AppRoute?> {
        Binding(get: { model.currentRoute }, set: { route in if let route { model.route = route } })
    }

    // MARK: Sidebar

    /// One device: today's flat list. Two or more: Home, then a group per device.
    @ViewBuilder private var sidebar: some View {
        if model.isGrouped {
            List(selection: selection) {
                Section("Home") {
                    ForEach(DeviceNavigation.homeScreens, id: \.self) { screen in
                        row(screen.title, systemImage: screen.systemImage, color: screen.color)
                            .tag(AppRoute.home(screen))
                    }
                }
                ForEach(model.devices.indices, id: \.self) { index in
                    let device = model.devices[index]
                    Section {
                        ForEach(DeviceUIRegistry.screens(for: device), id: \.self) { screen in
                            row(screen.screen.title, systemImage: screen.screen.systemImage, color: screen.screen.color)
                                .tag(AppRoute.device(device.key, screen))
                        }
                    } header: {
                        Text(device.displayName)
                    }
                }
            }
        } else {
            List(flatScreens, selection: selection) { screen in
                row(screen.title, systemImage: screen.systemImage, color: screen.color)
                    .tag(screen.route)
            }
        }
    }

    /// The single device's screens with Forecast and Claude activity in today's order.
    private var flatScreens: [Screen] {
        let available = DeviceUIRegistry.screens(for: model.primaryHeatPump)
        return Screen.allCases.filter { screen in screen.deviceScreen.map(available.contains) ?? true }
    }

    private func row(_ title: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            IconBadge(systemImage: systemImage, color: color)
        }
    }

    // MARK: Detail

    private var title: String {
        switch model.currentRoute {
        case .home(let screen): screen.title
        case .device(_, let screen): screen.screen.title
        }
    }

    /// The device's name; on Home screens with two or more devices, the app's.
    private var subtitle: String {
        guard model.isGrouped else { return model.primaryHeatPump.deviceName }
        switch model.currentRoute {
        case .home: return String(localized: "Heat Pump")
        case .device(let key, _): return model.device(for: key)?.displayName ?? String(localized: "Heat Pump")
        }
    }

    @ViewBuilder private var detail: some View {
        if model.needsOnboarding {
            OnboardingView()
        } else {
            switch model.currentRoute {
            case .home(.overview): HomeOverviewView()
            case .home(.forecast): OutlookView()
            case .home(.activity): ActivityView()
            case .device(let key, let screen):
                if let device = model.device(for: key) { DeviceUIRegistry.screen(screen, of: device) }
            }
        }
    }
}

/// Refresh that respects the service's throttle and shows a countdown.
/// Refreshes every device; the countdown is the shown device's.
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
            .help("Fetches new status from \(model.serviceName). At most once a minute, so the account is not blocked.")
        }
    }

    private func waitUntil(now: Date) -> Date? {
        let device = model.selectedHeatPump
        guard let result = device.stateResult else { return nil }
        if let until = result.blockedUntil, until > now { return until }
        if let next = result.nextRefreshAllowed, next > now { return next }
        if result.refreshed, let fetched = result.fetchedAt {
            let next = fetched.addingTimeInterval(device.service?.policy.minRefreshInterval ?? RateLimitPolicy.standard.minRefreshInterval)
            if next > now { return next }
        }
        return nil
    }
}

struct OnboardingView: View {
    @Environment(HeatPumpDeviceModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "thermometer.sun")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Welcome")
                    .font(.largeTitle.bold())
                Text(
                    "The app fetches status from the heat pump through \(model.serviceName), the same service the \(model.integration.brandName) app uses. Sign in with the email and password for your \(model.serviceName) account. The password is stored securely in the keychain on the Mac."
                )
                .fixedSize(horizontal: false, vertical: true)
                LoginForm(integration: model.integration)
                    .frame(maxWidth: 420)
            }
            .padding(32)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}
