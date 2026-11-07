import Foundation
import HeatPumpKit
import Integrations
import Observation
import SwiftUI

/// A device the app shows, whatever its kind. `AppModel` keeps one per enabled device and polls
/// them in turn; a kind's own model (`HeatPumpDeviceModel`, later an energy meter's) holds its
/// state and actions, and `DeviceUIRegistry` gives it its screens.
@MainActor
protocol DeviceModel: AnyObject {
    /// The hub's descriptor; nil while the device is not known yet (before the first sign-in).
    var descriptor: DeviceDescriptor? { get set }
    var kind: DeviceKind { get }
    /// The name the grouped sidebar and Home show (the user's own when set).
    var displayName: String { get }
    /// When the device's state was last fetched; the poll starts with the stalest device.
    var lastFetched: Date? { get }
    /// Credentials and state (the network part the integration's spacing limits).
    func pollState(force: Bool) async
    /// The device's slower reads (each limited by the service) after the shared syncs.
    func pollDetails() async
    /// Rereads the device's stored data (no network).
    func reloadLocal() async
    /// After the poll's reloads (change budget).
    func afterPoll() async
}

extension DeviceModel {
    var key: DeviceKey? { descriptor?.key }
}

/// One air-to-air heat pump: its service from the hub, its state, history, health, away modes,
/// weekly timer, firmware, local connection and the debouncer that sends edits. All rules
/// (caching, rate limits, validation, logging) live in HeatPumpKit.
@MainActor
@Observable
final class HeatPumpDeviceModel: DeviceModel {
    /// The device's service; nil when the database could not be opened.
    let service: HeatPumpService?
    /// The integration the device is reached through.
    let integration: any Integration
    /// Why the app could not start (the database), shown where an action fails for it.
    let startupError: String?
    var descriptor: DeviceDescriptor?
    var kind: DeviceKind { .airToAirHeatPump }
    /// The service as texts name it, e.g. "MELCloud".
    var serviceName: String { integration.displayName }
    /// The integration's error-code explanations.
    var errorCodes: any ErrorCodeExplaining { integration.errorCodes }
    /// The integration's knowledge documents.
    var knowledge: Knowledge { Knowledge(integration: integration) }

    var stateResult: StateResult?
    /// State as it should be after changes not yet confirmed by a refresh.
    var effectiveState: DeviceState?
    var health: HealthReport?
    var maintenance: [MaintenanceStatus] = []
    var errorLog: [ErrorLogEntry] = []
    var changes: [ChangeRecord] = []
    var fetchStatus: [FetchStateRow] = []
    var hasCredentials = true
    var lastError: String?
    /// Sends edits from Kontroll and the dial automatically.
    private(set) var debouncer: ChangeDebouncer?
    var today: EnergyBucket?
    var todayHourly: [HourCost] = []
    var estimatedPowerW: Double?
    /// Latest local reading from the Wi-Fi adapter and its reachability.
    var live: LiveStatus?
    /// Local readings of the last 60 minutes (power sparkline).
    var recentLocal: [LocalSample] = []
    var localSettings = LocalSettings.default
    /// The estimate for tomorrow (Overview).
    var tomorrow: TomorrowEstimate?
    /// Frost protection and holiday mode (cached; read from the cloud at most hourly).
    var away: AwaySettings?
    /// The weekly timer (cached; read at most every 6 hours).
    var weeklyTimer: WeeklyTimer?
    /// When the cloud refused to let the account read the weekly timer (reads paused until then).
    var timerRefusedUntil: Date?
    /// Unsaved edits of the Ukeplan page while another page is shown.
    var scheduleDraft: ScheduleDraft?
    /// Expected use and cost per forecast day from tomorrow (Prognose).
    var dailyOutlook: [DayOutlook] = []
    /// Wi-Fi adapter firmware and the cloud's update status (Health → Firmware).
    var firmware: FirmwareStatus?
    /// Bumped after every reload so views can refetch derived data (charts).
    var revision = 0

