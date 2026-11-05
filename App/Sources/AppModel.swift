import Foundation
import HeatPumpKit
import Observation
import SwiftUI

/// Sidebar destinations.
enum Screen: String, CaseIterable, Identifiable, Hashable {
    case overview, control, schedule, history, outlook, away, health, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Oversikt"
        case .control: "Kontroll"
        case .schedule: "Ukeplan"
        case .history: "Historikk"
        case .outlook: "Prognose"
        case .away: "Borte hjemmefra"
        case .health: "Helse"
        case .activity: "Claude-aktivitet"
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

/// Local power data for the Effekt tab (all aggregated in SQL by the service).
struct LocalPowerData {
    var buckets: [LocalPowerBucket] = []
    /// Starts per hour (per day for 1 år).
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
    /// Selected Settings tab (generelt, konto, strompris, lokal, claude, data). Dev: `VARMEPUMPE_SETTINGS_TAB`.
    var settingsTab = ProcessInfo.processInfo.environment["VARMEPUMPE_SETTINGS_TAB"] ?? "generelt"
    /// Light/dark choice, stored in UserDefaults. Dev: `VARMEPUMPE_APPEARANCE` overrides it without saving.
    private(set) var appearance: AppAppearance = .system
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
    /// MET forecast for the next 48 hours, where it is for, and the estimate for tomorrow.
    var forecast: [ForecastHour] = []
    var weatherLocation: WeatherLocation?
    var weatherFetchedAt: Date?
    var weatherMessage: String?
    var tomorrow: TomorrowEstimate?
    var weatherSettings = WeatherSettings.default
    /// Frost protection and holiday mode (cached; read from MELCloud at most hourly).
    var away: AwaySettings?
    /// MELCloud's weekly timer (cached; read at most every 6 hours).
    var weeklyTimer: WeeklyTimer?
    /// Unsaved edits of the Ukeplan page while another page is shown.
    var scheduleDraft: ScheduleDraft?
    /// Prices from now on with the estimate after the published ones (Prognose).
    var priceOutlook: PriceOutlook?
    /// Expected use and cost per forecast day from tomorrow (Prognose).
    var dailyOutlook: [DayOutlook] = []
    /// The whole stored forecast from this hour (up to nine days; Prognose).
    var longForecast: [ForecastHour] = []
    /// Price control (Prognose → Prisstyring); runs on the poll tick.
    let priceControl: PriceControlRunner
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
        appearance = environment["VARMEPUMPE_APPEARANCE"].flatMap(AppAppearance.init(rawValue:))
            ?? UserDefaults.standard.string(forKey: AppAppearance.defaultsKey).flatMap(AppAppearance.init(rawValue:))
            ?? .system
        priceControl = PriceControlRunner(service: service)
        if let service {
            debouncer = ChangeDebouncer(
                send: { [weak self] changes in
                    let outcomes = try await service.apply(changes, source: .app, reason: ChangeDebouncer.reason)
                    // A setpoint the user chose becomes price control's comfort temperature.
                    for case .temperature(let value) in changes where outcomes.contains(where: { $0.result == .ok }) {
                        await self?.priceControl.userChangedSetpoint(value)
                    }
                    await self?.afterSend()
                    return outcomes
                },
                budget: { try await service.writeBudget() })
        }
        priceControl.afterChange = { [weak self] in await self?.afterPriceControl() }
    }

