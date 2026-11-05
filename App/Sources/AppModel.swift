import Foundation
import HeatPumpKit
import Observation
import SwiftUI

/// Sidebar destinations.
enum Screen: String, CaseIterable, Identifiable, Hashable {
    case overview, control, history, health, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Oversikt"
        case .control: "Kontroll"
        case .history: "Historikk"
        case .health: "Helse"
        case .activity: "Claude-aktivitet"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "house.fill"
        case .control: "slider.horizontal.3"
        case .history: "chart.xyaxis.line"
        case .health: "heart.fill"
        case .activity: "sparkles"
        }
    }

    /// Badge colour in the sidebar.
    var color: Color {
        switch self {
        case .overview: .blue
        case .control: .orange
        case .history: .green
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
        case .day: "24 t"
        case .week: "7 d"
        case .month: "30 d"
        case .year: "1 år"
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
    /// and whole months (1 år) so the first column is never a fragment.
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
    /// False when MELCloud's temperature log is empty and only the app's own readings are shown.
    var fromMELCloud = true
    var power: [HistoryPoint] = []
    var modes: [HistoryPoint] = []
}

/// Local power data for the Effekt tab.
struct LocalPowerData {
    var buckets: [LocalPowerBucket] = []
    var starts: [HourStarts] = []
    var runningSeconds: TimeInterval = 0
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

/// App state. Wraps the `HeatPumpService` actor; all rules (caching, rate limits, validation,
/// logging) live in HeatPumpKit.
@MainActor
@Observable
final class AppModel {
    let service: HeatPumpService?
    let startupError: String?
    let isDemo: Bool

    var selection: Screen? = .overview
    /// Dev only (`VARMEPUMPE_HISTORY_TAB`): start tab in Historikk, for screenshots.
    var initialHistoryTab: String?
    /// Selected Settings tab (konto, strompris, lokal, claude, data). Dev: `VARMEPUMPE_SETTINGS_TAB`.
    var settingsTab = ProcessInfo.processInfo.environment["VARMEPUMPE_SETTINGS_TAB"] ?? "konto"
    var stateResult: StateResult?
    /// State as it should be after changes not yet confirmed by a refresh.
    var effectiveState: DeviceState?
    var health: HealthReport?
    var maintenance: [MaintenanceStatus] = []
    var errorLog: [ErrorLogEntry] = []
    var changes: [ChangeRecord] = []
    var fetchStatus: [FetchStateRow] = []
    var hasCredentials = true
    var isRefreshing = false
    var lastError: String?
    /// Sends edits from Kontroll and the dial automatically.
    private(set) var debouncer: ChangeDebouncer?
    var priceSettings = PriceSettings.default
    var todayPrices: [PriceBreakdown] = []
    var tomorrowPrices: [PriceBreakdown] = []
    var today: EnergyBucket?
    var todayHourly: [HourCost] = []
    var estimatedPowerW: Double?
    var priceMessage: String?
    /// Latest local reading from the Wi-Fi adapter and its reachability.
    var live: LiveStatus?
    /// Local readings of the last 60 minutes (power sparkline).
    var recentLocal: [LocalSample] = []
    var localSettings = LocalSettings.default
    /// Bumped after every reload so views can refetch derived data (charts).
    var revision = 0

    private var pollTask: Task<Void, Never>?
    private let notifier = Notifier()

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        do {
            let service = try HeatPumpService.makeDefault(environment: environment)
            self.service = service
            self.isDemo = service.isDemo
            self.startupError = nil
        } catch {
            self.service = nil
            self.isDemo = HeatPumpService.isMock(environment: environment)
            self.startupError = "Kunne ikke åpne databasen: \(error.localizedDescription)"
        }
        if let screen = environment["VARMEPUMPE_SCREEN"].flatMap(Screen.init(rawValue:)) {
            selection = screen
        }
        initialHistoryTab = environment["VARMEPUMPE_HISTORY_TAB"]
        if let service {
            debouncer = ChangeDebouncer(
                send: { [weak self] changes in
                    let outcomes = try await service.apply(changes, source: .app, reason: ChangeDebouncer.reason)
                    await self?.afterSend()
                    return outcomes
                },
                budget: { try await service.writeBudget() })
        }
    }

    /// Shows the state reported by the write right away (no extra network call) and logs it.
    private func afterSend() async {
        guard let service else { return }
        if let cached = try? await service.cachedState() {
            stateResult?.state = cached
            debouncer?.updateLive(cached)
        }
        await reloadLocal()
    }

    var state: DeviceState? { stateResult?.state }

    var deviceName: String { state?.name ?? "Varmepumpe" }

    var needsOnboarding: Bool {
        guard !isDemo, service != nil else { return false }
        return !hasCredentials || (stateResult?.needsLogin == true && state == nil)
    }

    /// True while a sent change is not yet reflected in fresh data from the unit.
    var isAwaitingConfirmation: Bool {
        guard let state else { return false }
        if state.hasPendingCommand { return true }
        guard let effectiveState else { return false }
        return ControlSettings(effectiveState) != ControlSettings(state)
    }

    var dbPath: String { service?.store.path ?? HistoryStore.defaultPath() }

    // MARK: Lifecycle

    func start() {
        guard pollTask == nil else { return }
        // The permission prompt waits for the user; it must not hold up the first refresh.
        Task { [notifier] in await notifier.requestPermissionOnce() }
        pollTask = Task { [weak self] in
            if let service = self?.service, service.isDemo { try? await service.seedDemoHistoryIfNeeded() }
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(force: false)
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return  // cancelled
                }
            }
        }
    }

    /// Stops polling (window closed / app quitting). The app only polls while open.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Asks the service for state (cache unless old; it enforces the 60 s / block rules),
    /// syncs history (hourly-limited by the service) and reloads local data.
    func refresh(force: Bool) async {
        guard let service, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        hasCredentials = await service.hasCredentials()
        do {
            stateResult = try await service.currentState(force: force)
            debouncer?.updateLive(stateResult?.state)
            if stateResult?.state != nil { _ = try await service.syncHistory() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        let sync = try? await service.syncPrices()
        priceMessage = sync?.status == .failed ? sync?.message : nil
        // Local adapter: one read per poll at most (the service enforces 20 s spacing and back-off).
        if (try? await service.localSettings())?.enabled == true { _ = try? await service.liveStatus(maxAge: 50) }
        await reloadLocal()
        await debouncer?.refreshBudget()
        await deliverNotifications()
    }

    func reloadLocal() async {
        guard let service else { return }
        do {
            effectiveState = try await service.effectiveState()
            health = try await service.healthReport()
            maintenance = try await service.maintenanceStatus()
            errorLog = try await service.errorLog(days: 90)
            changes = try await service.changeLog(limit: 500, source: nil)
            fetchStatus = try await service.fetchStatus()
            priceSettings = try await service.priceSettings()
            let now = Date()
            let calendar = Calendar.current
            todayPrices = try await service.prices(day: now)
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
                tomorrowPrices = try await service.prices(day: tomorrow)
            }
            let startOfDay = calendar.startOfDay(for: now)
            today = try await service.energy(period: .day, from: startOfDay, to: now).last {
                $0.period == WireDate.day(now, timeZone: .current)
            }
            todayHourly = try await service.hourlyConsumption(from: now.addingTimeInterval(-86_400), to: now)
            estimatedPowerW = try await service.estimatedPowerW()
            localSettings = try await service.localSettings()
            // Stored reading only; never reads the adapter.
            live = try await service.storedLiveStatus()
            recentLocal = try await service.localSamples(from: now.addingTimeInterval(-3600), to: now)
        } catch {
            lastError = error.localizedDescription
        }
        revision += 1
    }

    private func deliverNotifications() async {
        let planned = NotificationPlanner.plan(
            state: state, errorEvents: errorLog, maintenance: maintenance, memory: notifier.memory, now: Date())
        notifier.memory = planned.memory
        for notification in planned.notifications {
            await notifier.deliver(notification)
        }
    }

    // MARK: Data for views

    func history(range: HistoryRange, now: Date = Date()) async -> HistoryData {
        await history(from: range.start(now: now), to: now)
    }

    func history(from: Date, to end: Date) async -> HistoryData {
        guard let service else { return HistoryData() }
        var data = HistoryData()
        if let history = try? await service.temperatureHistory(from: from, to: end) {
            data.temperatures = history.points
            data.fromMELCloud = history.fromMELCloud
        }
        data.power = (try? await service.history(metric: .power, from: from, to: end)) ?? []
        data.modes = (try? await service.history(metric: .mode, from: from, to: end)) ?? []
        return data
    }

    /// Energy for the range (per hour for 24 t, per day for 7/30 d, per month for 1 år) and the
    /// same length of time before it.
    func energy(range: HistoryRange) async -> EnergyData {
        guard let service else { return EnergyData() }
        let to = Date()
        let from = range.start(now: to)
        let previousFrom = range.shifted(from, by: -1)
        let period: EnergyPeriod = range == .year ? .month : .day
        var data = EnergyData()
        data.buckets = (try? await service.energy(period: period, from: from, to: to)) ?? []
        data.previous = (try? await service.energy(period: period, from: previousFrom, to: from.addingTimeInterval(-1))) ?? []
        if range == .day || range == .week {
            data.hourly = (try? await service.hourlyConsumption(from: from, to: to)) ?? []
            data.previousHourly = (try? await service.hourlyConsumption(from: previousFrom, to: from)) ?? []
        }
        return data
    }

    // MARK: Local connection

    /// Local reading younger than 3 minutes, or nil.
    var liveSample: LocalSample? {
        guard let sample = live?.sample, Date().timeIntervalSince(sample.timestamp) < 180 else { return nil }
        return sample
    }

    /// Local reading newer than the cloud snapshot (for temperatures on Oversikt), or nil.
    var newerLocalSample: LocalSample? {
        guard let sample = liveSample else { return nil }
        guard let state else { return sample }
        return sample.timestamp > state.fetchedAt ? sample : nil
    }

    func localPower(range: HistoryRange) async -> LocalPowerData {
        guard let service else { return LocalPowerData() }
        let to = Date()
        let from = range.start(now: to)
        let bucket: TimeInterval =
            switch range {
            case .day: 5 * 60
            case .week: 30 * 60
            case .month: 2 * 3600
            case .year: 24 * 3600
            }
        var data = LocalPowerData()
        // The bucket still filling up is left out (a few readings would show as a spike).
        data.buckets = ((try? await service.localPowerBuckets(from: from, to: to, bucket: bucket)) ?? [])
            .filter { $0.start.addingTimeInterval(bucket) <= to }
        let samples = (try? await service.localSamples(from: from, to: to)) ?? []
        data.starts = CompressorCycles.startsPerHour(samples, timeZone: .current)
        data.runningSeconds = CompressorCycles.runningSeconds(in: samples)
        data.startsLast24h = CompressorCycles.starts(in: samples.filter { $0.timestamp >= to.addingTimeInterval(-86_400) }).starts
        return data
    }

    /// Saves the local settings. Returns a Norwegian error, or nil.
    func saveLocalSettings(_ settings: LocalSettings) async -> String? {
        guard let service else { return startupError }
        do {
            try await service.saveLocalSettings(settings)
            localSettings = try await service.localSettings()
            if localSettings.enabled { _ = try? await service.liveStatus(maxAge: 0) }
            await reloadLocal()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func testLocal(host: String) async -> LocalTestResult {
        guard let service else { return LocalTestResult(ok: false, message: startupError ?? "", sample: nil) }
        let result = (try? await service.testLocal(host: host))
            ?? LocalTestResult(ok: false, message: "Testen kunne ikke kjøres.", sample: nil)
        await reloadLocal()
        return result
    }

    func discoverLocal() async -> LocalDiscoveryResult {
        guard let service else { return LocalDiscoveryResult(host: nil, message: startupError ?? "") }
        let result = (try? await service.discoverLocal())
            ?? LocalDiscoveryResult(host: nil, message: "Søket kunne ikke kjøres.")
        localSettings = (try? await service.localSettings()) ?? localSettings
        await reloadLocal()
        return result
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
        hasTibberToken = await Task.detached { credentials.loadTibberToken() != nil }.value
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
        await savePriceSettings(priceSettings)
        return message
    }

    // MARK: Actions

    /// Returns a Norwegian error message, or nil on success.
    func recordMaintenance(kind: MaintenanceKind, date: Date, note: String) async -> String? {
        guard let service else { return startupError }
        do {
            _ = try await service.recordMaintenance(kind: kind, date: date, note: note.isEmpty ? nil : note)
            await reloadLocal()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// One login + state fetch. Returns (success, Norwegian message).
    func signIn(email: String, password: String) async -> (Bool, String) {
        guard let service else { return (false, startupError ?? "") }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else { return (false, "Fyll inn både e-post og passord.") }
        do {
            let result = try await service.signIn(MELCloudCredentials(email: email, password: password))
            stateResult = result
            hasCredentials = true
            await reloadLocal()
            if result.refreshed, let state = result.state {
                return (true, "Innlogget. Fant «\(state.name)».")
            }
            if let message = result.blockMessage {
                return (false, message)
            }
            if let next = result.nextRefreshAllowed {
                return (false, "Innloggingen er lagret. Vent litt før du tester igjen (tidligst kl. \(Norwegian.time(next))).")
            }
            return (false, result.error ?? "Ukjent feil ved innlogging.")
        } catch {
            return (false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// E-mail of the stored account (reads the keychain; call from Settings only).
    func accountEmail() async -> String? {
        await service?.accountEmail()
    }

    func signOut() async {
        guard let service else { return }
        do {
            try await service.signOut()
        } catch {
            lastError = error.localizedDescription
        }
        hasCredentials = await service.hasCredentials()
    }
}
