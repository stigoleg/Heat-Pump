import Foundation
import HeatPumpKit
import Integrations
import Observation
import SwiftUI

/// Sidebar destinations.
enum Screen: String, CaseIterable, Identifiable, Hashable {
    case overview, control, schedule, history, outlook, away, health, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .control: String(localized: "Control")
        case .schedule: String(localized: "Weekly schedule")
        case .history: String(localized: "History")
        case .outlook: String(localized: "Forecast")
        case .away: String(localized: "Away")
        case .health: String(localized: "Health")
        case .activity: String(localized: "Claude activity")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "house.fill"
        case .control: "slider.horizontal.3"
        case .schedule: "calendar.badge.clock"
        case .history: "chart.xyaxis.line"
        case .outlook: "chart.line.uptrend.xyaxis"
        case .away: "suitcase.fill"
        case .health: "heart.fill"
        case .activity: "sparkles"
        }
    }

    /// Badge colour in the sidebar.
    var color: Color {
        switch self {
        case .overview: .blue
        case .control: .orange
        case .schedule: .indigo
        case .history: .green
        case .outlook: .cyan
        case .away: .teal
        case .health: .red
        case .activity: .purple
        }
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case day, week, month, year
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: String(localized: "24 h")
        case .week: String(localized: "7 d")
        case .month: String(localized: "30 d")
        case .year: String(localized: "1 yr")
        }
    }
    var seconds: TimeInterval {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .year: 365 * 86_400
        }
    }

    /// Start of the period ending now: the last 24 hours, or whole calendar days (7 d, 30 d)
    /// and whole months (1 yr) so the first column is never a fragment.
    func start(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        let start: Date? =
            switch self {
            case .day: now.addingTimeInterval(-86_400)
            case .week: calendar.date(byAdding: .day, value: -6, to: today)
            case .month: calendar.date(byAdding: .day, value: -29, to: today)
            case .year:
                calendar.dateInterval(of: .month, for: now).flatMap { calendar.date(byAdding: .month, value: -11, to: $0.start) }
            }
        return start ?? now.addingTimeInterval(-seconds)
    }

    /// Moves a date one period length back (current period → previous period).
    func shifted(_ date: Date, by periods: Int, calendar: Calendar = .current) -> Date {
        let moved: Date? =
            switch self {
            case .day: date.addingTimeInterval(Double(periods) * 86_400)
            case .week: calendar.date(byAdding: .day, value: 7 * periods, to: date)
            case .month: calendar.date(byAdding: .day, value: 30 * periods, to: date)
            case .year: calendar.date(byAdding: .month, value: 12 * periods, to: date)
            }
        return moved ?? date.addingTimeInterval(Double(periods) * seconds)
    }
}

/// One plotted value with its series name.
struct SeriesPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
    let series: String
}

struct HistoryData {
    var temperatures: [TemperaturePoint] = []
    /// False when the service's temperature log is empty and only the app's own readings are shown.
    var fromService = true
    var power: [HistoryPoint] = []
    var modes: [HistoryPoint] = []
}

/// Local power data for the Effekt tab (all aggregated in SQL by the service).
struct LocalPowerData {
    var buckets: [LocalPowerBucket] = []
    /// Starts per hour (per day for 1 yr).
    var starts: [LocalPowerBucket] = []
    var startsUnit: Calendar.Component = .hour
    /// The whole period in one bucket.
    var totals: LocalPowerBucket?
    var startsLast24h = 0
}

/// Energy and cost for one period, with the previous period for comparison.
struct EnergyData {
    var buckets: [EnergyBucket] = []
    var previous: [EnergyBucket] = []
    /// Hourly use from the energy counter (24 t view and Effekt).
    var hourly: [HourCost] = []
    var previousHourly: [HourCost] = []
}

/// App state: the hub, the device models (one per enabled device), navigation, appearance,
/// updates, the shared energy context (prices, weather, outlook), price control and
/// notifications. Each device's own state and actions live in its model (`HeatPumpDeviceModel`);
/// all rules (caching, rate limits, validation, logging) live in HeatPumpKit.
@MainActor
@Observable
final class AppModel {
    /// Every device and integration; nil when the database could not be opened.
    let hub: DeviceHub?
    let startupError: String?
    let isDemo: Bool
    /// The integration this process starts with (also without a service, e.g. when the database
    /// failed); a device's model knows its own.
    let launchIntegration: any Integration

    /// The enabled devices in the registry's order. Never empty: before any device is known it
    /// holds the primary service's model, which finds its device on the first fetch.
    private(set) var devices: [any DeviceModel]
    /// Shown when no heat pump model exists (keeps views that need one working).
    @ObservationIgnored private let fallbackHeatPump: HeatPumpDeviceModel