    /// Called with a setpoint the user chose (price control's comfort temperature).
    @ObservationIgnored var onUserSetpoint: (@MainActor (Double) async -> Void)?
    /// Called after a firmware update finished, so the app refreshes (state and the rest).
    @ObservationIgnored var onNeedsRefresh: (@MainActor () async -> Void)?

    init(service: HeatPumpService?, integration: any Integration, startupError: String? = nil, descriptor: DeviceDescriptor? = nil) {
        self.service = service
        self.integration = service?.integration ?? integration
        self.startupError = startupError
        self.descriptor = descriptor
        if let service {
            debouncer = ChangeDebouncer(
                send: { [weak self] changes in
                    let outcomes = try await service.apply(changes, source: .app, reason: ChangeDebouncer.reason)
                    // A setpoint the user chose becomes price control's comfort temperature.
                    for case .temperature(let value) in changes where outcomes.contains(where: { $0.result == .ok }) {
                        await self?.onUserSetpoint?(value)
                    }
                    await self?.afterSend()
                    return outcomes
                },
                budget: { try await service.writeBudget() })
        }
    }

    var state: DeviceState? { stateResult?.state }

    /// The device as today's single-device screens name it (the cloud's name).
    var deviceName: String { state?.name ?? String(localized: "Heat pump") }

    var displayName: String { descriptor?.name ?? deviceName }

    var lastFetched: Date? { state?.fetchedAt }

