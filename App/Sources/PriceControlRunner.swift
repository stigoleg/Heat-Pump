import AppKit
import HeatPumpKit
import Observation

/// Runs price control in the app: one service tick per poll, restore before sleep and on quit,
/// and an activity that keeps App Nap from pausing the poll while it is on. The rules live in
/// HeatPumpKit (`PriceControlEngine`, `HeatPumpService.runPriceControl`). Ticks, switching,
/// restores and the user's own setpoint run one at a time (the service is an actor, so its calls
/// would otherwise interleave at every network wait).
@MainActor
@Observable
final class PriceControlRunner {
    private let service: HeatPumpService?
    private(set) var settings = PriceControlSettings.default
    private(set) var status: PriceControlStatus?
    private(set) var plan: PriceControlPlan?
    /// Outcome of the last switch on/off or settings save, or nil.
    var message: String?
    private(set) var isBusy = false
    /// True once the stored settings have been read (the quit-on-close choice depends on them).
    private(set) var loaded = false
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
    /// The last queued piece of work; the next one waits for it.
    @ObservationIgnored private var queue: Task<Void, Never>?
    /// Called after the runner may have sent a setpoint, so the views show the new state at once.
    @ObservationIgnored var afterChange: (@MainActor () async -> Void)?

    /// Longest the app waits for the restore when quitting.
    static let quitTimeout: Duration = .seconds(5)

    var enabled: Bool { settings.enabled }

    init(service: HeatPumpService?) {
        self.service = service
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.enabled else { return }
                Task { await self.restore(reason: String(localized: "The Mac is going to sleep – back to the normal temperature")) }
            }
        }
    }

    /// Runs `work` after everything queued before it.
    @discardableResult
    private func serialized<T: Sendable>(_ work: @escaping @Sendable @MainActor () async -> T) async -> T {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        queue = Task { _ = await task.value }
        return await task.value
    }

    /// Reads settings, last status and the plan (no network).
    func load() async {
        guard let service else { return }
        settings = (try? await service.priceControlSettings()) ?? settings
        status = try? await service.priceControlStatus()
        plan = try? await service.priceControlPlan()
        loaded = true
        updateActivity()
    }

    /// One controller tick after each poll (only while on).
    func tick() async {
        guard let service else { return }
        if !loaded { await load() }
        await serialized { [self] in
            guard enabled else {
                plan = try? await service.priceControlPlan()
                return
            }
            do {
                status = try await service.runPriceControl()
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            settings = (try? await service.priceControlSettings()) ?? settings
            plan = try? await service.priceControlPlan()
            await afterChange?()
        }
    }

    /// Turns price control on or off. Off sets the base temperature back first.
    func setEnabled(_ on: Bool) async {
        guard let service, on != enabled, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await serialized { [self] in
            guard on != enabled else { return }
            do {
                if on {
                    status = try await service.enablePriceControl()
                    message = nil
                } else {
                    let outcome = try await service.disablePriceControl()
                    status = try await service.priceControlStatus()
                    message = outcome.map { $0.result == .ok ? String(localized: "Price control is off. The temperature has been restored.") : $0.message }
                        ?? String(localized: "Price control is off.")
                }
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            settings = (try? await service.priceControlSettings()) ?? settings
            plan = try? await service.priceControlPlan()
            updateActivity()
            await afterChange?()
        }
    }

    /// Saves reductions, minimum and pre-heating. Returns an error message, or nil.
    func save(_ new: PriceControlSettings) async -> String? {
        guard let service else { return nil }
        return await serialized { [self] () -> String? in
            do {
                try await service.savePriceControlSettings(new)
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            settings = (try? await service.priceControlSettings()) ?? settings
            plan = try? await service.priceControlPlan()
            return nil
        }
    }

    /// The user changed the setpoint in the app (Kontroll or the dial).
    func userChangedSetpoint(_ value: Double) async {
        guard enabled, let service else { return }
        await serialized { [self] in
            try? await service.notePriceControlManualSetpoint(value)
            settings = (try? await service.priceControlSettings()) ?? settings
        }
    }

    /// Sets the base temperature back before sleep, even over the hourly cap: the house must not
    /// stay lowered while nothing watches it. This cannot loop, because the next tick after waking
    /// does not lower again within the same clock hour.
    func restore(reason: String) async {
        guard let service else { return }
        await serialized { [self] in
            _ = try? await service.restorePriceControl(reason: reason, always: true)
            await afterChange?()
        }
    }

    /// Restore before quitting (always sent, after any tick in flight), waiting at most
    /// `quitTimeout`. Reads the settings first when the app quits before they were loaded.
    func restoreBeforeQuit() async {
        guard let service else { return }
        if !loaded { await load() }
        guard enabled else { return }
        let work = Task { @MainActor in
            await self.serialized {
                _ = try? await service.restorePriceControl(reason: String(localized: "the app is quitting – back to the normal temperature"), always: true)
            }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work.value }
            group.addTask { try? await Task.sleep(for: Self.quitTimeout) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Keeps App Nap from stretching the poll while price control is on (the Mac may still sleep).
    private func updateActivity() {
        if enabled, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Price control follows the electricity price")
        } else if !enabled, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
