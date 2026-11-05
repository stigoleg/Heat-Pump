import Foundation
import Observation

/// What the auto-send status chip shows.
public enum AutoSendStatus: Sendable, Equatable {
    case idle
    /// Edited, waiting for the user to stop (2 s).
    case edited
    /// Kept as a draft until a write is allowed again.
    case waiting(String, retryAt: Date?)
    case sending
    /// Sent; the unit has not confirmed yet.
    case sent
    /// The next state from the unit matches what was sent.
    case confirmed
    case failed(String)

    /// Norwegian chip text.
    public var text: String {
        switch self {
        case .idle: ""
        case .edited: "Endret…"
        case .waiting(let reason, _): "Venter – \(reason)"
        case .sending: "Sender…"
        case .sent: "Sendt – venter på pumpen"
        case .confirmed: "Bekreftet"
        case .failed(let reason): "Feil: \(reason)"
        }
    }
}

/// Collects edits from the controls into one draft and sends it automatically 2 s after the
/// last edit (sliders and dials: after release). Fields are coalesced into one
/// `apply([DeviceChange], source: .app, …)`; an edit back to the current value drops the field.
/// The 5 s spacing and 12-per-hour budget are respected: when no write is allowed the draft is
/// kept as "venter" and sent when it is.
@MainActor
@Observable
public final class ChangeDebouncer {
    public static let reason = "Endret i appen"

    public private(set) var edits = ControlEdits()
    public private(set) var status: AutoSendStatus = .idle
    /// Writes left this rolling hour (from the service), when known.
    public private(set) var remainingThisHour: Int?
    public private(set) var lastOutcomes: [ChangeOutcome] = []