    /// After a price-control tick or switch: the state the write reported, and (outside a poll,
    /// which reloads anyway) the change log and the rest.
    private func afterPriceControl() async {
        guard let service else { return }
        if let cached = try? await service.cachedState(), cached != stateResult?.state {
            stateResult?.state = cached
            debouncer?.updateLive(cached)
        }
        if !isRefreshing { await reloadLocal() }
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
        let keychain = service?.credentials as? KeychainCredentialStore
        // The permission prompt waits for the user; it must not hold up the first refresh.
        Task { [notifier] in await notifier.requestPermissionOnce() }
        pollTask = Task { [weak self] in
            // Once per install, before anything reads the keychain: items from older versions get
            // the ACL shared with the helper (a read during the swap could miss an item).
            if let keychain { await Task.detached { keychain.migrateAccessIfNeeded() }.value }
            await self?.checkTibberToken()
            if let service = self?.service, service.isDemo { try? await service.seedDemoHistoryIfNeeded() }
            await self?.priceControl.load()
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

    /// True while price control is on: closing the window keeps the app and its polling running.
    var keepsRunningInBackground: Bool { priceControl.enabled }

    /// Stops polling (window closed / app quitting). The app only polls while open, unless price
    /// control is on.
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
        // Forecast (hourly at most, only when MET's copy expired), Tibber house use (hourly, only
        // with a token), away settings (hourly) and the weekly timer (6-hourly).
        let weather = try? await service.syncWeather()
        weatherMessage = weather?.status == .failed || weather?.status == .noLocation ? weather?.message : nil
        if hasTibberToken || isDemo { _ = try? await service.syncHouseConsumption() }
        if stateResult?.state != nil {
            _ = try? await service.awaySettings()
            _ = try? await service.weeklyTimer()
        }
        // Local adapter: one read per poll at most (the service enforces 20 s spacing and back-off).
        if (try? await service.localSettings())?.enabled == true { _ = try? await service.liveStatus(maxAge: 50) }
        await priceControl.tick()
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
            let hourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            let weather = try await service.weatherForecast(from: hourStart, to: hourStart.addingTimeInterval(48 * 3600))
            forecast = weather.hours
            weatherLocation = weather.location
            weatherFetchedAt = weather.fetchedAt
            weatherSettings = try await service.weatherSettings()
            tomorrow = try await service.tomorrowEstimate()
            away = try await service.storedAwaySettings()
            if let until = try await service.endpointRefusedUntil(HeatPumpService.awayFetchKey) {
                away?.refusedUntil = until
            }
            weeklyTimer = try await service.storedWeeklyTimer()
            timerRefusedUntil = try await service.endpointRefusedUntil(HeatPumpService.timerFetchKey)
            priceOutlook = try await service.priceOutlook()
            dailyOutlook = try await service.dailyOutlook()
            longForecast = try await service.weatherForecast(from: hourStart, to: hourStart.addingTimeInterval(10 * 86_400)).hours
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

    /// The house and the heat pump per hour and day (Tibber), for Energi og kostnad.
    func houseShare(range: HistoryRange) async -> HouseShareSummary? {
        guard let service else { return nil }
        let to = Date()
        // Yesterday is always included so the KPI can be shown for every range.
        let from = min(range.start(now: to), Calendar.current.startOfDay(for: to).addingTimeInterval(-86_400))
        guard let summary = try? await service.houseShare(from: from, to: to), !summary.hours.isEmpty else { return nil }
        return summary
    }

    /// Stretches of running, rest and defrost from local readings (not for 1 år: too many).
    /// Longer ranges are downsampled to the dominant kind per bucket (≥ 10 minutes, at most about
    /// a thousand buckets) so Drift draws a few hundred rectangles, not thousands.
    func phaseSpans(range: HistoryRange) async -> [LocalPhaseSpan] {
        guard let service, range != .year else { return [] }
        let to = Date()
        let resolution = range == .day ? 0 : max(600, range.seconds / 1000)
        return (try? await service.localPhaseSpans(from: range.start(now: to), to: to, resolution: resolution)) ?? []
    }

    /// Exact defrost stretches for the Effekt chart (a few per day).
    func defrostSpans(range: HistoryRange) async -> [LocalPhaseSpan] {
        guard let service, range != .year else { return [] }
        let to = Date()
        return ((try? await service.localPhaseSpans(from: range.start(now: to), to: to)) ?? []).filter { $0.kind == .defrost }
    }

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
            case .failed: return (false, sync.message ?? "Lagret, men varselet kunne ikke hentes.")
            case .skipped:
                let when = sync.nextAllowed.map { " kl. \(Format.hour($0))" } ?? " snart"
                return (true, "Lagret. Nytt varsel hentes\(when).")
            case .fetched, .notModified: return (true, "Lagret, og varselet er oppdatert.")
            case .upToDate, .noLocation: return (true, "Lagret.")
            }
        } catch {
            return (false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: Away

    /// Sends a frost-protection or holiday-mode change after the user confirmed it in a sheet.
    /// Returns whether it was sent and a Norwegian message (also for unexpected errors).
    func applyAway(_ change: AwayChange) async -> (ok: Bool, message: String) {
        guard let service else { return (false, startupError ?? "Appen kunne ikke starte.") }
        let result: (Bool, String)
        do {
            let outcome = try await service.applyAway(change, source: .app, reason: "Endret i appen (Borte hjemmefra)")
            result = (outcome.result == .ok, outcome.message)
        } catch {
            result = (false, "Endringen kunne ikke behandles: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
        await reloadLocal()
        await debouncer?.refreshBudget()
        return result
    }

    /// Reads frost protection and holiday mode (MELCloud at most hourly; `manual` = "Prøv igjen").
    func loadAway(manual: Bool = false) async {
        guard let service else { return }
        do {
            away = try await service.awaySettings(manual: manual)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// When MELCloud refused to let the account read the weekly timer (reads paused until then).
    var timerRefusedUntil: Date?

    /// The Ukeplan page: reads the plan when the cached copy is older than 10 minutes (blocks and a
    /// refusal pause still apply), so editing starts from a fresh plan.
    func loadWeeklyTimerForEditing() async {
        guard let service else { return }
        if let timer = try? await service.weeklyTimer(maxAge: HeatPumpService.timerManualInterval) { weeklyTimer = timer }
        timerRefusedUntil = try? await service.endpointRefusedUntil(HeatPumpService.timerFetchKey)
    }

    /// "Hent ukeplan nå": at most every 10 minutes; lifts a refusal pause.
    func refreshWeeklyTimer() async {
        guard let service else { return }
        weeklyTimer = try? await service.weeklyTimer(manual: true)
        timerRefusedUntil = try? await service.endpointRefusedUntil(HeatPumpService.timerFetchKey)
    }

    /// Saves the edited weekly timer in MELCloud after the user confirmed the differences. `base` is
    /// the plan the edit started from; nothing is sent if MELCloud's plan differs from it now.
    func saveWeeklyTimer(_ timer: WeeklyTimer, base: WeeklyTimer) async -> (ok: Bool, message: String) {
        guard let service else { return (false, startupError ?? "Appen kunne ikke starte.") }
        let result: (Bool, String)
        do {
            let outcome = try await service.saveWeeklyTimer(timer, base: base, source: .app, reason: "Endret i appen (Ukeplan)")
            result = (outcome.result == .ok, outcome.message)
        } catch {
            result = (false, "Ukeplanen kunne ikke lagres: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
        await reloadLocal()
        await debouncer?.refreshBudget()
        return result
    }

    // MARK: Firmware

    /// Wi-Fi adapter firmware and MELCloud's update status (Helse → Fastvare).
    var firmware: FirmwareStatus?

    /// Reads the firmware status (MELCloud at most every 60 s, every 15 s while an update runs;
    /// `force` = "Oppdater status"). Refreshes the device state once a running update has finished.
    func loadFirmware(force: Bool = false) async {
        guard let service else { return }
        let wasRunning = firmware?.isInProgress(now: Date()) == true
        do {
            firmware = try await service.firmwareStatus(force: force)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        if wasRunning, firmware?.phase == .complete { await refresh(force: false) }
    }

    /// Starts the waiting firmware update after the user confirmed the warnings in a sheet.
    func startFirmwareUpdate() async -> (ok: Bool, message: String) {
        await firmwareAction { try await $0.startFirmwareUpdate(source: .app, reason: "Startet i appen (Helse → Fastvare)") }
    }

    /// Cancels a running firmware update while MELCloud still allows it.
    func cancelFirmwareUpdate() async -> (ok: Bool, message: String) {
        await firmwareAction { try await $0.cancelFirmwareUpdate(source: .app, reason: "Avbrutt i appen (Helse → Fastvare)") }
    }

    private func firmwareAction(_ action: (HeatPumpService) async throws -> ChangeOutcome) async -> (ok: Bool, message: String) {
        guard let service else { return (false, startupError ?? "Appen kunne ikke starte.") }
        let result: (Bool, String)
        do {
            let outcome = try await action(service)
            result = (outcome.result == .ok, outcome.message)
        } catch {
            result = (false, "Kunne ikke behandles: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
        await loadFirmware()
        await reloadLocal()
        await debouncer?.refreshBudget()
        return result
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
        // The bucket still filling up, and buckets with only a couple of readings (the app was
        // open for a moment), are left out: a single reading would show as a spike.
        data.buckets = ((try? await service.localPowerBuckets(from: from, to: to, bucket: bucket)) ?? [])
            .filter { $0.start.addingTimeInterval(bucket) <= to && $0.count >= min(3, Int(bucket / 60)) }
        data.startsUnit = range == .year ? .day : .hour
        data.starts = range == .year
            ? data.buckets : (try? await service.localPowerBuckets(from: from, to: to, bucket: 3600)) ?? []
        data.totals = LocalPowerBucket.merged(data.starts)
        data.startsLast24h = (try? await service.localTotals(from: to.addingTimeInterval(-86_400), to: to))?.starts ?? 0
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
