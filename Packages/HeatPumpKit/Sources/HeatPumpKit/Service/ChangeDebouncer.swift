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
    /// Changes being sent or sent but not yet seen in live state. Shown and pruned against
    /// as if they were live, so edits made meanwhile are based on what was sent.
    public private(set) var inFlight = ControlEdits()
    public private(set) var status: AutoSendStatus = .idle
    /// Writes left this rolling hour (from the service), when known.
    public private(set) var remainingThisHour: Int?
    public private(set) var lastOutcomes: [ChangeOutcome] = []

    public let delay: TimeInterval
    @ObservationIgnored private var live: DeviceState?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var sentChanges: [DeviceChange] = []
    @ObservationIgnored private var isSending = false
    @ObservationIgnored private var sentAt: Date?
    /// The draft's mode was added only because power was turned on with no known mode.
    @ObservationIgnored private var impliedMode = false
    /// Longest a drag (`commit: false`) can hold back a send, in case the release is never seen.
    public static let dragFallback: TimeInterval = 10
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

    /// Live state with in-flight changes on top: the base every new edit is compared with.
    public var base: DeviceState? { live.map { s in inFlight.allChanges.reduce(s) { $1.applied(to: $0) } } }

    /// Live settings with in-flight changes and the draft on top (what the controls show).
    public var displayed: ControlSettings? { base.map { edits.displayed(over: ControlSettings($0)) } }

    /// The mode the controls should show; nil when the unit reports none and none is chosen.
    public var displayedMode: OperationMode? { edits.mode ?? base?.mode }

    public var hasDraft: Bool { !edits.isEmpty }

    /// New state from the unit: settles in-flight changes, confirms a sent change and drops
    /// draft fields the unit already has.
    public func updateLive(_ state: DeviceState?) {
        live = state
        guard let state else { return }
        let isNewer = sentAt.map { state.fetchedAt > $0 } ?? true
        if !isSending {
            if isNewer && !state.hasPendingCommand {
                // The unit has answered: live state is the truth now.
                inFlight = ControlEdits()
            } else {
                let mode = inFlight.mode
                inFlight.prune(against: ControlSettings(state))
                // With no known mode, ControlSettings assumes Varme; keep a sent mode.
                if state.mode == nil { inFlight.mode = mode }
            }
        }
        if status == .sent, isNewer, !state.hasPendingCommand, sentChanges.allSatisfy({ $0.applied(to: state) == state }) {
            status = .confirmed
        }
        prune()
        if edits.isEmpty, status == .edited {
            timer?.cancel()
            status = .idle
        }
    }

    /// Records an edit. Pass `commit: false` while a slider or dial is being dragged; call
    /// `commit()` on release to start the 2 s timer.
    public func edit(_ change: DeviceChange, commit: Bool = true) {
        guard let base else { return }
        switch change {
        case .power(let on):
            edits.power = on
            // MELCloud refuses a write without a valid mode; turning on picks Varme then.
            if on, base.mode == nil, edits.mode == nil {
                edits.mode = .heat
                impliedMode = true
            }
        case .mode(let mode):
            edits.mode = mode
            impliedMode = false
            edits.clampSetpoint(over: ControlSettings(base), limits: base.limits, step: base.temperatureIncrement)
        case .temperature(let celsius): edits.setTemperature = celsius
        case .fanSpeed(let speed): edits.fanSpeed = speed
        case .vaneVertical(let vane): edits.vaneVertical = vane
        case .vaneHorizontal(let vane): edits.vaneHorizontal = vane
        }
        prune()
        guard !edits.isEmpty else {
            timer?.cancel()
            if status == .edited || isWaiting { status = .idle }
            return
        }
        if !isSending { status = .edited }
        // While dragging the send waits for the release (commit), with a long fallback.
        schedule(after: commit ? delay : max(delay, Self.dragFallback))
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

    private func prune() {
        guard let base else { return }
        var pruned = edits
        pruned.prune(against: ControlSettings(base))
        // With no known mode, ControlSettings assumes Varme; keep an explicit mode edit.
        if base.mode == nil { pruned.mode = edits.mode }
        // A mode added only for "power on" goes when power is back to its current value.
        if impliedMode, pruned.power == nil {
            pruned.mode = nil
            impliedMode = false
        }
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
        // The draft moves to the in-flight overlay so the controls keep showing it and edits
        // made during the send are compared with it, not with the old live state.
        inFlight = inFlight.merging(draft)
        edits = ControlEdits()
        impliedMode = false
        isSending = true
        sentAt = now()
        status = .sending
        do {
            let outcomes = try await send(changes)
            isSending = false
            lastOutcomes = outcomes
            if !outcomes.isEmpty, outcomes.allSatisfy({ $0.result == .ok }) {
                sentChanges = changes
                status = .sent
                if let live { inFlight.prune(against: ControlSettings(live)) }
            } else if let retry = outcomes.compactMap(\.nextAllowed).max() {
                // Not allowed yet (budget or spacing): keep the draft; newer edits win.
                inFlight = ControlEdits()
                edits = draft.merging(edits)
                status = .waiting("sendes kl. \(Norwegian.time(retry)).", retryAt: retry)
                schedule(after: max(0.2, retry.timeIntervalSince(now()) + 0.2))
            } else {
                inFlight = ControlEdits()
                let failure = outcomes.first { $0.result != .ok }
                status = .failed(failure.map(Self.reasonText) ?? "Ingen endring ble sendt.")
            }
        } catch {
            isSending = false
            inFlight = ControlEdits()
            status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        prune()
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