    /// Where the main window is (Sidebar). Dev: `VARMEPUMPE_SCREEN`.
    var route: AppRoute = .device(nil, .overview)
    /// Dev only (`VARMEPUMPE_HISTORY_TAB`): start tab in Historikk, for screenshots.
    var initialHistoryTab: String?
    /// Selected Settings tab (generelt, konto, enheter, strompris, lokal, vaer, claude, data). Dev: `VARMEPUMPE_SETTINGS_TAB`.
    var settingsTab = ProcessInfo.processInfo.environment["VARMEPUMPE_SETTINGS_TAB"] ?? "generelt"
    /// Light/dark choice, stored in UserDefaults. Dev: `VARMEPUMPE_APPEARANCE` overrides it without saving.
    private(set) var appearance: AppAppearance = .system
    var isRefreshing = false
    var lastError: String?
    var priceSettings = PriceSettings.default
    var todayPrices: [PriceBreakdown] = []
    var tomorrowPrices: [PriceBreakdown] = []
    var priceMessage: String?
    /// MET forecast for the next 48 hours and where it is for.
    var forecast: [ForecastHour] = []
    var weatherLocation: WeatherLocation?
    var weatherFetchedAt: Date?
    var weatherMessage: String?
    var weatherSettings = WeatherSettings.default
    /// Prices from now on with the estimate after the published ones (Prognose).
    var priceOutlook: PriceOutlook?
    /// The whole stored forecast from this hour (up to nine days; Prognose).
    var longForecast: [ForecastHour] = []
    /// Every device's changes with the device (Claude activity with two or more devices).
    var allChanges: [(device: DeviceDescriptor?, record: ChangeRecord)] = []
    /// Price control (Prognose → Prisstyring); runs on the poll tick.
    let priceControl: PriceControlRunner
    /// The device price control steers (nil until known).
    private(set) var priceControlDevice: DeviceKey?
    /// App updates from GitHub releases (Innstillinger → Generelt).
    let updater = Updater()
    /// The menu bar item (Settings → General → Menu bar). Dev: `VARMEPUMPE_MENU_BAR`.
    let menuBar = MenuBarPreferences()