    /// True while a sent change is not yet reflected in fresh data from the unit.
    var isAwaitingConfirmation: Bool {
        guard let state else { return false }
        if state.hasPendingCommand { return true }
        guard let effectiveState else { return false }
        return ControlSettings(effectiveState) != ControlSettings(state)
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

    /// After a price-control tick or switch: the state the write reported.
    func takeCachedState() async {
        guard let service else { return }
        if let cached = try? await service.cachedState(), cached != stateResult?.state {
            stateResult?.state = cached
            debouncer?.updateLive(cached)
        }
    }

    // MARK: Polling

    /// Asks the service for state (cache unless old; it enforces the 60 s / block rules) and
    /// syncs history (hourly-limited by the service).
    func pollState(force: Bool) async {
        guard let service else { return }
        hasCredentials = await service.hasCredentials()
        do {
            stateResult = try await service.currentState(force: force)
            debouncer?.updateLive(stateResult?.state)
            if stateResult?.state != nil { _ = try await service.syncHistory() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Away settings (hourly), the weekly timer (6-hourly) and one local adapter read per poll at
    /// most (the service enforces 20 s spacing and back-off).
    func pollDetails() async {
        guard let service else { return }
        if stateResult?.state != nil {
            _ = try? await service.awaySettings()
            _ = try? await service.weeklyTimer()
        }
        if (try? await service.localSettings())?.enabled == true { _ = try? await service.liveStatus(maxAge: 50) }
    }

    func afterPoll() async {
        await debouncer?.refreshBudget()
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
            let now = Date()
            let calendar = Calendar.current
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
            tomorrow = try await service.tomorrowEstimate()
            away = try await service.storedAwaySettings()
            if let until = try await service.endpointRefusedUntil(HeatPumpService.awayFetchKey) {
                away?.refusedUntil = until
            }
            weeklyTimer = try await service.storedWeeklyTimer()
            timerRefusedUntil = try await service.endpointRefusedUntil(HeatPumpService.timerFetchKey)
            dailyOutlook = try await service.dailyOutlook()
        } catch {
            lastError = error.localizedDescription
        }
        revision += 1
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
            data.fromService = history.fromService
        }
        data.power = (try? await service.history(metric: .power, from: from, to: end)) ?? []
        data.modes = (try? await service.history(metric: .mode, from: from, to: end)) ?? []
        return data
    }

    /// Energy for the range (per hour for 24 h, per day for 7/30 d, per month for 1 yr) and the
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

    /// The house and the heat pump per hour and day (Tibber), for Energi og kostnad.
    func houseShare(range: HistoryRange) async -> HouseShareSummary? {
        guard let service else { return nil }
        let to = Date()
        // Yesterday is always included so the KPI can be shown for every range.
        let from = min(range.start(now: to), Calendar.current.startOfDay(for: to).addingTimeInterval(-86_400))
        guard let summary = try? await service.houseShare(from: from, to: to), !summary.hours.isEmpty else { return nil }
        return summary
    }

    /// Stretches of running, rest and defrost from local readings (not for 1 yr: too many).
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

    // MARK: Away

    /// Sends a frost-protection or holiday-mode change after the user confirmed it in a sheet.
    /// Returns whether it was sent and a message (also for unexpected errors).
    func applyAway(_ change: AwayChange) async -> (ok: Bool, message: String) {
        guard let service else { return (false, startupError ?? String(localized: "The app could not start.")) }
        let result: (Bool, String)
        do {
            let outcome = try await service.applyAway(change, source: .app, reason: String(localized: "Changed in the app (Away)"))
            result = (outcome.result == .ok, outcome.message)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            result = (false, String(localized: "The change could not be processed: \(detail)"))
        }
        await reloadLocal()
        await debouncer?.refreshBudget()
        return result
    }

    /// Reads frost protection and holiday mode (the cloud at most hourly; `manual` = "Try Again").
    func loadAway(manual: Bool = false) async {
        guard let service else { return }
        do {
            away = try await service.awaySettings(manual: manual)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Weekly timer

    /// The Ukeplan page: reads the plan when the cached copy is older than 10 minutes (blocks and a
    /// refusal pause still apply), so editing starts from a fresh plan.
    func loadWeeklyTimerForEditing() async {
        guard let service else { return }
        if let timer = try? await service.weeklyTimer(maxAge: HeatPumpService.timerManualInterval) { weeklyTimer = timer }
        timerRefusedUntil = try? await service.endpointRefusedUntil(HeatPumpService.timerFetchKey)
    }

    /// "Fetch Now" (weekly schedule): at most every 10 minutes; lifts a refusal pause.
    func refreshWeeklyTimer() async {
        guard let service else { return }
        weeklyTimer = try? await service.weeklyTimer(manual: true)
        timerRefusedUntil = try? await service.endpointRefusedUntil(HeatPumpService.timerFetchKey)
    }

    /// Saves the edited weekly timer after the user confirmed the differences. `base` is the plan
    /// the edit started from; nothing is sent if the cloud's plan differs from it now.
    func saveWeeklyTimer(_ timer: WeeklyTimer, base: WeeklyTimer) async -> (ok: Bool, message: String) {
        guard let service else { return (false, startupError ?? String(localized: "The app could not start.")) }
        let result: (Bool, String)
        do {
            let outcome = try await service.saveWeeklyTimer(timer, base: base, source: .app, reason: String(localized: "Changed in the app (Weekly schedule)"))
            result = (outcome.result == .ok, outcome.message)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            result = (false, String(localized: "The weekly schedule could not be saved: \(detail)"))
        }
        await reloadLocal()
        await debouncer?.refreshBudget()
        return result
    }

    // MARK: Firmware

    /// Reads the firmware status (the cloud at most every 60 s, every 15 s while an update runs;
    /// `force` = "Refresh Status"). Refreshes the device state once a running update has finished.
    func loadFirmware(force: Bool = false) async {
        guard let service else { return }
        let wasRunning = firmware?.isInProgress(now: Date()) == true
        do {
            firmware = try await service.firmwareStatus(force: force)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        if wasRunning, firmware?.phase == .complete { await onNeedsRefresh?() }
    }

    /// Starts the waiting firmware update after the user confirmed the warnings in a sheet.
    func startFirmwareUpdate() async -> (ok: Bool, message: String) {
        await firmwareAction { try await $0.startFirmwareUpdate(source: .app, reason: String(localized: "Started in the app (Health → Firmware)")) }
    }

    /// Cancels a running firmware update while the cloud still allows it.
    func cancelFirmwareUpdate() async -> (ok: Bool, message: String) {
        await firmwareAction { try await $0.cancelFirmwareUpdate(source: .app, reason: String(localized: "Canceled in the app (Health → Firmware)")) }
    }

    private func firmwareAction(_ action: (HeatPumpService) async throws -> ChangeOutcome) async -> (ok: Bool, message: String) {
        guard let service else { return (false, startupError ?? String(localized: "The app could not start.")) }
        let result: (Bool, String)
        do {
            let outcome = try await action(service)
            result = (outcome.result == .ok, outcome.message)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            result = (false, String(localized: "Could not be processed: \(detail)"))
        }
        await loadFirmware()
        await reloadLocal()
        await debouncer?.refreshBudget()
        return result
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

    /// Saves the local settings. Returns an error message, or nil.
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
            ?? LocalTestResult(ok: false, message: String(localized: "The test could not be run."), sample: nil)
        await reloadLocal()
        return result
    }

    func discoverLocal() async -> LocalDiscoveryResult {
        guard let service else { return LocalDiscoveryResult(host: nil, message: startupError ?? "") }
        let result = (try? await service.discoverLocal())
            ?? LocalDiscoveryResult(host: nil, message: String(localized: "The search could not be run."))
        localSettings = (try? await service.localSettings()) ?? localSettings
        await reloadLocal()
        return result
    }

    // MARK: Actions

    /// Returns an error message, or nil on success.
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

    /// E-mail of the stored account (reads the keychain; call from Settings only).
    func accountEmail() async -> String? {
        await service?.accountEmail()
    }
}

/// One energy meter (the house's): today's use and cost, the hours and days, and live power
/// while the app runs. All rules (spacing, pricing, the live connection) live in HeatPumpKit.
@MainActor
@Observable
final class EnergyMeterDeviceModel: DeviceModel {
    let service: EnergyMeterService
    var descriptor: DeviceDescriptor?
    var kind: DeviceKind { .energyMeter }
    /// The meter's service as texts name it, e.g. "Tibber".
    var serviceName: String { service.serviceName }
    var displayName: String { descriptor?.name ?? serviceName }
    var hasLivePower: Bool { descriptor?.capabilities.contains(.livePower) == true }

    var status: MeterStatus?
    /// Live minutes of the last hour (the trend).
    var recentMinutes: [LiveMinute] = []
    /// The newest reading of this run's live stream.
    var liveReading: LivePowerReading?
    var liveState: LivePowerState?
    var hasCredentials = true
    /// Why the hours could not be fetched (named after the service), or nil.
    var syncProblem: String?
    var lastSync: Date?
    /// Bumped after every reload so views can refetch derived data (charts).
    var revision = 0

    @ObservationIgnored private var liveTask: Task<Void, Never>?

    init(service: EnergyMeterService, descriptor: DeviceDescriptor?) {
        self.service = service
        self.descriptor = descriptor
    }

    var lastFetched: Date? { lastSync }

    // MARK: Polling

    /// The hours (at most hourly; the service enforces it).
    func pollState(force: Bool) async {
        hasCredentials = await service.hasCredentials()
        guard hasCredentials else { return }
        do {
            let sync = try await service.syncHours()
            syncProblem = sync.status == .failed ? sync.message : nil
        } catch {
            syncProblem = service.describe(error)
        }
    }

    func pollDetails() async {}

    func afterPoll() async {}

    func reloadLocal() async {
        let now = Date()
        status = (try? await service.status()) ?? status
        recentMinutes = (try? await service.liveMinutes(from: now.addingTimeInterval(-3600), to: now)) ?? recentMinutes
        lastSync = (try? await service.lastHourSync()) ?? lastSync
        if (try? await service.credentialsRejected()) == true {
            syncProblem = service.describe(HeatPumpError.credentialsRejected)
        }
        revision += 1
    }

    // MARK: Live power

    /// Starts the live stream when the meter has one (the app runs and the meter is on); a
    /// second call does nothing.
    func startLive() {
        guard hasLivePower, liveTask == nil else { return }
        let service = service
        liveTask = Task { [weak self] in
            for await event in await service.live() {
                guard let self else { return }
                switch event {
                case .reading(let reading): self.liveReading = reading
                case .state(let state): self.liveState = state
                }
            }
        }
    }

    /// Stops the stream (the Mac sleeps, polling stops, the meter is turned off).
    func stopLive() {
        liveTask?.cancel()
        liveTask = nil
    }

    /// The live reading when it is recent (younger than 2 minutes), else nil.
    var currentReading: LivePowerReading? {
        guard let reading = liveReading, Date().timeIntervalSince(reading.at) < 120 else { return nil }
        return reading
    }

    /// Power now: this run's newest reading, else the newest stored minute when recent.
    var powerNowW: Double? {
        if let reading = currentReading { return reading.powerW }
        guard let minute = status?.live, Date().timeIntervalSince(minute.lastReading) < 120 else { return nil }
        return minute.powerW
    }

    /// Why live power is off, when it stopped for good.
    var liveProblem: String? {
        guard case .stopped(let reason) = liveState else { return nil }
        return reason.message(serviceName: serviceName)
    }

    // MARK: Data for views

    func hourly(from: Date, to: Date) async -> [HourCost] {
        (try? await service.hourly(from: from, to: to)) ?? []
    }

    func daily(from: Date, to: Date) async -> [MeterPeriod] {
        (try? await service.daily(from: from, to: to)) ?? []
    }
}

/// One air quality sensor: its newest values with levels and findings, the history for its
/// charts and whether a high long-term radon average is notified. All rules (spacing, levels,
/// findings) live in HeatPumpKit (`AirQualityService`).
@MainActor
@Observable
final class AirQualityDeviceModel: DeviceModel {
    let service: AirQualityService
    var descriptor: DeviceDescriptor?
    var kind: DeviceKind { .airQualitySensor }
    /// The sensor's service as texts name it.
    var serviceName: String { service.serviceName }
    var displayName: String { descriptor?.name ?? serviceName }
    /// The integration's knowledge documents.
    var knowledge: Knowledge { Knowledge(integration: service.integration) }

    var status: AirQualityStatus?
    var hasCredentials = true
    /// Why the values could not be fetched (named after the service), or nil.
    var syncProblem: String?
    var lastSync: Date?
    var radonAlerts = false
    /// Bumped after every reload so views can refetch derived data (charts).
    var revision = 0

    init(service: AirQualityService, descriptor: DeviceDescriptor?) {
        self.service = service
        self.descriptor = descriptor
    }

    var lastFetched: Date? { lastSync }

    // MARK: Polling

    /// The newest values of every sensor of the integration (at most every 5 minutes; the
    /// service enforces it, so the integration's other sensors find them fetched).
    func pollState(force: Bool) async {
        hasCredentials = await service.hasCredentials()
        guard hasCredentials else { return }
        do {
            let sync = try await service.syncLatest()
            syncProblem = sync.status == .failed ? sync.message : nil
        } catch {
            syncProblem = service.describe(error)
        }
    }

    /// Thresholds (daily) and the hourly history (hourly).
    func pollDetails() async {
        guard hasCredentials else { return }
        _ = try? await service.syncThresholds()
        _ = try? await service.syncHistory()
    }

    func afterPoll() async {}

    func reloadLocal() async {
        status = (try? await service.status()) ?? status
        lastSync = (try? await service.lastSync()) ?? lastSync
        radonAlerts = (try? await service.radonAlertsEnabled()) ?? radonAlerts
        if (try? await service.credentialsRejected()) == true {
            syncProblem = service.describe(HeatPumpError.credentialsRejected)
        }
        revision += 1
    }

    // MARK: Actions

    func setRadonAlerts(_ enabled: Bool) async {
        radonAlerts = enabled
        try? await service.setRadonAlerts(enabled)
    }

    // MARK: Data for views

    func hours(from: Date, to: Date) async -> [AirQualityHour] {
        (try? await service.hours(from: from, to: to)) ?? []
    }

    func thresholds() async -> AirQualityThresholds {
        (try? await service.thresholds()) ?? .standard
    }
}
