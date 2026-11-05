import AppKit
import HeatPumpKit
import Observation

/// Runs price control in the app: one service tick per poll, restore before sleep and on quit,
/// and an activity that keeps App Nap from pausing the poll while it is on. The rules live in
/// HeatPumpKit (`PriceControlEngine`, `HeatPumpService.runPriceControl`).
@MainActor
@Observable
final class PriceControlRunner {
    private let service: HeatPumpService?
    private(set) var settings = PriceControlSettings.default
    private(set) var status: PriceControlStatus?
    private(set) var plan: PriceControlPlan?
    /// Outcome of the last switch on/off or settings save (Norwegian), or nil.
    var message: String?
    private(set) var isBusy = false
    /// True once the stored settings have been read (the quit-on-close choice depends on them).
    private(set) var loaded = false
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
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
                Task { await self.restore(reason: "Macen skal sove – tilbake til vanlig temperatur") }
            }
        }
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
        guard enabled, !isBusy else {
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

    /// Turns price control on or off. Off sets the base temperature back first.
    func setEnabled(_ on: Bool) async {
        guard let service, on != enabled, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if on {
                status = try await service.enablePriceControl()
                message = nil
            } else {
                let outcome = try await service.disablePriceControl()
                status = try await service.priceControlStatus()
                message = outcome.map { $0.result == .ok ? "Prisstyring er av. Temperaturen er satt tilbake." : $0.message }
                    ?? "Prisstyring er av."
            }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        settings = (try? await service.priceControlSettings()) ?? settings
        plan = try? await service.priceControlPlan()
        updateActivity()
        await afterChange?()
    }

    /// Saves reductions, minimum and pre-heating. Returns a Norwegian error, or nil.
    func save(_ new: PriceControlSettings) async -> String? {
        guard let service else { return nil }
        do {
            try await service.savePriceControlSettings(new)
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        settings = (try? await service.priceControlSettings()) ?? settings
        plan = try? await service.priceControlPlan()
        return nil
    }

    /// The user changed the setpoint in the app (Kontroll or the dial).
    func userChangedSetpoint(_ value: Double) async {
        guard enabled, let service else { return }
        try? await service.notePriceControlManualSetpoint(value)
        settings = (try? await service.priceControlSettings()) ?? settings
    }

    /// Sets the base temperature back (sleep); the next tick after waking applies the plan again.
    func restore(reason: String) async {
        guard let service else { return }
        _ = try? await service.restorePriceControl(reason: reason)
        await afterChange?()
    }

    /// Restore before quitting, waiting at most `quitTimeout`.
    func restoreBeforeQuit() async {
        guard enabled, let service else { return }
        let work = Task { _ = try? await service.restorePriceControl(reason: "appen avsluttes – tilbake til vanlig temperatur") }
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
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Prisstyring følger strømprisen")
        } else if !enabled, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