    private var pollTask: Task<Void, Never>?
    private let notifier = Notifier()
    /// Between the Mac's sleep and wake notifications (live power is paused).
    private var isAsleep = false
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        launchIntegration = IntegrationCatalog.current(environment: environment)
        let service: HeatPumpService?
        do {
            let hub = try IntegrationCatalog.makeHub(environment: environment)
            self.hub = hub
            service = hub.primaryAtLaunch
            self.isDemo = hub.isDemo
            self.startupError = nil
        } catch {
            self.hub = nil
            service = nil
            self.isDemo = IntegrationCatalog.isDemo(environment: environment)
            self.startupError = String(localized: "Could not open the database: \(error.localizedDescription)")
        }
        let primary = HeatPumpDeviceModel(service: service, integration: launchIntegration, startupError: startupError)
        devices = [primary]
        fallbackHeatPump = service == nil ? primary : HeatPumpDeviceModel(service: nil, integration: launchIntegration, startupError: startupError)
        if let route = environment["VARMEPUMPE_SCREEN"].flatMap(DeviceNavigation.route(devScreen:)) {
            self.route = route
        }
        initialHistoryTab = environment["VARMEPUMPE_HISTORY_TAB"]
        appearance = environment["VARMEPUMPE_APPEARANCE"].flatMap(AppAppearance.init(rawValue:))
            ?? UserDefaults.standard.string(forKey: AppAppearance.defaultsKey).flatMap(AppAppearance.init(rawValue:))
            ?? .system
        priceControl = PriceControlRunner(service: service)
        connect(primary)
        priceControl.afterChange = { [weak self] in await self?.afterPriceControl() }
        observeSleep()
        observeWindows()
    }

    /// A window closing (checked once it is gone) or coming forward decides the Dock icon.
    private func observeWindows() {
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateDockIcon() }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDockIcon() }
            },
        ]
    }

    /// Starts the meters' live streams that are not running, while polling and awake (a stream
    /// that stopped for good starts again after new credentials or when a home gains live power).
    private func resumeLive() {
        guard pollTask != nil, !isAsleep else { return }
        for meter in meters { meter.startLive() }
    }

    /// Live power pauses while the Mac sleeps and resumes after it wakes (while polling).
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isAsleep = true
                    for meter in self.meters { meter.stopLive() }
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isAsleep = false
                    if self.pollTask != nil { for meter in self.meters { meter.startLive() } }
                }
            },
        ]
    }

    /// Wires a heat pump's model to the app: its setpoints feed price control when it is price
    /// control's device, and a finished firmware update refreshes.
    private func connect(_ device: HeatPumpDeviceModel) {
        device.onUserSetpoint = { [weak self, weak device] value in
            guard let self, let device, device.service != nil, device.service === self.priceControl.service else { return }
            await self.priceControl.userChangedSetpoint(value)
        }
        device.onNeedsRefresh = { [weak self] in await self?.refresh(force: false) }
    }

    /// After a price-control tick or switch: the state the write reported, and (outside a poll,
    /// which reloads anyway) the change log and the rest.
    private func afterPriceControl() async {
        guard let device = heatPumps.first(where: { $0.service != nil && $0.service === priceControl.service }) else { return }
        await device.takeCachedState()
        if !isRefreshing { await reloadLocal() }
    }

    // MARK: Devices

    var heatPumps: [HeatPumpDeviceModel] { devices.compactMap { $0 as? HeatPumpDeviceModel } }

    var meters: [EnergyMeterDeviceModel] { devices.compactMap { $0 as? EnergyMeterDeviceModel } }

    var sensors: [AirQualityDeviceModel] { devices.compactMap { $0 as? AirQualityDeviceModel } }

    /// The first heat pump: what the app shows with one device, and the screens of Home use.
    var primaryHeatPump: HeatPumpDeviceModel { heatPumps.first ?? fallbackHeatPump }

    /// Two or more devices: the sidebar has Home and one group per device.
    var isGrouped: Bool { DeviceNavigation.isGrouped(deviceCount: devices.count) }

    var descriptors: [DeviceDescriptor] { devices.compactMap(\.descriptor) }

    /// The device of `key` (nil: the primary device).
    func device(for key: DeviceKey?) -> (any DeviceModel)? {
        guard let key else { return devices.first }
        return devices.first { $0.key == key }
    }

    /// The heat pump the current route is about, else the primary one (Home, Settings).
    var selectedHeatPump: HeatPumpDeviceModel {
        if case .device(let key, _) = currentRoute, let device = device(for: key) as? HeatPumpDeviceModel { return device }
        return primaryHeatPump
    }

    /// The primary service: shared reads (prices, weather, outlook) go through it, as before
    /// devices.
    var service: HeatPumpService? { primaryHeatPump.service }

    /// The service as app-wide texts name it (the primary device's), e.g. "MELCloud".
    var serviceName: String { primaryHeatPump.serviceName }

    /// Matches the device models to the hub's enabled devices (no network). A model is kept as
    /// long as the hub serves its device with the same service, so a device found by the first
    /// sign-in keeps the model that was showing it.
    func syncDevices() async {
        guard let hub else { return }
        do {
            var next: [any DeviceModel] = []
            /// Meters whose live power came or went (a Pulse paired or removed since the last listing).
            var liveChanged: [EnergyMeterDeviceModel] = []
            for descriptor in try await hub.devices() {
                switch try await hub.service(for: descriptor.key) {
                case .heatPump(let service):
                    let model = heatPumps.first { $0.service === service } ?? makeHeatPump(service)
                    if model.descriptor != descriptor { model.descriptor = descriptor }
                    next.append(model)
                case .energyMeter(let service):
                    let model = meters.first { $0.service === service } ?? EnergyMeterDeviceModel(service: service, descriptor: descriptor)
                    if model.descriptor != descriptor {
                        let hadLive = model.hasLivePower
                        model.descriptor = descriptor
                        if model.hasLivePower != hadLive { liveChanged.append(model) }
                    }
                    next.append(model)
                case .airQuality(let service):
                    let model = sensors.first { $0.service === service } ?? AirQualityDeviceModel(service: service, descriptor: descriptor)
                    if model.descriptor != descriptor { model.descriptor = descriptor }
                    next.append(model)
                case nil: continue
                }
            }
            if next.isEmpty {
                // No device known yet: the primary service finds its device on the first fetch.
                let service = try await hub.primaryService()
                let model = heatPumps.first { $0.service === service } ?? makeHeatPump(service)
                if model.descriptor != nil { model.descriptor = nil }
                next = [model]
            }
            if next.map(ObjectIdentifier.init) != devices.map(ObjectIdentifier.init) {
                // A meter that is no longer served stops its live stream; a new one starts while polling.
                let kept = Set(next.map(ObjectIdentifier.init))
                for meter in meters where !kept.contains(ObjectIdentifier(meter)) { meter.stopLive() }
                devices = next
                resumeLive()
            }
            for meter in liveChanged where !meter.hasLivePower { meter.stopLive() }
            if !liveChanged.isEmpty { resumeLive() }
            await loadIntegrations()
            let controlled = try await hub.priceControlService()
            if controlled !== priceControl.service, !priceControl.isBusy { await priceControl.use(controlled) }
            let key = try await hub.priceControlDevice()
            if key != priceControlDevice { priceControlDevice = key }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func makeHeatPump(_ service: HeatPumpService?) -> HeatPumpDeviceModel {
        let model = HeatPumpDeviceModel(service: service, integration: launchIntegration, startupError: startupError)
        connect(model)
        return model
    }

    /// Every device of the active integrations, disabled ones too (Settings → Account). In demo
    /// mode only the simulated units `VARMEPUMPE_DEMO_DEVICES` asks for (the others are disabled
    /// by the demo, not by the user).
    func allDevices() async -> [DeviceDescriptor] {
        let devices = (try? await hub?.allDevices()) ?? []
        return isDemo ? devices.filter(\.isEnabled) : devices
    }

    func setEnabled(_ enabled: Bool, device key: DeviceKey) async -> String? {
        guard let hub else { return startupError }
        // Turning off price control's device turns price control off first (the temperature is
        // set back), as choosing another device does.
        if !enabled, key == priceControlDevice, priceControl.enabled { await priceControl.setEnabled(false) }
        do {
            try await hub.setEnabled(enabled, for: key)
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await syncDevices()
        await reloadLocal()
        return nil
    }

    func rename(_ key: DeviceKey, to name: String) async -> String? {
        guard let hub else { return startupError }
        do {
            try await hub.rename(key, to: name.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await syncDevices()
        return nil
    }

    /// Lists the accounts' devices again (one request per integration, under its spacing).
    func refreshDeviceList() async -> String? {
        guard let hub else { return startupError }
        do {
            _ = try await hub.refreshDeviceList()
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await syncDevices()
        await reloadLocal()
        return nil
    }

    // MARK: Navigation

    /// The route as shown: with one device every device route is the primary device's.
    var currentRoute: AppRoute { DeviceNavigation.normalized(route, devices: descriptors) }

    /// The sidebar screen of the current route, for views that move to another screen of the same
    /// device ("Open Control") or to a Home screen.
    var selection: Screen? {
        get { Screen(currentRoute) }
        set {
            guard let newValue else { return }
            switch newValue {
            case .outlook: route = .home(.forecast)
            case .activity: route = .home(.activity)
            default:
                guard let screen = newValue.deviceScreen else { return }
                if case .device(let key, _) = currentRoute {
                    route = .device(key, screen)
                } else {
                    route = .device(nil, screen)
                }
            }
        }
    }

    var needsOnboarding: Bool {
        let device = primaryHeatPump
        guard !isDemo, !isGrouped, device.service != nil else { return false }
        return !device.hasCredentials || (device.stateResult?.needsLogin == true && device.state == nil)
    }

    var dbPath: String { service?.store.path ?? HistoryStore.defaultPath() }

    // MARK: Lifecycle

    func start() {
        guard pollTask == nil else { return }
        let keychain = service?.credentials as? KeychainCredentialStore
        // The permission prompt waits for the user; it must not hold up the first refresh.
        Task { [notifier] in await notifier.requestPermissionOnce() }
        pollTask = Task { [weak self] in
            // The devices first (no network), so two or more show their groups at once.
            await self?.syncDevices()
            // Then (local only): whether price control is on decides what closing the window does.
            await self?.priceControl.load()
            // Once per install, before anything reads the keychain: items from older versions get
            // the ACL shared with the helper (a read during the swap could miss an item).
            if let keychain { await Task.detached { keychain.migrateAccessIfNeeded() }.value }
            await self?.checkTibberToken()
            if let hub = self?.hub, hub.isDemo { try? await hub.seedDemoHistoryIfNeeded() }
            if let self, !self.isAsleep { for meter in self.meters { meter.startLive() } }
            while !Task.isCancelled {
                guard let self else { return }
                // Nothing while the Mac sleeps (a dark wake can run the loop): price control has
                // set the temperature back and live power is paused until it wakes.
                if !self.isAsleep {
                    await self.syncDevices()
                    await self.refresh(force: false)
                    // New devices on an account (at most daily per integration, mostly from listings
                    // the integration fetched anyway).
                    if let hub = self.hub, (try? await hub.discoverDevices()) == true {
                        await self.syncDevices()
                        await self.reloadLocal()
                    }
                }
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return  // cancelled
                }
            }
        }
    }

    /// True while price control or the menu bar item is on: closing the window keeps the app and
    /// its polling running.
    var keepsRunningInBackground: Bool { priceControl.enabled || menuBar.enabled }

    /// With the menu bar item on, the app has no Dock icon while none of its windows is open (a
    /// menu bar app, as macOS expects); it comes back with the window. Without it the Dock icon
    /// stays, also while price control keeps the app running.
    func updateDockIcon() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        let policy: NSApplication.ActivationPolicy = menuBar.enabled && !hasWindow ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// Settings → General → Menu bar. Turned off with no window open, the app goes back to
    /// quitting when its last window closes; the Dock icon returns at once.
    func setMenuBarEnabled(_ on: Bool) {
        menuBar.setEnabled(on)
        updateDockIcon()
    }

    /// Stops polling (window closed / app quitting). The app only polls while open, unless price
    /// control or the menu bar item is on.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        for meter in meters { meter.stopLive() }
    }

    /// The devices with the stalest state first. An integration allows one state fetch a minute
    /// for its whole account, so devices sharing one take turns.
    private var pollOrder: [any DeviceModel] {
        devices.enumerated()
            .sorted { ($0.element.lastFetched ?? .distantPast, $0.offset) < ($1.element.lastFetched ?? .distantPast, $1.offset) }
            .map(\.element)
    }

    /// Asks each device's service for state (cache unless old; it enforces the 60 s / block
    /// rules), syncs history, prices, weather and the rest (each limited by the service) and
    /// reloads local data.
    func refresh(force: Bool) async {
        guard let service, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let devices = pollOrder
        for device in devices { await device.pollState(force: force) }
        let sync = try? await service.syncPrices()
        priceMessage = sync?.status == .failed ? sync?.message : nil
        // Forecast (hourly at most, only when MET's copy expired), Tibber house use (hourly, only
        // with a token), then each device's away settings, weekly timer and local adapter.
        let weather = try? await service.syncWeather()
        weatherMessage = weather?.status == .failed || weather?.status == .noLocation ? weather?.message : nil
        if hasTibberToken || isDemo { _ = try? await service.syncHouseConsumption() }
        for device in devices { await device.pollDetails() }
        await priceControl.tick()
        await reloadLocal()
        for device in devices { await device.afterPoll() }
        await deliverNotifications()
    }

    /// Rereads the shared data (prices, weather, outlook) and every device's stored data.
    func reloadLocal() async {
        guard let service else { return }
        do {
            priceSettings = try await service.priceSettings()
            let now = Date()
            let calendar = Calendar.current
            todayPrices = try await service.prices(day: now)
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
                tomorrowPrices = try await service.prices(day: tomorrow)
            }
            let hourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            let weather = try await service.weatherForecast(from: hourStart, to: hourStart.addingTimeInterval(48 * 3600))
            forecast = weather.hours
            weatherLocation = weather.location
            weatherFetchedAt = weather.fetchedAt
            weatherSettings = try await service.weatherSettings()
            priceOutlook = try await service.priceOutlook()
            longForecast = try await service.weatherForecast(from: hourStart, to: hourStart.addingTimeInterval(10 * 86_400)).hours
        } catch {
            lastError = error.localizedDescription
        }
        for device in devices { await device.reloadLocal() }
        if isGrouped, let hub { allChanges = (try? await hub.changeLog(limit: 500)) ?? allChanges }
    }

    /// Per heat pump; with two or more the title names the device. The first device keeps the
    /// memory it had before devices, the others get their own. Air quality sensors always name
    /// the sensor and keep their own memory.
    private func deliverNotifications() async {
        let named = isGrouped
        for (index, device) in heatPumps.enumerated() {
            let memoryKey = index == 0 ? nil : device.key
            let planned = NotificationPlanner.plan(
                state: device.state, errorEvents: device.errorLog, maintenance: device.maintenance, memory: notifier.memory(for: memoryKey),
                now: Date(), serviceName: device.serviceName, noErrorCodes: device.errorCodes.noErrorCodes,
                device: named ? device.key.map { ($0, device.displayName) } : nil)
            notifier.setMemory(planned.memory, for: memoryKey)
            for notification in planned.notifications {
                await notifier.deliver(notification)
            }
        }
        // Air quality sensors: a high long-term radon average, when turned on for the sensor.
        for device in sensors {
            guard let key = device.key else { continue }
            let planned = NotificationPlanner.planAirQuality(
                status: device.status, enabled: device.radonAlerts, memory: notifier.memory(for: key), now: Date(),
                device: (key, device.displayName))
            notifier.setMemory(planned.memory, for: key)
            for notification in planned.notifications { await notifier.deliver(notification) }
        }
    }

    // MARK: Data for views

    /// Price level of the current hour (nil for Norgespris or without enough history).
    var currentPriceLevel: PriceLevel? {
        let hour = Calendar.current.dateInterval(of: .hour, for: Date())?.start
        return todayPrices.first { $0.hour == hour }?.level
    }

    /// Forecast for the chart range (temperature tab), from now on.
    func forecast(until end: Date) async -> [ForecastHour] {
        guard let service else { return [] }
        let start = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
        return (try? await service.weatherForecast(from: start, to: end).hours) ?? []
    }

    // MARK: Menu bar

    /// The device the menu bar shows: the one last chosen in the panel, else the primary one (also
    /// when the chosen one is gone or the panel has nothing for its kind).
    var menuBarDevice: any DeviceModel {
        let key = MenuBarLayout.shownDevice(chosen: menuBar.chosenDevice, devices: menuBarDevices.compactMap(\.key))
        return devices.first { $0.key != nil && $0.key == key } ?? devices[0]
    }

    /// The devices the menu bar panel can show (its device picker lists them).
    var menuBarDevices: [any DeviceModel] { devices.filter { MenuBarPanel.shows($0.kind) } }

    /// The price of the current hour (shared by every device).
    var currentPrice: PriceBreakdown? {
        let now = Date()
        return todayPrices.first { $0.hour <= now && now < $0.hour.addingTimeInterval(3600) }
    }

    /// What the menu bar title can show for `device` right now (missing values stay nil).
    func menuBarValues(for device: any DeviceModel) -> MenuBarValues {
        var values = MenuBarValues(
            outdoor: forecast.first?.temperature, priceNowOre: currentPrice?.totalOre, priceLevel: currentPrice?.level)
        if let pump = device as? HeatPumpDeviceModel, let state = pump.state {
            let shown = pump.debouncer?.displayed ?? ControlSettings(state)
            let mode = pump.debouncer?.displayedMode ?? state.mode
            values.symbol = !shown.power ? .off : mode.map { .mode($0) }
            values.indoor = pump.newerLocalSample?.roomTemperature ?? state.roomTemperature
            values.target = state.setTemperature == nil ? nil : shown.setTemperature
            values.outdoor = pump.newerLocalSample?.outdoorTemperature ?? state.outdoorTemperature ?? values.outdoor
            values.powerW = pump.liveSample?.powerW.map(Double.init) ?? pump.estimatedPowerW
            values.todayCostNok = pump.today?.costNok
            values.health = pump.health?.overall
        } else if let meter = device as? EnergyMeterDeviceModel {
            values.symbol = .meter
            values.powerW = meter.powerNowW
            values.todayCostNok = meter.status?.today.cost?.totalNok
            values.priceNowOre = values.priceNowOre ?? meter.status?.priceNowOre
        } else if let sensor = device as? AirQualityDeviceModel {
            values.symbol = .sensor
            if let status = sensor.status {
                values.indoor = status.value(.temperature)?.value
                values.radon = (status.value(.radonShortTerm) ?? status.value(.radonLongTerm))?.value
                values.co2 = status.value(.co2)?.value
                values.humidity = status.value(.humidity)?.value
                values.health = status.findings.map(\.severity).max()
            }
        }
        return values
    }

    var menuBarSegments: [MenuBarSegment] { menuBar.layout.segments(for: menuBarValues(for: menuBarDevice)) }

    // MARK: Weather settings

    /// Reads the stored weather settings (Settings may open before the first reload; saving
    /// the empty defaults would drop the chosen place).
    func loadWeatherSettings() async -> WeatherSettings {
        if let service, let stored = try? await service.weatherSettings() { weatherSettings = stored }
        return weatherSettings
    }

    /// Saves and fetches the forecast for the new place when MET allows it. Returns the
    /// outcome for the Save button.
    func saveWeatherSettings(_ settings: WeatherSettings) async -> (ok: Bool, text: String) {
        guard let service else { return (false, startupError ?? "") }
        do {
            try await service.saveWeatherSettings(settings)
            let sync = try await service.syncWeather()
            weatherMessage = sync.status == .failed || sync.status == .noLocation ? sync.message : nil
            await reloadLocal()
            switch sync.status {
            case .failed: return (false, sync.message ?? String(localized: "Saved, but the forecast could not be fetched."))
            case .skipped:
                if let next = sync.nextAllowed {
                    return (true, String(localized: "Saved. A new forecast will be fetched at \(Format.hour(next))."))
                }
                return (true, String(localized: "Saved. A new forecast will be fetched soon."))
            case .fetched, .notModified: return (true, String(localized: "Saved, and the forecast is updated."))
            case .upToDate, .noLocation: return (true, String(localized: "Saved."))
            }
        } catch {
            return (false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: Appearance

    func setAppearance(_ value: AppAppearance) {
        appearance = value
        UserDefaults.standard.set(value.rawValue, forKey: AppAppearance.defaultsKey)
        applyAppearance()
    }

    func cycleAppearance() { setAppearance(appearance.next) }

    /// App-wide, so Settings, alerts and menus follow too.
    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }

    // MARK: Prices

    /// Reads the stored price settings (Settings may open before the first reload).
    func loadPriceSettings() async -> PriceSettings {
        if let service, let stored = try? await service.priceSettings() { priceSettings = stored }
        return priceSettings
    }

    func savePriceSettings(_ settings: PriceSettings) async {
        guard let service else { return }
        do {
            try await service.savePriceSettings(settings)
            priceSettings = settings
            let sync = try await service.syncPrices()
            priceMessage = sync.status == .failed ? sync.message : nil
        } catch {
            priceMessage = error.localizedDescription
        }
        await reloadLocal()
    }

    /// Whether a Tibber token is stored. Cached; refreshed only by `checkTibberToken()`
    /// (Settings opening, after saving), so views never read the keychain while rendering.
    private(set) var hasTibberToken = false

    func checkTibberToken() async {
        guard let credentials = service?.credentials else { return }
        hasTibberToken = await Task.detached { credentials.hasTibberToken() }.value
    }

    /// Saves the token in the keychain and tests it with one request.
    func saveAndTestTibberToken(_ token: String) async -> String {
        guard let service else { return startupError ?? "" }
        do {
            try service.credentials?.saveTibberToken(token)
        } catch {
            return error.localizedDescription
        }
        let message = await service.testTibberToken(token)
        // The meter shares the token: a refused one may work again now.
        try? await hub?.sharedCredentialsChanged()
        resumeLive()
        await savePriceSettings(priceSettings)
        return message
    }

    // MARK: Price control

    /// Heat pumps price control can steer (thermostat); a device picker appears with two or more.
    var priceControlCandidates: [HeatPumpDeviceModel] {
        heatPumps.filter { $0.descriptor?.capabilities.contains(.thermostat) == true }
    }

    /// Moves price control to another device. Its settings are shared, so it is turned off on the
    /// old device first (which sets that device's temperature back).
    func setPriceControlDevice(_ key: DeviceKey) async {
        guard let hub, key != priceControlDevice else { return }
        if priceControl.enabled { await priceControl.setEnabled(false) }
        do {
            try await hub.setPriceControlDevice(key)
        } catch {
            priceControl.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        await syncDevices()
    }

    // MARK: Integrations and sign-in

    /// The integrations in use (empty until the hub has answered).
    private(set) var activeIntegrations: [any Integration] = []
    private var integrationsLoaded = false

    func loadIntegrations() async {
        guard let hub else { return }
        let active = await hub.activeIntegrations
        if active.map(\.id) != activeIntegrations.map(\.id) { activeIntegrations = active }
        integrationsLoaded = true
    }

    /// Every service a user can connect (Add Device, Settings → Devices), active ones too; never
    /// the simulated ones. In demo mode the list shows, but signing in is not used.
    var setupIntegrations: [any Integration] {
        guard let hub else { return [] }
        return hub.catalog.filter { !IntegrationCatalog.simulated.contains($0.id) }
    }

    func isActive(_ integration: any Integration) -> Bool {
        activeIntegrations.contains { $0.id == integration.id }
    }

    /// The Add Device sheet in the main window (sidebar button, File → Add Device…), and the
    /// service it opens on (nil: the list). Dev: `VARMEPUMPE_ADD_DEVICE=1` or `=<integration id>`.
    var showingAddDevice = ProcessInfo.processInfo.environment["VARMEPUMPE_ADD_DEVICE"] != nil
    var addDeviceChoice: String? = ProcessInfo.processInfo.environment["VARMEPUMPE_ADD_DEVICE"].flatMap { $0 == "1" ? nil : $0 }

    func addDevice(choosing id: String? = nil) {
        addDeviceChoice = id
        showingAddDevice = true
    }

    /// Values already stored for an integration that is not active yet (its token shared with the
    /// electricity price), to fill in its sign-in form. Reads the keychain; call from Settings only.
    func storedValues(for integration: any Integration) async -> [String: String] {
        guard integration.credentialMapping.isShared, let credentials = service?.credentials else { return [:] }
        let mapping = integration.credentialMapping
        return await Task.detached { (try? credentials.loadValues(for: mapping))?.fields ?? [:] }.value
    }

    func credentialFields(for integration: any Integration) -> [CredentialField] {
        hub?.credentialFields(for: integration.id) ?? integration.credentialFields
    }

    func hasCredentials(integration id: String) async -> Bool {
        await hub?.hasCredentials(integration: id) ?? false
    }

    /// One login + state fetch with the integration's sign-in fields. Returns (success, message).
    func signIn(integration: any Integration, values: [String: String]) async -> (Bool, String) {
        guard let hub, service != nil else { return (false, startupError ?? "") }
        let (values, problem) = Self.checked(values, fields: credentialFields(for: integration))
        if let problem { return (false, problem) }
        do {
            let result = try await hub.signIn(integration: integration.id, values: CredentialValues(values))
            return await signedIn(result, integration: integration.id)
        } catch {
            return (false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Starts using another integration and signs in to it.
    func addIntegration(_ integration: any Integration, values: [String: String]) async -> (Bool, String) {
        guard let hub else { return (false, startupError ?? "") }
        let (values, problem) = Self.checked(values, fields: credentialFields(for: integration))
        if let problem { return (false, problem) }
        do {
            let result = try await hub.addIntegration(id: integration.id, credentials: CredentialValues(values))
            await loadIntegrations()
            guard let result else {
                await syncDevices()
                await reloadLocal()
                return (true, String(localized: "Added."))
            }
            return await signedIn(result, integration: integration.id)
        } catch {
            return (false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Stops using an integration; its devices keep their data.
    func removeIntegration(_ integration: any Integration) async -> String? {
        guard let hub else { return startupError }
        if priceControlDevice?.integration == integration.id, priceControl.enabled { await priceControl.setEnabled(false) }
        do {
            try await hub.removeIntegration(id: integration.id)
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await loadIntegrations()
        await syncDevices()
        await reloadLocal()
        return nil
    }

    /// Trims the e-mail and checks that every field is filled in.
    private static func checked(_ values: [String: String], fields: [CredentialField]) -> ([String: String], String?) {
        var values = values
        for field in fields where field.kind == .email {
            values[field.id] = values[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard fields.contains(where: { (values[$0.id] ?? "").isEmpty }) else { return (values, nil) }
        if Set(fields.map(\.kind)) == [.email, .password] { return (values, String(localized: "Enter both email and password.")) }
        return (values, String(localized: "Fill in every field."))
    }

    /// Shows a sign-in's test fetch on the device it found and says how it went.
    private func signedIn(_ result: StateResult, integration id: String) async -> (Bool, String) {
        await syncDevices()
        // New credentials: a live stream the old ones stopped may start again.
        resumeLive()
        if result.state == nil, result.refreshed, result.error == nil {
            // An integration without a heat pump (a meter): it listed its devices.
            await reloadLocal()
            let found = await allDevices().filter { $0.integrationId == id }.map(\.name)
            if found.count == 1, let name = found.first { return (true, String(localized: "Signed in. Found “\(name)”.")) }
            return (true, String(localized: "Signed in. Found \(found.count) devices."))
        }
        let device =
            heatPumps.first { $0.key != nil && $0.key == result.state?.key }
            ?? heatPumps.first { $0.key?.integration == id } ?? primaryHeatPump
        device.stateResult = result
        device.hasCredentials = true
        await reloadLocal()
        if result.refreshed, let state = result.state {
            return (true, String(localized: "Signed in. Found “\(state.name)”."))
        }
        if let message = result.blockMessage {
            return (false, message)
        }
        if let next = result.nextRefreshAllowed {
            return (false, String(localized: "The sign-in is saved. Wait a little before testing again (at \(Display.time(next)) at the earliest)."))
        }
        return (false, result.error ?? String(localized: "Unknown error when signing in."))
    }

    func signOut(integration: any Integration) async {
        guard let hub, service != nil else { return }
        do {
            try await hub.signOut(integration: integration.id)
        } catch {
            lastError = error.localizedDescription
        }
        for device in heatPumps where device.integration.id == integration.id {
            if let service = device.service { device.hasCredentials = await service.hasCredentials() }
        }
    }
}

extension Screen {
    /// The device screen this sidebar screen is (nil for Forecast and Claude activity).
    var deviceScreen: DeviceScreen? {
        switch self {
        case .overview: .overview
        case .control: .control
        case .schedule: .schedule
        case .history: .history
        case .away: .away
        case .health: .health
        case .outlook, .activity: nil
        }
    }

    /// The single-device route of this screen.
    var route: AppRoute {
        switch self {
        case .outlook: .home(.forecast)
        case .activity: .home(.activity)
        default: .device(nil, deviceScreen ?? .overview)
        }
    }

    /// The sidebar screen of a route (nil for Home's overview, which has no single-device screen).
    init?(_ route: AppRoute) {
        switch route {
        case .home(.overview): return nil
        case .home(.forecast): self = .outlook
        case .home(.activity): self = .activity
        case .device(_, let screen): self = Screen.allCases.first { $0.deviceScreen == screen } ?? .overview
        }
    }
}
