import Foundation
import HeatPumpKit
import Observation

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
        case .overview: "house"
        case .control: "slider.horizontal.3"
        case .history: "chart.xyaxis.line"
        case .health: "heart.text.square"
        case .activity: "sparkles"
        }
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: "24 t"
        case .week: "7 d"
        case .month: "30 d"
        }
    }
    var seconds: TimeInterval {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
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
    var temperatures: [SeriesPoint] = []
    var power: [HistoryPoint] = []
    var modes: [HistoryPoint] = []
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
            while !Task.isCancelled {
                await self?.refresh(force: false)
                try? await Task.sleep(for: .seconds(60))
            }
        }
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
            if stateResult?.state != nil { _ = try await service.syncHistory() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await reloadLocal()
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

    func history(range: HistoryRange) async -> HistoryData {
        guard let service else { return HistoryData() }
        let to = Date()
        let from = to.addingTimeInterval(-range.seconds)
        var data = HistoryData()
        let series: [(HistoryMetric, String)] = [
            (.roomTemperature, "Inne"), (.outdoorTemperature, "Ute"), (.setTemperature, "Ønsket"),
        ]
        for (metric, name) in series {
            let points = (try? await service.history(metric: metric, from: from, to: to)) ?? []
            data.temperatures += points.compactMap { p in p.value.map { SeriesPoint(date: p.timestamp, value: $0, series: name) } }
        }
        data.power = (try? await service.history(metric: .power, from: from, to: to)) ?? []
        data.modes = (try? await service.history(metric: .mode, from: from, to: to)) ?? []
        return data
    }

    func energy(period: EnergyPeriod) async -> [EnergyBucket] {
        guard let service else { return [] }
        let to = Date()
        let days: Double =
            switch period {
            case .day: 30
            case .week: 12 * 7
            case .month: 365
            }
        return (try? await service.energy(period: period, from: to.addingTimeInterval(-days * 86_400), to: to)) ?? []
    }

    // MARK: Actions

    func send(_ changes: [DeviceChange]) async -> [ChangeOutcome] {
        guard let service else { return [] }
        do {
            let outcomes = try await service.apply(changes, source: .app, reason: "Endret i appen")
            await reloadLocal()
            return outcomes
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

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
            if let next = result.nextRefreshAllowed {
                return (false, "Innloggingen er lagret, men status kan hentes tidligst \(Norwegian.time(next)) (maks én gang i minuttet).")
            }
            if let until = result.blockedUntil {
                return (false, HeatPumpError.blocked(until: until).errorDescription ?? "")
            }
            return (false, result.error ?? "Ukjent feil ved innlogging.")
        } catch {
            return (false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
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