    public let delay: TimeInterval
    @ObservationIgnored private var live: DeviceState?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var sentChanges: [DeviceChange] = []
    @ObservationIgnored private var isSending = false
    @ObservationIgnored private let send: @Sendable ([DeviceChange]) async throws -> [ChangeOutcome]
    @ObservationIgnored private let budget: @Sendable () async throws -> WriteBudget
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(
        delay: TimeInterval = 2,
        send: @escaping @Sendable ([DeviceChange]) async throws -> [ChangeOutcome],
        budget: @escaping @Sendable () async throws -> WriteBudget,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds(max(0, $0))) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.delay = delay
        self.send = send
        self.budget = budget
        self.sleep = sleep
        self.now = now
    }

    /// Debouncer that sends through `service` as source `app`.
    public convenience init(service: HeatPumpService, delay: TimeInterval = 2) {
        self.init(
            delay: delay,
            send: { changes in try await service.apply(changes, source: .app, reason: ChangeDebouncer.reason) },
            budget: { try await service.writeBudget() })
    }

    /// Live settings with the draft on top (what the controls show).
    public var displayed: ControlSettings? { live.map { edits.displayed(over: ControlSettings($0)) } }
    public var hasDraft: Bool { !edits.isEmpty }

    /// New state from the unit: drops draft fields it already has and confirms a sent change.
    public func updateLive(_ state: DeviceState?) {
        live = state
        guard let state else { return }
        if status == .sent, !state.hasPendingCommand, sentChanges.allSatisfy({ $0.applied(to: state) == state }) {
            status = .confirmed
        }
        prune(against: state)
        if edits.isEmpty, status == .edited {
            timer?.cancel()
            status = .idle
        }
    }

    /// Records an edit. Pass `commit: false` while a slider or dial is being dragged; call
    /// `commit()` on release to start the 2 s timer.
    public func edit(_ change: DeviceChange, commit: Bool = true) {
        guard let live else { return }
        switch change {
        case .power(let on):
            edits.power = on
            // MELCloud refuses a write without a valid mode; turning on picks Varme then.
            if on, live.mode == nil, edits.mode == nil { edits.mode = .heat }
        case .mode(let mode):
            edits.mode = mode
            edits.clampSetpoint(over: ControlSettings(live), limits: live.limits, step: live.temperatureIncrement)
        case .temperature(let celsius): edits.setTemperature = celsius
        case .fanSpeed(let speed): edits.fanSpeed = speed
        case .vaneVertical(let vane): edits.vaneVertical = vane
        case .vaneHorizontal(let vane): edits.vaneHorizontal = vane
        }
        prune(against: live)
        guard !edits.isEmpty else {
            timer?.cancel()
            if status == .edited || isWaiting { status = .idle }
            return
        }
        if !isSending { status = .edited }
        if commit { schedule(after: delay) } else { timer?.cancel() }
    }

    /// Starts the send timer for the current draft (after a slider/dial is released).
    public func commit() {
        guard !edits.isEmpty else { return }
        schedule(after: delay)
    }

    /// Sends the draft now (also used by tests instead of waiting for the timer).
    public func flush() async {
        timer?.cancel()
        timer = nil
        await fire()
    }

    /// Updates the remaining-writes counter without sending.
    public func refreshBudget() async {
        remainingThisHour = (try? await budget())?.remaining
    }

    // MARK: Internals

    private var isWaiting: Bool {
        if case .waiting = status { return true }
        return false
    }

    private func prune(against state: DeviceState) {
        var pruned = edits
        pruned.prune(against: ControlSettings(state))
        // With no known mode, ControlSettings assumes Varme; keep an explicit mode edit.
        if state.mode == nil { pruned.mode = edits.mode }
        edits = pruned
    }

    private func schedule(after seconds: TimeInterval) {
        timer?.cancel()
        let sleep = self.sleep
        timer = Task { [weak self] in
            do { try await sleep(seconds) } catch { return }
            await self?.fire()
        }
    }

    private func fire() async {
        guard !isSending, !edits.isEmpty, live != nil else { return }
        if let b = try? await budget() {
            remainingThisHour = b.remaining
            if let next = b.nextAllowed, next > now() {
                let reason =
                    b.remaining <= 0
                    ? "maks \(ChangeBudget.maxChangesPerHour) endringer per time er brukt. Sendes kl. \(Norwegian.time(next))."
                    : "sendes om noen sekunder."
                status = .waiting(reason, retryAt: next)
                schedule(after: next.timeIntervalSince(now()) + 0.2)
                return
            }
        }
        let draft = edits
        let changes = draft.allChanges
        edits = ControlEdits()
        isSending = true
        status = .sending
        defer { isSending = false }
        do {
            let outcomes = try await send(changes)
            lastOutcomes = outcomes
            if !outcomes.isEmpty, outcomes.allSatisfy({ $0.result == .ok }) {
                sentChanges = changes
                status = .sent
            } else if let retry = outcomes.compactMap(\.nextAllowed).max() {
                // Not allowed yet (budget or spacing): keep the draft; newer edits win.
                edits = draft.merging(edits)
                status = .waiting("sendes kl. \(Norwegian.time(retry)).", retryAt: retry)
                schedule(after: max(0.2, retry.timeIntervalSince(now()) + 0.2))
            } else {
                let failure = outcomes.first { $0.result != .ok }
                status = .failed(failure.map(Self.reasonText) ?? "Ingen endring ble sendt.")
            }
        } catch {
            status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        remainingThisHour = (try? await budget())?.remaining
        if !edits.isEmpty, !isWaiting {
            status = .edited
            schedule(after: delay)
        }
    }

    private static func reasonText(_ outcome: ChangeOutcome) -> String {
        for prefix in ["Ikke sendt: ", "Endringen feilet: "] where outcome.message.hasPrefix(prefix) {
            return String(outcome.message.dropFirst(prefix.count))
        }
        return outcome.message
    }
}

extension ControlEdits {
    /// Every edited field as a change (also fields equal to some default).
    public var allChanges: [DeviceChange] {
        var result: [DeviceChange] = []
        if let power { result.append(.power(power)) }
        if let mode { result.append(.mode(mode)) }
        if let setTemperature { result.append(.temperature(setTemperature)) }
        if let fanSpeed { result.append(.fanSpeed(fanSpeed)) }
        if let vaneVertical { result.append(.vaneVertical(vaneVertical)) }
        if let vaneHorizontal { result.append(.vaneHorizontal(vaneHorizontal)) }
        return result
    }

    /// `other`'s fields win over these.
    public func merging(_ other: ControlEdits) -> ControlEdits {
        var merged = self
        if let v = other.power { merged.power = v }
        if let v = other.mode { merged.mode = v }
        if let v = other.setTemperature { merged.setTemperature = v }
        if let v = other.fanSpeed { merged.fanSpeed = v }
        if let v = other.vaneVertical { merged.vaneVertical = v }
        if let v = other.vaneHorizontal { merged.vaneHorizontal = v }
        return merged
    }
}
